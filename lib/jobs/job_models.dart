import '../core/json.dart';

enum StepType { installApk, runScript, pushFile, shell, uninstall, reboot }

/// Один шаг сценария, как его вернул сервер (`start_job`).
class JobStep {
  const JobStep({
    required this.type,
    required this.title,
    this.storagePath,
    this.sizeBytes,
    this.encKey,
    this.sha256,
    this.cmd,
    this.packages = const [],
    this.grantPermissions = false,
    this.downgrade = false,
    this.remotePath,
    this.ignoreErrors = false,
  });

  final StepType type;
  final String title;
  final String? storagePath;
  final int? sizeBytes;
  final String? encKey;

  /// SHA-256 расшифрованного файла (hex, из таблицы payloads). Скрипты и файлы сверяются с ним
  /// до отправки на головное устройство.
  final String? sha256;
  final String? cmd;
  final List<String> packages;

  /// Для install_apk: выдать приложению все разрешения при установке (аналог `adb install -g`).
  final bool grantPermissions;

  /// Для install_apk: разрешить установку более старой версии (аналог `adb install -d`).
  final bool downgrade;

  /// Для push_file: куда записать файл на головном устройстве.
  final String? remotePath;

  /// Для shell: ошибка команды не прерывает задание (очистка временных файлов и т.п.).
  final bool ignoreErrors;

  bool get needsPayload =>
      type == StepType.installApk ||
      type == StepType.runScript ||
      type == StepType.pushFile;

  factory JobStep.fromJson(Map<String, dynamic> j) {
    final type = switch (j['type']) {
      'install_apk' => StepType.installApk,
      'run_script' => StepType.runScript,
      'push_file' => StepType.pushFile,
      'shell' => StepType.shell,
      'uninstall' => StepType.uninstall,
      'reboot' => StepType.reboot,
      final other => throw FormatException('Неизвестный шаг сценария: $other'),
    };
    return JobStep(
      type: type,
      title: str(j['title']),
      storagePath: strOrNull(j['storage_path']),
      sizeBytes: (j['size_bytes'] as num?)?.toInt(),
      encKey: strOrNull(j['enc_key']),
      sha256: strOrNull(j['sha256'])?.toLowerCase(),
      cmd: strOrNull(j['cmd']),
      packages: [for (final p in (j['packages'] as List?) ?? const []) str(p)],
      grantPermissions: boolOr(j['grant']),
      downgrade: boolOr(j['downgrade']),
      remotePath: strOrNull(j['remote_path']),
      ignoreErrors: boolOr(j['ignore_errors']),
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
    jobId: requireStr(j, 'job_id', 'Запуск услуги'),
    price: intOr(j['price']),
    repeat: boolOr(j['repeat']),
    steps: ((j['steps'] as List?) ?? const [])
        .map((e) => JobStep.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}

class DeviceInfo {
  const DeviceInfo({
    required this.build,
    required this.model,
    required this.serial,
    this.huSerial = '',
  });
  final String build;
  final String model;
  final String serial;

  /// Заводской серийный номер головного устройства (ro.serialno). По нему сервер отличает
  /// повтор услуги на той же машине (бесплатно) от другой машины с тем же VIN (платно).
  final String huSerial;
  Map<String, dynamic> toJson() => {
    'build': build,
    'model': model,
    'serial': serial,
    'hu_serial': huSerial,
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

/// Собственный APK мастера, добавленный в окне настройки пакета.
class CustomApk {
  const CustomApk({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.selected = true,
  });
  final String path;
  final String name;
  final int sizeBytes;
  final bool selected;

  CustomApk copyWith({bool? selected}) => CustomApk(
    path: path,
    name: name,
    sizeBytes: sizeBytes,
    selected: selected ?? this.selected,
  );
}

/// Предпросмотр основного пакета услуги: что будет установлено и сколько это стоит.
class PackagePreview {
  const PackagePreview({
    required this.items,
    required this.price,
    required this.repeat,
  });
  final List<String> items;
  final int price;
  final bool repeat;

  factory PackagePreview.fromJson(Map<String, dynamic> j) => PackagePreview(
    price: intOr(j['price']),
    repeat: boolOr(j['repeat']),
    items: [
      for (final e in ((j['items'] as List?) ?? const []))
        if ((e as Map)['type'] != 'reboot')
          _itemTitle(Map<String, dynamic>.from(e)),
    ],
  );

  static String _itemTitle(Map<String, dynamic> e) {
    final title = strOrNull(e['title']);
    if (title != null && title.isNotEmpty) return title;
    return switch (e['type']) {
      'install_apk' => 'Установка приложения',
      'run_script' => 'Выполнение сценария настройки',
      'uninstall' => 'Удаление приложений',
      _ => 'Настройка системы',
    };
  }
}
