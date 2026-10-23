import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/json.dart';
import '../core/vin.dart';

import '../jobs/job_models.dart';
import 'adb_client.dart';
import 'adb_sync.dart';

/// Выполнение команд на головном устройстве. Всё, что нужно сценариям, проходит через этот интерфейс,
/// поэтому в тестах он заменяется заглушкой, а позже может быть заменён нативным ADB на Dart.
abstract class AdbExecutor {
  Future<DeviceInfo> readDeviceInfo(String serial);

  /// VIN, который хранит само головное устройство (настройки и свойства системы, только чтение).
  /// null, если не нашёлся или ГУ не ответило: тогда мастер вводит VIN вручную.
  Future<String?> readVin(String serial);

  /// Короткая команда `adb shell`.
  Future<String> shell(String serial, String command);

  /// Команда adb на компьютере (`adb -s <serial> <args>`), например `tcpip 5555` или `usb`.
  Future<String> host(String serial, List<String> args);

  /// Выполняет скрипт, уже записанный на ГУ по пути [remotePath] (`adb shell sh <файл>`),
  /// и удаляет его. Возвращает код выхода и вывод скрипта.
  Future<ScriptResult> runScript(String serial, String remotePath);

  /// Передаёт поток байт в stdin команды на ГУ (`adb exec-in ...`). Ничего не пишет на диск.
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  );

  /// Установка APK: файл копируется на ГУ (как `adb install`), затем `pm install`.
  /// [onProgress] — сколько байт уже передано.
  Future<void> install(
    String serial,
    Stream<List<int>> data, {
    bool grant = false,
    bool downgrade = false,
    void Function(int sent)? onProgress,
  });

  /// Запись файла на ГУ по пути [remotePath] (как `adb push`).
  Future<void> push(
    String serial,
    Stream<List<int>> data,
    String remotePath, {
    void Function(int sent)? onProgress,
  });

  /// Мастер нажал «Остановить»: прервать всё, что сейчас передаётся и выполняется.
  void cancel();

  Future<void> reboot(String serial);

  /// Пункт 1 AUTOMAX KG «Разблокировать авторизацию»: тем же способом, что и в AUTOMAX
  /// (`echo <пароль>| adb shell disable-verify 1`, затем `adb shell setprop vecentek.model 1`).
  /// После этого ГУ больше не спрашивает пароль и остальные команды доходят.
  Future<void> unlock(String serial);

  /// Ждёт, пока ГУ снова появится в ADB. false, если не появилось за [timeout].
  Future<bool> waitForDevice(String serial, Duration timeout);
}

/// Итог скрипта на ГУ: код выхода и вывод (stdout и stderr вместе).
typedef ScriptResult = ({int code, String output});

/// Метка, после которой скрипт печатает свой код выхода. Код берётся из вывода, а не из
/// кода `adb shell`: без протокола shell v2 adb всегда возвращает 0.
const scriptExitMarker = 'NOX_SCRIPT_EXIT=';

/// Разбор вывода `sh <файл>; echo NOX_SCRIPT_EXIT=$?`. null, если метки нет (скрипт прерван).
ScriptResult? parseScriptOutput(String raw) {
  final text = raw.replaceAll('\r\n', '\n');
  final at = text.lastIndexOf(scriptExitMarker);
  if (at < 0) return null;
  final code = int.tryParse(
    text.substring(at + scriptExitMarker.length).trim().split('\n').first,
  );
  if (code == null) return null;
  return (code: code, output: text.substring(0, at).trim());
}

/// ГУ отказалось от протокола копирования adb: соединение закрыто без ответа.
/// На Changan Q07 бывает и «Write failed»: ГУ рвёт соединение, пока программа пишет.
bool syncRefused(AdbStallException e) =>
    e.message == 'adb закрыл соединение' ||
    e.message.startsWith('Связь с adb прервалась');

/// Данные в base64 строками по 76 знаков (57 байт) для `base64 -d` на ГУ.
Stream<List<int>> base64Lines(Stream<List<int>> data) async* {
  const line = 57;
  final rest = <int>[];
  await for (final chunk in data) {
    rest.addAll(chunk);
    final whole = rest.length - rest.length % line;
    if (whole == 0) continue;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < whole; i += line) {
      out
        ..add(ascii.encode(base64.encode(rest.sublist(i, i + line))))
        ..addByte(10);
    }
    rest.removeRange(0, whole);
    yield out.takeBytes();
  }
  if (rest.isNotEmpty) {
    yield [...ascii.encode(base64.encode(rest)), 10];
  }
}

