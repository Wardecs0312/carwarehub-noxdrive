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
    // Вывод scrcpy не нужен, но его надо вычитывать, иначе процесс встанет на заполненном буфере.
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.drain<void>());
    // Если scrcpy сразу упал (нет ГУ, нет разрешения), сообщаем причину.
    final early = await p.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    if (early != -1) {
      throw HuMirrorException('Не удалось открыть экран ГУ (код $early)');
    }
    return HuMirror._(p);
  }

  void stop() => _process.kill();
}

class HuMirrorException implements Exception {
  HuMirrorException(this.message);
  final String message;
  @override
  String toString() => message;
}
