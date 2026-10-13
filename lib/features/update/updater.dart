import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models.dart';

/// Автообновление программы для Windows.
///
/// 1. Скачивает zip новой версии из приватного bucket `releases` по временной ссылке (в фоне, с прогрессом).
/// 2. Сверяет SHA-256 с `app_releases.sha256` — повреждённый или подменённый файл не ставится.
/// 3. Распаковывает во временную папку и запускает скрипт замены: он ждёт закрытия программы,
///    останавливает adb/scrcpy из папки программы, копирует новые файлы поверх и запускает программу снова.
///
/// На Android и в PWA используется [openUpdate] из update_ui.dart (установщик/браузер).
class Updater {
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// Папка программы (там лежат exe, data\, adb\, scrcpy\).
  static Directory get installDir => File(Platform.resolvedExecutable).parent;

  static Directory _work(AppRelease r) => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}nox_update_${r.buildNumber}',
  );

  /// Скачивание с прогрессом 0..1.
  static Future<File> download(
    AppRelease r,
    void Function(double progress) onProgress,
  ) async {
    final url = await Supabase.instance.client.storage
        .from('releases')
        .createSignedUrl(r.downloadPath, 3600);
    final dir = _work(r);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}update.zip');

    final client = HttpClient();
    try {
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      if (resp.statusCode != 200) {
        throw UpdateException('Сервер обновлений ответил ${resp.statusCode}');
      }
      final total = resp.contentLength > 0
          ? resp.contentLength
          : (r.sizeBytes ?? 0);
      final sink = file.openWrite();
      var done = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0) onProgress((done / total).clamp(0, 1).toDouble());
      }
      await sink.close();
    } finally {
      client.close();
    }
    return file;
  }

  /// Проверка контрольной суммы. Без суммы в базе обновление не ставится.
  static Future<void> verify(File file, String? expected) async {
    if (expected == null || expected.isEmpty) {
      throw UpdateException('Для этой версии не указана контрольная сумма');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != expected.toLowerCase()) {
      throw UpdateException(
        'Файл обновления повреждён (контрольная сумма не совпала)',
      );
    }
  }

  /// Распаковка. Возвращает папку, где лежит exe новой версии.
  static Future<Directory> extract(File zip, AppRelease r) async {
    final out = Directory('${_work(r).path}${Platform.pathSeparator}new');
    if (await out.exists()) await out.delete(recursive: true);
    await extractFileToDisk(zip.path, out.path);
    final exeName = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last;
    if (await File('${out.path}${Platform.pathSeparator}$exeName').exists()) {
      return out;
    }
    // Архив мог быть упакован с корневой папкой.
    await for (final e in out.list()) {
      if (e is Directory &&
          await File('${e.path}${Platform.pathSeparator}$exeName').exists()) {
        return e;
      }
    }
    throw UpdateException('В архиве обновления нет $exeName');
  }

  /// Скрипт замены файлов (только ASCII: пути передаются параметрами, кириллица в путях не ломается).
  static const _applyScript = r'''
param([int]$ParentPid, [string]$Src, [string]$Dst, [string]$Exe)
$ErrorActionPreference = 'SilentlyContinue'
try { Wait-Process -Id $ParentPid -Timeout 60 } catch {}
$adb = Join-Path $Dst 'adb\adb.exe'
if (Test-Path -LiteralPath $adb) { & $adb kill-server | Out-Null }
Get-Process adb, scrcpy | Where-Object { $_.Path -and $_.Path.StartsWith($Dst) } | Stop-Process -Force
Start-Sleep -Milliseconds 700
robocopy $Src $Dst /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
$code = $LASTEXITCODE
Start-Process -FilePath (Join-Path $Dst $Exe) -WorkingDirectory $Dst
if ($code -lt 8) { Remove-Item -LiteralPath (Split-Path $Src -Parent) -Recurse -Force }
''';

  /// Запускает замену и закрывает программу. Новая версия откроется сама.
  static Future<Never> applyAndRestart(Directory newDir) async {
    final work = newDir.parent.path.endsWith('new')
        ? newDir.parent.parent
        : newDir.parent;
    final script = File('${work.path}${Platform.pathSeparator}apply.ps1');
    // BOM: Windows PowerShell 5 читает файл как UTF-8.
    await script.writeAsString('﻿$_applyScript');
    final exeName = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last;
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
      '-ParentPid',
      '$pid',
      '-Src',
      newDir.path,
      '-Dst',
      installDir.path,
      '-Exe',
      exeName,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}
