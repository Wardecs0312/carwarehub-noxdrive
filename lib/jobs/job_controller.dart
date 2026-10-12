import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../adb/adb_executor.dart';
import '../adb/adb_status_checker.dart';
import '../app/env.dart';
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

final adbExecutorProvider = Provider<AdbExecutor>((_) => ProcessAdbExecutor());

final jobBackendProvider = Provider<JobBackend>(
  (_) => Env.hasSupabase ? SupabaseJobBackend() : DemoJobBackend(),
);

final appVersionProvider = FutureProvider<String>((_) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
});

/// Менеджер фонового выполнения услуги.
/// Файлы идут из облака в расшифровку и сразу в stdin ADB: на диск ничего не попадает.
class JobController extends Notifier<JobState> {
  @override
  JobState build() => const JobState();

  void reset() => state = const JobState();

  Future<void> run({
    required ServiceItem service,
    required String vin,
    required CarModel model,
  }) async {
    if (state.phase == JobPhase.running) return;
    final executor = ref.read(adbExecutorProvider);
    final backend = ref.read(jobBackendProvider);
    final adb = ref.read(adbStatusProvider).value;

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
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        final title = step.title.isEmpty
            ? 'Шаг ${i + 1} из ${steps.length}'
            : step.title;
        void report(double within) => state = state.copyWith(
          stepTitle: title,
          progress: (i + within) / steps.length,
        );
        report(0);
        log.writeln('[${i + 1}/${steps.length}] $title');
        await _runStep(step, adb.serial!, executor, backend, report, log);
      }

      await backend.finishJob(jobId, success: true, log: log.toString());
      state = state.copyWith(
        phase: JobPhase.success,
        progress: 1,
        stepTitle: 'Готово',
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
        final args = step.type == StepType.installApk
            ? ['cmd', 'package', 'install', '-r', '-S', '$size']
            : ['sh'];
        await executor.pipe(serial, args, plain);
        if (done != size) throw JobException('Файл получен не полностью');
      case StepType.shell:
        log.writeln(await executor.shell(serial, step.cmd ?? ''));
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
