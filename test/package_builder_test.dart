import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import '../tool/package_builder.dart';

Archive _zip(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, bytes) => a.addFile(ArchiveFile.bytes(name, bytes)));
  return a;
}

const _prep = 'echo SECRET | disable-verify 1';

Map<String, String> _ids(RecipePlan p) => {
  for (final f in p.files) f.key: 'id:${f.key}',
};

void main() {
  group('русификация [1]', () {
    final zip = _zip({
      'nox.bat': [1],
      'soft/b_Maps.apk': [1, 2],
      'soft/A_keyboard.APK': [3],
      'soft/readme.txt': [4],
      'soft/sub/inner.apk': [5],
      'other/x.apk': [6],
    });

    test('берёт только .apk из soft, по алфавиту без учёта регистра', () {
      final plan = planRussify(zip, prep: _prep);
      expect(plan.files.map((f) => f.key), [
        'pre.sh',
        'soft/A_keyboard.APK',
        'soft/b_Maps.apk',
      ]);
    });

    test('подготовка повторяет батник: доступ, настройки, setprop', () {
      final plan = planRussify(zip, prep: _prep);
      final script = String.fromCharCodes(plan.files.first.bytes);
      expect(script.split('\n'), [
        _prep,
        'am start -n com.android.settings/.Settings',
        'setprop vecentek.model 1',
        '',
      ]);
    });

    test('приложения ставятся с выдачей разрешений (-g)', () {
      final steps = planRussify(
        zip,
        prep: _prep,
      ).steps(_ids(planRussify(zip, prep: _prep)));
      expect(steps.map((s) => s['type']), [
        'run_script',
        'install_apk',
        'install_apk',
      ]);
      expect(steps[1], {
        'type': 'install_apk',
        'title': 'Установка: A_keyboard',
        'payload_id': 'id:soft/A_keyboard.APK',
        'grant': true,
      });
    });

    test('понимает обратные слэши и лишнюю корневую папку', () {
      final plan = planRussify(
        _zip({
          r'nox\soft\app.apk': [1],
        }),
        prep: _prep,
      );
      expect(plan.files.map((f) => f.key), ['pre.sh', 'soft/app.apk']);
    });

    test(
      'нет apk: пакет только из подготовки, приложения добавляет мастер',
      () {
        final plan = planRussify(
          _zip({
            'x.txt': [1],
          }),
          prep: _prep,
        );
        expect(plan.files.map((f) => f.key), ['pre.sh']);
        expect(plan.steps(_ids(plan)).map((s) => s['type']), ['run_script']);
      },
    );
  });

  group('системные приложения [5]', () {
    final zip = _zip({
      'firmware/Z.apk': [1],
      'firmware/A.apk': [2],
    });

    test('установка с понижением версии (-d) и три overlay', () {
      final plan = planSystemApps(zip, prep: _prep);
      final steps = plan.steps(_ids(plan));
      expect(steps.map((s) => s['type']), [
        'run_script',
        'install_apk',
        'install_apk',
        'shell',
        'shell',
        'shell',
      ]);
      expect(steps[1]['downgrade'], true);
      expect(steps[1].containsKey('grant'), isFalse);
      expect(
        steps[3]['cmd'],
        'cmd overlay enable com.google.android.overlay.aiassistant',
      );
      expect(
        steps[5]['cmd'],
        'cmd overlay enable com.google.android.overlay.carlauncher',
      );
      // в предпросмотре мастера одна строка «Включение Overlay»
      expect(
        steps.where((s) => s['hidden'] != true && s['type'] == 'shell').length,
        1,
      );
    });

    test(
      'в скрипте подготовки нет am start (в батнике его нет для этой ветки)',
      () {
        final script = String.fromCharCodes(
          planSystemApps(zip, prep: _prep).files.first.bytes,
        );
        expect(script, '$_prep\nsetprop vecentek.model 1\n');
      },
    );
  });

  group('голосовое управление [2]', () {
    final zip = _zip({
      'nox/WT_SpeechMiddleware.apk': [1],
      'nox/SpeechHMI.apk': [2],
      'nox/IflytekSpeech/a.bin': [3],
      'nox/IflytekSpeech/res/b.bin': [4],
      'nox/WT_ThemeResourcesDay/WT_ThemeResourcesDay.apk': [5],
      'nox/WT_ThemeResourcesNight/WT_ThemeResourcesNight.apk': [6],
    });

    test('packed: ресурсы одним tar, распаковка сразу в tinnove, без тем', () {
      final plan = planVoice(zip, prep: _prep, packed: true, themes: false);
      final steps = plan.steps(_ids(plan));
      final cmds = [
        for (final s in steps)
          if (s['type'] == 'shell') s['cmd'],
      ];
      expect(cmds, [
        'pm install -g -r /data/local/tmp/SpeechHMI.apk',
        'tar -xf /data/local/tmp/IflytekSpeech.tar -C /resources/appdata/tinnove/',
        'mv /data/local/tmp/SpeechHMI.apk /resources/appdata/tinnove/',
        'mv /data/local/tmp/WT_SpeechMiddleware.apk /resources/appdata/tinnove/',
        'rm -f /data/local/tmp/IflytekSpeech.tar',
        'rm /data/local/tmp/*.apk',
      ]);
      final pushes = [
        for (final s in steps)
          if (s['type'] == 'push_file') s['remote_path'],
      ];
      expect(pushes, [
        '/data/local/tmp/WT_SpeechMiddleware.apk',
        '/data/local/tmp/SpeechHMI.apk',
        '/data/local/tmp/IflytekSpeech.tar',
      ]);
      final tarFile = plan.files.firstWhere((f) => f.key == 'IflytekSpeech.tar');
      final names = TarDecoder()
          .decodeBytes(tarFile.bytes)
          .files
          .where((f) => f.isFile)
          .map((f) => f.name)
          .toList();
      expect(names, ['IflytekSpeech/a.bin', 'IflytekSpeech/res/b.bin']);
      expect(plan.files.any((f) => f.key.startsWith('WT_ThemeResources')), isFalse);
    });

    test('packed с темами: темы передаются и переносятся, ошибка переноса не роняет', () {
      final plan = planVoice(zip, prep: _prep, packed: true);
      final steps = plan.steps(_ids(plan));
      final themeMv = [
        for (final s in steps)
          if (s['type'] == 'shell' && (s['cmd'] as String).contains('WT_ThemeResources')) s,
      ];
      expect(themeMv.map((s) => s['cmd']), [
        'mv /data/local/tmp/WT_ThemeResourcesDay.apk /resources/appdata/tinnove/WT_ThemeResourcesDay/',
        'mv /data/local/tmp/WT_ThemeResourcesNight.apk /resources/appdata/tinnove/WT_ThemeResourcesNight/',
      ]);
      expect(themeMv.every((s) => s['ignore_errors'] == true), isTrue);
    });

    test('файлы и порядок шагов как в ветке :voice', () {
      final plan = planVoice(zip, prep: _prep);
      final steps = plan.steps(_ids(plan));
      final cmds = [
        for (final s in steps)
          if (s['type'] == 'shell') s['cmd'],
      ];
      expect(cmds, [
        "mkdir -p '/data/local/tmp/IflytekSpeech' '/data/local/tmp/IflytekSpeech/res'",
        'pm install -g -r /data/local/tmp/SpeechHMI.apk',
        'cp -r /data/local/tmp/IflytekSpeech /resources/appdata/tinnove/',
        'mv /data/local/tmp/SpeechHMI.apk /resources/appdata/tinnove/',
        'mv /data/local/tmp/WT_SpeechMiddleware.apk /resources/appdata/tinnove/',
        'mv /data/local/tmp/WT_ThemeResourcesDay.apk /resources/appdata/tinnove/WT_ThemeResourcesDay/',
        'mv /data/local/tmp/WT_ThemeResourcesNight.apk /resources/appdata/tinnove/WT_ThemeResourcesNight/',
        'rm -rf /data/local/tmp/IflytekSpeech',
        'rm /data/local/tmp/*.apk',
      ]);
      final pushes = {
        for (final s in steps)
          if (s['type'] == 'push_file') s['remote_path']: s['payload_id'],
      };
      expect(pushes.keys, [
        '/data/local/tmp/WT_SpeechMiddleware.apk',
        '/data/local/tmp/SpeechHMI.apk',
        '/data/local/tmp/IflytekSpeech/a.bin',
        '/data/local/tmp/IflytekSpeech/res/b.bin',
        '/data/local/tmp/WT_ThemeResourcesDay.apk',
        '/data/local/tmp/WT_ThemeResourcesNight.apk',
      ]);
      // очистка и перенос тем (папок тем нет на части Q05) не прерывают задание, как в батнике
      expect(
        [
          for (final s in steps)
            if (s['ignore_errors'] == true) s['cmd'],
        ],
        [
          'mv /data/local/tmp/WT_ThemeResourcesDay.apk /resources/appdata/tinnove/WT_ThemeResourcesDay/',
          'mv /data/local/tmp/WT_ThemeResourcesNight.apk /resources/appdata/tinnove/WT_ThemeResourcesNight/',
          'rm -rf /data/local/tmp/IflytekSpeech',
          'rm /data/local/tmp/*.apk',
        ],
      );
    });

    test('мастеру показаны укрупнённые пункты, а не каждый файл', () {
      final plan = planVoice(zip, prep: _prep);
      final titles = [
        for (final s in plan.steps(_ids(plan)))
          if (s['hidden'] != true) s['title'],
      ];
      expect(titles, [
        'Подготовка системы',
        'Загрузка основы',
        'Загрузка ресурсов',
        'Установка компонентов',
        'Перемещение файлов',
        'Очистка временных файлов',
      ]);
    });

    test('нет нужного файла: ошибка называет его', () {
      final broken = _zip({
        'SpeechHMI.apk': [1],
      });
      expect(
        () => planVoice(broken, prep: _prep),
        throwsA(
          predicate((e) => e.toString().contains('WT_SpeechMiddleware.apk')),
        ),
      );
    });
  });

  test('приборка [6]: подготовка как в остальных услугах, затем один apk с выдачей разрешений', () {
    final plan = planCluster([1, 2, 3], prep: _prep);
    final steps = plan.steps(_ids(plan));
    expect(steps.map((s) => s['type']), ['run_script', 'install_apk']);
    expect(steps.last['grant'], true);
    expect(steps.last['payload_id'], 'id:cluster.apk');
    expect(
      String.fromCharCodes(plan.files.first.bytes),
      '$_prep\nsetprop vecentek.model 1\n',
    );
  });

  test('[7] перевод приборки: помощник в /data/local/tmp, set ru, ошибка помощника роняет шаг', () {
    final plan = planClusterLanguage([7, 7], prep: _prep);
    final steps = plan.steps(_ids(plan));
    expect(steps.map((s) => s['type']), [
      'run_script',
      'push_file',
      'shell',
      'shell',
    ]);
    expect(steps[1]['remote_path'], clusterLanguageHelperPath);
    expect(steps[1]['payload_id'], 'id:cluster-language-helper.jar');
    final run = steps[2]['cmd'] as String;
    expect(
      run,
      contains(
        'CLASSPATH=$clusterLanguageHelperPath app_process /system/bin C281PolymericLanguage set ru',
      ),
    );
    expect(run, contains('*ERROR*) exit 1'));
    expect(steps[2]['hidden'], isNull);
    expect(steps[3]['cmd'], 'rm -f $clusterLanguageHelperPath');
    expect(steps[3]['ignore_errors'], true);
    expect(
      String.fromCharCodes(plan.files.first.bytes),
      '$_prep\nsetprop vecentek.model 1\n',
    );
  });
  group('Q07 (FunkyDev Q07 Language Tool)', () {
    Archive q07Zip({bool badHash = false, int count = 36}) {
      final zip = Archive();
      final rows = <String>[
        '"Order","Apk","OverlayPackage","TargetPackage","Label","SHA256"',
      ];
      for (var i = 1; i <= count; i++) {
        final bytes = utf8.encode('apk $i');
        zip.addFile(ArchiveFile('q07 ru/apks/A$i.apk', bytes.length, bytes));
        final sum = badHash && i == 5
            ? '0' * 64
            : crypto.sha256.convert(bytes).toString().toUpperCase();
        rows.add('"$i","A$i.apk","com.o$i.azru","com.t$i","L$i","$sum"');
      }
      final csv = utf8.encode('﻿${rows.join('\r\n')}\r\n');
      zip.addFile(ArchiveFile('q07 ru/overlays.csv', csv.length, csv));
      final legacy = utf8.encode(
        '"OverlayPackage","TargetPackage","Label"\r\n"com.old.ru","com.t1","Old"\r\n',
      );
      zip.addFile(
        ArchiveFile('q07 ru/legacy_overlays.csv', legacy.length, legacy),
      );
      for (final lang in ['az', 'ru']) {
        for (final n in [
          'lamb_json.json',
          'cast_video_kara_json.json',
          'guide_json.json',
        ]) {
          final b = utf8.encode('{"$lang":"$n"}');
          zip.addFile(ArchiveFile('q07 ru/dlp_dynamic/$lang/$n', b.length, b));
        }
      }
      return zip;
    }

    test('кнопка 1: подготовка, остановка, 36 установок, DLP, включение, возврат настроек', () {
      final plan = planQ07Prepare(q07Zip());
      final steps = plan.steps(_ids(plan));
      final visible = [
        for (final s in steps)
          if (s['hidden'] != true) s['title'],
      ];
      expect(visible.first, 'Подготовка системы');
      expect(visible[1], startsWith('Остановка прежнего перевода'));
      expect(steps.where((s) => s['type'] == 'install_apk').length, 36);
      expect(
        steps
            .where((s) => s['type'] == 'install_apk')
            .every((s) => s['grant'] != true),
        isTrue,
      );
      final pushes = steps
          .where((s) => s['type'] == 'push_file')
          .map((s) => s['remote_path']);
      expect(
        pushes,
        contains('/resources/custormer/ivi/Lamb/skin_ru/lamb_json.json'),
      );
      expect(pushes.where((p) => '$p'.startsWith('/resources/')).length, 6);
      expect(visible[visible.length - 2], startsWith('Включение перевода'));
      expect(visible.last, 'Возврат настроек системы');
      final enable = [
        for (final f in plan.files)
          if (f.key.startsWith('enable')) utf8.decode(f.bytes),
      ].join('\n');
      expect(enable, contains('cmd overlay disable --user "\$usr" com.old.ru'));
      expect(enable, contains('en com.o36.azru com.t36'));
      expect(enable, contains('install-existing'));
      expect(enable, contains('exit 1'));
    });

    test(
      'скрипты Q07 не идут через run_script: adb exec-in теряет код выхода',
      () {
        for (final plan in [
          planQ07Prepare(q07Zip()),
          planQ07Russify(q07Zip()),
        ]) {
          final steps = plan.steps(_ids(plan));
          expect(steps.where((s) => s['type'] == 'run_script'), isEmpty);
          // Каждый скрипт кладётся файлом и выполняется через adb shell с передачей кода выхода.
          for (final f in plan.files.where((f) => f.kind == 'sh')) {
            final path = '/data/local/tmp/nox_q07_${f.key}';
            final i = steps.indexWhere((s) => s['remote_path'] == path);
            expect(i, isNot(-1), reason: f.key);
            expect(steps[i + 1]['type'], 'shell');
            expect(steps[i + 1]['cmd'], startsWith('sh $path '));
            expect(steps[i + 1]['cmd'], endsWith(r'exit $rc'));
          }
        }
      },
    );

    test(
      'включение делится на части (у adb shell в программе предел 60 секунд)',
      () {
        final plan = planQ07Prepare(q07Zip());
        final parts = plan.files
            .where((f) => f.key.startsWith('enable'))
            .toList();
        expect(parts.length, 9);
        for (final p in parts) {
          expect(
            RegExp(
              r'^en ',
              multiLine: true,
            ).allMatches(utf8.decode(p.bytes)).length,
            lessThanOrEqualTo(4),
          );
        }
        // Устаревшие оверлеи выключаются в первой части, лаунчер перезапускается в последней.
        expect(utf8.decode(parts.first.bytes), contains('com.old.ru'));
        expect(utf8.decode(parts.last.bytes), contains('sdalauncher'));
        expect(utf8.decode(parts[1].bytes), isNot(contains('sdalauncher')));
      },
    );

    test('кнопка 2: только включение перевода и перезагрузка', () {
      final plan = planQ07Russify(q07Zip());
      final types = plan.steps(_ids(plan)).map((s) => s['type']).toList();
      expect(types.last, 'reboot');
      expect(types.where((t) => t == 'reboot').length, 1);
      expect(types.where((t) => t == 'install_apk'), isEmpty);
    });

    test(
      'неверная контрольная сумма или не 36 оверлеев: пакет не собирается',
      () {
        expect(
          () => planQ07Prepare(q07Zip(badHash: true)),
          throwsA(isA<RecipeException>()),
        );
        expect(
          () => planQ07Russify(q07Zip(count: 35)),
          throwsA(isA<RecipeException>()),
        );
      },
    );

    test('скрипты для ГУ синтаксически верны (sh -n)', () async {
      final plan = planQ07Prepare(q07Zip());
      final dir = await Directory.systemTemp.createTemp('q07sh');
      addTearDown(() => dir.delete(recursive: true));
      for (final f in plan.files.where((f) => f.kind == 'sh')) {
        final file = File('${dir.path}/${f.key}')..writeAsBytesSync(f.bytes);
        final r = await Process.run('sh', ['-n', file.path]);
        expect(r.exitCode, 0, reason: '${f.key}: ${r.stderr}');
      }
    }, skip: !_hasSh());

    test('одно приложение (звук мотора, СГУ): установка с разрешениями', () {
      final plan = planSingleApk([
        0x50,
        0x4B,
        3,
        4,
        5,
      ], title: 'Установка звука мотора');
      final steps = plan.steps(_ids(plan));
      expect(steps.map((s) => s['type']), ['shell', 'install_apk']);
      expect(steps.last['grant'], true);
      expect(
        () => planSingleApk([1, 2, 3, 4], title: 'x'),
        throwsA(isA<RecipeException>()),
      );
    });
  });

  group('кастомный голос MMVoice [2б]', () {
    final zip = _zip({
      'MMVOICE_2026/1.INSTALL_MMVOICE.bat': [1],
      'MMVOICE_2026/MMVoice-SystemAdapter.apk': [0x50, 0x4B, 1],
      'MMVOICE_2026/MMVoice.apk': [0x50, 0x4B, 2],
      'MMVOICE_2026/MMVoice-QuietLaunch-v1.apk': [0x50, 0x4B, 3],
    });

    test(
      'адаптер, затем приложение, затем выбор помощника и кнопка на руле',
      () {
        final plan = planCustomVoice(zip, prep: _prep);
        expect(plan.files.map((f) => f.key), [
          'pre.sh',
          'MMVoice-SystemAdapter.apk',
          'MMVoice.apk',
        ]);
        final steps = plan.steps(_ids(plan));
        expect(steps.map((s) => s['type']), [
          'run_script',
          'install_apk',
          'install_apk',
          'shell',
          'shell',
        ]);
        expect(steps[1]['payload_id'], 'id:MMVoice-SystemAdapter.apk');
        expect(steps[2]['grant'], true);
        expect(
          steps[3]['cmd'],
          contains('voice_interaction_service $mmVoiceInteraction'),
        );
        expect(
          steps[3]['cmd'],
          contains('secure assistant $mmVoiceInteraction'),
        );
        expect(
          utf8.decode(plan.files.first.bytes),
          contains('setprop vecentek.model 1'),
        );
      },
    );

    test('без MMVoice.apk пакет не собирается', () {
      expect(
        () => planCustomVoice(
          _zip({
            'MMVOICE_2026/MMVoice-SystemAdapter.apk': [1],
          }),
          prep: _prep,
        ),
        throwsA(isA<RecipeException>()),
      );
    });

    test('служба кнопки добавляется к включённым, не затирает их и не дублируется', () async {
      final cmd =
          planCustomVoice(
                zip,
                prep: _prep,
              ).steps(_ids(planCustomVoice(zip, prep: _prep))).last['cmd']
              as String;
      Future<String> run(String current) async {
        // settings подменён: get печатает текущее значение, put — что записано.
        final script =
            'settings() { if [ "\$1" = get ]; then echo "$current"; else echo "PUT \$3=\$4"; fi; }\n$cmd';
        final r = await Process.run('sh', ['-c', script]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return r.stdout as String;
      }

      expect(
        await run('null'),
        contains('PUT enabled_accessibility_services=$mmVoiceKeyAccessibility'),
      );
      expect(
        await run('a/b.C'),
        contains(
          'PUT enabled_accessibility_services=a/b.C:$mmVoiceKeyAccessibility',
        ),
      );
      final again = await run('a/b.C:$mmVoiceKeyAccessibility');
      expect(again, isNot(contains('enabled_accessibility_services')));
      expect(again, contains('PUT accessibility_enabled=1'));
    }, skip: !_hasSh());
  });
}

bool _hasSh() {
  try {
    return Process.runSync('sh', ['-c', 'true']).exitCode == 0;
  } catch (_) {
    return false;
  }
}
