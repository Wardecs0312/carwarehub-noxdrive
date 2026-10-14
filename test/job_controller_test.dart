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
  bool grant = false,
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
        grantPermissions: grant,
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
    'install_apk с grant выдаёт разрешения (-g), как adb install -r -g',
    () async {
      final (c, exec, _, apk) = await _setup(withReboot: false, grant: true);
      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: _vin, model: _model);

      expect(
        exec.calls.single,
        'pipe:cmd package install -r -g -S ${apk.length}',
      );
    },
  );

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

      // Повторное нажатие не создаёт вторую заявку.
      await c.read(jobControllerProvider.notifier).requestRefund();
      expect(backend.refundCalls, 1);
      expect(c.read(jobControllerProvider).refundable, isFalse);
    },
  );

  group('шаги сценариев из nox.bat', () {
    Future<(ProviderContainer, FakeExecutor, FakeBackend)> setupSteps(
      List<JobStep> steps,
    ) async {
      final key = List<int>.generate(32, (i) => i + 7);
      final bytes = List<int>.generate(700, (i) => i % 200);
      final enc = await PayloadCipher(key).encrypt(bytes);
      final fixed = [
        for (final s in steps)
          s.needsPayload
              ? JobStep(
                  type: s.type,
                  title: s.title,
                  storagePath: 'p',
                  sizeBytes: bytes.length,
                  encKey: PayloadCipher(key).keyBase64,
                  remotePath: s.remotePath,
                  downgrade: s.downgrade,
                )
              : s,
      ];
      final exec = FakeExecutor();
      final backend = FakeBackend(
        JobTicket(jobId: 'j', price: 0, repeat: false, steps: fixed),
        enc,
      );
      final c = ProviderContainer(
        overrides: [
          adbExecutorProvider.overrideWithValue(exec),
          jobBackendProvider.overrideWithValue(backend),
          appVersionProvider.overrideWith((_) async => '1.0.0+1'),
          adbStatusProvider.overrideWith(
            (_) => Stream.value(
              const AdbStatus(AdbConnection.connected, serial: 'A'),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(adbStatusProvider, (_, _) {});
      await c.read(adbStatusProvider.future);
      return (c, exec, backend);
    }

    test('push_file записывает расшифрованный файл на ГУ, install -d, ошибки очистки игнорируются', () async {
      final (c, exec, backend) = await setupSteps(const [
        JobStep(
          type: StepType.pushFile,
          title: 'Загрузка',
          remotePath: "/data/local/tmp/it's.apk",
        ),
        JobStep(type: StepType.installApk, title: 'Системное', downgrade: true),
        JobStep(
          type: StepType.shell,
          title: 'Очистка',
          cmd: 'rm /data/local/tmp/*.apk',
          ignoreErrors: true,
        ),
      ]);
      exec.failShell.add('rm /data/local/tmp/*.apk');
      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: _vin, model: _model);

      expect(c.read(jobControllerProvider).phase, JobPhase.success);
      expect(exec.calls, [
        r"pipe:cat > '/data/local/tmp/it'\''s.apk'",
        'pipe:cmd package install -r -d -S 700',
        'shell:rm /data/local/tmp/*.apk',
      ]);
      expect(exec.received.first.length, 700);
      expect(backend.finished, [true]);
    });

    test('shell без ignore_errors прерывает задание', () async {
      final (c, exec, backend) = await setupSteps(const [
        JobStep(
          type: StepType.shell,
          title: 'Overlay',
          cmd: 'cmd overlay enable x',
        ),
      ]);
      exec.failShell.add('cmd overlay enable x');
      await c
          .read(jobControllerProvider.notifier)
          .run(service: _service, vin: _vin, model: _model);

      expect(c.read(jobControllerProvider).phase, JobPhase.failed);
      expect(backend.finished, [false]);
    });

    test(
      'сценарий JSON из базы разбирается: push_file, downgrade, ignore_errors',
      () {
        final s = JobStep.fromJson({
          'type': 'push_file',
          'title': 't',
          'remote_path': '/x',
          'storage_path': 'p',
          'size_bytes': 5,
          'enc_key': 'k',
        });
        expect(s.type, StepType.pushFile);
        expect(s.remotePath, '/x');
        expect(
          JobStep.fromJson({'type': 'install_apk', 'downgrade': true})
              .downgrade,
          isTrue,
        );
        expect(
          JobStep.fromJson({'type': 'shell', 'ignore_errors': true})
              .ignoreErrors,
          isTrue,
        );
      },
    );
  });
}
