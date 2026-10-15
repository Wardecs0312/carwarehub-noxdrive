import 'dart:convert';

import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/features/update/updater.dart';
import 'package:carwarehub_noxdrive/security/release_signature.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Тестовый ключ (не настоящий): seed из нулей и единиц.
final _seed = base64Encode(List<int>.generate(32, (i) => i));
const _sha = 'aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44';

Future<String> _pub() => ReleaseSignature.publicKeyOf(_seed);

Future<String> _sign({
  String platform = 'windows',
  String version = '2.0.15',
  int build = 15,
  String sha = _sha,
}) => ReleaseSignature.sign(
  seedBase64: _seed,
  platform: platform,
  version: version,
  build: build,
  sha256: sha,
);

Future<bool> _verify(
  String? sig, {
  String platform = 'windows',
  String version = '2.0.15',
  int build = 15,
  String sha = _sha,
  String? pub,
}) async => ReleaseSignature.verify(
  signatureBase64: sig,
  platform: platform,
  version: version,
  build: build,
  sha256: sha,
  publicKey: pub ?? await _pub(),
);

void main() {
  test('подписанный выпуск проходит проверку', () async {
    expect(await _verify(await _sign()), isTrue);
  });

  test('без подписи обновление отвергается', () async {
    expect(await _verify(null), isFalse);
    expect(await _verify(''), isFalse);
  });

  test('подмена файла (другая контрольная сумма) отвергается', () async {
    final sig = await _sign();
    expect(await _verify(sig, sha: 'ff${_sha.substring(2)}'), isFalse);
  });

  test('подпись нельзя перенести на другую версию или платформу', () async {
    final sig = await _sign();
    expect(await _verify(sig, version: '2.0.16', build: 16), isFalse);
    expect(await _verify(sig, platform: 'android'), isFalse);
  });

  test('подпись чужим ключом отвергается', () async {
    final other = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 9));
    final otherPub = base64Encode((await other.extractPublicKey()).bytes);
    expect(await _verify(await _sign(), pub: otherPub), isFalse);
  });

  test(
    'мусор вместо подписи не роняет программу, а просто отвергается',
    () async {
      expect(await _verify('не base64 !!!'), isFalse);
    },
  );

  test('программа без подписи выпуска выдаёт понятную ошибку', () async {
    const r = AppRelease(
      version: '2.0.15',
      buildNumber: 15,
      isMandatory: false,
      downloadPath: 'windows/2.0.15+15.zip',
      sha256: _sha,
    );
    await expectLater(
      Updater.verifySignature(r),
      throwsA(
        isA<UpdateException>().having(
          (e) => '$e',
          'текст',
          contains('не подписано'),
        ),
      ),
    );
  });

  test('в программу зашит именно открытый ключ из 32 байт', () {
    expect(base64Decode(ReleaseSignature.publicKeyBase64), hasLength(32));
  });
}
