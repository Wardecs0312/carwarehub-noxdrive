import 'dart:async';

import 'package:carwarehub_noxdrive/adb/adb_executor.dart';
import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/jobs/job_backend.dart';
import 'package:carwarehub_noxdrive/jobs/job_controller.dart';
import 'package:carwarehub_noxdrive/jobs/job_models.dart';
import 'package:carwarehub_noxdrive/security/payload_cipher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeExecutor implements AdbExecutor {
  final calls = <String>[];
  List<int> received = [];
  bool failPipe = false;

  @override
  Future<DeviceInfo> readDeviceInfo(String serial) async =>
      DeviceInfo(build: 'CHANGAN.Q05.1.0', model: 'Q05', serial: serial);

  @override
  Future<String> shell(String serial, String command) async {
    calls.add('shell:$command');
    return 'ok';
  }

  @override
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  ) async {
    calls.add('pipe:${remoteArgs.join(' ')}');
    if (failPipe) throw AdbException('Failure [INSTALL_FAILED]');
    received = [await for (final c in data) ...c];
  }

  @override
  Future<void> reboot(String serial) async => calls.add('reboot');
}

class FakeBackend implements JobBackend {
  FakeBackend(this.ticket, this.encrypted);
  final JobTicket ticket;
  final List<int> encrypted;
  final finished = <bool>[];
  bool refundRequested = false;

  @override
  Future<JobTicket> startJob({
    required String vin,
    required int serviceId,
    required int modelId,
    required String appVersion,
    required DeviceInfo device,
  }) async => ticket;

  @override
  Future<void> finishJob(
    String jobId, {
    required bool success,
    required String log,
  }) async => finished.add(success);

  @override
  Future<void> requestRefund(String jobId, String reason) async =>
      refundRequested = true;

  @override
  Stream<List<int>> openPayload(String storagePath) async* {
    for (var i = 0; i < encrypted.length; i += 5000) {
      yield encrypted.sublist(
        i,
        i + 5000 > encrypted.length ? encrypted.length : i + 5000,
      );
    }
  }
}

const _service = ServiceItem(
  id: 6,
  code: 'cluster',
  title: 'Вывод на приборку',
  priceCredits: 5,
);
const _model = CarModel(id: 1, code: 'q05', title: 'Changan Q05');

Future<(ProviderContainer, FakeExecutor, FakeBackend, List<int>)> _setup({
  bool failPipe = false,
}) async {
  final key = List<int>.generate(32, (i) => i + 1);
  final apk = List<int>.generate(150000, (i) => i % 251);
  final enc = await PayloadCipher(key).encrypt(apk);
  final ticket = JobTicket(
    jobId: 'job-1',
    price: 5,
    repeat: false,
    steps: [
      JobStep(
        type: StepType.installApk,
        title: 'Установка APK',
        storagePath: 'apk/x.enc',
        sizeBytes: apk.length,
        encKey: PayloadCipher(key).keyBase64,
      ),
      const JobStep(type: StepType.reboot, title: 'Перезагрузка'),
    ],
  );
  final exec = FakeExecutor()..failPipe = failPipe;
  final backend = FakeBackend(ticket, enc);
  final container = ProviderContainer(
    overrides: [
      adbExecutorProvider.overrideWithValue(exec),
      jobBackendProvider.overrideWithValue(backend),
      appVersionProvider.overrideWith((_) async => '1.0.0+1'),
      adbStatusProvider.overrideWith(
        (_) =>
            Stream.value(const AdbStatus(AdbConnection.connected, serial: 'A')),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(adbStatusProvider, (_, _) {});
  await container.read(adbStatusProvider.future);
  return (container, exec, backend, apk);
}

void main() {
  test(
    'APK расшифровывается потоком и уходит в ADB без записи на диск',
    () async {
      final (c, exec, backend, apk) = await _setup();
      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: 'LS5A3ABC1NA000123', model: _model);

      final s = c.read(jobControllerProvider);
      expect(s.phase, JobPhase.success);
      expect(s.progress, 1);
      expect(exec.received, apk);
      expect(exec.calls, [
        'pipe:cmd package install -r -S ${apk.length}',
        'reboot',
      ]);
      expect(backend.finished, [true]);
    },
  );

  test(
    'сбой установки: задание закрыто как failed, доступен возврат',
    () async {
      final (c, _, backend, _) = await _setup(failPipe: true);
      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: 'LS5A3ABC1NA000123', model: _model);

      final s = c.read(jobControllerProvider);
      expect(s.phase, JobPhase.failed);
      expect(s.refundable, isTrue);
      expect(backend.finished, [false]);

      await c.read(jobControllerProvider.notifier).requestRefund();
      expect(backend.refundRequested, isTrue);
    },
  );
}
