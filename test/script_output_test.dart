import 'dart:convert';
import 'dart:io';

import 'package:carwarehub_noxdrive/adb/adb_executor.dart';
import 'package:carwarehub_noxdrive/adb/adb_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'base64 строками: ГУ соберёт ровно те же байты (запасной путь Q07)',
    () async {
      final data = List<int>.generate(70001, (i) => (i * 31) % 256);
      final chunks = [
        data.sublist(0, 5),
        data.sublist(5, 40000),
        data.sublist(40000),
      ];
      final text = ascii.decode([
        for (final c in await base64Lines(Stream.fromIterable(chunks)).toList())
          ...c,
      ]);
      final lines = text.trimRight().split('\n');
      expect(lines.every((l) => l.length <= 76), isTrue);
      expect(base64.decode(lines.join()), data);
    },
  );

  test('закрытое без ответа соединение = ГУ не принимает копирование adb', () {
    expect(syncRefused(AdbStallException('adb закрыл соединение')), isTrue);
    expect(
      syncRefused(AdbStallException('Связь с adb прервалась: Write failed')),
      isTrue,
    );
    expect(syncRefused(AdbStallException('Передача замерла')), isFalse);
  });

  test('код выхода и вывод скрипта берутся из метки', () {
    expect(parseScriptOutput('line 1\r\nError: x\r\nNOX_SCRIPT_EXIT=3\r\n'), (
      code: 3,
      output: 'line 1\nError: x',
    ));
    expect(parseScriptOutput('NOX_SCRIPT_EXIT=0\n'), (code: 0, output: ''));
  });

  test('нет метки: скрипт прерван', () {
    expect(parseScriptOutput("error: device 'A' not found"), isNull);
    expect(parseScriptOutput(''), isNull);
  });

  test('та же команда, что уходит в adb shell, на настоящем sh', () async {
    final dir = await Directory.systemTemp.createTemp('nox_script');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path.replaceAll(r'\', '/')}/s.sh';
    for (final (body, code) in [('echo hi', 0), ('echo bad >&2; exit 4', 4)]) {
      File(path).writeAsStringSync(body);
      final r = await Process.run('sh', [
        '-c',
        'sh $path 2>&1; echo "$scriptExitMarker\$?"; rm -f $path',
      ]);
      final parsed = parseScriptOutput('${r.stdout}${r.stderr}')!;
      expect(parsed.code, code);
      expect(parsed.output, code == 0 ? 'hi' : 'bad');
      expect(File(path).existsSync(), isFalse);
    }
  }, skip: !_hasSh());
}

bool _hasSh() {
  try {
    return Process.runSync('sh', ['-c', 'true']).exitCode == 0;
  } catch (_) {
    return false;
  }
}
