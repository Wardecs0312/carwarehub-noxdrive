enum StepType { installApk, runScript, shell, uninstall, reboot }

/// Один шаг сценария, как его вернул сервер (`start_job`).
class JobStep {
  const JobStep({
    required this.type,
    required this.title,
    this.storagePath,
    this.sizeBytes,
    this.encKey,
    this.cmd,
    this.packages = const [],
  });

  final StepType type;
  final String title;
  final String? storagePath;
  final int? sizeBytes;
  final String? encKey;
  final String? cmd;
  final List<String> packages;

  bool get needsPayload =>
      type == StepType.installApk || type == StepType.runScript;

  factory JobStep.fromJson(Map<String, dynamic> j) {
    final type = switch (j['type']) {
      'install_apk' => StepType.installApk,
      'run_script' => StepType.runScript,
      'shell' => StepType.shell,
      'uninstall' => StepType.uninstall,
      'reboot' => StepType.reboot,
      final other => throw FormatException('Неизвестный шаг сценария: $other'),
    };
    return JobStep(
      type: type,
      title: (j['title'] as String?) ?? '',
      storagePath: j['storage_path'] as String?,
      sizeBytes: (j['size_bytes'] as num?)?.toInt(),
      encKey: j['enc_key'] as String?,
      cmd: j['cmd'] as String?,
      packages: ((j['packages'] as List?) ?? const []).cast<String>(),
    );
  }
}

class JobTicket {
  const JobTicket({
    required this.jobId,
    required this.price,
    required this.repeat,
    required this.steps,
  });
  final String jobId;
  final int price;
  final bool repeat;
  final List<JobStep> steps;

  factory JobTicket.fromJson(Map<String, dynamic> j) => JobTicket(
    jobId: j['job_id'] as String,
    price: (j['price'] as num).toInt(),
    repeat: (j['repeat'] as bool?) ?? false,
    steps: (j['steps'] as List)
        .map((e) => JobStep.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}

class DeviceInfo {
  const DeviceInfo({
    required this.build,
    required this.model,
    required this.serial,
  });
  final String build;
  final String model;
  final String serial;
  Map<String, dynamic> toJson() => {
    'build': build,
    'model': model,
    'serial': serial,
  };
}

/// Ошибка с понятным для мастера текстом.
class JobException implements Exception {
  JobException(this.message, {this.jobId, this.refundable = false});
  final String message;
  final String? jobId;

  /// Деньги за задание уже списаны, можно подать заявку на возврат.
  final bool refundable;
  @override
  String toString() => message;
}
