import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../adb/adb_executor.dart';
import '../adb/adb_status_checker.dart';
import '../app/env.dart';
import '../app/platform.dart';
import '../data/auth_repository.dart';
import '../data/models.dart';
import '../security/payload_cipher.dart';
import 'job_backend.dart';
import 'job_models.dart';

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

  Future<void> run({
    required ServiceItem service,
    required String vin,
    required CarModel model,
    List<CustomApk> customApks = const [],
  }) async {
    if (state.phase == JobPhase.running) return;
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

      final steps = ticket.steps;
      final total = steps.length + customs.length;

      // Перезагрузка (если она есть в сценарии) выполняется в самом конце, после своих APK мастера.
      final main = steps.where((s) => s.type != StepType.reboot).toList();
      final tail = steps.where((s) => s.type == StepType.reboot).toList();

      Future<void> runScenarioStep(int index, JobStep step) async {
        final title = step.title.isEmpty
            ? 'Шаг ${index + 1} из ${steps.length}'
            : step.title;
        void report(double within) => state = state.copyWith(
          stepTitle: title,
          progress: (index + within) / total,
        );
        report(0);
        log.writeln('[${index + 1}/${steps.length}] $title');
        try {
          await _runStep(step, adb.serial!, executor, backend, report, log);
        } catch (e) {
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
          await _runStep(step, adb.serial!, executor, backend, report, log);
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
        log.writeln('[custom ${j + 1}/${customs.length}] ${apk.name}');
        try {
          await _installCustom(apk, adb.serial!, executor, report);
        } catch (e) {
          failed.add(apk.name);
          log.writeln('Не установлен ${apk.name}: $e');
        }
      }

      // 3. Перезагрузка
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
    } catch (e) {
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
    var done = 0;
    final stream = file.openRead().map((chunk) {
      done += chunk.length;
      report((done / size).clamp(0, 1).toDouble());
      return chunk;
    });
    await executor.pipe(serial, [
      'cmd',
      'package',
      'install',
      '-r',
      '-S',
      '$size',
    ], stream);
    report(1);
  }

  Future<void> _runStep(
    JobStep step,
    String serial,
    AdbExecutor executor,
    JobBackend backend,
    void Function(double) report,
    StringBuffer log,
  ) async {
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
        var done = 0;
        final decrypted = PayloadCipher.fromBase64(key)
            .decrypt(backend.openPayload(path))
            .map((chunk) {
              done += chunk.length;
              report(size == 0 ? 1 : (done / size).clamp(0, 1).toDouble());
              return chunk;
            });
        // APK идёт потоком: установщик Android сам отвергнет неполный или чужой файл.
        // Скрипт и файл для записи сначала принимаются целиком и сверяются, иначе при обрыве
        // на головном устройстве успела бы выполниться (или записаться) только часть.
        final Stream<List<int>> plain;
        if (step.type == StepType.installApk) {
          plain = decrypted;
        } else {
          final bytes = await _verifiedPayload(decrypted, size, step.sha256);
          plain = Stream.value(bytes);
        }
        final args = switch (step.type) {
          StepType.installApk => [
            'cmd',
            'package',
            'install',
            '-r',
            if (step.grantPermissions) '-g',
            if (step.downgrade) '-d',
            '-S',
            '$size',
          ],
          StepType.pushFile => [_pushCommand(step)],
          _ => ['sh'],
        };
        await executor.pipe(serial, args, plain);
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
    }
    report(1);
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

  /// Команда на ГУ, которая записывает stdin в файл: `cat > '/путь/файл'`.
  String _pushCommand(JobStep step) {
    final path = step.remotePath;
    if (path == null || path.isEmpty) {
      throw JobException('Сценарий повреждён: не указан путь на устройстве');
    }
    return "cat > '${path.replaceAll("'", r"'\''")}'";
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

final jobControllerProvider = NotifierProvider<JobController, JobState>(
  JobController.new,
);
