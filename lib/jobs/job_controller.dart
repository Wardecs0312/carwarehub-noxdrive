import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../adb/adb_executor.dart';
import '../adb/adb_sync.dart';
import '../adb/adb_status_checker.dart';
import '../adb/wifi_adb.dart';
import '../app/env.dart';
import '../app/platform.dart';
import '../data/auth_repository.dart';
import '../data/models.dart';
import '../security/payload_cipher.dart';
import 'job_backend.dart';
import 'job_models.dart';

/// Установщик Android отказал, потому что на машине уже стоит более новая версия приложения.
bool isNewerAlreadyInstalled(Object e) =>
    e.toString().contains('INSTALL_FAILED_VERSION_DOWNGRADE');

/// Команды adb на компьютере мастера, которые разрешено запускать из сценария:
/// открыть ADB по Wi-Fi (порт 5555) и вернуть ADB только на USB.
const allowedAdbHostCommands = [
  ['tcpip', '5555'],
  ['usb'],
];

bool _sameArgs(List<String> a, List<String> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

/// Куда на ГУ кладётся скрипт шага run_script перед выполнением (после выполнения удаляется).
const scriptPath = '/data/local/tmp/nox_step.sh';

/// Строка журнала для пропущенной установки.
const newerInstalledNote =
    'На машине уже установлена более новая версия, шаг пропущен';

enum JobPhase { idle, running, success, failed }

class JobState {
  const JobState({
    this.phase = JobPhase.idle,
    this.progress = 0,
    this.stepTitle = '',
    this.serviceTitle = '',
    this.message,
    this.jobId,
    this.refundable = false,
  });

  final JobPhase phase;
  final double progress;
  final String stepTitle;
  final String serviceTitle;

  /// При ошибке: причина. При успехе: примечание (например, какие свои APK не установились).
  final String? message;
  final String? jobId;
  final bool refundable;

  JobState copyWith({
    JobPhase? phase,
    double? progress,
    String? stepTitle,
    String? message,
    String? jobId,
    bool? refundable,
  }) => JobState(
    phase: phase ?? this.phase,
    progress: progress ?? this.progress,
    stepTitle: stepTitle ?? this.stepTitle,
    serviceTitle: serviceTitle,
    message: message ?? this.message,
    jobId: jobId ?? this.jobId,
    refundable: refundable ?? this.refundable,
  );
}

final adbExecutorProvider = Provider<AdbExecutor>(
  (_) => canUseAdb ? ProcessAdbExecutor() : const UnsupportedAdbExecutor(),
);

final jobBackendProvider = Provider<JobBackend>(
  (_) => Env.hasSupabase ? SupabaseJobBackend() : DemoJobBackend(),
);

final appVersionProvider = FutureProvider<String>((_) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
});

typedef PreviewKey = ({int serviceId, int modelId, String vin});

/// Сколько ждать расчёт цены в окне подтверждения.
const previewTimeout = Duration(seconds: 25);

/// Состав основного пакета для окна настройки. Читает модель/прошивку ГУ и спрашивает сервер.
final packagePreviewProvider = FutureProvider.autoDispose
    .family<PackagePreview, PreviewKey>((ref, key) async {
      final adb = ref.read(adbStatusProvider).value;
      if (adb == null || !adb.isReady || adb.serial == null) {
        throw JobException(
          adb?.blockedHint ?? 'Подключите автомобиль по USB/ADB',
        );
      }
      final executor = ref.read(adbExecutorProvider);
      // Сначала разблокировка: запертое ГУ ждёт пароль, и чтение данных машины висело,
      // а с ним и окно подтверждения.
      Future<PackagePreview> load() async {
        await executor.unlock(adb.serial!);
        final device = await executor.readDeviceInfo(adb.serial!);
        return ref
            .read(jobBackendProvider)
            .preview(
              vin: key.vin,
              serviceId: key.serviceId,
              modelId: key.modelId,
              device: device,
            );
      }

      return load().timeout(
        previewTimeout,
        onTimeout: () => throw JobException(
          'Автомобиль не ответил за ${previewTimeout.inSeconds} секунд',
        ),
      );
    });

/// Менеджер фонового выполнения услуги.
/// Основной пакет идёт из облака через расшифровку сразу в stdin ADB: на диск ничего не попадает.
/// Затем по очереди ставятся собственные APK мастера (читаются с его диска потоком, копий не создаётся).
class JobController extends Notifier<JobState> {
  @override
  JobState build() => const JobState();

  void reset() => state = const JobState();

