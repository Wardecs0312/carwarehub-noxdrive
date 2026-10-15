import 'package:carwarehub_noxdrive/adb/adb_executor.dart';
import 'package:carwarehub_noxdrive/jobs/apk_picker.dart';
import 'package:carwarehub_noxdrive/jobs/job_backend.dart';
import 'package:carwarehub_noxdrive/jobs/job_models.dart';

class FakeExecutor implements AdbExecutor {
  final calls = <String>[];

  /// Что получило ГУ в stdin по каждому вызову pipe, по порядку.
  final received = <List<int>>[];

  /// Вызовы pipe с таким размером завершатся ошибкой установки.
  final failSizes = <int>{};

  /// Команды shell, которые завершатся ошибкой.
  final failShell = <String>{};

  @override
  Future<DeviceInfo> readDeviceInfo(String serial) async =>
      DeviceInfo(build: 'CHANGAN.Q05.1.0', model: 'Q05', serial: serial);

  @override
  Future<String> shell(String serial, String command) async {
    calls.add('shell:$command');
    if (failShell.contains(command)) throw AdbException('нет доступа');
    return 'ok';
  }

  @override
  Future<void> pipe(
    String serial,
    List<String> remoteArgs,
    Stream<List<int>> data,
  ) async {
    calls.add('pipe:${remoteArgs.join(' ')}');
    final bytes = [await for (final c in data) ...c];
    received.add(bytes);
    if (failSizes.contains(bytes.length)) {
      throw AdbException('Failure [INSTALL_FAILED]');
    }
  }

  @override
  Future<void> reboot(String serial) async => calls.add('reboot');
}

class FakeBackend implements JobBackend {
  FakeBackend(this.ticket, this.encrypted);
  final JobTicket ticket;
  final List<int> encrypted;
  final finished = <bool>[];
  bool refundRequested = false;
  int refundCalls = 0;

  /// Отметка об успехе не доходит до сервера (обрыв связи в конце задания).
  bool failFinishSuccess = false;

  @override
  Future<JobTicket> startJob({
    required String vin,
    required int serviceId,
    required int modelId,
    required String appVersion,
    required DeviceInfo device,
  }) async => ticket;

  @override
  Future<PackagePreview> preview({
    required String vin,
    required int serviceId,
    required int modelId,
    required DeviceInfo device,
  }) async => const PackagePreview(
    items: ['Яндекс Навигатор', 'Языковой пакет'],
    price: 5,
    repeat: false,
  );

  @override
  Future<void> finishJob(
    String jobId, {
    required bool success,
    required String log,
  }) async {
    if (success && failFinishSuccess) throw Exception('нет связи');
    finished.add(success);
  }

  @override
  Future<void> requestRefund(String jobId, String reason) async {
    refundCalls++;
    refundRequested = true;
  }

  @override
  Stream<List<int>> openPayload(String storagePath) async* {
    for (var i = 0; i < encrypted.length; i += 5000) {
      yield encrypted.sublist(
        i,
        i + 5000 > encrypted.length ? encrypted.length : i + 5000,
      );
    }
  }
}

class FakePicker implements ApkPicker {
  FakePicker(this.files);
  final List<CustomApk> files;

  @override
  Future<List<CustomApk>> pick() async => files;
}
