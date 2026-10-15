import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/json.dart';

import '../jobs/job_models.dart';
import 'adb_client.dart';

/// Выполнение команд на головном устройстве. Всё, что нужно сценариям, проходит через этот интерфейс,
/// поэтому в тестах он заменяется заглушкой, а позже может быть заменён нативным ADB на Dart.
abstract class AdbExecutor {
  Future<DeviceInfo> readDeviceInfo(String serial);

  /// Короткая команда `adb shell`.
  Future<String> shell(String serial, String command);

  /// Передаёт поток байт в stdin команды на ГУ (`adb exec-in ...`). Ничего не пишет на диск.
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  );

  Future<void> reboot(String serial);
}

class AdbException implements Exception {
  AdbException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Заглушка для платформ без USB (браузер). Кнопки услуг там заблокированы,
/// но если вызов всё же случится, мастер увидит понятную причину.
class UnsupportedAdbExecutor implements AdbExecutor {
  const UnsupportedAdbExecutor();

  static Never _fail() => throw AdbException(
    'Услуги запускаются в программе для Windows или Android',
  );

  @override
  Future<DeviceInfo> readDeviceInfo(String serial) async => _fail();

  @override
  Future<String> shell(String serial, String command) async => _fail();

  @override
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  ) async => _fail();

  @override
  Future<void> reboot(String serial) async => _fail();
}

/// Реализация через adb.exe. Процессы запускаются без окна консоли:
/// приложение GUI-типа, `Process.start` не создаёт видимой консоли для дочернего процесса.
/// (Нужно проверить на целевом ПК с Windows.)
class ProcessAdbExecutor implements AdbExecutor {
  ProcessAdbExecutor({String? adbPath}) : _adb = adbPath ?? resolveAdbPath();

  final String _adb;

  Future<ProcessResult> _run(String serial, List<String> args) async {
    try {
      return await runWithTimeout(_adb, [
        '-s',
        serial,
        ...args,
      ], const Duration(seconds: 60));
    } on TimeoutException {
      throw AdbException('Устройство не ответило за 60 секунд');
    }
  }

  @override
  Future<String> shell(String serial, String command) async {
    final r = await _run(serial, ['shell', command]);
    if (r.exitCode != 0) {
      throw AdbException('Команда не выполнена: ${r.stderr}'.trim());
    }
    return str(r.stdout).trim();
  }

  @override
  Future<DeviceInfo> readDeviceInfo(String serial) async {
    final build = await shell(serial, 'getprop ro.build.display.id');
    final model = await shell(serial, 'getprop ro.product.model');
    // Серийный номер самого ГУ. Пустой ответ не ошибка: тогда сервер не даст бесплатный повтор.
    String huSerial = '';
    try {
      huSerial = await shell(serial, 'getprop ro.serialno');
    } on AdbException {
      huSerial = '';
    }
    return DeviceInfo(
      build: build,
      model: model,
      serial: serial,
      huSerial: huSerial,
    );
  }

  @override
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  ) async {
    final p = await Process.start(_adb, [
      '-s',
      serial,
      'exec-in',
      ...remoteArgs,
    ]);
    final out = StringBuffer();
    final outSub = p.stdout.transform(utf8.decoder).listen(out.write);
    final errSub = p.stderr.transform(utf8.decoder).listen(out.write);
    try {
      await p.stdin.addStream(data);
      await p.stdin.close();
    } on SocketException {
      // ГУ закрыло поток раньше времени: причину покажет вывод процесса ниже
    }
    final int code;
    try {
      code = await p.exitCode.timeout(const Duration(minutes: 10));
    } on TimeoutException {
      p.kill();
      await outSub.cancel();
      await errSub.cancel();
      throw AdbException('Установка не завершилась за 10 минут');
    }
    await outSub.cancel();
    await errSub.cancel();
    final text = out.toString();
    // adb exec-in не всегда передаёт код выхода команды на ГУ, поэтому смотрим и на текст.
    // Установка APK обязана вывести Success. Для остальных команд ошибкой считаем только
    // явные признаки сбоя, а не любое слово «Error»: оно бывает и в обычном выводе.
    final isInstall = remoteArgs.contains('install');
    final failed =
        code != 0 ||
        RegExp(r'Failure|Exception|\bError:').hasMatch(text) ||
        (isInstall && !text.contains('Success'));
    if (failed) {
      throw AdbException(
        text.trim().isEmpty ? 'Ошибка выполнения (код $code)' : text.trim(),
      );
    }
  }

  @override
  Future<void> reboot(String serial) async {
    final r = await _run(serial, ['reboot']);
    if (r.exitCode != 0) {
      throw AdbException('Не удалось перезагрузить: ${r.stderr}'.trim());
    }
  }
}
