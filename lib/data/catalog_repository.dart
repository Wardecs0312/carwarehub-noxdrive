import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/env.dart';
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

  /// Возвращает релиз новее текущей версии приложения или null.
  Future<AppRelease?> availableUpdate() async {
    if (!Env.hasSupabase) return null;
    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;
    final rows = await _db
        .from('app_releases')
        .select()
        .eq('platform', 'windows')
        .eq('channel', 'stable')
        .eq('is_active', true)
        .order('build_number', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    final r = AppRelease.fromJson(rows.first);
    return r.buildNumber > current ? r : null;
  }
}

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

final updateProvider = FutureProvider(
  (ref) => ref.watch(catalogRepositoryProvider).availableUpdate(),
);
