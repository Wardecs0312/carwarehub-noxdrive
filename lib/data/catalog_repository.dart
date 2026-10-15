import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/env.dart';
import 'auth_repository.dart';
import 'models.dart';

/// Загружает каталог моделей, услуг и информацию об обновлении из Supabase.
/// Без настроенного Supabase показывает демо-данные, чтобы интерфейс запускался.
class CatalogRepository {
  SupabaseClient get _db => Supabase.instance.client;

  Future<List<CarModel>> models() async {
    if (!Env.hasSupabase) return _demoModels;
    final rows = await _db
        .from('car_models')
        .select('id, code, title')
        .eq('is_active', true)
        .order('sort_order');
    return rows.map(CarModel.fromJson).toList();
  }

  /// Услуги, доступные для выбранной модели (таблица model_services).
  Future<List<ServiceItem>> servicesFor(int modelId) async {
    if (!Env.hasSupabase) return _demoServices;
    final rows = await _db
        .from('model_services')
        .select(
          'price_override, services(id, code, title, price_credits, allow_custom_apks, sort_order)',
        )
        .eq('model_id', modelId)
        .eq('is_active', true);
    final items = rows.map((r) {
      final s = Map<String, dynamic>.from(r['services'] as Map);
      s['price_credits'] = r['price_override'] ?? s['price_credits'];
      return (s['sort_order'] as int? ?? 100, ServiceItem.fromJson(s));
    }).toList()..sort((a, b) => a.$1.compareTo(b.$1));
    return items.map((e) => e.$2).toList();
  }

  /// Прайс-лист (пакеты и отдельные активации) с исключениями по моделям.
  Future<List<PriceGroup>> priceGroups() async {
    if (!Env.hasSupabase) return _demoPrices;
    final rows = await _db
        .from('price_groups')
        .select()
        .eq('is_active', true)
        .order('sort_order');
    return rows.map(PriceGroup.fromJson).toList();
  }

  /// Возвращает релиз новее текущей версии приложения или null.
  Future<AppRelease?> availableUpdate() async {
    // PWA обновляется сама (service worker), проверка нужна только установленным сборкам.
    final platform = releasePlatform;
    if (!Env.hasSupabase || platform == null) return null;
    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;
    final rows = await _db
        .from('app_releases')
        .select()
        .eq('platform', platform)
        .eq('channel', 'stable')
        .eq('is_active', true)
        .order('build_number', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    final r = AppRelease.fromJson(rows.first);
    return r.buildNumber > current ? r : null;
  }
}

/// Значение `app_releases.platform` для текущей сборки; null для PWA.
String? get releasePlatform {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'windows',
    TargetPlatform.android => 'android',
    _ => null,
  };
}

const _demoPrices = [
  PriceGroup(
    code: 'complex',
    title: 'Обычный доступ: русификация',
    description: 'Разблокировка ADB, полный перевод системы, установка приложений, перевод приборной панели, голосовой ассистент',
    priceCredits: 4,
    priceRub: 4000,
    priceUsd: 48,
    items: [
      (title: 'Разблокировка ADB', naModels: []),
      (title: 'Полный перевод системы', naModels: []),
      (title: 'Установка приложений', naModels: []),
      (title: 'Перевод приборной панели', naModels: ['q05']),
      (title: 'Голосовой ассистент', naModels: []),
    ],
    naModels: [],
  ),
  PriceGroup(
    code: 'cluster',
    title: 'Вывод приложений на приборную панель',
    description: 'Отдельный доступ',
    priceCredits: 2,
    priceRub: 2000,
    priceUsd: 23,
    items: [(title: 'Вывод приложений на приборную панель', naModels: [])],
    naModels: ['q05'],
  ),
];

const _demoModels = [
  CarModel(id: 1, code: 'q05', title: 'Changan Q05'),
  CarModel(id: 2, code: 'uni-z', title: 'Changan UNI-Z'),
  CarModel(id: 3, code: 'cs75-pro', title: 'Changan CS75 Pro'),
  CarModel(id: 4, code: 'cs55-plus', title: 'Changan CS55 Plus'),
  CarModel(id: 5, code: 'uni-v', title: 'Changan UNI-V'),
];

const _demoServices = [
  ServiceItem(
    id: 1,
    code: 'russify',
    title: 'Русификация и установка приложений',
    priceCredits: 0,
    allowCustomApks: true,
  ),
  ServiceItem(
    id: 2,
    code: 'voice',
    title: 'Установка голосового управления',
    priceCredits: 0,
    allowCustomApks: true,
  ),
  ServiceItem(
    id: 3,
    code: 'debloat',
    title: 'Удаление китайских приложений',
    priceCredits: 0,
  ),
  ServiceItem(
    id: 4,
    code: 'reboot',
    title: 'Перезагрузка автомобиля',
    priceCredits: 0,
  ),
  ServiceItem(
    id: 5,
    code: 'sysapps',
    title: 'Установка системных приложений',
    priceCredits: 0,
    allowCustomApks: true,
  ),
  ServiceItem(
    id: 6,
    code: 'cluster',
    title: 'Вывод приложений на приборную панель',
    priceCredits: 0,
  ),
];

final catalogRepositoryProvider = Provider((_) => CatalogRepository());

final modelsProvider = FutureProvider(
  (ref) => ref.watch(catalogRepositoryProvider).models(),
);

final selectedModelProvider = StateProvider<CarModel?>((_) => null);

final servicesProvider = FutureProvider((ref) async {
  final model = ref.watch(selectedModelProvider);
  if (model == null) return <ServiceItem>[];
  return ref.watch(catalogRepositoryProvider).servicesFor(model.id);
});

/// Прайс-лист. Если таблица ещё не создана (миграция 0008 не применена), карточка цены не показывается.
final priceGroupsProvider = FutureProvider<List<PriceGroup>>((ref) async {
  try {
    return await ref.watch(catalogRepositoryProvider).priceGroups();
  } catch (_) {
    return const [];
  }
});

/// Специальные цены текущего мастера (код строки прайса → кредиты). Пусто — обычные цены.
final myPricesProvider = FutureProvider<Map<String, int>>((ref) async {
  if (!Env.hasSupabase) return const {};
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return const {};
  try {
    final rows = await Supabase.instance.client
        .from('master_prices')
        .select('group_code, price_credits')
        .eq('master_id', uid);
    return {
      for (final r in rows)
        '${r['group_code']}': (r['price_credits'] as num?)?.toInt() ?? 0,
    };
  } catch (_) {
    return const {}; // таблицы ещё нет (миграция 0011 не применена)
  }
});

/// Как часто программа сама перепроверяет обновления, пока открыта.
const updateRecheckInterval = Duration(minutes: 30);

/// Доступное обновление. Список версий виден только вошедшим, поэтому проверка повторяется
/// после входа и смены аккаунта (иначе новый мастер не увидит обязательное обновление до
/// перезапуска), а также раз в [updateRecheckInterval], пока программа открыта.
final updateProvider = FutureProvider<AppRelease?>((ref) {
  ref.watch(sessionProvider.select((s) => s.value?.user.id));
  final timer = Timer(updateRecheckInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(catalogRepositoryProvider).availableUpdate();
});