  /// Мастер нажал «Остановить».
  bool _cancelRequested = false;

  /// Остановить идущую услугу: передача на ГУ прерывается, задание закрывается как неуспешное.
  void cancel() {
    if (state.phase != JobPhase.running) return;
    _cancelRequested = true;
    state = state.copyWith(stepTitle: 'Остановка...');
    ref.read(adbExecutorProvider).cancel();
  }

  void _checkCancelled() {
    if (_cancelRequested) throw JobException('Остановлено мастером');
  }

  Future<void> run({
    required ServiceItem service,
    required String vin,
    required CarModel model,
    List<CustomApk> customApks = const [],
  }) async {
    if (state.phase == JobPhase.running) return;
    _cancelRequested = false;
    final executor = ref.read(adbExecutorProvider);
    final backend = ref.read(jobBackendProvider);
    final adb = ref.read(adbStatusProvider).value;
    final customs = service.allowCustomApks
        ? customApks.where((a) => a.selected).toList()
        : <CustomApk>[];

    state = JobState(
      phase: JobPhase.running,
      serviceTitle: service.title,
      stepTitle: 'Подготовка',
    );
    if (adb == null || !adb.isReady || adb.serial == null) {
      state = state.copyWith(
        phase: JobPhase.failed,
        message: adb?.blockedHint ?? 'Подключите автомобиль по USB/ADB',
      );
      return;
    }

    final log = StringBuffer();
    String? jobId;
    var charged = false;
    Timer? heartbeat;
    try {
      // Пункт 1 AUTOMAX KG: сначала разблокировка паролем, иначе ГУ не выполняет команды adb shell.
      state = state.copyWith(stepTitle: 'Разблокировка доступа ADB');
      await executor.unlock(adb.serial!);
      final device = await executor.readDeviceInfo(adb.serial!);
      final version = await ref.read(appVersionProvider.future);
      final ticket = await backend.startJob(
        vin: vin,
        serviceId: service.id,
        modelId: model.id,
        appVersion: version,
        device: device,
      );
      jobId = ticket.jobId;
      charged = ticket.price > 0;
      state = state.copyWith(jobId: jobId);
      // «Задание живо»: сервер снимает задание, только если отметок нет дольше 5 минут
      // (программу закрыли или компьютер выключился посреди услуги).
      final id = jobId;
      heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(backend.heartbeat(id).catchError((_) {}));
      });

      final steps = ticket.steps;
      final total = steps.length + customs.length;

      // Перезагрузка (если она есть в сценарии) выполняется в самом конце, после своих APK мастера.
      final main = steps.where((s) => s.type != StepType.reboot).toList();
      final tail = steps.where((s) => s.type == StepType.reboot).toList();

      // Файлы всех шагов начинают скачиваться сразу, параллельно с установкой.
      backend.prefetch([
        for (final s in main)
          if (s.storagePath != null) s.storagePath!,
      ]);

      Future<void> runScenarioStep(int index, JobStep step) async {
        final title = step.title.isEmpty
            ? 'Шаг ${index + 1} из ${steps.length}'
            : step.title;
        String? extra;
        void report(double within) => state = state.copyWith(
          stepTitle: extra == null ? title : '$title — $extra',
          progress: (index + within) / total,
        );
        void status(String? text) => extra = text;
        report(0);
        _checkCancelled();
        log.writeln('[${index + 1}/${steps.length}] $title');
        try {
          try {
            await _runStep(
              step,
              adb.serial!,
              executor,
              backend,
              report,
              log,
              status,
            );
          } on FormatException catch (e) {
            // Файл в кэше повреждён: скачиваем заново и повторяем шаг один раз.
            final path = step.storagePath;
            if (path == null) rethrow;
            log.writeln('Файл повреждён, скачиваю заново: $e');
            await backend.invalidatePayload(path);
            report(0);
            await _runStep(
              step,
              adb.serial!,
              executor,
              backend,
              report,
              log,
              status,
            );
          }
        } on AdbStallException catch (e) {
          // Передача замерла: процесс уже снят, пробуем шаг ещё раз.
          _checkCancelled();
          log.writeln('Передача замерла, повтор: $e');
          report(0);
          await _runStep(
            step,
            adb.serial!,
            executor,
            backend,
            report,
            log,
            status,
          );
        } catch (e) {
          _checkCancelled();
          // ГУ на секунду пропало из ADB (кабель, сон ГУ): ждём его и повторяем шаг один раз.
          if (!isDeviceLost(e) || step.type == StepType.reboot) rethrow;
          log.writeln('ГУ пропало из ADB, жду подключения: $e');
          state = state.copyWith(
            stepTitle: 'Ожидание подключения автомобиля...',
          );
          if (!await executor.waitForDevice(adb.serial!, _deviceWait)) {
            throw AdbException(
              'Автомобиль отключился и не вернулся за ${_deviceWait.inSeconds} секунд. '
              'Проверьте USB-кабель и запустите услугу ещё раз',
            );
          }
          report(0);
          await _runStep(
            step,
            adb.serial!,
            executor,
            backend,
            report,
            log,
            status,
          );
        }
      }

