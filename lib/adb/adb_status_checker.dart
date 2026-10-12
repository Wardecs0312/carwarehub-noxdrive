import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'adb_client.dart';
import 'adb_status.dart';

/// Фоновая проверка ADB-подключения (ADB Status Checker).
/// Опрашивает устройство раз в [interval] и выдаёт статус только при изменении.
class AdbStatusChecker {
  AdbStatusChecker(this._client, {this.interval = const Duration(seconds: 2)});

  final AdbClient _client;
  final Duration interval;

  Stream<AdbStatus> watch() async* {
    AdbStatus? last;
    while (true) {
      final status = await _client.readStatus();
      if (status != last) {
        last = status;
        yield status;
      }
      await Future<void>.delayed(interval);
    }
  }
}

final adbClientProvider = Provider<AdbClient>((_) => ProcessAdbClient());

/// Статус ADB в реальном времени. Опрос идёт, пока на провайдер кто-то подписан.
final adbStatusProvider = StreamProvider<AdbStatus>(
  (ref) => AdbStatusChecker(ref.watch(adbClientProvider)).watch(),
);
