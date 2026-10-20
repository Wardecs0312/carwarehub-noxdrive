import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../adb/adb_executor.dart';
import '../../adb/adb_status_checker.dart';
import '../../app/env.dart';
import '../../core/vin.dart';
import '../../jobs/job_controller.dart';

/// Одна команда диагностики. Все команды только читают: ничего на ГУ не меняют.
class DiagCommand {
  const DiagCommand(this.id, this.title, this.cmd);
  final String id;
  final String title;
  final String cmd;
}

/// Свойства ГУ, которые читаются через getprop.
const diagProps = [
  'ro.product.model',
  'ro.product.board',
  'ro.build.display.id',
  'ro.build.version.release',
  'ro.hardware',
];

/// Фиксированный список команд чтения. Мастер и сервер его не меняют.
final diagCommands = <DiagCommand>[
  for (final p in diagProps)
    DiagCommand('prop:$p', 'Свойство $p', 'getprop $p'),
  // От чьего имени работает adb shell (shell или root): нужно, чтобы понять, требует ли
  // перевод приборки adb root.
  const DiagCommand('id', 'Права ADB', 'id'),
  const DiagCommand('packages', 'Список приложений', 'pm list packages'),
  const DiagCommand(
    'display',
    'Экраны (кратко)',
    'dumpsys display | grep -iE "DisplayDeviceInfo|mDisplayId|mBaseDisplayInfo" | head -n 60',
  ),
  const DiagCommand(
    'services',
    'Службы приборной панели',
    'service list | grep -iE "polymeric|meterdisplay|interactive"',
  ),
];

/// Помощник перевода приборки (пункт 7). Команда probe только проверяет, что служба
/// polymeric_service отвечает, и ничего не переключает.
const diagHelperAsset = 'assets/tools/c281-polymeric-language-helper.jar';
const diagHelperRemote = '/data/local/tmp/nox_diag_polymeric.jar';
const diagProbeCmd =
    'CLASSPATH=$diagHelperRemote app_process /system/bin C281PolymericLanguage probe';

/// Сколько символов вывода одной команды сохраняется (защита от огромных ответов).
const diagMaxOutput = 60000;

/// Метка, по которой из вывода достаётся код завершения команды.
const _exitMark = '__nox_exit=';

/// Команда оборачивается так, чтобы ошибки (stderr) попали в вывод, а код завершения
/// пришёл последней строкой: тогда «grep ничего не нашёл» не считается сбоем ADB.
String wrapDiagCommand(String cmd) => '($cmd) 2>&1; echo "$_exitMark\$?"';

/// Разбор ответа обёрнутой команды: вывод без служебной строки и код завершения.
({String output, int? exit}) parseDiagOutput(String raw) {
  final lines = raw.replaceAll('\r', '').split('\n');
  final i = lines.lastIndexWhere((l) => l.trim().startsWith(_exitMark));
  if (i < 0) return (output: raw.trim(), exit: null);
  final code = int.tryParse(lines[i].trim().substring(_exitMark.length));
  lines.removeAt(i);
  return (output: lines.join('\n').trim(), exit: code);
}

String _clip(String s) => s.length <= diagMaxOutput
    ? s
    : '${s.substring(0, diagMaxOutput)}\n…[обрезано: ${s.length} символов]';

class DiagResult {
  const DiagResult({
    required this.id,
    required this.title,
    required this.cmd,
    this.output = '',
    this.exit,
    this.error,
    this.ms = 0,
  });
  final String id;
  final String title;
  final String cmd;
  final String output;
  final int? exit;
  final String? error;
  final int ms;

  bool get ok => error == null && (exit == null || exit == 0);

  Map<String, dynamic> toJson() => {
    'id': id,
    'cmd': cmd,
    'exit': exit,
    'output': output,
    if (error != null) 'error': error,
    'ms': ms,
  };
}

class DiagReport {
  const DiagReport({
    required this.serial,
    required this.results,
    required this.startedAt,
    this.vin,
    this.appVersion = '',
  });
  final String serial;
  final String? vin;
  final String appVersion;
  final DateTime startedAt;
  final List<DiagResult> results;

  String? _out(String id) {
    for (final r in results) {
      if (r.id == id && r.ok && r.output.isNotEmpty) return r.output;
    }
    return null;
  }

  String? get model => _out('prop:ro.product.model');

