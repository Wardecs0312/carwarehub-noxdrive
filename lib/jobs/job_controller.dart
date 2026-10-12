import 'dart:io';

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

/// Состав основного пакета для окна настройки. Читает модель/прошивку ГУ и спрашивает сервер.
final packagePreviewProvider = FutureProvider.autoDispose
    .family<PackagePreview, PreviewKey>((ref, key) async {
      final adb = ref.read(adbStatusProvider).value;
      if (adb == null || !adb.isReady || adb.serial == null) {
        throw JobException(
          adb?.blockedHint ?? 'Подключите автомобиль по USB/ADB',
        );
      }
      final device = await ref
          .read(adbExecutorProvider)
          .readDeviceInfo(adb.serial!);
      return ref
          .read(jobBackendProvider)
          .preview(
            vin: key.vin,
            serviceId: key.serviceId,
            modelId: key.modelId,
            device: device,
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
        await _runStep(step, adb.serial!, executor, backend, report, log);
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

      await backend.finishJob(jobId, success: true, log: log.toString());
      state = state.copyWith(
        phase: JobPhase.success,
        progress: 1,
        stepTitle: 'Готово',
        message: failed.isEmpty
            ? null
            : 'Основной пакет установлен. Не удалось установить: ${failed.join(', ')}',
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
        final plain = PayloadCipher.fromBase64(key)
            .decrypt(backend.openPayload(path))
            .map((chunk) {
              done += chunk.length;
              report(size == 0 ? 1 : (done / size).clamp(0, 1).toDouble());
              return chunk;
            });
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
    if (id == null) return;
    await ref.read(jobBackendProvider).requestRefund(id, state.message ?? '');
    state = state.copyWith(
      refundable: false,
      message: 'Заявка на возврат отправлена администратору',
    );
  }
}

final jobControllerProvider = NotifierProvider<JobController, JobState>(
  JobController.new,
);
