import 'dart:io';

import 'package:carwarehub_noxdrive/jobs/custom_apk_store.dart';
import 'package:carwarehub_noxdrive/jobs/job_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('nox_apks'));
  tearDown(() => dir.delete(recursive: true));

  File apk(String name, int size) =>
      File('${dir.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(List.filled(size, 1));

  test('список своих APK сохраняется и читается с галочками', () async {
    final f1 = apk('Nav.apk', 10), f2 = apk('Music.apk', 20);
    final store = FileCustomApkStore(file: File('${dir.path}/list.json'));
    await store.save([
      CustomApk(path: f1.path, name: 'Nav.apk', sizeBytes: 10),
      CustomApk(
        path: f2.path,
        name: 'Music.apk',
        sizeBytes: 20,
        selected: false,
      ),
    ]);
    final loaded = await store.load();
    expect(loaded.map((a) => (a.name, a.selected, a.sizeBytes)), [
      ('Nav.apk', true, 10),
      ('Music.apk', false, 20),
    ]);
  });

  test('файл, удалённый с диска, пропадает из списка', () async {
    final f1 = apk('Nav.apk', 10), f2 = apk('Gone.apk', 5);
    final store = FileCustomApkStore(file: File('${dir.path}/list.json'));
    await store.save([
      CustomApk(path: f1.path, name: 'Nav.apk', sizeBytes: 10),
      CustomApk(path: f2.path, name: 'Gone.apk', sizeBytes: 5),
    ]);
    f2.deleteSync();
    expect((await store.load()).map((a) => a.name), ['Nav.apk']);
  });

  test('повреждённый файл списка не ломает программу', () async {
    final list = File('${dir.path}/list.json')..writeAsStringSync('{не json');
    expect(await FileCustomApkStore(file: list).load(), isEmpty);
  });
}
