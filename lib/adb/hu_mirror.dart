import 'dart:async';
import 'dart:io';

import 'adb_client.dart';

/// Окно с экраном ГУ на ноутбуке мастера (scrcpy, Apache 2.0). Окно затем захватывается
/// как источник трансляции `screen-hu`. Управление ГУ из окна выключено (`--no-control`).
class HuMirror {
  HuMirror._(this._process);

  static const windowTitle = 'nox.drive: экран ГУ';

  final Process _process;

  /// scrcpy лежит рядом с программой в папке `scrcpy\` (как adb в `adb\`).
  static String get path {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir${Platform.pathSeparator}scrcpy${Platform.pathSeparator}scrcpy.exe';
  }

  static bool get available => Platform.isWindows && File(path).existsSync();

  static Future<HuMirror> start(String serial) async {
    final p = await Process.start(
      path,
      [
        '-s',
        serial,
        '--window-title',
        windowTitle,
        '--no-control',
        '--no-audio',
        '--max-size',
        '1280',
        '--max-fps',
        '15',
        '--video-bit-rate',
        '4M',
      ],
      // scrcpy работает через тот же adb, что и программа: второй сервер adb не запускается.
      environment: {'ADB': resolveAdbPath()},
    );
    // Вывод scrcpy вычитывается (иначе процесс встанет на заполненном буфере) и запоминается:
    // если scrcpy упадёт, его последние строки и есть причина.
    final out = StringBuffer();
    void keep(String chunk) {
      out.write(chunk);
      if (out.length > 4000) {
        final tail = out.toString().substring(out.length - 2000);
        out
          ..clear()
          ..write(tail);
      }
    }

    final outDone = p.stdout
        .transform(const SystemEncoding().decoder)
        .listen(keep)
        .asFuture<void>();
    final errDone = p.stderr
        .transform(const SystemEncoding().decoder)
        .listen(keep)
        .asFuture<void>();
    // Если scrcpy сразу упал (нет ГУ, кодек, разрешение), сообщаем его собственную причину.
    final early = await p.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => -1,
    );
    if (early != -1) {
      await Future.wait([outDone, errDone])
          .timeout(const Duration(seconds: 1), onTimeout: () => const []);
      throw HuMirrorException(
        'scrcpy не запустился (код $early): ${lastLines(out.toString())}',
      );
    }
    return HuMirror._(p);
  }

  void stop() => _process.kill();
}

/// Последние осмысленные строки вывода scrcpy (там ошибка), не длиннее 300 символов.
String lastLines(String output) {
  final lines = output
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final errors = lines.where(
    (l) => l.startsWith('ERROR') || l.contains('rror'),
  );
  final picked = (errors.isNotEmpty ? errors : lines).toList();
  final text = picked
      .skip(picked.length > 3 ? picked.length - 3 : 0)
      .join(' / ');
  if (text.isEmpty) return 'вывода нет';
  return text.length > 300 ? text.substring(text.length - 300) : text;
}

class HuMirrorException implements Exception {
  HuMirrorException(this.message);
  final String message;
  @override
  String toString() => message;
}
