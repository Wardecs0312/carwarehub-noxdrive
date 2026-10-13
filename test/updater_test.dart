import 'dart:io';

import 'package:carwarehub_noxdrive/features/update/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('upd_test'));
  tearDown(() async => root.delete(recursive: true));

  File f(Directory d, String rel) =>
      File('${d.path}${Platform.pathSeparator}$rel');

  test('новые файлы копируются поверх, вложенные папки создаются', () async {
    final from = await Directory('${root.path}/new').create();
    final to = await Directory('${root.path}/app').create();
    await f(to, 'app.exe').writeAsString('old');
    await f(to, 'keep.txt').writeAsString('keep');
    await f(from, 'app.exe').writeAsString('new');
    await Directory('${from.path}/data').create();
    await f(from, 'data${Platform.pathSeparator}app.so').writeAsString('so');

    final n = await Updater.replaceFiles(from, to);

    expect(n, 2);
    expect(await f(to, 'app.exe').readAsString(), 'new');
    expect(
      await f(to, 'data${Platform.pathSeparator}app.so').readAsString(),
      'so',
    );
    expect(await f(to, 'keep.txt').readAsString(), 'keep');
  });
}
