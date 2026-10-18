import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'job_models.dart';
import 'payload_store.dart';

/// Серверная часть выполнения услуги: биллинг, VIN, шаги сценария и доступ к зашифрованным файлам.
abstract class JobBackend {
  Future<JobTicket> startJob({
    required String vin,
    required int serviceId,
    required int modelId,
    required String appVersion,
    required DeviceInfo device,
  });

  /// Что входит в основной пакет и сколько стоит. Ничего не списывает.
  Future<PackagePreview> preview({
    required String vin,
    required int serviceId,
    required int modelId,
    required DeviceInfo device,
  });

  Future<void> finishJob(
    String jobId, {
    required bool success,
    required String log,
  });

  Future<void> requestRefund(String jobId, String reason);

  /// Зашифрованный поток файла из приватного хранилища (на диске хранится только
  /// в зашифрованном виде, в кэше программы).
  Stream<List<int>> openPayload(String storagePath);

  /// Начать заранее скачивать файлы следующих шагов.
  void prefetch(Iterable<String> storagePaths);

  /// Дождаться, пока файл окажется на диске, с ходом скачивания. true — его пришлось скачивать.
  Future<bool> fetchPayload(
    String storagePath, {
    void Function(int got, int? total)? onProgress,
  });

  /// Отметка «задание живо» (раз в 30 секунд во время услуги).
  Future<void> heartbeat(String jobId);

  /// Заранее скачать в кэш все файлы услуг модели (как у батника: к приезду машины всё на диске).
  Future<void> prefetchModel(int modelId);

  /// Файл не прошёл проверку при расшифровке: убрать из кэша, чтобы скачать заново.
  Future<void> invalidatePayload(String storagePath);

  /// Убрать из кэша самые старые файлы, если он стал слишком большим.
  Future<void> trimCache();
}

const _errorTexts = {
  'AUTH_REQUIRED': 'Войдите в аккаунт мастера',
  'MASTER_BLOCKED': 'Аккаунт мастера заблокирован. Обратитесь к администратору',
  'VIN_INVALID':
      'VIN должен содержать 17 символов (латиница и цифры, без I, O, Q)',
  'SERVICE_UNAVAILABLE': 'Эта услуга недоступна для выбранной модели',
  'SCENARIO_NOT_FOUND': 'Для этой прошивки автомобиля сценарий ещё не добавлен',
  'INSUFFICIENT_BALANCE': 'Недостаточно кредитов на балансе',
};

String _humanize(PostgrestException e) {
  for (final entry in _errorTexts.entries) {
    if (e.message.contains(entry.key)) return entry.value;
  }
  return 'Ошибка сервера: ${e.message}';
}

class SupabaseJobBackend implements JobBackend {
  SupabaseClient get _db => Supabase.instance.client;

  @override
  Future<JobTicket> startJob({
    required String vin,
    required int serviceId,
    required int modelId,
    required String appVersion,
    required DeviceInfo device,
  }) async {
    try {
      final res = await _db.rpc(
        'start_job',
        params: {
          'p_vin': vin,
          'p_service_id': serviceId,
          'p_model_id': modelId,
          'p_app_version': appVersion,
          'p_device': device.toJson(),
        },
      );
      return JobTicket.fromJson(Map<String, dynamic>.from(res as Map));
    } on PostgrestException catch (e) {
      throw JobException(_humanize(e));
    }
  }

  @override
  Future<PackagePreview> preview({
    required String vin,
    required int serviceId,
    required int modelId,
    required DeviceInfo device,
  }) async {
    try {
      final res = await _db.rpc(
        'scenario_preview',
        params: {
          'p_vin': vin,
          'p_service_id': serviceId,
          'p_model_id': modelId,
          'p_device': device.toJson(),
        },
      );
      return PackagePreview.fromJson(Map<String, dynamic>.from(res as Map));
    } on PostgrestException catch (e) {
      throw JobException(_humanize(e));
    }
  }

  @override
  Future<void> finishJob(
    String jobId, {
    required bool success,
    required String log,
  }) async {
    await _db.rpc(
      'finish_job',
      params: {'p_job_id': jobId, 'p_success': success, 'p_log': log},
    );
  }

