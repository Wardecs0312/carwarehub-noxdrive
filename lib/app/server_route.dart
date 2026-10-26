import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'env.dart';

/// Откуда программа узнаёт адрес посредника для России. Страница скачивания на Vercel открывается
/// из России; при переезде посредника меняется только этот файл, выпуск программы не нужен.
const routeConfigUrl = 'https://noxdrive-download.vercel.app/route.json';

/// Адрес базы для этого компьютера: напрямую Supabase или посредник в России
/// (Россия режет скорость к Cloudflare, на котором стоит Supabase: вход проходит, файлы — нет).
String chooseServerUrl({
  required String direct,
  String? proxy,
  String? countryCode,
  String? override,
}) {
  final hasProxy = proxy != null && proxy.startsWith('https://');
  if (override == 'direct' || !hasProxy) return direct;
  if (override == 'ru') return proxy;
  return countryCode?.toUpperCase() == 'RU' ? proxy : direct;
}

/// Выбранный адрес базы (заполняется в [resolveServerUrl] до запуска Supabase).
class ServerRoute {
  static String url = Env.supabaseUrl;
  static bool get viaProxy => url != Env.supabaseUrl;
}

File? _cacheFile() {
  final base = Platform.environment['LOCALAPPDATA'];
  if (base == null) return null;
  return File(
    '$base${Platform.pathSeparator}nox.drive${Platform.pathSeparator}route.json',
  );
}

/// Код страны по IP: два независимых сервиса, первый ответивший.
Future<String?> fetchCountryCode(http.Client c) async {
  try {
    final r = await c
        .get(Uri.parse('https://ipwho.is/?fields=success,country_code'))
        .timeout(const Duration(seconds: 3));
    final j = asMap(jsonDecode(r.body));
    if (j['success'] == true) return strOrNull(j['country_code']);
  } catch (_) {}
  try {
    final r = await c
        .get(Uri.parse('https://ipapi.co/country/'))
        .timeout(const Duration(seconds: 3));
    final code = r.body.trim();
    if (r.statusCode == 200 && RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
      return code;
    }
  } catch (_) {}
  return null;
}

/// Свежие данные (адрес посредника и страна) → файл для следующего запуска.
Future<Map<String, String?>> _refresh(File? cache) async {
  final c = http.Client();
  try {
    String? proxy;
    try {
      final r = await c
          .get(Uri.parse(routeConfigUrl))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) {
        proxy = strOrNull(asMap(jsonDecode(r.body))['ru_proxy']);
      }
    } catch (_) {}
    final country = await fetchCountryCode(c);
    final data = {'proxy': proxy, 'country': country};
    // Страна не определилась — прошлое решение не затираем.
    if (cache != null && country != null) {
      try {
        await cache.parent.create(recursive: true);
        await cache.writeAsString(jsonEncode(data));
      } catch (_) {}
    }
    return data;
  } finally {
    c.close();
  }
}

/// Решает, куда ходить, до запуска Supabase. Если есть решение с прошлого запуска, берёт его
/// сразу (запуск не ждёт сети) и обновляет в фоне; в первый раз ждёт проверку не дольше 5 с.
/// NOX_SERVER=ru|direct — ручной выбор (поддержка, проверка).
Future<void> resolveServerUrl() async {
  if (kIsWeb || !Env.hasSupabase) return;
  final override = Platform.environment['NOX_SERVER'];
  final cache = _cacheFile();
  Map<String, String?>? data;
  try {
    if (cache != null && cache.existsSync()) {
      final j = asMap(jsonDecode(await cache.readAsString()));
      data = {
        'proxy': strOrNull(j['proxy']),
        'country': strOrNull(j['country']),
      };
    }
  } catch (_) {}
  if (data == null) {
    // Первый запуск: ждём не дольше 5 с, иначе напрямую (решение запомнится в фоне).
    data = await _refresh(cache)
        .timeout(const Duration(seconds: 5), onTimeout: () => const {});
  } else {
    unawaited(_refresh(cache));
  }
  ServerRoute.url = chooseServerUrl(
    direct: Env.supabaseUrl,
    proxy: data['proxy'],
    countryCode: data['country'],
    override: override,
  );
}
