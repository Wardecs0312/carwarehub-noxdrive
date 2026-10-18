import 'dart:io';

import 'package:carwarehub_noxdrive/jobs/payload_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('nox_store'));
  tearDown(() => dir.delete(recursive: true));

  test('файл скачивается один раз, повторно берётся из кэша', () async {
    var downloads = 0;
    final store = PayloadStore(dir, (path, f, _) async {
      downloads++;
      await f.writeAsBytes([1, 2, 3]);
    });
    expect(await store.open('voice/a.enc').expand((c) => c).toList(), [
      1,
      2,
      3,
    ]);
    expect(await store.open('voice/a.enc').expand((c) => c).toList(), [
      1,
      2,
      3,
    ]);
    expect(downloads, 1);
  });

  test('одновременно не больше заданного числа загрузок', () async {
    var active = 0, peak = 0;
    final store = PayloadStore(dir, (path, f, _) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await f.writeAsBytes([7]);
      active--;
    }, concurrency: 3);
    await Future.wait([for (var i = 0; i < 12; i++) store.ensure('v/$i.enc')]);
    expect(peak, 3);
  });

  test('заранее начатая загрузка не повторяется при открытии', () async {
    var downloads = 0;
    final store = PayloadStore(dir, (path, f, _) async {
      downloads++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await f.writeAsBytes([9]);
    });
    store.prefetch(['x/1.enc']);
    expect(await store.open('x/1.enc').expand((c) => c).toList(), [9]);
    expect(downloads, 1);
  });

  test('обрыв загрузки не оставляет битый файл в кэше', () async {
    var fail = true;
    final store = PayloadStore(dir, (path, f, _) async {
      await f.writeAsBytes([1]);
      if (fail) throw const SocketException('обрыв');
      await f.writeAsBytes([1, 2]);
    });
    await expectLater(store.ensure('a/b.enc'), throwsA(isA<SocketException>()));
    expect(await store.fileFor('a/b.enc').exists(), isFalse);
    fail = false;
    expect(await store.open('a/b.enc').expand((c) => c).toList(), [1, 2]);
  });

  test('повреждённый файл удаляется и скачивается заново', () async {
    var downloads = 0;
    final store = PayloadStore(dir, (path, f, _) async {
      downloads++;
      await f.writeAsBytes([downloads]);
    });
    await store.ensure('p.enc');
    await store.invalidate('p.enc');
    expect(await store.open('p.enc').expand((c) => c).toList(), [2]);
  });

  test('кэш больше предела: удаляются самые старые файлы', () async {
    final store = PayloadStore(dir, (path, f, _) async {
      await f.writeAsBytes(List.filled(100, 0));
    }, maxBytes: 250);
    for (final n in ['1', '2', '3']) {
      await store.ensure('$n.enc');
      await store
          .fileFor('$n.enc')
          .setLastModified(DateTime(2026, 1, int.parse(n)));
    }
    await store.trim();
    expect(await store.fileFor('1.enc').exists(), isFalse);
    expect(await store.fileFor('3.enc').exists(), isTrue);
  });

  test('ход скачивания виден, из кэша — без скачивания', () async {
    final store = PayloadStore(dir, (path, f, progress) async {
      progress(50, 100);
      progress(100, 100);
      await f.writeAsBytes(List.filled(100, 1));
    });
    final seen = <int>[];
    expect(
      await store.fetch('a.enc', onProgress: (g, _) => seen.add(g)),
      isTrue,
    );
    expect(seen, [50, 100]);
    expect(await store.fetch('a.enc'), isFalse);
  });

  test('недокачанные файлы прошлого запуска удаляются', () async {
    final store = PayloadStore(dir, (path, f, _) async {});
    await File('${dir.path}/x.enc.part').writeAsBytes([1]);
    await File('${dir.path}/y.enc').writeAsBytes([1]);
    await store.cleanupPartials();
    expect(await File('${dir.path}/x.enc.part').exists(), isFalse);
    expect(await File('${dir.path}/y.enc').exists(), isTrue);
  });
}
