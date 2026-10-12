// Админ-утилита: шифрует файл (APK, sh) для загрузки в приватный bucket `payloads`.
//   dart run tool/encrypt_payload.dart <входной файл> <выходной файл.enc>
// Печатает ключ (base64), размер исходника и sha256. Эти значения вносятся в таблицу payloads
// (enc_key, size_bytes, sha256). Ключ никому не показывайте и не коммитьте.
import 'dart:convert';
import 'dart:io';

import 'package:carwarehub_noxdrive/security/payload_cipher.dart';
import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Использование: dart run tool/encrypt_payload.dart <in> <out.enc>',
    );
    exit(64);
  }
  final plain = await File(args[0]).readAsBytes();
  final key = PayloadCipher.generateKey();
  final enc = await PayloadCipher(key).encrypt(plain);
  await File(args[1]).writeAsBytes(enc);
  final hash = await Sha256().hash(plain);
  stdout
    ..writeln('enc_key   : ${base64Encode(key)}')
    ..writeln('size_bytes: ${plain.length}')
    ..writeln(
      'sha256    : ${hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
}