      // 1. Основной пакет из облака
      for (var i = 0; i < main.length; i++) {
        await runScenarioStep(i, main[i]);
      }

      // 2. Свои APK мастера. Сбой одного файла не отменяет основной пакет и остальные файлы.
      final failed = <String>[];
      for (var j = 0; j < customs.length; j++) {
        final apk = customs[j];
        final title = 'Установка пользовательского файла: ${apk.name}...';
        void report(double within) => state = state.copyWith(
          stepTitle: title,
          progress: (main.length + j + within) / total,
        );
        report(0);
        _checkCancelled();
        log.writeln('[custom ${j + 1}/${customs.length}] ${apk.name}');
        try {
          try {
            await _installCustom(apk, adb.serial!, executor, report);
          } on AdbStallException catch (e) {
            _checkCancelled();
            log.writeln('Передача замерла, повтор: $e');
            report(0);
            await _installCustom(apk, adb.serial!, executor, report);
          }
        } catch (e) {
          _checkCancelled();
          failed.add(apk.name);
          log.writeln('Не установлен ${apk.name}: $e');
        }
      }

      // 3. Перезагрузка
      _checkCancelled();
      for (var k = 0; k < tail.length; k++) {
        await runScenarioStep(main.length + customs.length + k, tail[k]);
      }

