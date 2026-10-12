import 'dart:io';

import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/jobs/job_controller.dart';
import 'package:carwarehub_noxdrive/jobs/job_models.dart';
import 'package:carwarehub_noxdrive/security/payload_cipher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _service = ServiceItem(
  id: 1,
  code: 'russify',
  title: 'Русификация',
  priceCredits: 5,
  allowCustomApks: true,
);
const _model = CarModel(id: 1, code: 'q05', title: 'Changan Q05');
const _vin = 'LS5A3ABC1NA000123';

Future<(ProviderContainer, FakeExecutor, FakeBackend, List<int>)> _setup({
  bool withReboot = true,
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
        title: 'Основной пакет',
        storagePath: 'apk/x.enc',
        sizeBytes: apk.length,
        encKey: PayloadCipher(key).keyBase64,
      ),
      if (withReboot)
        const JobStep(type: StepType.reboot, title: 'Перезагрузка'),
    ],
  );
  final exec = FakeExecutor();
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

Future<CustomApk> _tempApk(
  String name,
  List<int> bytes, {
  bool selected = true,
}) async {
  final dir = await Directory.systemTemp.createTemp('nox_test');
  addTearDown(() => dir.delete(recursive: true));
  final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
  return CustomApk(
    path: f.path,
    name: name,
    sizeBytes: bytes.length,
    selected: selected,
  );
}

void main() {
  test(
    'APK расшифровывается потоком и уходит в ADB без записи на диск',
    () async {
      final (c, exec, backend, apk) = await _setup();
      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: _vin, model: _model);

      final s = c.read(jobControllerProvider);
      expect(s.phase, JobPhase.success);
      expect(s.progress, 1);
      expect(exec.received.single, apk);
      expect(exec.calls, [
        'pipe:cmd package install -r -S ${apk.length}',
        'reboot',
      ]);
      expect(backend.finished, [true]);
    },
  );

  test(
    'свои APK ставятся после основного пакета, перезагрузка в самом конце',
    () async {
      final (c, exec, _, apk) = await _setup();
      final a = await _tempApk('YandexNavigator.apk', List.filled(1000, 1));
      final b = await _tempApk('Other.apk', List.filled(2000, 2));
      final skipped = await _tempApk(
        'Skipped.apk',
        List.filled(3000, 3),
        selected: false,
      );

      final titles = <String>[];
      c.listen(jobControllerProvider, (_, n) => titles.add(n.stepTitle));
      await c
          .read(jobControllerProvider.notifier)
          .run(
            service: _service,
            vin: _vin,
            model: _model,
            customApks: [a, skipped, b],
          );

      expect(c.read(jobControllerProvider).phase, JobPhase.success);
      expect(c.read(jobControllerProvider).message, isNull);
      expect(exec.calls, [
        'pipe:cmd package install -r -S ${apk.length}',
        'pipe:cmd package install -r -S 1000',
        'pipe:cmd package install -r -S 2000',
        'reboot',
      ]);
      expect(exec.received[1], List.filled(1000, 1));
      expect(exec.received[2], List.filled(2000, 2));
      expect(
        titles,
        contains('Установка пользовательского файла: YandexNavigator.apk...'),
      );
      expect(
        titles,
        isNot(contains('Установка пользовательского файла: Skipped.apk...')),
      );
    },
  );

  test(
    'сбой своего APK не отменяет остальные, мастеру показано, что не встало',
    () async {
      final (c, exec, backend, _) = await _setup();
      final bad = await _tempApk('Bad.apk', List.filled(1000, 1));
      final good = await _tempApk('Good.apk', List.filled(2000, 2));
      exec.failSizes.add(1000);

      await c
          .read(jobControllerProvider.notifier)
          .run(
            service: _service,
            vin: _vin,
            model: _model,
            customApks: [bad, good],
          );

      final s = c.read(jobControllerProvider);
      expect(s.phase, JobPhase.success);
      expect(s.message, contains('Bad.apk'));
      expect(s.message, isNot(contains('Good.apk')));
      expect(exec.received.length, 3);
      expect(backend.finished, [true]);
    },
  );

  test(
    'услуга без разрешения на свои APK игнорирует переданные файлы',
    () async {
      final (c, exec, _, _) = await _setup(withReboot: false);
      final a = await _tempApk('X.apk', List.filled(10, 1));
      const noCustom = ServiceItem(
        id: 4,
        code: 'debloat',
        title: 'Удаление',
        priceCredits: 0,
      );

      await c
          .read(jobControllerProvider.notifier)
          .run(service: noCustom, vin: _vin, model: _model, customApks: [a]);

      expect(exec.received.length, 1);
    },
  );

  test(
    'сбой основного пакета: свои APK не ставятся, доступен возврат',
    () async {
      final (c, exec, backend, apk) = await _setup();
      final a = await _tempApk('X.apk', List.filled(10, 1));
      exec.failSizes.add(apk.length);

      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: _vin, model: _model, customApks: [a]);

      final s = c.read(jobControllerProvider);
      expect(s.phase, JobPhase.failed);
      expect(s.refundable, isTrue);
      expect(exec.received.length, 1);
      expect(backend.finished, [false]);

      await c.read(jobControllerProvider.notifier).requestRefund();
      expect(backend.refundRequested, isTrue);
    },
  );
}
