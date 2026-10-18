import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Передача на ГУ «замерла»: данных не уходило дольше допустимого.
class AdbStallException implements Exception {
  AdbStallException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Запись файла на ГУ по протоколу копирования adb (тот же, что у `adb push` и `adb install`).
///
/// Зачем: потоковая установка через `adb exec-in cmd package install -S` на ГУ Changan иногда
/// замирала навсегда (RuStore на 63 из 92 МБ, WT_VehicleCenter на 103 из 180 МБ), а `adb push`
/// того же файла проходил за 2 секунды. Здесь данные идут прямо из программы в протокол
/// копирования adb, без записи расшифрованного файла на диск компьютера.
class AdbSync {
  AdbSync({this.port = 5037, this.stallTimeout = const Duration(seconds: 60)});

  final int port;

  /// Сколько ждать, если данные перестали уходить на ГУ.
  final Duration stallTimeout;

  static const _maxData = 64 * 1024;

  /// Открытые соединения: [cancel] закрывает их, если мастер нажал «Остановить».
  final _sockets = <Socket>{};

  void cancel() {
    for (final s in _sockets.toList()) {
      s.destroy();
    }
    _sockets.clear();
  }

  /// Пишет [data] в файл [remotePath] на ГУ [serial]. [onProgress] получает число отправленных байт.
  Future<void> push(
    String serial,
    Stream<List<int>> data,
    String remotePath, {
    void Function(int sent)? onProgress,
    int mode = 0x81A4, // обычный файл, права 0644
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
    ).timeout(const Duration(seconds: 10));
    _sockets.add(socket);
    final reader = _Reader(socket);
    try {
      await _request(socket, reader, 'host:transport:$serial');
      await _request(socket, reader, 'sync:');

      final spec = utf8.encode('$remotePath,$mode');
      await _send(socket, _packet('SEND', spec.length), spec);

      var sent = 0;
      final pending = BytesBuilder(copy: false);
      Future<void> flushChunk(Uint8List chunk) async {
        await _send(socket, _packet('DATA', chunk.length), chunk);
        sent += chunk.length;
        onProgress?.call(sent);
      }

      await for (final part in data) {
        pending.add(part);
        while (pending.length >= _maxData) {
          final all = pending.takeBytes();
          await flushChunk(Uint8List.sublistView(all, 0, _maxData));
          pending.add(Uint8List.sublistView(all, _maxData));
        }
      }
      if (pending.isNotEmpty) await flushChunk(pending.takeBytes());

      final mtime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _send(socket, _packet('DONE', mtime), const []);

      // ГУ отвечает после записи файла на диск: на большой файл это может занять время.
      final head = await reader.read(8, const Duration(minutes: 2));
      final id = ascii.decode(head.sublist(0, 4));
      final len = ByteData.sublistView(head, 4).getUint32(0, Endian.little);
      if (id == 'FAIL') {
        final msg = utf8.decode(
          await reader.read(len, const Duration(seconds: 10)),
          allowMalformed: true,
        );
        throw AdbStallException('ГУ не приняло файл: $msg');
      }
      if (id != 'OKAY') throw AdbStallException('Неожиданный ответ ГУ: $id');
      // QUIT: корректно закрываем сессию копирования.
      socket.add(_packet('QUIT', 0));
      await socket.flush().timeout(const Duration(seconds: 5));
    } on SocketException catch (e) {
      throw AdbStallException('Связь с adb прервалась: ${e.message}');
    } finally {
      _sockets.remove(socket);
      socket.destroy();
      await reader.close();
    }
  }

  Future<void> _request(Socket s, _Reader r, String request) async {
    final body = utf8.encode(request);
    s.add(ascii.encode(body.length.toRadixString(16).padLeft(4, '0')));
    s.add(body);
    await s.flush().timeout(stallTimeout);
    final status = ascii.decode(await r.read(4, const Duration(seconds: 20)));
    if (status == 'OKAY') return;
    var msg = status;
    try {
      final len = int.parse(
        ascii.decode(await r.read(4, const Duration(seconds: 5))),
        radix: 16,
      );
      msg = utf8.decode(
        await r.read(len, const Duration(seconds: 5)),
        allowMalformed: true,
      );
    } catch (_) {}
    if (msg.contains('not found')) {
      throw AdbStallException("device '$msg' not found");
    }
    throw AdbStallException('adb отказал: $msg');
  }

  /// Отправка с «сторожем»: если ОС не принимает данные дольше [stallTimeout], передача замерла.
  Future<void> _send(Socket s, List<int> header, List<int> body) async {
    s.add(header);
    if (body.isNotEmpty) s.add(body);
    try {
      await s.flush().timeout(stallTimeout);
    } on TimeoutException {
      throw AdbStallException(
        'Передача на автомобиль замерла: данные не уходили ${stallTimeout.inSeconds} секунд',
      );
    }
  }

  static Uint8List _packet(String id, int value) {
    final b = Uint8List(8)..setAll(0, ascii.encode(id));
    ByteData.sublistView(b).setUint32(4, value, Endian.little);
    return b;
  }
}

/// Последовательное чтение ответа из сокета нужными порциями.
class _Reader {
  _Reader(Socket socket) {
    _sub = socket.listen(
      (d) {
        _buf.add(d);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder();
  Completer<void>? _waiter;
  Object? _error;
  bool _closed = false;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  Future<Uint8List> read(int n, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buf.length < n) {
      if (_error != null) {
        throw AdbStallException('Связь с adb прервалась: $_error');
      }
      if (_closed) throw AdbStallException('adb закрыл соединение');
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw AdbStallException(
          'Автомобиль не ответил за ${timeout.inSeconds} секунд',
        );
      }
      _waiter = Completer<void>();
      await _waiter!.future.timeout(left, onTimeout: () {});
    }
    final all = _buf.takeBytes();
    final out = Uint8List.sublistView(all, 0, n);
    _buf.add(Uint8List.sublistView(all, n));
    return Uint8List.fromList(out);
  }

  Future<void> close() => _sub.cancel();
}