  Map<String, dynamic> toJson() => {
    'version': 1,
    'app_version': appVersion,
    'adb_serial': serial,
    'vin': vin,
    'started_at': startedAt.toUtc().toIso8601String(),
    'props': {for (final p in diagProps) p: _out('prop:$p')},
    'results': [for (final r in results) r.toJson()],
  };

  /// Текст для «Скопировать отчёт» (если отправить на сервер не получилось).
  String toText() {
    final b = StringBuffer()
      ..writeln('nox.drive диагностика ${startedAt.toIso8601String()}')
      ..writeln('Программа: $appVersion, ADB: $serial, VIN: ${vin ?? '-'}');
    for (final r in results) {
      b
        ..writeln()
        ..writeln('## ${r.title}: ${r.cmd}')
        ..writeln(
          r.error != null
              ? 'ОШИБКА: ${r.error}'
              : '[код ${r.exit ?? '?'}] ${r.output}',
        );
    }
    return b.toString();
  }
}

/// Загрузка помощника из ресурсов программы (в тестах подменяется).
typedef HelperLoader = Future<List<int>> Function();

Future<List<int>> loadBundledHelper() async {
  final data = await rootBundle.load(diagHelperAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Выполняет команды диагностики по очереди. Ошибка одной команды не останавливает остальные.
class DiagnosticsRunner {
  DiagnosticsRunner(this._adb, {HelperLoader? loadHelper})
    : _loadHelper = loadHelper ?? loadBundledHelper;

  final AdbExecutor _adb;
  final HelperLoader _loadHelper;

  /// Сколько шагов покажет индикатор: разблокировка, команды, проба приборки.
  static int get totalSteps => diagCommands.length + 2;

  Future<DiagReport> run(
    String serial, {
    String? vin,
    String appVersion = '',
    void Function(int done, String title)? onStep,
  }) async {
    final started = DateTime.now();
    final results = <DiagResult>[];
    var step = 0;

    onStep?.call(step, 'Разблокировка ADB');
    results.add(
      await _timed('unlock', 'Разблокировка ADB', 'disable-verify', () async {
        await _adb.unlock(serial);
        return (output: '', exit: null);
      }),
    );
    step++;

    for (final c in diagCommands) {
      onStep?.call(step, c.title);
      results.add(await _shell(serial, c));
      step++;
    }

    onStep?.call(step, 'Проба перевода приборной панели');
    results.addAll(await _probe(serial));
    step++;
    onStep?.call(step, 'Готово');

    return DiagReport(
      serial: serial,
      vin: vin,
      appVersion: appVersion,
      startedAt: started,
      results: results,
    );
  }

  Future<DiagResult> _shell(String serial, DiagCommand c) =>
      _timed(c.id, c.title, c.cmd, () async {
        final raw = await _adb.shell(serial, wrapDiagCommand(c.cmd));
        return parseDiagOutput(raw);
      });

  /// Помощник кладётся во временную папку, выполняется probe, файл сразу удаляется
  /// (удаление идёт, даже если проба упала).
  Future<List<DiagResult>> _probe(String serial) async {
    final out = <DiagResult>[];
    final push = await _timed(
      'helper_push',
      'Копирование помощника приборки',
      'push $diagHelperRemote',
      () async {
        final bytes = await _loadHelper();
        await _adb.push(serial, Stream.value(bytes), diagHelperRemote);
        return (output: '${bytes.length} байт', exit: null);
      },
    );
    out.add(push);
    try {
      if (push.ok) {
        out.add(
          await _shell(
            serial,
            const DiagCommand(
              'cluster_probe',
              'Проба перевода приборной панели',
              diagProbeCmd,
            ),
          ),
        );
      }
    } finally {
      out.add(
        await _shell(
          serial,
          const DiagCommand(
            'helper_rm',
            'Удаление помощника',
            'rm -f $diagHelperRemote',
          ),
        ),
      );
    }
    return out;
  }

  Future<DiagResult> _timed(
    String id,
    String title,
    String cmd,
    Future<({String output, int? exit})> Function() body,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final r = await body();
      return DiagResult(
        id: id,
        title: title,
        cmd: cmd,
        output: _clip(r.output),
        exit: r.exit,
        ms: sw.elapsedMilliseconds,
      );
    } catch (e) {
      return DiagResult(
        id: id,
        title: title,
        cmd: cmd,
        error: _clip('$e'),
        ms: sw.elapsedMilliseconds,
      );
    }
  }
}

/// Куда уходит отчёт диагностики.
abstract class DiagnosticsBackend {
  /// false — демо-режим без сервера: отчёт только показывается и копируется.
  bool get canSend;
  Future<void> send(DiagReport report);
}

class SupabaseDiagnosticsBackend implements DiagnosticsBackend {
  @override
  bool get canSend => true;

  @override
  Future<void> send(DiagReport report) async {
    try {
      // master_id сервер ставит сам (auth.uid()), читать отчёты может только администратор.
      await Supabase.instance.client.from('diagnostics').insert({
        'vin': report.vin,
        'model': report.model,
        'app_version': report.appVersion,
        'payload': report.toJson(),
      });
    } on PostgrestException catch (e) {
      throw Exception(switch (e.code) {
        '42P01' => 'На сервере ещё нет приёма диагностики',
        '42501' => 'Сервер не принял отчёт (не больше 30 в сутки)',
        _ => 'Ошибка сервера: ${e.message}',
      });
    }
  }
}

class DemoDiagnosticsBackend implements DiagnosticsBackend {
  @override
  bool get canSend => false;

  @override
  Future<void> send(DiagReport report) async {}
}

final diagnosticsBackendProvider = Provider<DiagnosticsBackend>(
  (_) =>
      Env.hasSupabase ? SupabaseDiagnosticsBackend() : DemoDiagnosticsBackend(),
);

final diagHelperLoaderProvider = Provider<HelperLoader>(
  (_) => loadBundledHelper,
);

enum DiagPhase { idle, running, sent, notSent }

class DiagState {
  const DiagState({
    this.phase = DiagPhase.idle,
    this.done = 0,
    this.stepTitle = '',
    this.report,
    this.message,
  });
  final DiagPhase phase;
  final int done;
  final String stepTitle;
  final DiagReport? report;

  /// Почему отчёт не ушёл на сервер (или что это демо-режим).
  final String? message;

  double get progress => done / DiagnosticsRunner.totalSteps;
}

class DiagnosticsController extends Notifier<DiagState> {
  @override
  DiagState build() => const DiagState();

  void reset() => state = const DiagState();

  /// [vin] — что мастер ввёл в поле VIN (необязательно: неверный VIN просто не попадёт в отчёт).
  Future<void> run({String vin = ''}) async {
    if (state.phase == DiagPhase.running) return;
    final adb = ref.read(adbStatusProvider).value;
    final serial = adb?.serial;
    if (adb == null || !adb.isReady || serial == null) {
      state = DiagState(
        phase: DiagPhase.notSent,
        message: adb?.blockedHint ?? 'Подключите автомобиль по USB/ADB',
      );
      return;
    }
    state = const DiagState(phase: DiagPhase.running, stepTitle: 'Начало');
    final v = normalizeVin(vin);
    String version = '';
    try {
      version = await ref.read(appVersionProvider.future);
    } catch (_) {}
    final report =
        await DiagnosticsRunner(
          ref.read(adbExecutorProvider),
          loadHelper: ref.read(diagHelperLoaderProvider),
        ).run(
          serial,
          vin: isValidVin(v) ? v : null,
          appVersion: version,
          onStep: (done, title) => state = DiagState(
            phase: DiagPhase.running,
            done: done,
            stepTitle: title,
          ),
        );
    final backend = ref.read(diagnosticsBackendProvider);
    if (!backend.canSend) {
      state = DiagState(
        phase: DiagPhase.notSent,
        done: DiagnosticsRunner.totalSteps,
        report: report,
        message: 'Демо-режим: отчёт не отправлен на сервер',
      );
      return;
    }
    state = DiagState(
      phase: DiagPhase.running,
      done: DiagnosticsRunner.totalSteps,
      stepTitle: 'Отправка администратору',
      report: report,
    );
    try {
      await backend.send(report).timeout(const Duration(seconds: 30));
      state = DiagState(
        phase: DiagPhase.sent,
        done: DiagnosticsRunner.totalSteps,
        report: report,
      );
    } catch (e) {
      state = DiagState(
        phase: DiagPhase.notSent,
        done: DiagnosticsRunner.totalSteps,
        report: report,
        message: e is TimeoutException
            ? 'Сервер не ответил за 30 секунд'
            : '$e'.replaceFirst('Exception: ', ''),
      );
    }
  }
}

final diagnosticsControllerProvider =
    NotifierProvider<DiagnosticsController, DiagState>(
      DiagnosticsController.new,
    );
