import 'dart:io';

import 'package:carwarehub_noxdrive/adb/adb_executor.dart';
import 'package:carwarehub_noxdrive/adb/adb_status.dart';
import 'package:carwarehub_noxdrive/adb/adb_status_checker.dart';
import 'package:carwarehub_noxdrive/features/diagnostics/diagnostics.dart';
import 'package:carwarehub_noxdrive/features/diagnostics/diagnostics_ui.dart';
import 'package:carwarehub_noxdrive/jobs/job_controller.dart';
import 'package:carwarehub_noxdrive/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// ГУ, которое отвечает на команды диагностики как настоящее.
class DiagExecutor extends FakeExecutor {
  /// Подстрока команды → что ответит ГУ (без служебной строки с кодом).
  final answers = <String, String>{
    'getprop ro.product.model': 'C281MCA2',
    'pm list packages': 'package:com.android.settings\npackage:com.tinnove.x',
    'service list': '12\tpolymeric_service: [com.tinnove.polymericservice.IPolymericService]',
    'C281PolymericLanguage probe': 'binderAlive=true\nprobe=ok',
  };

  /// Команды с такой подстрокой завершатся с кодом 1 (как grep без совпадений).
  final exitOne = <String>{};

  /// Команды с такой подстрокой падают на стороне ADB (ГУ не ответило).
  final throwOn = <String>{};

  bool failPush = false;

  @override
  Future<void> unlock(String serial) async {
    calls.add('unlock');
    await super.unlock(serial);
  }

  @override
  Future<String> shell(String serial, String command) async {
    calls.add('shell:$command');
    for (final t in throwOn) {
      if (command.contains(t)) throw AdbException('Устройство не ответило');
    }
    var out = '';
    for (final e in answers.entries) {
      if (command.contains(e.key)) out = e.value;
    }
    final code = exitOne.any(command.contains) ? 1 : 0;
    return '$out\n__nox_exit=$code';
  }

  @override
  Future<void> push(
    String serial,
    Stream<List<int>> data,
    String remotePath, {
    void Function(int sent)? onProgress,
  }) async {
    if (failPush) {
      calls.add('push $remotePath');
      throw AdbException('нет места');
    }
    await super.push(serial, data, remotePath, onProgress: onProgress);
  }
}

class FakeDiagBackend implements DiagnosticsBackend {
  final sent = <DiagReport>[];
  bool fail = false;

  @override
  bool get canSend => true;

  @override
  Future<void> send(DiagReport report) async {
    if (fail) throw Exception('На сервере ещё нет приёма диагностики');
    sent.add(report);
  }
}

const _helper = [1, 2, 3, 4];

DiagnosticsRunner _runner(DiagExecutor e) =>
    DiagnosticsRunner(e, loadHelper: () async => _helper);

ProviderContainer _container(
  DiagExecutor exec,
  DiagnosticsBackend backend, {
  AdbStatus adb = const AdbStatus(AdbConnection.connected, serial: 'A'),
}) {
  final c = ProviderContainer(
    overrides: [
      adbExecutorProvider.overrideWithValue(exec),
      diagnosticsBackendProvider.overrideWithValue(backend),
      diagHelperLoaderProvider.overrideWithValue(() async => _helper),
      appVersionProvider.overrideWith((_) async => '2.0.30+30'),
      adbStatusProvider.overrideWith((_) => Stream.value(adb)),
    ],
  );
  addTearDown(c.dispose);
  c.listen(adbStatusProvider, (_, _) {});
  return c;
}