      // Установка уже прошла. Обрыв связи в конце не должен превращать её в «сбой»,
      // поэтому отметку об успехе отправляем с повторами и не роняем задание, если не вышло.
      final reported = await _reportSuccess(backend, jobId, log.toString());
      final notes = [
        if (failed.isNotEmpty)
          'Основной пакет установлен. Не удалось установить: ${failed.join(', ')}',
        if (!reported) 'Услуга выполнена, но связь с сервером потеряна. Возврат запрашивать не нужно',
      ];
      state = state.copyWith(
        phase: JobPhase.success,
        progress: 1,
        stepTitle: 'Готово',
        message: notes.isEmpty ? null : notes.join('. '),
      );
      ref.invalidate(balanceProvider);
    } catch (err) {
      final e = _cancelRequested ? JobException('Остановлено мастером') : err;
      log.writeln('ОШИБКА: $e');
      if (jobId != null && jobId != 'demo') {
        try {
          await backend.finishJob(jobId, success: false, log: log.toString());
        } catch (_) {
          // сервер закроет зависшее задание сам (expire_stale_jobs)
        }
      }
      state = state.copyWith(
        phase: JobPhase.failed,
        message: e is JobException || e is AdbException || e is FormatException
            ? e.toString()
            : 'Сбой: $e',
        refundable: charged,
      );
      ref.invalidate(balanceProvider);
    } finally {
      heartbeat?.cancel();
      _cancelRequested = false;
      // Кэш файлов не растёт бесконечно: старые удаляются после услуги.
      unawaited(backend.trimCache().catchError((_) {}));
    }
  }

  /// Отправляет серверу отметку об успехе: до 3 попыток с паузой. Возвращает false, если не удалось.
  Future<bool> _reportSuccess(
    JobBackend backend,
    String jobId,
    String log,
  ) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await backend.finishJob(jobId, success: true, log: log);
        return true;
      } catch (_) {
        if (attempt < 3) await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    return false;
  }

  Future<void> _installCustom(
    CustomApk apk,
    String serial,
    AdbExecutor executor,
    void Function(double) report,
  ) async {
    final file = File(apk.path);
    if (!await file.exists()) throw JobException('Файл не найден');
    final size = await file.length();
    if (size == 0) throw JobException('Файл пуст');
    // Как `adb install`: файл копируется на ГУ, затем pm install (поток в установщик зависал).
    try {
      await executor.install(
        serial,
        file.openRead(),
        grant: true,
        onProgress: (sent) => report((sent / size).clamp(0, 1).toDouble()),
      );
    } on AdbException catch (e) {
      if (!isNewerAlreadyInstalled(e)) rethrow;
    }
    report(1);
  }

  Future<void> _runStep(
    JobStep step,
    String serial,
    AdbExecutor executor,
    JobBackend backend,
    void Function(double) report,
    StringBuffer log, [
    void Function(String?)? onStatus,
  ]) async {
    switch (step.type) {
      case StepType.installApk:
      case StepType.runScript:
      case StepType.pushFile:
        final size = step.sizeBytes;
        final path = step.storagePath;
        final key = step.encKey;
        if (size == null || path == null || key == null) {
          throw JobException('Сценарий повреждён: нет данных файла');
        }
        // Сначала файл должен быть на диске (кэш). Если его ещё нет, полоска показывает
        // скачивание (первая половина шага), затем передачу на автомобиль (вторая).
        final downloaded = await backend.fetchPayload(
          path,
          onProgress: (got, all) {
            final t = all ?? size;
            report(t <= 0 ? 0 : (got / t).clamp(0, 1) * 0.5);
            onStatus?.call('скачивание ${got >> 20} из ${t >> 20} МБ');
          },
        );
        onStatus?.call(null);
        final base = downloaded ? 0.5 : 0.0;
        final span = 1 - base;
        var done = 0;
        final decrypted = PayloadCipher.fromBase64(key)
            .decrypt(backend.openPayload(path))
            .map((chunk) {
              done += chunk.length;
              return chunk;
            });
        void sent(int n) =>
            report(size == 0 ? 1 : base + span * (n / size).clamp(0, 1));
        // APK идёт потоком: установщик Android сам отвергнет неполный или чужой файл.
        // Скрипт и файл для записи сначала принимаются целиком и сверяются, иначе при обрыве
        // на головном устройстве успела бы выполниться (или записаться) только часть.
        switch (step.type) {
          case StepType.installApk:
            // Как `adb install`: копирование на ГУ, затем pm install. Установщик Android
            // сам отвергнет неполный или чужой файл.
            try {
              await executor.install(
                serial,
                decrypted,
                grant: step.grantPermissions,
                downgrade: step.downgrade,
                onProgress: sent,
              );
            } on AdbException catch (e) {
              // На машине уже стоит более новая версия (так бывает на свежих прошивках).
              // Батник в этом случае шёл дальше, задание тоже не роняем.
              if (!isNewerAlreadyInstalled(e)) rethrow;
              log.writeln(newerInstalledNote);
              report(1);
              return;
            }
          case StepType.pushFile:
            // Файл сначала принимается целиком и сверяется, иначе при обрыве на ГУ
            // записалась бы только часть.
            final bytes = await _verifiedPayload(decrypted, size, step.sha256);
            await executor.push(
              serial,
              Stream.value(bytes),
              _remotePath(step),
              onProgress: sent,
            );
          default:
            // Скрипт тоже принимается целиком и сверяется до выполнения. Он кладётся на ГУ
            // файлом и выполняется через adb shell: `adb exec-in` не возвращает ни вывод,
            // ни код выхода, и ошибка скрипта выглядела бы успехом.
            final bytes = await _verifiedPayload(decrypted, size, step.sha256);
            await executor.push(
              serial,
              Stream.value(bytes),
              scriptPath,
              onProgress: sent,
            );
            final r = await executor.runScript(serial, scriptPath);
            if (r.output.isNotEmpty) log.writeln(r.output);
            if (r.code != 0) {
              final tail = r.output
                  .split('\n')
                  .reversed
                  .take(5)
                  .toList()
                  .reversed;
              final why = tail.join('\n').trim();
              if (!step.ignoreErrors) {
                throw JobException(
                  why.isEmpty
                      ? 'Скрипт завершился с ошибкой (код ${r.code})'
                      : 'Скрипт завершился с ошибкой (код ${r.code}): $why',
                );
              }
              log.writeln('Пропущено: скрипт завершился с кодом ${r.code}');
            }
        }
        if (done != size) throw JobException('Файл получен не полностью');
      case StepType.shell:
        try {
          final out = await executor.shell(serial, step.cmd ?? '');
          // pm/cmd могут напечатать Failure [..] и всё равно завершиться с кодом 0
          if (RegExp(r'Failure \[').hasMatch(out)) throw AdbException(out);
          log.writeln(out);
        } on AdbException catch (e) {
          if (!step.ignoreErrors) rethrow;
          log.writeln('Пропущено: $e');
        }
      case StepType.uninstall:
        for (final pkg in step.packages) {
          // отсутствие пакета не ошибка: нужное состояние уже достигнуто
          log.writeln(
            await executor.shell(serial, 'pm uninstall --user 0 $pkg || true'),
          );
        }
      case StepType.reboot:
        await executor.reboot(serial);
      case StepType.adbHost:
        // С сервера на компьютере мастера выполняются только эти команды.
        if (!allowedAdbHostCommands.any((c) => _sameArgs(c, step.args))) {
          throw JobException(
            'Недопустимая команда adb: ${step.args.join(' ')}',
          );
        }
        final openWifi = _sameArgs(step.args, const ['tcpip', '5555']);
        // Адрес машины в Wi-Fi читается до `adb tcpip`: после него связь по кабелю пропадает.
        String? ip;
        if (openWifi && !isNetworkSerial(serial)) {
          try {
            ip = wifiAddressFrom(await executor.shell(serial, wifiIpCommand));
          } on AdbException {
            ip = null;
          }
        }
        log.writeln(await executor.host(serial, step.args));
        if (openWifi && !isNetworkSerial(serial)) {
          await _connectWifi(ip, executor, log);
        }
        // ADB вернулся на кабель: подключение по Wi-Fi больше не работает.
        if (_sameArgs(step.args, const ['usb']) && isNetworkSerial(serial)) {
          await executor.disconnect(serial);
        }
    }
    report(1);
  }

  /// После `adb tcpip 5555` программа сама подключается к машине по Wi-Fi.
  /// Не вышло — не ошибка задания: ADB по Wi-Fi открыт, мастер подключится позже.
  Future<void> _connectWifi(
    String? ip,
    AdbExecutor executor,
    StringBuffer log,
  ) async {
    if (ip == null) {
      log.writeln(
        'Машина не подключена к Wi-Fi: подключиться без кабеля не получится',
      );
      return;
    }
    final address = '$ip:$wifiAdbPort';
    ref.read(lastWifiAddressProvider.notifier).state = address;
    unawaited(saveWifiAddress(address));
    // adbd на машине перезапускается пару секунд: несколько попыток.
    for (var i = 0; i < 5; i++) {
      try {
        log.writeln(await executor.connect(address));
        log.writeln('Подключено по Wi-Fi: $address. Кабель можно отключить');
        return;
      } on AdbException catch (e) {
        if (i == 4) {
          log.writeln(
            'Не удалось подключиться к $address: $e. '
            'Компьютер должен быть в той же сети Wi-Fi, что и машина',
          );
          return;
        }
        await Future<void>.delayed(wifiRetryDelay);
      }
    }
  }

  /// Принимает расшифрованный файл целиком и сверяет размер и SHA-256 с данными сервера.
  Future<List<int>> _verifiedPayload(
    Stream<List<int>> data,
    int size,
    String? expectedSha256,
  ) async {
    final bytes = <int>[await for (final chunk in data) ...chunk];
    if (bytes.length != size) {
      throw JobException(
        'Файл получен не полностью, на автомобиль ничего не отправлено',
      );
    }
    if (expectedSha256 != null &&
        crypto.sha256.convert(bytes).toString() != expectedSha256) {
      throw JobException(
        'Файл не прошёл проверку целостности, на автомобиль ничего не отправлено',
      );
    }
    return bytes;
  }

  /// Путь на ГУ, куда записывается файл шага.
  String _remotePath(JobStep step) {
    final path = step.remotePath;
    if (path == null || path.isEmpty) {
      throw JobException('Сценарий повреждён: не указан путь на устройстве');
    }
    return path;
  }

  Future<void> requestRefund() async {
    final id = state.jobId;
    // Кнопка гасится сразу: двойное нажатие не создаёт вторую заявку на возврат.
    if (id == null || !state.refundable) return;
    final reason = state.message ?? '';
    state = state.copyWith(refundable: false);
    try {
      await ref.read(jobBackendProvider).requestRefund(id, reason);
      state = state.copyWith(
        message: 'Заявка на возврат отправлена администратору',
      );
    } catch (e) {
      // Ошибку видно в окне, кнопка снова доступна.
      state = state.copyWith(
        refundable: true,
        message: e is JobException
            ? e.message
            : 'Не удалось отправить заявку: $e',
      );
    }
  }
}

/// Сколько ждать, пока ГУ снова появится в ADB после обрыва.
const _deviceWait = Duration(seconds: 60);

/// Пауза между попытками подключиться по Wi-Fi (в тестах 0).
var wifiRetryDelay = const Duration(seconds: 2);

final jobControllerProvider = NotifierProvider<JobController, JobState>(
  JobController.new,
);
