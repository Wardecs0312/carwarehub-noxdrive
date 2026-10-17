import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/jobs/apk_picker.dart';
import 'package:carwarehub_noxdrive/jobs/custom_apk_store.dart';
import 'package:carwarehub_noxdrive/jobs/job_controller.dart';
import 'package:carwarehub_noxdrive/jobs/job_models.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<void> _open(
  WidgetTester tester,
  FakePicker picker,
  FakeBackend backend,
  FakeExecutor exec, {
  MemoryApkStore? store,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adbStatusProvider.overrideWith(
          (_) => Stream.value(
            const AdbStatus(AdbConnection.connected, serial: 'A'),
          ),
        ),
        apkPickerProvider.overrideWithValue(picker),
        customApkStoreProvider.overrideWithValue(store ?? MemoryApkStore()),
        jobBackendProvider.overrideWithValue(backend),
        adbExecutorProvider.overrideWithValue(exec),
        appVersionProvider.overrideWith((_) async => '1.0.0+1'),
      ],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('vin-field')),
    'LS5A3ABC1NA000123',
  );
  await tester.tap(find.text('Changan Q05'));
  await tester.pumpAndSettle();
}

void main() {
  const a = CustomApk(
    path: '/x/YandexNavigator.apk',
    name: 'YandexNavigator.apk',
    sizeBytes: 5 * 1024 * 1024,
  );
  const b = CustomApk(path: '/x/Other.apk', name: 'Other.apk', sizeBytes: 2048);

  testWidgets(
    'услуга [1] открывает окно настройки пакета, а не запускается сразу',
    (tester) async {
      final backend = FakeBackend(
        const JobTicket(jobId: 'j', price: 0, repeat: false, steps: []),
        const [],
      );
      final exec = FakeExecutor();
      await _open(tester, FakePicker([a, b]), backend, exec);

      await tester.tap(find.text('Русификация и установка приложений'));
      await tester.pumpAndSettle();

      expect(find.text('Настройка пакета установки'), findsOneWidget);
      expect(find.text('Яндекс Навигатор'), findsOneWidget); // основной пакет
      expect(find.text('Свои файлы не добавлены'), findsOneWidget);
      expect(exec.calls, isEmpty);

      await tester.tap(find.byKey(const Key('add-apk')));
      await tester.pumpAndSettle();
      expect(find.text('YandexNavigator.apk'), findsOneWidget);
      expect(find.text('5.0 МБ'), findsOneWidget);
      expect(find.text('2 КБ'), findsOneWidget);
      expect(find.text('Начать установку (+2)'), findsOneWidget);

      // снять галочку с первого файла
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('Начать установку (+1)'), findsOneWidget);

      // убрать второй из списка
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      expect(find.text('Other.apk'), findsNothing);
      expect(find.text('Начать установку'), findsOneWidget);
    },
  );

  testWidgets(
    'свои APK запоминаются: при следующем открытии окна они уже в списке',
    (tester) async {
      final store = MemoryApkStore([a, b.copyWith(selected: false)]);
      final backend = FakeBackend(
        const JobTicket(jobId: 'j', price: 0, repeat: false, steps: []),
        const [],
      );
      await _open(
        tester,
        FakePicker(const []),
        backend,
        FakeExecutor(),
        store: store,
      );

      await tester.tap(find.text('Русификация и установка приложений'));
      await tester.pumpAndSettle();

      // Добавлены раньше: оба в списке, галочки как были.
      expect(find.text('YandexNavigator.apk'), findsOneWidget);
      expect(find.text('Other.apk'), findsOneWidget);
      expect(find.text('Начать установку (+1)'), findsOneWidget);

      // Удаление тоже запоминается.
      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      expect(store.saved.map((x) => x.name), ['YandexNavigator.apk']);
    },
  );

  testWidgets('установка начинается только после «Подтвердить загрузку»', (
    tester,
  ) async {
    final backend = FakeBackend(
      const JobTicket(jobId: 'j', price: 0, repeat: false, steps: []),
      const [],
    );
    final exec = FakeExecutor();
    await _open(tester, FakePicker(const []), backend, exec);
    await tester.tap(find.text('Русификация и установка приложений'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Начать установку'));
    await tester.pumpAndSettle();
    expect(find.text('Подтвердите загрузку на автомобиль'), findsOneWidget);
    expect(find.text('LS5A3ABC1NA000123'), findsWidgets);
    expect(backend.finished, isEmpty, reason: 'ещё ничего не запущено');

    await tester.tap(find.byKey(const Key('confirm-back')));
    await tester.pumpAndSettle();
    expect(find.text('Настройка пакета установки'), findsOneWidget);

    await tester.tap(find.text('Начать установку'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-load')));
    await tester.pumpAndSettle();
    expect(backend.finished, [
      true,
    ], reason: 'установка прошла после подтверждения');
  });

  testWidgets('отмена не запускает установку', (tester) async {
    final exec = FakeExecutor();
    await _open(
      tester,
      FakePicker([a]),
      FakeBackend(
        const JobTicket(jobId: 'j', price: 0, repeat: false, steps: []),
        const [],
      ),
      exec,
    );
    await tester.tap(find.text('Русификация и установка приложений'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    expect(find.text('Настройка пакета установки'), findsNothing);
    expect(exec.calls, isEmpty);
    expect(find.byKey(const Key('job-progress')), findsNothing);
  });

  testWidgets(
    'услуга без своих APK: сразу «Подтвердите загрузку», запуск только после кнопки',
    (tester) async {
      final exec = FakeExecutor();
      await _open(
        tester,
        FakePicker([]),
        FakeBackend(
          const JobTicket(
            jobId: 'j',
            price: 0,
            repeat: false,
            steps: [
              JobStep(type: StepType.shell, title: 'Проверка', cmd: 'echo'),
            ],
          ),
          const [],
        ),
        exec,
      );
      await tester.tap(find.text('Перезагрузка автомобиля'));
      await tester.pumpAndSettle();

      expect(find.text('Настройка пакета установки'), findsNothing);
      expect(find.text('Подтвердите загрузку на автомобиль'), findsOneWidget);
      expect(find.text('Свои APK'), findsNothing);
      expect(exec.calls, isEmpty); // без подтверждения ничего не запускается

      await tester.tap(find.byKey(const Key('confirm-load')));
      await tester.pumpAndSettle();
      expect(find.text('Услуга успешно выполнена'), findsOneWidget);
      expect(exec.calls, ['shell:echo']);
    },
  );

  testWidgets('услуга без своих APK: «Отмена» ничего не запускает', (
    tester,
  ) async {
    final exec = FakeExecutor();
    await _open(
      tester,
      FakePicker([]),
      FakeBackend(
        const JobTicket(
          jobId: 'j',
          price: 0,
          repeat: false,
          steps: [
            JobStep(type: StepType.shell, title: 'Проверка', cmd: 'echo'),
          ],
        ),
        const [],
      ),
      exec,
    );
    await tester.tap(find.text('Перезагрузка автомобиля'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-back')));
    await tester.pumpAndSettle();
    expect(find.text('Подтвердите загрузку на автомобиль'), findsNothing);
    expect(exec.calls, isEmpty);
  });

  testWidgets(
    'машина не ответила при расчёте цены: подтверждение всё равно есть и запускает услугу',
    (tester) async {
      final exec = FakeExecutor();
      final backend = FakeBackend(
        const JobTicket(
          jobId: 'j',
          price: 0,
          repeat: false,
          steps: [
            JobStep(type: StepType.shell, title: 'Проверка', cmd: 'echo'),
          ],
        ),
        const [],
      )..failPreview = true;
      await _open(tester, FakePicker([]), backend, exec);
      await tester.tap(find.text('Перезагрузка автомобиля'));
      await tester.pumpAndSettle();

      expect(find.text('Подтвердите загрузку на автомобиль'), findsOneWidget);
      expect(find.text('определится при запуске'), findsOneWidget);
      expect(
        exec.unlocks,
        greaterThanOrEqualTo(1),
      ); // разблокировка до чтения машины
      expect(exec.readBeforeUnlock, isFalse);
      expect(exec.calls, isEmpty);

      await tester.tap(find.byKey(const Key('confirm-load')));
      await tester.pumpAndSettle();
      expect(find.text('Услуга успешно выполнена'), findsOneWidget);
    },
  );
}