void main() {
  group('разбор вывода', () {
    test('код завершения берётся из служебной строки', () {
      final r = parseDiagOutput('a\r\nb\r\n__nox_exit=1\r\n');
      expect(r.output, 'a\nb');
      expect(r.exit, 1);
    });

    test('без служебной строки код неизвестен', () {
      final r = parseDiagOutput('verify password: verify failed!');
      expect(r.exit, isNull);
      expect(r.output, 'verify password: verify failed!');
    });

    test('обёртка собирает stderr и печатает код', () {
      expect(wrapDiagCommand('id'), r'(id) 2>&1; echo "__nox_exit=$?"');
    });
  });

  test('в списке только команды чтения', () {
    final all = [for (final c in diagCommands) c.cmd, diagProbeCmd];
    for (final cmd in all) {
      expect(
        cmd,
        isNot(
          matches(
            RegExp(
              r'\b(setprop|install|uninstall|reboot|settings put|rm|dd|set ru)\b',
            ),
          ),
        ),
        reason: cmd,
      );
    }
    expect(diagProbeCmd, endsWith(' probe'));
  });

  test(
    'разблокировка первой, затем команды, проба приборки и удаление помощника',
    () async {
      final e = DiagExecutor();
      final steps = <String>[];
      final r = await _runner(e).run(
        'A',
        vin: 'LS5A3ABC4NA000123',
        appVersion: '2.0.30+30',
        onStep: (_, t) => steps.add(t),
      );

      expect(e.calls.first, 'unlock');
      expect(
        e.calls.where((c) => c.startsWith('shell:')).first,
        contains('getprop'),
      );
      final push = e.calls.indexOf('push $diagHelperRemote');
      final probe = e.calls.indexWhere((c) => c.contains('probe'));
      final rm = e.calls.indexWhere(
        (c) => c.contains('rm -f $diagHelperRemote'),
      );
      expect(push, greaterThan(0));
      expect(probe, greaterThan(push));
      expect(rm, greaterThan(probe));
      expect(e.received.last, _helper);
      expect(steps.last, 'Готово');

      expect(r.model, 'C281MCA2');
      final json = r.toJson();
      expect(json['vin'], 'LS5A3ABC4NA000123');
      expect((json['props'] as Map)['ro.product.model'], 'C281MCA2');
      final probeResult = r.results.firstWhere((x) => x.id == 'cluster_probe');
      expect(probeResult.output, contains('probe=ok'));
      expect(probeResult.ok, isTrue);
    },
  );

  test('ошибка одной команды не останавливает остальные', () async {
    final e = DiagExecutor()
      ..throwOn.add('pm list packages')
      ..exitOne.add('service list');
    final r = await _runner(e).run('A');
    final pkgs = r.results.firstWhere((x) => x.id == 'packages');
    expect(pkgs.error, contains('не ответило'));
    expect(r.results.firstWhere((x) => x.id == 'services').exit, 1);
    expect(r.results.any((x) => x.id == 'cluster_probe'), isTrue);
    expect(r.toText(), contains('ОШИБКА: Устройство не ответило'));
  });

  test(
    'помощник не скопировался: проба пропущена, удаление всё равно идёт',
    () async {
      final e = DiagExecutor()..failPush = true;
      final r = await _runner(e).run('A');
      expect(r.results.any((x) => x.id == 'cluster_probe'), isFalse);
      expect(
        r.results.firstWhere((x) => x.id == 'helper_push').error,
        isNotNull,
      );
      expect(e.calls.last, contains('rm -f $diagHelperRemote'));
    },
  );

  test('проба упала: помощник удалён', () async {
    final e = DiagExecutor()..throwOn.add('C281PolymericLanguage');
    final r = await _runner(e).run('A');
    expect(
      r.results.firstWhere((x) => x.id == 'cluster_probe').error,
      isNotNull,
    );
    expect(e.calls.last, contains('rm -f $diagHelperRemote'));
  });

  test('огромный вывод обрезается', () async {
    final e = DiagExecutor()
      ..answers['pm list packages'] = 'x' * (diagMaxOutput + 10);
    final r = await _runner(e).run('A');
    final out = r.results.firstWhere((x) => x.id == 'packages').output;
    expect(out.length, lessThan(diagMaxOutput + 100));
    expect(out, contains('обрезано'));
  });

  group('контроллер', () {
    test('отчёт уходит на сервер', () async {
      final b = FakeDiagBackend();
      final c = _container(DiagExecutor(), b);
      await c.read(adbStatusProvider.future);
      await c
          .read(diagnosticsControllerProvider.notifier)
          .run(vin: 'ls5a3abc4na000123');
      final s = c.read(diagnosticsControllerProvider);
      expect(s.phase, DiagPhase.sent);
      expect(s.progress, 1);
      expect(b.sent.single.vin, 'LS5A3ABC4NA000123');
      expect(b.sent.single.appVersion, '2.0.30+30');
    });

    test('неверный VIN не попадает в отчёт', () async {
      final b = FakeDiagBackend();
      final c = _container(DiagExecutor(), b);
      await c.read(adbStatusProvider.future);
      await c.read(diagnosticsControllerProvider.notifier).run(vin: '123');
      expect(b.sent.single.vin, isNull);
    });

    test('сервер не принял: отчёт остаётся для копирования', () async {
      final b = FakeDiagBackend()..fail = true;
      final c = _container(DiagExecutor(), b);
      await c.read(adbStatusProvider.future);
      await c.read(diagnosticsControllerProvider.notifier).run();
      final s = c.read(diagnosticsControllerProvider);
      expect(s.phase, DiagPhase.notSent);
      expect(s.report, isNotNull);
      expect(s.message, 'На сервере ещё нет приёма диагностики');
    });

    test('без ADB ничего не выполняется', () async {
      final e = DiagExecutor();
      final c = _container(
        e,
        FakeDiagBackend(),
        adb: const AdbStatus(AdbConnection.disconnected),
      );
      await c.read(adbStatusProvider.future);
      await c.read(diagnosticsControllerProvider.notifier).run();
      final s = c.read(diagnosticsControllerProvider);
      expect(s.phase, DiagPhase.notSent);
      expect(s.report, isNull);
      expect(e.calls, isEmpty);
    });
  });

  test('помощник приборки лежит в ресурсах программы', () {
    final f = File(diagHelperAsset);
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), 3544);
  });

  testWidgets('кнопка: подтверждение, ход и итог в демо-режиме', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final exec = DiagExecutor();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adbStatusProvider.overrideWith(
            (_) => Stream.value(
              const AdbStatus(AdbConnection.connected, serial: 'A'),
            ),
          ),
          adbExecutorProvider.overrideWithValue(exec),
          diagHelperLoaderProvider.overrideWithValue(() async => _helper),
          appVersionProvider.overrideWith((_) async => '2.0.30+30'),
        ],
        child: const NoxDriveApp(),
      ),
    );
    await tester.pumpAndSettle();
    // При подключении ГУ программа сама читает VIN (разблокировка и чтение настроек) —
    // это не диагностика, поэтому дальше считаем только её команды.
    exec.calls.clear();

    final button = find.byKey(const Key('diagnostics-button'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text(diagConfirmText), findsOneWidget);
    expect(
      exec.calls,
      isEmpty,
      reason: 'до подтверждения ничего не выполняется',
    );

    await tester.tap(find.byKey(const Key('diagnostics-confirm')));
    await tester.pumpAndSettle();

    expect(exec.calls.first, 'unlock');
    expect(find.byKey(const Key('diagnostics-not-sent')), findsOneWidget);
    expect(find.textContaining('Демо-режим'), findsOneWidget);
    expect(find.byKey(const Key('diagnostics-copy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnostics-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagnostics-close')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('без ADB кнопка заблокирована', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adbStatusProvider.overrideWith(
            (_) => Stream.value(const AdbStatus(AdbConnection.disconnected)),
          ),
        ],
        child: const NoxDriveApp(),
      ),
    );
    await tester.pumpAndSettle();
    final b = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('diagnostics-button')),
    );
    expect(b.onPressed, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
