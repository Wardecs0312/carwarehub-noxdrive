import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// AES-256-GCM через встроенную в Windows библиотеку bcrypt.dll (аппаратное ускорение AES).
/// Чисто Dart-реализация расшифровывала ~7 МБ/с, и большие пакеты шли минутами.
/// На других платформах и при любой ошибке загрузки возвращается null — тогда
/// используется прежняя реализация.
class NativeAesGcm {
  NativeAesGcm._(this._lib, this._key);

  final _Bcrypt _lib;
  final Pointer<Void> _key;

  static NativeAesGcm? create(List<int> key) {
    if (!Platform.isWindows || key.length != 32) return null;
    try {
      final lib = _Bcrypt.instance;
      final alg = lib.alg;
      final hKey = calloc<Pointer<Void>>();
      final secret = calloc<Uint8>(32);
      try {
        secret.asTypedList(32).setAll(0, key);
        final st = lib.generateSymmetricKey(
          alg,
          hKey,
          nullptr,
          0,
          secret,
          32,
          0,
        );
        if (st != 0) return null;
        return NativeAesGcm._(lib, hKey.value);
      } finally {
        calloc.free(secret);
        calloc.free(hKey);
      }
    } catch (_) {
      return null;
    }
  }

  /// Расшифровывает блок. Бросает [FormatException], если тег не совпал.
  Uint8List decrypt(
    Uint8List cipherText,
    List<int> nonce,
    List<int> aad,
    List<int> tag,
  ) {
    final n = cipherText.length;
    final pIn = calloc<Uint8>(n == 0 ? 1 : n);
    final pOut = calloc<Uint8>(n == 0 ? 1 : n);
    final pNonce = calloc<Uint8>(nonce.length);
    final pAad = calloc<Uint8>(aad.isEmpty ? 1 : aad.length);
    final pTag = calloc<Uint8>(tag.length);
    final info = calloc<_AuthInfo>();
    final written = calloc<Uint32>();
    try {
      if (n > 0) pIn.asTypedList(n).setAll(0, cipherText);
      pNonce.asTypedList(nonce.length).setAll(0, nonce);
      if (aad.isNotEmpty) pAad.asTypedList(aad.length).setAll(0, aad);
      pTag.asTypedList(tag.length).setAll(0, tag);
      info.ref
        ..cbSize = sizeOf<_AuthInfo>()
        ..dwInfoVersion = 1
        ..pbNonce = pNonce
        ..cbNonce = nonce.length
        ..pbAuthData = aad.isEmpty ? nullptr : pAad
        ..cbAuthData = aad.length
        ..pbTag = pTag
        ..cbTag = tag.length
        ..pbMacContext = nullptr
        ..cbMacContext = 0
        ..cbAAD = 0
        ..cbData = 0
        ..dwFlags = 0;
      final st = _lib.decrypt(
        _key,
        pIn,
        n,
        info.cast(),
        nullptr,
        0,
        pOut,
        n,
        written,
        0,
      );
      if (st == _statusAuthTagMismatch) {
        throw const FormatException('Проверка целостности файла не пройдена');
      }
      if (st != 0) {
        throw FormatException(
          'Ошибка расшифровки (0x${st.toUnsigned(32).toRadixString(16)})',
        );
      }
      return Uint8List.fromList(pOut.asTypedList(written.value));
    } finally {
      calloc.free(pIn);
      calloc.free(pOut);
      calloc.free(pNonce);
      calloc.free(pAad);
      calloc.free(pTag);
      calloc.free(info);
      calloc.free(written);
    }
  }

  void dispose() => _lib.destroyKey(_key);
}

const _statusAuthTagMismatch = -1073700862; // 0xC000A002

/// BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO
final class _AuthInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwInfoVersion;
  external Pointer<Uint8> pbNonce;
  @Uint32()
  external int cbNonce;
  external Pointer<Uint8> pbAuthData;
  @Uint32()
  external int cbAuthData;
  external Pointer<Uint8> pbTag;
  @Uint32()
  external int cbTag;
  external Pointer<Uint8> pbMacContext;
  @Uint32()
  external int cbMacContext;
  @Uint32()
  external int cbAAD;
  @Uint64()
  external int cbData;
  @Uint32()
  external int dwFlags;
}

typedef _OpenC = Int32 Function(
  Pointer<Pointer<Void>>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
);
typedef _OpenD = int Function(
  Pointer<Pointer<Void>>,
  Pointer<Utf16>,
  Pointer<Utf16>,
  int,
);
typedef _SetPropC = Int32 Function(
  Pointer<Void>,
  Pointer<Utf16>,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _SetPropD = int Function(
  Pointer<Void>,
  Pointer<Utf16>,
  Pointer<Uint8>,
  int,
  int,
);
typedef _GenKeyC = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _GenKeyD = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
);
typedef _DecryptC = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Uint32,
);
typedef _DecryptD = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  int,
);
typedef _DestroyC = Int32 Function(Pointer<Void>);
typedef _DestroyD = int Function(Pointer<Void>);

class _Bcrypt {
  _Bcrypt._() {
    final lib = DynamicLibrary.open('bcrypt.dll');
    final open = lib.lookupFunction<_OpenC, _OpenD>(
      'BCryptOpenAlgorithmProvider',
    );
    final setProp = lib.lookupFunction<_SetPropC, _SetPropD>(
      'BCryptSetProperty',
    );
    generateSymmetricKey = lib.lookupFunction<_GenKeyC, _GenKeyD>(
      'BCryptGenerateSymmetricKey',
    );
    decrypt = lib.lookupFunction<_DecryptC, _DecryptD>('BCryptDecrypt');
    destroyKey = lib.lookupFunction<_DestroyC, _DestroyD>('BCryptDestroyKey');

    final hAlg = calloc<Pointer<Void>>();
    final name = 'AES'.toNativeUtf16();
    final prop = 'ChainingMode'.toNativeUtf16();
    final mode = 'ChainingModeGCM'.toNativeUtf16();
    try {
      if (open(hAlg, name, nullptr, 0) != 0) {
        throw StateError('BCryptOpenAlgorithmProvider');
      }
      final modeBytes = (mode.length + 1) * 2;
      if (setProp(hAlg.value, prop, mode.cast(), modeBytes, 0) != 0) {
        throw StateError('BCryptSetProperty');
      }
      alg = hAlg.value;
    } finally {
      calloc.free(hAlg);
      calloc.free(name);
      calloc.free(prop);
      calloc.free(mode);
    }
  }

  static final instance = _Bcrypt._();

  late final Pointer<Void> alg;
  late final _GenKeyD generateSymmetricKey;
  late final _DecryptD decrypt;
  late final _DestroyD destroyKey;
}
