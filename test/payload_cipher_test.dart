import 'dart:math';

import 'package:carwarehub_noxdrive/security/payload_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> _split(List<int> data, int size) async* {
  for (var i = 0; i < data.length; i += size) {
    yield data.sublist(i, min(i + size, data.length));
  }
}

Future<List<int>> _collect(Stream<List<int>> s) async => [
  await for (final p in s) ...p,
];

void main() {
  final key = List<int>.generate(32, (i) => i);
  final cipher = PayloadCipher(key);

  for (final len in [
    0,
    1,
    1000,
    PayloadCipher.chunkSize,
    PayloadCipher.chunkSize + 1,
    200000,
  ]) {
    test('расшифровка потоком, размер $len', () async {
      final plain = List<int>.generate(len, (i) => i * 7 % 256);
      final enc = await cipher.encrypt(plain);
      final dec = await _collect(cipher.decrypt(_split(enc, 777)));
      expect(dec, plain);
    });
  }

  test('подмена байта обнаруживается', () async {
    final enc = await cipher.encrypt(List<int>.filled(5000, 1));
    enc[40] ^= 1;
    expect(_collect(cipher.decrypt(_split(enc, 4096))), throwsFormatException);
  });

  test('обрезанный файл обнаруживается', () async {
    final plain = List<int>.filled(PayloadCipher.chunkSize * 2 + 10, 3);
    final enc = await cipher.encrypt(plain);
    final cut = enc.sublist(
      0,
      12 + PayloadCipher.chunkSize + 16,
    ); // остался только 1-й блок
    expect(_collect(cipher.decrypt(_split(cut, 4096))), throwsFormatException);
  });

  test('неверный ключ', () async {
    final enc = await cipher.encrypt([1, 2, 3]);
    final other = PayloadCipher(List<int>.filled(32, 9));
    expect(_collect(other.decrypt(_split(enc, 100))), throwsFormatException);
  });
}