/// Удалась ли команда `adb exec-in`. Важно: exec-in не возвращает вывод команды на ГУ,
/// поэтому при успешной установке APK ответ пустой. Ошибкой считается только ненулевой код
/// или явный отказ (`Failure [...]`, исключение, `Error:` в начале сообщения).
bool pipeFailed(int exitCode, String output) =>
    exitCode != 0 ||
    RegExp(r'Failure|Exception|^\s*Error:', multiLine: true).hasMatch(output);

/// Пароль авторизации ADB на ГУ Changan (Tinnove/Vecentek), как в AUTOMAX KG.
const huAdbPassword = 'adb36987';

/// ГУ пропало из ADB (кабель, сон, перезапуск службы ADB на ГУ).
bool isDeviceLost(Object e) => RegExp(
  r"device '.*' not found|device offline|no devices/emulators found|device not found",
  caseSensitive: false,
).hasMatch('$e');

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
  Future<void> unlock(String serial) async => _fail();

  @override
  Future<DeviceInfo> readDeviceInfo(String serial) async => _fail();

  @override
  Future<String?> readVin(String serial) async => null;

  @override
  Future<String> shell(String serial, String command) async => _fail();

  @override
  Future<String> host(String serial, List<String> args) async => _fail();

  @override
  Future<ScriptResult> runScript(String serial, String remotePath) async =>
      _fail();

  @override
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  ) async => _fail();

  @override
  Future<void> install(
    String serial,
    Stream<List<int>> data, {
    bool grant = false,
    bool downgrade = false,
    void Function(int sent)? onProgress,
  }) async => _fail();

  @override
  Future<void> push(
    String serial,
    Stream<List<int>> data,
    String remotePath, {
    void Function(int sent)? onProgress,
  }) async => _fail();

  @override
  void cancel() {}

  @override
  Future<void> reboot(String serial) async => _fail();

  @override
  Future<bool> waitForDevice(String serial, Duration timeout) async => false;
}

/// Реализация через adb.exe. Процессы запускаются без окна консоли:
/// приложение GUI-типа, `Process.start` не создаёт видимой консоли для дочернего процесса.
/// (Нужно проверить на целевом ПК с Windows.)
class ProcessAdbExecutor implements AdbExecutor {
  ProcessAdbExecutor({String? adbPath, AdbSync? sync})
    : _adb = adbPath ?? resolveAdbPath(),
      _sync = sync ?? AdbSync();

  final String _adb;
  final AdbSync _sync;

  /// Процессы adb, которые сейчас идут (для «Остановить»).
  final _procs = <Process>{};

  /// Сколько ждать, если данные перестали уходить на ГУ.
  static const stallTimeout = Duration(seconds: 60);

  /// Сколько ждать сам `pm install` после копирования файла.
  static const installTimeout = Duration(minutes: 5);

  @override
  void cancel() {
    _sync.cancel();
    for (final p in _procs.toList()) {
      p.kill();
    }
    _procs.clear();
  }

