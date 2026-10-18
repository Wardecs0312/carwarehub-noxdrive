import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:carwarehub_noxdrive/adb/adb_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// Поддельный adb-сервер: разбирает протокол копирования так же, как настоящий.
class _FakeAdbServer {
  late ServerSocket server;
  final files = <String, List<int>>{};
  bool stallAfterSend = false;
  String? failWith;

  Future<int> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
    return server.port;
  }

  Future<void> _handle(Socket s) async {
    final buf = BytesBuilder();
    final waiters = <Completer<void>>[];
    final sub = s.listen(
      (d) {
        buf.add(d);
        for (final w in List.of(waiters)) {
          waiters.remove(w);
          w.complete();
        }
      },
      onDone: () {},
      onError: (_) {},
    );
    var data = Uint8List(0);
    Future<Uint8List> take(int n) async {
      while (data.length < n) {
        if (buf.isEmpty) {
          final c = Completer<void>();
          waiters.add(c);
          await c.future;
        }
        data = Uint8List.fromList([...data, ...buf.takeBytes()]);
      }
      final out = data.sublist(0, n);
      data = data.sublist(n);
      return out;
    }

    Future<String> request() async {
      final len = int.parse(ascii.decode(await take(4)), radix: 16);
      return utf8.decode(await take(len));
    }

    expect(await request(), startsWith('host:transport:'));
    s.add(ascii.encode('OKAY'));
    expect(await request(), 'sync:');
    s.add(ascii.encode('OKAY'));
    int u32(Uint8List b) => ByteData.sublistView(b).getUint32(0, Endian.little);
    final h = await take(8);
    expect(ascii.decode(h.sublist(0, 4)), 'SEND');
    final spec = utf8.decode(await take(u32(h.sublist(4))));
    final path = spec.substring(0, spec.lastIndexOf(','));
    if (stallAfterSend) {
      sub.pause(); // ГУ «замерло»: больше ничего не читаем
      return;
    }
    final body = <int>[];
    while (true) {
      final ph = await take(8);
      final id = ascii.decode(ph.sublist(0, 4));
      final v = u32(ph.sublist(4));
      if (id == 'DATA') {
        body.addAll(await take(v));
      } else if (id == 'DONE') {
        break;
      }
    }
    if (failWith != null) {
      final m = utf8.encode(failWith!);
      s.add([...ascii.encode('FAIL'), m.length, 0, 0, 0, ...m]);
    } else {
      files[path] = body;
      s.add([...ascii.encode('OKAY'), 0, 0, 0, 0]);
    }
    await s.flush();
  }
}

void main() {
  test(
    'файл доходит целиком, большими кусками, прогресс растёт до конца',
    () async {
      final fake = _FakeAdbServer();
      final port = await fake.start();
      addTearDown(fake.server.close);
      final payload = List<int>.generate(300 * 1024 + 17, (i) => i % 251);
      var last = 0;
      await AdbSync(port: port).push(
        'SER',
        Stream.fromIterable([payload.sublist(0, 1000), payload.sublist(1000)]),
        '/data/local/tmp/x.apk',
        onProgress: (n) => last = n,
      );
      expect(fake.files['/data/local/tmp/x.apk'], payload);
      expect(last, payload.length);
    },
  );

  test('ГУ отказало: понятная ошибка', () async {
    final fake = _FakeAdbServer()..failWith = 'No space left on device';
    final port = await fake.start();
    addTearDown(fake.server.close);
    await expectLater(
      AdbSync(port: port).push('SER', Stream.value([1, 2, 3]), '/x'),
      throwsA(
        isA<AdbStallException>().having(
          (e) => e.message,
          'message',
          contains('No space left'),
        ),
      ),
    );
  });

  test('ГУ перестало принимать данные: сторож прерывает передачу', () async {
    final fake = _FakeAdbServer()..stallAfterSend = true;
    final port = await fake.start();
    addTearDown(fake.server.close);
    final big = Stream.fromIterable(
      List.generate(400, (_) => List<int>.filled(64 * 1024, 7)),
    );
    await expectLater(
      AdbSync(
        port: port,
        stallTimeout: const Duration(seconds: 2),
      ).push('SER', big, '/x').timeout(const Duration(seconds: 60)),
      throwsA(isA<AdbStallException>()),
    );
  });
}
