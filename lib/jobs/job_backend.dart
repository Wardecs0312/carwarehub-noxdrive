import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'job_models.dart';

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

  /// Зашифрованный поток файла из приватного хранилища. На диск не пишется.
  Stream<List<int>> openPayload(String storagePath);
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

  @override
  Stream<List<int>> openPayload(String storagePath) async* {
    final url = await _db.storage
        .from('payloads')
        .createSignedUrl(storagePath, 300);
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw JobException(
          'Не удалось получить файл с сервера (код ${resp.statusCode})',
        );
      }
      yield* resp;
    } finally {
      client.close(force: true);
    }
  }
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
}
