import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/package_builder.dart';

Archive _zip(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, bytes) => a.addFile(ArchiveFile.bytes(name, bytes)));
  return a;
}

void main() {
  test('берёт только .apk из soft, по алфавиту без учёта регистра', () {
    final apks = collectApks(
      _zip({
        'nox.bat': [1],
        'soft/b_Maps.apk': [1, 2],
        'soft/A_keyboard.APK': [3],
        'soft/readme.txt': [4],
        'soft/sub/inner.apk': [5],
        'other/x.apk': [6],
      }),
    );
    expect(apks.map((e) => e.name), ['A_keyboard.APK', 'b_Maps.apk']);
    expect(apks.first.bytes, [3]);
  });

  test('понимает обратные слэши и лишнюю корневую папку архива', () {
    final apks = collectApks(
      _zip({
        r'nox\soft\app.apk': [1],
      }),
    );
    expect(apks.map((e) => e.name), ['app.apk']);
  });

  test('шаги: подготовка, приложения с выдачей разрешений, перезагрузка', () {
    final steps = buildSteps(
      preScriptId: 'p0',
      apks: [
        (id: 'a1', name: 'YandexNavigator.apk'),
        (id: 'a2', name: 'Maps.apk'),
      ],
      reboot: true,
    );
    expect(steps.map((s) => s['type']), [
      'run_script',
      'install_apk',
      'install_apk',
      'reboot',
    ]);
    expect(steps[1], {
      'type': 'install_apk',
      'title': 'Установка: YandexNavigator',
      'payload_id': 'a1',
      'grant': true,
    });
  });

  test('без скрипта подготовки и перезагрузки только установка', () {
    final steps = buildSteps(apks: [(id: 'a1', name: 'X.apk')]);
    expect(steps.length, 1);
  });
}
