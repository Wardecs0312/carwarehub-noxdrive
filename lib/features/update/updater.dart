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
/// 3. Распаковывает во временную папку и сама заменяет свои файлы (занятые переименовывает в *.nox-old),
///    запускает новую версию и закрывается. Старые файлы удаляются при следующем запуске.
///    Журнал: %TEMP%\nox_update.log.
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
    // Запуск прямо из zip (Проводник распаковывает во временную папку): обновлять там бессмысленно.
    if (installDir.path.startsWith(Directory.systemTemp.path)) {
      throw UpdateException(
        'Программа запущена прямо из архива. Распакуйте архив в обычную папку и запускайте оттуда',
      );
    }
    log('download: ${r.version}+${r.buildNumber} ${r.downloadPath}');
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

  /// Суффикс старых файлов, которые нельзя удалить, пока программа работает.
  static const oldSuffix = '.nox-old';

  /// Журнал обновления: %TEMP%\nox_update.log (что заменено, какие ошибки).
  static File get logFile => File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}nox_update.log',
  );

  static void log(String line) {
    try {
      logFile.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// Замена файлов программой самой себе, без внешних скриптов.
  /// Windows не даёт удалить или перезаписать запущенный exe и загруженные dll, но даёт их
  /// переименовать: старый файл получает суффикс [oldSuffix], на его место кладётся новый.
  /// Старые файлы удаляются при следующем запуске ([cleanupOldFiles]).
  /// Возвращает число заменённых файлов.
  static Future<int> replaceFiles(Directory from, Directory to) async {
    var n = 0;
    await for (final e in from.list(recursive: true)) {
      if (e is! File) continue;
      final rel = e.path.substring(from.path.length + 1);
      final target = File('${to.path}${Platform.pathSeparator}$rel');
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        try {
          await target.delete();
        } on FileSystemException {
          final old = File('${target.path}$oldSuffix');
          if (await old.exists()) await old.delete();
          await target.rename(old.path);
        }
      }
      await e.copy(target.path);
      n++;
    }
    return n;
  }

  /// Удаляет файлы *.nox-old, оставшиеся от прошлого обновления, и временные папки загрузки.
  static Future<void> cleanupOldFiles() async {
    if (!supported) return;
    try {
      await for (final e in installDir.list(recursive: true)) {
        if (e is File && e.path.endsWith(oldSuffix)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      await for (final e in Directory.systemTemp.list()) {
        if (e is Directory &&
            e.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('nox_update_')) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Ставит новую версию поверх текущей и перезапускает программу.
  static Future<Never> applyAndRestart(Directory newDir) async {
    final dst = installDir;
    log('apply: ${newDir.path} -> ${dst.path}');
    // adb из папки программы держит adb.exe: останавливаем сервер, чтобы заменить файл.
    final adb = File(
      '${dst.path}${Platform.pathSeparator}adb${Platform.pathSeparator}adb.exe',
    );
    if (await adb.exists()) {
      try {
        await Process.run(adb.path, [
          'kill-server',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final int n;
    try {
      n = await replaceFiles(newDir, dst);
    } catch (e) {
      log('apply failed: $e');
      throw UpdateException(
        'Не удалось заменить файлы программы ($e). '
        'Если программа лежит в Program Files, перенесите папку, например, на Рабочий стол',
      );
    }
    log('apply: replaced $n files, restarting');
    await Process.start(
      Platform.resolvedExecutable,
      const [],
      workingDirectory: dst.path,
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}