  @override
  Future<void> requestRefund(String jobId, String reason) async {
    try {
      await _db.rpc(
        'request_refund',
        params: {'p_activation_id': jobId, 'p_reason': reason},
      );
    } on PostgrestException catch (e) {
      throw JobException(_humanize(e));
    }
  }

  /// Одно соединение на все файлы (раньше на каждый файл открывалось новое).
  static final _http = HttpClient()
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 8;

  static final store = PayloadStore(
    Directory(
      '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
      '${Platform.pathSeparator}nox.drive${Platform.pathSeparator}payload-cache',
    ),
    _downloadTo,
  );

  static Future<void> _downloadTo(
    String storagePath,
    File target,
    DownloadProgress progress,
  ) async {
    final url = await Supabase.instance.client.storage
        .from('payloads')
        .createSignedUrl(storagePath, 600);
    for (var attempt = 1; ; attempt++) {
      try {
        final req = await _http.getUrl(Uri.parse(url));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          throw JobException(
            'Не удалось получить файл с сервера (код ${resp.statusCode})',
          );
        }
        final total = resp.contentLength >= 0 ? resp.contentLength : null;
        var got = 0;
        final sink = target.openWrite();
        try {
          await resp
              .map((c) {
                got += c.length;
                progress(got, total);
                return c;
              })
              .pipe(sink);
        } catch (_) {
          await sink.close();
          rethrow;
        }
        return;
      } on JobException {
        rethrow;
      } catch (e) {
        // Обрыв интернета посреди файла: ещё две попытки.
        if (attempt >= 3) {
          throw JobException('Обрыв связи при загрузке файла: $e');
        }
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
  }

  @override
  Stream<List<int>> openPayload(String storagePath) => store.open(storagePath);

  @override
  void prefetch(Iterable<String> storagePaths) => store.prefetch(storagePaths);

  @override
  Future<bool> fetchPayload(
    String storagePath, {
    void Function(int got, int? total)? onProgress,
  }) => store.fetch(storagePath, onProgress: onProgress);

  @override
  Future<void> heartbeat(String jobId) =>
      _db.rpc('job_heartbeat', params: {'p_job': jobId});

  @override
  Future<void> prefetchModel(int modelId) async {
    final rows = await _db.rpc(
      'payloads_for_model',
      params: {'p_model': modelId},
    );
    final paths = [
      for (final r in rows as List)
        if (r is String) r else if (r is Map) '${r.values.first}',
    ];
    store.prefetch(paths);
  }

  @override
  Future<void> invalidatePayload(String storagePath) =>
      store.invalidate(storagePath);

  @override
  Future<void> trimCache() => store.trim();
}

/// Без настроенного Supabase: безопасный демо-режим, который только читает модель ГУ.
class DemoJobBackend implements JobBackend {
  @override
  Future<JobTicket> startJob({
    required String vin,
    required int serviceId,
    required int modelId,
    required String appVersion,
    required DeviceInfo device,
  }) async => const JobTicket(
    jobId: 'demo',
    price: 0,
    repeat: false,
    steps: [
      JobStep(
        type: StepType.shell,
        title: 'Проверка связи с устройством',
        cmd: 'getprop ro.product.model',
      ),
    ],
  );

  @override
  Future<PackagePreview> preview({
    required String vin,
    required int serviceId,
    required int modelId,
    required DeviceInfo device,
  }) async => const PackagePreview(
    items: ['Яндекс Навигатор', 'Русская клавиатура', 'Языковой пакет'],
    price: 0,
    repeat: false,
  );

  @override
  Future<void> finishJob(
    String jobId, {
    required bool success,
    required String log,
  }) async {}

  @override
  Future<void> requestRefund(String jobId, String reason) async {}

  @override
  Stream<List<int>> openPayload(String storagePath) =>
      Stream.error(JobException('Демо-режим: файлы недоступны'));

  @override
  void prefetch(Iterable<String> storagePaths) {}

  @override
  Future<bool> fetchPayload(
    String storagePath, {
    void Function(int got, int? total)? onProgress,
  }) async => false;

  @override
  Future<void> heartbeat(String jobId) async {}

  @override
  Future<void> prefetchModel(int modelId) async {}

  @override
  Future<void> invalidatePayload(String storagePath) async {}

  @override
  Future<void> trimCache() async {}
}
