import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/json.dart';

import 'adb_status.dart';

/// Запускает процесс и убивает его, если он не завершился за [timeout].
/// `Process.run(...).timeout()` только перестаёт ждать, а сам процесс продолжает висеть.
Future<ProcessResult> runWithTimeout(
  String executable,
  List<String> args,
  Duration timeout,
) async {
  final p = await Process.start(executable, args);
  final out = <int>[];
  final err = <int>[];
  final outDone = p.stdout.forEach(out.addAll);
  final errDone = p.stderr.forEach(err.addAll);
  try {
    final code = await p.exitCode.timeout(timeout);
    await Future.wait([outDone, errDone]);
    return ProcessResult(
      p.pid,
      code,
      utf8.decode(out, allowMalformed: true),
      utf8.decode(err, allowMalformed: true),
    );
  } on TimeoutException {
    p.kill();
    rethrow;
  }
}

/// Источник данных об ADB-устройствах. В тестах подменяется заглушкой.
abstract class AdbClient {
  Future<AdbStatus> readStatus();
}

/// Разбор вывода `adb devices -l`. Берётся первое устройство.
AdbStatus parseAdbDevices(String output) {
  // Служебные строки демона ADB могут идти до заголовка, поэтому ищем его явно.
  final all = output.split(RegExp(r'\r?\n'));
  final header = all.indexWhere((l) => l.startsWith('List of devices'));
  final lines = header < 0 ? const <String>[] : all.skip(header + 1);
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('*')) {
      continue; // служебные строки демона
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      continue;
    }
    final serial = parts[0];
    final state = parts[1];
    final model = RegExp(r'model:(\S+)').firstMatch(line)?.group(1);
    switch (state) {
      case 'device':
        return AdbStatus(AdbConnection.connected, serial: serial, model: model);
      case 'unauthorized':
        return AdbStatus(AdbConnection.unauthorized, serial: serial);
      default: // offline и прочее: считаем, что устройства нет
        continue;
    }
  }
  return const AdbStatus(AdbConnection.disconnected);
}

/// Путь к adb: сначала рядом с программой (папка adb), затем из PATH.
String resolveAdbPath() {
  final dir = File(Platform.resolvedExecutable).parent.path;
  final bundled = File(
    '$dir${Platform.pathSeparator}adb${Platform.pathSeparator}adb.exe',
  );
  return bundled.existsSync() ? bundled.path : 'adb';
}

/// Вызывает adb.exe. Сначала ищет рядом с программой (папка adb), затем в PATH.
class ProcessAdbClient implements AdbClient {
  ProcessAdbClient({String? adbPath}) : _adbPath = adbPath ?? _defaultPath();

  final String _adbPath;

  static String _defaultPath() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final bundled = File(
      '$dir${Platform.pathSeparator}adb${Platform.pathSeparator}adb.exe',
    );
    return bundled.existsSync() ? bundled.path : 'adb';
  }

  @override
  Future<AdbStatus> readStatus() async {
    try {
      final result = await runWithTimeout(_adbPath, [
        'devices',
        '-l',
      ], const Duration(seconds: 5));
      if (result.exitCode != 0) {
        return const AdbStatus(AdbConnection.disconnected);
      }
      return parseAdbDevices(str(result.stdout));
    } on ProcessException {
      return const AdbStatus(AdbConnection.adbMissing);
    } on TimeoutException {
      return const AdbStatus(AdbConnection.disconnected);
    }
  }
}
