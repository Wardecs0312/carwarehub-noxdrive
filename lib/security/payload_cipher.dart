import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'native_aes_gcm.dart';

/// Потоковое шифрование файлов AES-256-GCM блоками, чтобы расшифровывать «на лету»
/// и не держать файл целиком (и тем более на диске).
///
/// Формат: 'NXD1' | baseNonce(8) | блок{ шифртекст(<=64 КиБ) + тег(16) } ...
/// Nonce блока = baseNonce | номер блока (u32, big-endian).
/// AAD блока = 1 байт: 1 для последнего блока, 0 для остальных. Это защищает от
/// перестановки блоков и от обрезания файла.
class PayloadCipher {
  PayloadCipher(this.key) : assert(key.length == 32);

  static const chunkSize = 64 * 1024;
  static const _tagLen = 16;
  static const _magic = [0x4E, 0x58, 0x44, 0x31]; // NXD1
  static const _headerLen = 12;

  final List<int> key;
  final _algo = AesGcm.with256bits();

  String get keyBase64 => base64Encode(key);

  factory PayloadCipher.fromBase64(String b64) =>
      PayloadCipher(base64Decode(b64));

  static List<int> generateKey() {
    final r = Random.secure();
    return List<int>.generate(32, (_) => r.nextInt(256));
  }

  List<int> _nonce(List<int> base, int counter) {
    final n = Uint8List(12)..setRange(0, 8, base);
    ByteData.view(n.buffer).setUint32(8, counter);
    return n;
  }

  /// Шифрование целого файла (для админ-утилиты и тестов).
  Future<Uint8List> encrypt(List<int> plain, {List<int>? baseNonce}) async {
    final base =
        baseNonce ?? List<int>.generate(8, (_) => Random.secure().nextInt(256));
    final out = BytesBuilder()
      ..add(_magic)
      ..add(base);
    final total = plain.length;
    final chunks = total == 0 ? 1 : (total + chunkSize - 1) ~/ chunkSize;
    for (var i = 0; i < chunks; i++) {
      final start = i * chunkSize;
      final end = min(start + chunkSize, total);
      final box = await _algo.encrypt(
        plain.sublist(start, end),
        secretKey: SecretKey(key),
        nonce: _nonce(base, i),
        aad: [i == chunks - 1 ? 1 : 0],
      );
      out
        ..add(box.cipherText)
        ..add(box.mac.bytes);
    }
    return out.takeBytes();
  }

  /// Потоковая расшифровка. Бросает [FormatException] при подмене, обрыве или неверном ключе.
  Stream<List<int>> decrypt(Stream<List<int>> source) async* {
    final buf = BytesBuilder(copy: false);
    List<int>? base;
    var counter = 0;
    const full = chunkSize + _tagLen;
    // Быстрая расшифровка средствами Windows; если недоступна — прежняя реализация.
    final native = NativeAesGcm.create(key);

    Future<List<int>> open(Uint8List block, bool last) async {
      if (block.length < _tagLen) {
        throw const FormatException('Повреждённый блок данных');
      }
      if (native != null) {
        return native.decrypt(
          Uint8List.sublistView(block, 0, block.length - _tagLen),
          _nonce(base!, counter++),
          [last ? 1 : 0],
          Uint8List.sublistView(block, block.length - _tagLen),
        );
      }
      try {
        return await _algo.decrypt(
          SecretBox(
            block.sublist(0, block.length - _tagLen),
            nonce: _nonce(base!, counter++),
            mac: Mac(block.sublist(block.length - _tagLen)),
          ),
          secretKey: SecretKey(key),
          aad: [last ? 1 : 0],
        );
      } on SecretBoxAuthenticationError {
        throw const FormatException('Проверка целостности файла не пройдена');
      }
    }

    try {
      await for (final part in source) {
        buf.add(part);
        var data = buf.takeBytes();
        var offset = 0;
        if (base == null) {
          if (data.length < _headerLen) {
            buf.add(data);
            continue;
          }
          if (!const ListEquality().equals(data.sublist(0, 4), _magic)) {
            throw const FormatException('Неизвестный формат файла');
          }
          base = data.sublist(4, _headerLen);
          offset = _headerLen;
        }
        // Блок можно считать «не последним» только когда за ним есть ещё данные.
        while (data.length - offset > full) {
          yield await open(
            Uint8List.sublistView(data, offset, offset + full),
            false,
          );
          offset += full;
        }
        buf.add(Uint8List.sublistView(data, offset));
      }
      if (base == null) throw const FormatException('Файл пуст или обрезан');
      yield await open(buf.takeBytes(), true);
    } finally {
      native?.dispose();
    }
  }
}

class ListEquality {
  const ListEquality();
  bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
