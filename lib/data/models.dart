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
    this.variantOf,
    this.choiceTitle,
  });
  final int id;
  final String code;
  final String title;
  final int priceCredits;

  /// Для услуги можно добавить свои APK (услуги установки).
  final bool allowCustomApks;

  /// Код кнопки, вариантом которой является услуга (например, кастомный голос у «voice»).
  /// Такая услуга не показывается отдельной карточкой, её выбирают в окне выбора варианта.
  final String? variantOf;

  /// Название в окне выбора варианта («Штатный голос»); пусто — [title].
  final String? choiceTitle;

  String get choiceLabel => choiceTitle ?? title;

  factory ServiceItem.fromJson(Map<String, dynamic> j) => ServiceItem(
    id: intOr(j['id']),
    code: str(j['code']),
    title: str(j['title']),
    priceCredits: intOr(j['price_credits']),
    allowCustomApks: boolOr(j['allow_custom_apks']),
    variantOf: serviceVariantOf[str(j['code'])],
    choiceTitle: serviceChoiceTitles[str(j['code'])],
  );
}

/// Услуга-вариант -> код кнопки, внутри которой её выбирают.
/// Хранится в программе: в боевой базе нет SQL-доступа для новых колонок.
const serviceVariantOf = {'voicecustom': 'voice'};

/// Названия в окне выбора варианта.
const serviceChoiceTitles = {
  'voice': 'Штатный голос',
  'voicecustom': 'Кастомный голос MMVoice',
};

/// Карточки услуг: услуги-варианты прячутся внутрь своей кнопки.
/// [variants] по коду кнопки — остальные варианты, кроме самой кнопки.
({List<ServiceItem> cards, Map<String, List<ServiceItem>> variants})
splitVariants(List<ServiceItem> all) {
  final codes = {for (final s in all) s.code};
  final cards = <ServiceItem>[];
  final variants = <String, List<ServiceItem>>{};
  for (final s in all) {
    final parent = s.variantOf;
    // Вариант без своей кнопки (кнопка выключена для модели) показывается обычной карточкой.
    if (parent != null && codes.contains(parent)) {
      (variants[parent] ??= []).add(s);
    } else {
      cards.add(s);
    }
  }
  return (cards: cards, variants: variants);
}

/// Строка прайс-листа (таблица price_groups): пакет или отдельная активация.
/// С баланса мастера списываются кредиты ([priceCredits]); рубли и доллары — для справки.
class PriceGroup {
  const PriceGroup({
    required this.code,
    required this.title,
    this.description,
    required this.priceCredits,
    required this.priceRub,
    required this.priceUsd,
    required this.items,
    required this.naModels,
  });

  final String code;
  final String title;
  final String? description;
  final int priceCredits;
  final int priceRub;
  final int priceUsd;

  /// Состав пакета; у пункта может быть список моделей, где он недоступен.
  final List<({String title, List<String> naModels})> items;

  /// Модели, для которых вся строка недоступна.
  final List<String> naModels;

  bool availableFor(String modelCode) => !naModels.contains(modelCode);

  factory PriceGroup.fromJson(Map<String, dynamic> j) => PriceGroup(
    code: str(j['code']),
    title: str(j['title']),
    description: strOrNull(j['description']),
    priceCredits: intOr(j['price_credits']),
    priceRub: intOr(j['price_rub']),
    priceUsd: intOr(j['price_usd']),
    items: [
      for (final i in (j['items'] as List?) ?? const [])
        (
          title: str(asMap(i)['title']),
          naModels: [
            for (final m in (asMap(i)['na_models'] as List?) ?? const [])
              str(m),
          ],
        ),
    ],
    naModels: [for (final m in (j['na_models'] as List?) ?? const []) str(m)],
  );
}

/// «4 000 ₽» с неразрывным пробелом между разрядами.
String formatRub(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '$b ₽';
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
    this.sha256,
    this.sizeBytes,
    this.signature,
  });
  final String version;
  final int buildNumber;
  final bool isMandatory;

  /// Путь в приватном bucket `releases` (zip папки программы или .apk).
  final String downloadPath;
  final String? minSupportedVersion;
  final String? releaseNotes;

  /// Контрольная сумма файла: скачанное обновление без совпадения не устанавливается.
  final String? sha256;
  final int? sizeBytes;

  /// Подпись выпуска ключом администратора (Ed25519, base64), см. ReleaseSignature.
  final String? signature;

  factory AppRelease.fromJson(Map<String, dynamic> j) => AppRelease(
    version: str(j['version']),
    buildNumber: intOr(j['build_number']),
    isMandatory: boolOr(j['is_mandatory']),
    downloadPath: str(j['download_path']),
    minSupportedVersion: strOrNull(j['min_supported_version']),
    releaseNotes: strOrNull(j['release_notes']),
    sha256: strOrNull(j['sha256'])?.toLowerCase(),
    sizeBytes: j['size_bytes'] == null ? null : intOr(j['size_bytes']),
    signature: strOrNull(j['signature']),
  );
}
