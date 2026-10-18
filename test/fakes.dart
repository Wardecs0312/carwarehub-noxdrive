import 'package:carwarehub_noxdrive/adb/adb_executor.dart';
import 'package:carwarehub_noxdrive/adb/adb_sync.dart';
import 'package:carwarehub_noxdrive/jobs/apk_picker.dart';
import 'package:carwarehub_noxdrive/jobs/custom_apk_store.dart';
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

  /// Столько первых вызовов pipe завершатся так, будто ГУ пропало из ADB.
  int loseDeviceTimes = 0;

  /// Сколько раз программа ждала возвращения ГУ.
  int waits = 0;

  /// Сколько раз выполнена разблокировка (пункт 1 AUTOMAX KG) и что было до неё.
  int unlocks = 0;
  bool readBeforeUnlock = false;

  @override
  Future<void> unlock(String serial) async => unlocks++;

  @override
  Future<DeviceInfo> readDeviceInfo(String serial) async {
    if (unlocks == 0) readBeforeUnlock = true;
    return DeviceInfo(build: 'CHANGAN.Q05.1.0', model: 'Q05', serial: serial);
  }

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
    if (loseDeviceTimes > 0) {
      loseDeviceTimes--;
      throw AdbException("error: device '$serial' not found");
    }
    final bytes = [await for (final c in data) ...c];
    received.add(bytes);
    if (failSizes.contains(bytes.length)) {
      throw AdbException('Failure [INSTALL_FAILED]');
    }
  }

  Future<void> _deliver(String call, Stream<List<int>> data) async {
    calls.add(call);
    if (loseDeviceTimes > 0) {
      loseDeviceTimes--;
      throw AdbException("error: device 'X' not found");
    }
    if (stallTimes > 0) {
      stallTimes--;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      throw AdbStallException('Передача на автомобиль замерла');
    }
    final bytes = [await for (final c in data) ...c];
    received.add(bytes);
    if (failSizes.contains(bytes.length)) {
      throw AdbException('Failure [INSTALL_FAILED]');
    }
  }

  /// Столько первых передач «замрут» (сторож снимет их).
  int stallTimes = 0;
  int cancels = 0;

  @override
  Future<void> install(
    String serial,
    Stream<List<int>> data, {
    bool grant = false,
    bool downgrade = false,
    void Function(int sent)? onProgress,
  }) => _deliver(
    ['install', if (grant) '-g', if (downgrade) '-d'].join(' '),
    data,
  );

  @override
  Future<void> push(
    String serial,
    Stream<List<int>> data,
    String remotePath, {
    void Function(int sent)? onProgress,
  }) => _deliver('push $remotePath', data);

  @override
  void cancel() => cancels++;

  @override
  Future<void> reboot(String serial) async => calls.add('reboot');

  @override
  Future<bool> waitForDevice(String serial, Duration timeout) async {
    waits++;
    return true;
  }
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

  /// Расчёт цены для окна подтверждения падает (машина не ответила).
  bool failPreview = false;

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
  }) async {
    if (failPreview) throw Exception('Автомобиль не ответил');
    return const PackagePreview(
      items: ['Яндекс Навигатор', 'Языковой пакет'],
      price: 5,
      repeat: false,
    );
  }

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

  /// Какие файлы программа попросила скачать заранее.
  final prefetched = <String>[];
  final invalidated = <String>[];

  @override
  void prefetch(Iterable<String> storagePaths) =>
      prefetched.addAll(storagePaths);

  @override
  Future<void> invalidatePayload(String storagePath) async =>
      invalidated.add(storagePath);

  @override
  Future<bool> fetchPayload(
    String storagePath, {
    void Function(int got, int? total)? onProgress,
  }) async => false;

  int heartbeats = 0;

  @override
  Future<void> heartbeat(String jobId) async => heartbeats++;

  final prefetchedModels = <int>[];

  @override
  Future<void> prefetchModel(int modelId) async =>
      prefetchedModels.add(modelId);

  @override
  Future<void> trimCache() async {}

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

/// Список своих APK мастера в памяти (вместо файла в %APPDATA%).
class MemoryApkStore implements CustomApkStore {
  MemoryApkStore([List<CustomApk>? initial]) : saved = [...?initial];
  List<CustomApk> saved;
  int saves = 0;

  @override
  Future<List<CustomApk>> load() async => List.of(saved);

  @override
  Future<void> save(List<CustomApk> apks) async {
    saves++;
    saved = List.of(apks);
  }
}
