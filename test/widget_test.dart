import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/app/theme.dart';
import 'package:carwarehub_noxdrive/jobs/job_controller.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _vin = 'LS5A3ABC4NA000123';

Future<void> _pump(
  WidgetTester tester,
  AdbStatus status, {
  String? vin,
  FakeExecutor? executor,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adbStatusProvider.overrideWith((_) => Stream.value(status)),
        // Настоящий adb в тестах не запускается: ГУ «не хранит» VIN, поле заполняет тест.
        adbExecutorProvider.overrideWithValue(executor ?? FakeExecutor()),
      ],
      child: const NoxDriveApp(),
    ),
  );
  await tester.pumpAndSettle();
  if (vin != null) {
    await tester.enterText(find.byKey(const Key('vin-field')), vin);
  }
  await tester.tap(find.text('Changan Q05'));
  await tester.pumpAndSettle();
}

Color _dotColor(WidgetTester tester) =>
    ((tester.widget<Container>(find.byKey(const Key('adb-dot')))).decoration
            as BoxDecoration)
        .color!;

Iterable<InkWell> _cards(WidgetTester tester) => tester.widgetList<InkWell>(
  find.descendant(of: find.byType(Card), matching: find.byType(InkWell)),
);

void main() {
  testWidgets('шапка: бренд и контакт поддержки', (tester) async {
    await _pump(tester, const AdbStatus(AdbConnection.disconnected));
    expect(find.text('nox.drive'), findsOneWidget);
    expect(find.text('AUTOMOTIVE TECHNOLOGY'), findsOneWidget);
    expect(find.text('ДЛЯ АДБ ДОСТУПА ПИСАТЬ В ТГ @wiqqq99'), findsOneWidget);
    expect(find.text('INSTAGRAM @nox.drive.kg'), findsOneWidget);
  });

  testWidgets('нет ADB: красный индикатор, услуги заблокированы с подсказкой', (
    tester,
  ) async {
    await _pump(tester, const AdbStatus(AdbConnection.disconnected), vin: _vin);

    expect(find.text('ADB: Не подключено'), findsOneWidget);
    expect(_dotColor(tester), NoxColors.bad);
    expect(find.byTooltip('Подключите автомобиль по USB/ADB'), findsWidgets);
    expect(
      tester.widget<Text>(find.byKey(const Key('blocked-reason'))).data,
      'Подключите автомобиль по USB/ADB',
    );
    expect(_cards(tester), isNotEmpty);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });

  testWidgets('ADB есть, но VIN не введён: услуги заблокированы', (
    tester,
  ) async {
    await _pump(tester, const AdbStatus(AdbConnection.connected, serial: 'A'));

    expect(find.text('ADB: Подключено (Устройство активно)'), findsOneWidget);
    expect(_dotColor(tester), NoxColors.ok);
    expect(find.byTooltip('Введите VIN (17 символов)'), findsWidgets);
    expect(find.byKey(const Key('blocked-reason')), findsOneWidget);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });

  testWidgets('«Назад» возвращает к выбору модели', (tester) async {
    await _pump(tester, const AdbStatus(AdbConnection.connected, serial: 'A'));
    expect(_cards(tester), isNotEmpty);
    await tester.tap(find.byKey(const Key('back-to-models')));
    await tester.pumpAndSettle();
    expect(_cards(tester), isEmpty);
    expect(find.text('Выберите модель автомобиля'), findsOneWidget);
  });

  testWidgets('ADB и VIN готовы: услуги активны', (tester) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A'),
      vin: _vin,
    );

    expect(find.text('Русификация и установка приложений'), findsOneWidget);
    expect(_cards(tester).length, 7);
    expect(find.byKey(const Key('blocked-reason')), findsNothing);
    expect(_cards(tester).every((w) => w.onTap != null), isTrue);
  });

  testWidgets('голос: сначала выбор штатный/кастомный, потом подтверждение', (
    tester,
  ) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A'),
      vin: _vin,
    );
    // Кастомный голос не отдельная карточка, а вариант кнопки голосового управления.
    expect(find.text('Установка кастомного голоса'), findsNothing);
    await tester.tap(find.text('Установка голосового управления'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('variant-choice')), findsOneWidget);
    expect(find.text('Штатный голос'), findsOneWidget);
    expect(find.text('Входит в пакет, без доплаты'), findsOneWidget);
    expect(find.text('Кастомный голос MMVoice'), findsOneWidget);
    expect(find.text('2 кр.'), findsOneWidget);
    // Пока вариант не выбран, дальше не пройти.
    final next = find.descendant(
      of: find.byKey(const Key('variant-next')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(next).onPressed, isNull);

    await tester.tap(find.byKey(const Key('variant-voicecustom')));
    await tester.pump();
    await tester.tap(next);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('variant-choice')), findsNothing);
    expect(find.text('Подтвердите загрузку на автомобиль'), findsOneWidget);
    expect(find.text('Установка кастомного голоса'), findsOneWidget);
  });

  testWidgets(
    'кастомный голос недоступен на Android 9 (MMVoice требует Android 11)',
    (tester) async {
      final exec = FakeExecutor()
        ..shellReplies['getprop ro.build.version.sdk'] = '28';
      await _pump(
        tester,
        const AdbStatus(AdbConnection.connected, serial: 'A'),
        vin: _vin,
        executor: exec,
      );
      await tester.tap(find.text('Установка голосового управления'));
      await tester.pumpAndSettle();

      expect(
        find.text('Нужен Android 11 или новее, на машине Android 9'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('variant-voicecustom')));
      await tester.pump();
      final next = find.descendant(
        of: find.byKey(const Key('variant-next')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(next).onPressed, isNull);
      // Штатный голос выбрать можно.
      await tester.tap(find.byKey(const Key('variant-voice')));
      await tester.pump();
      expect(tester.widget<FilledButton>(next).onPressed, isNotNull);
    },
  );

  testWidgets('VIN с буквой O считается неверным', (tester) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A'),
      vin: 'LS5A3ABC1NO000123',
    );
    // Подсказка видна под полем и в строке причины над услугами.
    expect(find.text('В VIN нет букв I, O, Q'), findsWidgets);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });

  testWidgets('ГУ подключили: VIN читается с машины, модель выбирается сама', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // adb работает только в программе для Windows; тест притворяется Windows.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final exec = FakeExecutor()..vinOnDevice = 'LS6CME0F7TB000002';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adbStatusProvider.overrideWith(
            (_) => Stream.value(
              const AdbStatus(AdbConnection.connected, serial: 'A'),
            ),
          ),
          adbExecutorProvider.overrideWithValue(exec),
        ],
        child: const NoxDriveApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(exec.unlocks, greaterThan(0));
    expect(exec.vinReads, 1);
    expect(find.text('LS6CME0F7TB000002'), findsOneWidget);
    expect(
      find.text('VIN определён с машины, модель: Changan Q05'),
      findsOneWidget,
    );
    expect(find.text('Русификация и установка приложений'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('VIN с опечаткой: услуги закрыты, мастер видит причину', (
    tester,
  ) async {
    await _pump(
      tester,
      const AdbStatus(AdbConnection.connected, serial: 'A'),
      vin: 'LS5A3ABC1NA000123',
    );
    expect(find.textContaining('не сходится контрольная цифра'), findsWidgets);
    expect(_cards(tester).every((w) => w.onTap == null), isTrue);
  });
}
