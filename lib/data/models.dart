/// Модели каталога. Заполняются из таблиц Supabase, а не из кода.
class CarModel {
  const CarModel({required this.id, required this.code, required this.title});
  final int id;
  final String code;
  final String title;

  factory CarModel.fromJson(Map<String, dynamic> j) => CarModel(
    id: j['id'] as int,
    code: j['code'] as String,
    title: j['title'] as String,
  );
}

class ServiceItem {
  const ServiceItem({
    required this.id,
    required this.code,
    required this.title,
    required this.priceCredits,
    this.allowCustomApks = false,
  });
  final int id;
  final String code;
  final String title;
  final int priceCredits;

  /// Для услуги можно добавить свои APK (услуги установки).
  final bool allowCustomApks;

  factory ServiceItem.fromJson(Map<String, dynamic> j) => ServiceItem(
    id: j['id'] as int,
    code: j['code'] as String,
    title: j['title'] as String,
    priceCredits: (j['price_credits'] as int?) ?? 0,
    allowCustomApks: (j['allow_custom_apks'] as bool?) ?? false,
  );
}

/// Последняя доступная версия приложения (таблица app_releases) для Auto-Up.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.buildNumber,
    required this.isMandatory,
    required this.downloadPath,
    this.minSupportedVersion,
    this.releaseNotes,
  });
  final String version;
  final int buildNumber;
  final bool isMandatory;
  final String downloadPath;
  final String? minSupportedVersion;
  final String? releaseNotes;

  factory AppRelease.fromJson(Map<String, dynamic> j) => AppRelease(
    version: j['version'] as String,
    buildNumber: j['build_number'] as int,
    isMandatory: (j['is_mandatory'] as bool?) ?? false,
    downloadPath: j['download_path'] as String,
    minSupportedVersion: j['min_supported_version'] as String?,
    releaseNotes: j['release_notes'] as String?,
  );
}
