import '../core/json.dart';

/// Модели каталога. Заполняются из таблиц Supabase, а не из кода.
class CarModel {
  const CarModel({required this.id, required this.code, required this.title});
  final int id;
  final String code;
  final String title;

  factory CarModel.fromJson(Map<String, dynamic> j) => CarModel(
    id: intOr(j['id']),
    code: str(j['code']),
    title: str(j['title']),
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
    id: intOr(j['id']),
    code: str(j['code']),
    title: str(j['title']),
    priceCredits: intOr(j['price_credits']),
    allowCustomApks: boolOr(j['allow_custom_apks']),
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
    version: str(j['version']),
    buildNumber: intOr(j['build_number']),
    isMandatory: boolOr(j['is_mandatory']),
    downloadPath: str(j['download_path']),
    minSupportedVersion: strOrNull(j['min_supported_version']),
    releaseNotes: strOrNull(j['release_notes']),
  );
}
