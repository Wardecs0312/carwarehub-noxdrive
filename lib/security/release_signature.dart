import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Подпись выпусков программы (Ed25519).
///
/// Утилита выпуска (`tool/publish_release.dart`) подписывает секретным ключом из сейфа администратора
/// строку «платформа + версия + номер сборки + SHA-256 файла». Подпись хранится в `app_releases.signature`.
/// Программа перед установкой обновления проверяет её открытым ключом [publicKeyBase64], зашитым в код.
/// Без верной подписи обновление не ставится, даже если запись и файл в базе подменены:
/// подделать подпись без секретного ключа нельзя.
class ReleaseSignature {
  ReleaseSignature._();

  /// Открытая половина ключа подписи выпусков nox.drive. Секретная половина только у администратора.
  static const publicKeyBase64 = '5IA7EwREoOgCUjUkHH+l4H2KOE1Tg/Gyt9eW/8A93Zg=';

  static final _algo = Ed25519();

  /// Что именно подписывается. Версия и платформа входят в подпись, поэтому подписанный файл
  /// нельзя выдать за другую версию или за выпуск для другой платформы.
  static List<int> message({
    required String platform,
    required String version,
    required int build,
    required String sha256,
  }) => utf8.encode(
    'nox.drive release v1\n$platform\n$version\n$build\n${sha256.toLowerCase()}\n',
  );

  /// Подпись выпуска секретным ключом (seed 32 байта в base64). Только для утилиты выпуска.
  static Future<String> sign({
    required String seedBase64,
    required String platform,
    required String version,
    required int build,
    required String sha256,
  }) async {
    final keyPair = await _algo.newKeyPairFromSeed(base64Decode(seedBase64));
    final sig = await _algo.sign(
      message(
        platform: platform,
        version: version,
        build: build,
        sha256: sha256,
      ),
      keyPair: keyPair,
    );
    return base64Encode(sig.bytes);
  }

  /// Открытый ключ, соответствующий секретному (чтобы утилита выпуска сверила, тем ли ключом подписывает).
  static Future<String> publicKeyOf(String seedBase64) async {
    final keyPair = await _algo.newKeyPairFromSeed(base64Decode(seedBase64));
    return base64Encode((await keyPair.extractPublicKey()).bytes);
  }

  /// Проверка подписи. false, если подписи нет, она повреждена или сделана другим ключом.
  static Future<bool> verify({
    required String? signatureBase64,
    required String platform,
    required String version,
    required int build,
    required String sha256,
    String publicKey = publicKeyBase64,
  }) async {
    if (signatureBase64 == null || signatureBase64.isEmpty) return false;
    try {
      return await _algo.verify(
        message(
          platform: platform,
          version: version,
          build: build,
          sha256: sha256,
        ),
        signature: Signature(
          base64Decode(signatureBase64),
          publicKey: SimplePublicKey(
            base64Decode(publicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } on FormatException {
      return false;
    }
  }
}