  /// Запуск adb с учётом «Остановить» и таймаута (процесс убивается, а не остаётся висеть).
  Future<ProcessResult> _tracked(List<String> args, Duration timeout) async {
    final p = await Process.start(_adb, args);
    _procs.add(p);
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
    } finally {
      _procs.remove(p);
    }
  }

  @override
  Future<void> push(
    String serial,
    Stream<List<int>> data,
    String remotePath, {
    void Function(int sent)? onProgress,
  }) => _write(serial, data, remotePath, onProgress);

  /// ГУ, которые не принимают протокол копирования adb (Changan Q07 сразу закрывает
  /// соединение). Им файлы передаются через `adb shell`, как в батнике FunkyDev Q07.
  final _noSync = <String>{};

  /// Запись файла на ГУ: протокол копирования adb, а если ГУ его не принимает,
  /// `adb shell "base64 -d > файл"` со сверкой размера.
  Future<void> _write(
    String serial,
    Stream<List<int>> data,
    String remotePath,
    void Function(int sent)? onProgress,
  ) async {
    if (!_noSync.contains(serial)) {
      try {
        await _sync.push(serial, data, remotePath, onProgress: onProgress);
        return;
      } on AdbStallException catch (e) {
        if (!syncRefused(e)) rethrow;
        // Поток данных уже начат: шаг повторится, и файл пойдёт через adb shell.
        _noSync.add(serial);
        throw AdbStallException(
          'ГУ не принимает копирование файлов adb, передаю через adb shell',
        );
      }
    }
    await _shellWrite(serial, data, remotePath, onProgress);
  }

  Future<void> _shellWrite(
    String serial,
    Stream<List<int>> data,
    String remotePath,
    void Function(int sent)? onProgress,
  ) async {
    final tmp = '$remotePath.nox';
    final p = await Process.start(_adb, [
      '-s',
      serial,
      'shell',
      "base64 -d > '$tmp'",
    ]);
    _procs.add(p);
    final out = StringBuffer();
    final outSub = p.stdout.transform(utf8.decoder).listen(out.write);
    final errSub = p.stderr.transform(utf8.decoder).listen(out.write);
    var last = DateTime.now();
    var stalled = false;
    final watch = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(last) > stallTimeout) {
        stalled = true;
        p.kill();
      }
    });
    var sent = 0;
    int code;
    try {
      try {
        await p.stdin.addStream(
          base64Lines(
            data.map((c) {
              last = DateTime.now();
              sent += c.length;
              onProgress?.call(sent);
              return c;
            }),
          ),
        );
        await p.stdin.close();
      } on SocketException {
        // adb закрылся раньше времени: причину покажет вывод ниже
      } catch (_) {
        // Ошибка в самих данных (например, расшифровка): adb не должен остаться висеть.
        p.kill();
        await _quiet(serial, "rm -f '$tmp'");
        rethrow;
      }
      code = await p.exitCode.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          p.kill();
          return -1;
        },
      );
    } finally {
      watch.cancel();
      _procs.remove(p);
      await outSub.cancel();
      await errSub.cancel();
    }
    if (stalled) {
      await _quiet(serial, "rm -f '$tmp'");
      throw AdbStallException(
        'Передача на автомобиль замерла: данные не уходили ${stallTimeout.inSeconds} секунд',
      );
    }
    final text = out.toString().trim();
    if (code != 0) {
      await _quiet(serial, "rm -f '$tmp'");
      throw AdbException(
        text.isEmpty ? 'Файл не записан на автомобиль (код $code)' : text,
      );
    }
    // Как в батнике: размер файла на ГУ должен совпасть с отправленным.
    final size = int.tryParse((await shell(serial, "wc -c < '$tmp'")).trim());
    if (size != sent) {
      await _quiet(serial, "rm -f '$tmp'");
      throw AdbException(
        'Файл записан на автомобиль не полностью: $size из $sent байт'
        '${text.isEmpty ? '' : ' ($text)'}',
      );
    }
    await shell(serial, "chmod 644 '$tmp' && mv -f '$tmp' '$remotePath'");
  }

  @override
  Future<void> install(
    String serial,
    Stream<List<int>> data, {
    bool grant = false,
    bool downgrade = false,
    void Function(int sent)? onProgress,
  }) async {
    final remote =
        '/data/local/tmp/nox_${DateTime.now().microsecondsSinceEpoch}.apk';
    try {
      await _write(serial, data, remote, onProgress);
      final ProcessResult r;
      try {
        r = await _tracked([
          '-s',
          serial,
          'shell',
          'pm',
          'install',
          '-r',
          if (grant) '-g',
          if (downgrade) '-d',
          remote,
        ], installTimeout);
      } on TimeoutException {
        // pm install завис на ГУ: снимаем его там же, чтобы он не мешал следующим установкам.
        await _quiet(serial, "pkill -f '$remote'");
        throw AdbStallException(
          'Установка не завершилась за ${installTimeout.inMinutes} минут',
        );
      }
      final text = '${r.stdout}\n${r.stderr}'.trim();
      // adb shell возвращает вывод pm, поэтому успех проверяется по слову Success.
      if (!RegExp(r'^Success', multiLine: true).hasMatch(text)) {
        throw AdbException(
          text.isEmpty ? 'Установка не удалась (код ${r.exitCode})' : text,
        );
      }
    } finally {
      await _quiet(serial, "rm -f '$remote'");
    }
  }

  /// Служебная команда, ошибки которой не важны (уборка временных файлов).
  Future<void> _quiet(String serial, String command) async {
    try {
      await _tracked([
        '-s',
        serial,
        'shell',
        command,
      ], const Duration(seconds: 15));
    } catch (_) {}
  }

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
  Future<String> host(String serial, List<String> args) async {
    final r = await _run(serial, args);
    final out = '${r.stdout}${r.stderr}'.trim();
    if (r.exitCode != 0 ||
        RegExp(r'^\s*error:', multiLine: true).hasMatch(out)) {
      throw AdbException(out.isEmpty ? 'Команда adb не выполнена' : out);
    }
    return out;
  }

  /// Сколько может идти один скрипт на ГУ.
  static const scriptTimeout = Duration(minutes: 10);

  @override
  Future<ScriptResult> runScript(String serial, String remotePath) async {
    final ProcessResult r;
    try {
      r = await _tracked([
        '-s',
        serial,
        'shell',
        'sh $remotePath 2>&1; echo "$scriptExitMarker\$?"; rm -f $remotePath',
      ], scriptTimeout);
    } on TimeoutException {
      throw AdbStallException(
        'Скрипт на автомобиле не завершился за ${scriptTimeout.inMinutes} минут',
      );
    }
    final out = '${r.stdout}${r.stderr}';
    final result = parseScriptOutput(out);
    if (result == null) {
      final text = out.trim();
      throw AdbException(
        text.isEmpty ? 'Скрипт прерван (код ${r.exitCode})' : text,
      );
    }
    return result;
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
  Future<String?> readVin(String serial) async {
    try {
      // Все источники одной командой: каждое чтение печатает свою строку (пустую, если нет).
      final out = await shell(serial, vinReadCommands.join('; '));
      final vin = pickVin(out.split(RegExp(r'\r?\n')));
      if (vin != null) return vin;
      return findVinIn(await shell(serial, vinSearchCommand));
    } on AdbException {
      return null;
    }
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
    _procs.add(p);
    final out = StringBuffer();
    final outSub = p.stdout.transform(utf8.decoder).listen(out.write);
    final errSub = p.stderr.transform(utf8.decoder).listen(out.write);
    // Сторож: если данные перестали уходить на ГУ дольше [stallTimeout], процесс снимается.
    var last = DateTime.now();
    var stalled = false;
    final watch = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(last) > stallTimeout) {
        stalled = true;
        p.kill();
      }
    });
    try {
      await p.stdin.addStream(
        data.map((c) {
          last = DateTime.now();
          return c;
        }),
      );
      await p.stdin.close();
    } on SocketException {
      // ГУ закрыло поток раньше времени: причину покажет вывод процесса ниже
    } finally {
      watch.cancel();
    }
    if (stalled) {
      _procs.remove(p);
      await outSub.cancel();
      await errSub.cancel();
      throw AdbStallException(
        'Передача на автомобиль замерла: данные не уходили ${stallTimeout.inSeconds} секунд',
      );
    }
    final int code;
    try {
      code = await p.exitCode.timeout(const Duration(minutes: 10));
    } on TimeoutException {
      p.kill();
      _procs.remove(p);
      await outSub.cancel();
      await errSub.cancel();
      throw AdbStallException(
        'Команда на автомобиле не завершилась за 10 минут',
      );
    }
    _procs.remove(p);
    await outSub.cancel();
    await errSub.cancel();
    final text = out.toString();
    final failed = pipeFailed(code, text);
    if (failed) {
      throw AdbException(
        text.trim().isEmpty ? 'Ошибка выполнения (код $code)' : text.trim(),
      );
    }
  }

  @override
  Future<void> unlock(String serial) async {
    // Как в AUTOMAX: пароль уходит с компьютера в stdin `adb shell`. Вывод не важен
    // (AUTOMAX тоже его скрывает): на уже разблокированном ГУ команда просто ничего не меняет.
    try {
      final p = await Process.start(_adb, [
        '-s',
        serial,
        'shell',
        'disable-verify',
        '1',
      ]);
      final out = p.stdout.drain<void>();
      final err = p.stderr.drain<void>();
      try {
        p.stdin.write('$huAdbPassword\r\n');
        await p.stdin.flush();
        await p.stdin.close();
      } on SocketException {
        // команда завершилась, не дочитав пароль: ГУ уже разблокировано
      }
      await p.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          p.kill();
          return -1;
        },
      );
      await Future.wait([out, err])
          .timeout(const Duration(seconds: 2), onTimeout: () => const []);
    } on ProcessException catch (e) {
      throw AdbException('Не удалось запустить adb: ${e.message}');
    }
    try {
      await _run(serial, ['shell', 'setprop', 'vecentek.model', '1']);
    } on AdbException {
      // как в AUTOMAX: ошибка setprop не останавливает работу
    }
  }

  @override
  Future<void> reboot(String serial) async {
    final r = await _run(serial, ['reboot']);
    if (r.exitCode != 0) {
      throw AdbException('Не удалось перезагрузить: ${r.stderr}'.trim());
    }
  }

  @override
  Future<bool> waitForDevice(String serial, Duration timeout) async {
    try {
      final r = await runWithTimeout(_adb, [
        '-s',
        serial,
        'wait-for-device',
      ], timeout);
      return r.exitCode == 0;
    } on TimeoutException {
      return false;
    }
  }
}
