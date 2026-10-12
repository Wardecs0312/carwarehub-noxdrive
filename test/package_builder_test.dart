import 'package:archive/archive.dart';
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

    test('нет apk: понятная ошибка', () {
      expect(
        () => planRussify(
          _zip({
            'x.txt': [1],
          }),
          prep: _prep,
        ),
        throwsA(isA<RecipeException>()),
      );
    });
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
      // очистка не прерывает задание
      expect(steps.where((s) => s['ignore_errors'] == true).length, 2);
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

  test('приборка [6]: один apk, выдача разрешений', () {
    final plan = planCluster([1, 2, 3]);
    final steps = plan.steps(_ids(plan));
    expect(steps.single['type'], 'install_apk');
    expect(steps.single['grant'], true);
    expect(steps.single['payload_id'], 'id:cluster.apk');
  });
}
