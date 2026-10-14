// Публикация новой версии программы для автообновления (таблица app_releases + bucket releases).
// Запускать на компьютере администратора; ключ service_role только в переменных окружения.
// Обычно вызывается из tool/release_windows.ps1, который сначала собирает программу и архив.
//
//   SUPABASE_URL=https://<project>.supabase.co SUPABASE_SERVICE_KEY=<service_role>
//   dart run tool/publish_release.dart --file build/nox-windows.zip --platform windows \
//       --notes "Что нового" [--mandatory] [--dry-run]
//
// Версия и номер сборки берутся из pubspec.yaml (version: 2.0.0+2).
// Перед загрузкой утилита проверяет всё, из-за чего выпуск ломается у мастеров, и при ошибке ничего не публикует:
//   1. номер сборки больше любого уже выпущенного для этой платформы (иначе мастера не увидят обновление);
//   2. версия внутри exe совпадает с pubspec.yaml (иначе программа будет бесконечно предлагать обновиться);
//   3. программа собрана с адресом этого проекта Supabase, а не в демо-режиме без входа;
//   4. в корне архива есть exe, движок, data\, adb\ и scrcpy\.
// После загрузки файл скачивается обратно и сверяется по SHA-256. Если запись в базу не удалась,
// загруженный файл удаляется, чтобы не оставалось полувыпуска.
// --dry-run выполняет все проверки (с сетью, если заданы переменные), но ничего не загружает.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

Map<String, String> _args(List<String> a) {
  final out = <String, String>{};
  for (var i = 0; i < a.length; i++) {
    if (!a[i].startsWith('--')) continue;
    final k = a[i].substring(2);
    final flag = i + 1 >= a.length || a[i + 1].startsWith('--');
    out[k] = flag ? 'true' : a[++i];
  }
  return out;
}

Never _fail(String m) {
  stderr.writeln('ОШИБКА: $m');
  stderr.writeln('Ничего не опубликовано.');
  exit(64);
}

void _ok(String m) => stdout.writeln('  ✓ $m');

const _exeName = 'carwarehub_noxdrive.exe';

/// Есть ли в байтах строка (обычная или в UTF-16, как в ресурсах версии exe).
bool _containsText(List<int> bytes, String text, {bool utf16 = false}) {
  final needle = utf16
      ? [
          for (final c in text.codeUnits) ...[c & 0xff, c >> 8],
        ]
      : utf8.encode(text);
  outer:
  for (var i = 0; i <= bytes.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Проверки архива Windows. Возвращает список проблем (пустой = всё в порядке).
List<String> checkWindowsZip(
  List<int> zipBytes, {
  required String version,
  required int build,
  String? supabaseUrl,
}) {
  final problems = <String>[];
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    return ['файл не является zip-архивом ($e)'];
  }
  // На повреждённых данных распаковщик может не упасть, а вернуть пустой архив.
  if (zip.files.isEmpty) return ['файл не является zip-архивом или пуст'];
  final names = {for (final f in zip.files) f.name.replaceAll('\\', '/')};
  ArchiveFile? find(String n) {
    for (final f in zip.files) {
      if (f.name.replaceAll('\\', '/') == n) return f;
    }
    return null;
  }

  for (final required in [
    _exeName,
    'flutter_windows.dll',
    'data/app.so',
    'data/icudtl.dat',
    'adb/adb.exe',
    'adb/AdbWinApi.dll',
    'adb/AdbWinUsbApi.dll',
    'scrcpy/scrcpy.exe',
  ]) {
    if (!names.contains(required)) {
      problems.add(
        'в корне архива нет $required (упакуйте содержимое папки Release, а не саму папку)',
      );
    }
  }

  final exe = find(_exeName);
  if (exe != null) {
    final want = '$version+$build';
    if (!_containsText(exe.content as List<int>, want, utf16: true)) {
      problems.add(
        'версия внутри $_exeName не $want. Пересоберите программу после изменения pubspec.yaml '
        '(без --build-name/--build-number)',
      );
    }
  }

  final so = find('data/app.so');
  if (so != null && supabaseUrl != null) {
    final host = Uri.parse(supabaseUrl).host;
    if (!_containsText(so.content as List<int>, host)) {
      problems.add(
        'программа собрана без адреса проекта $host: у мастеров она откроется в демо-режиме без входа. '
        'Соберите с --dart-define=SUPABASE_URL и --dart-define=SUPABASE_ANON_KEY',
      );
    }
  }
  return problems;
}

class _Api {
  _Api(this.base, this.key);
  final String base;
  final String key;
  final _http = HttpClient();

  Future<(int, List<int>)> send(
    String method,
    String path, {
    List<int>? body,
    Map<String, String> headers = const {},
  }) async {
    final req = await _http.openUrl(method, Uri.parse('$base$path'));
    req.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key');
    headers.forEach(req.headers.set);
    if (body != null) req.add(body);
    final resp = await req.close();
    final bytes = <int>[await for (final c in resp) ...c];
    return (resp.statusCode, bytes);
  }

  void close() => _http.close(force: true);
}

Future<void> main(List<String> argv) async {
  final a = _args(argv);
  final dry = a['dry-run'] == 'true';
  final path = a['file'] ?? _fail('Нужен --file');
  final platform = a['platform'] ?? 'windows';
  if (!['windows', 'android'].contains(platform)) {
    _fail('--platform: windows или android');
  }
  final file = File(path);
  if (!file.existsSync()) _fail('Файл не найден: $path');

  final pubspec = File('pubspec.yaml').readAsStringSync();
  final m = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+(\d+)',
    multiLine: true,
  ).firstMatch(pubspec);
  if (m == null) _fail('В pubspec.yaml нет version: X.Y.Z+N');
  final version = m.group(1)!;
  final build = int.parse(m.group(2)!);

  final bytes = file.readAsBytesSync();
  final sum = sha256.convert(bytes).toString();
  final ext = path.toLowerCase().endsWith('.apk') ? 'apk' : 'zip';
  if (platform == 'windows' && ext != 'zip') _fail('Для Windows нужен zip');
  if (platform == 'android' && ext != 'apk') _fail('Для Android нужен apk');
  final storagePath = '$platform/$version+$build.$ext';
  stdout.writeln(
    'Версия $version (сборка $build), $platform, '
    '${(bytes.length / 1024 / 1024).toStringAsFixed(1)} МБ, sha256 $sum',
  );

  final url = Platform.environment['SUPABASE_URL'];
  final key = Platform.environment['SUPABASE_SERVICE_KEY'];

  stdout.writeln('Проверка файла:');
  if (platform == 'windows') {
    final problems = checkWindowsZip(
      bytes,
      version: version,
      build: build,
      supabaseUrl: url,
    );
    if (problems.isNotEmpty) _fail(problems.join('\n  '));
    _ok('архив: exe, движок, data, adb, scrcpy на месте');
    _ok('версия внутри программы $version+$build совпадает с pubspec.yaml');
    if (url != null) {
      _ok('программа собрана с адресом ${Uri.parse(url).host}');
    } else {
      stdout.writeln('  ! адрес проекта не проверен: не задан SUPABASE_URL');
    }
  }

  if (url == null || key == null) {
    if (dry) {
      stdout.writeln(
        'Пробный запуск без SUPABASE_URL/SUPABASE_SERVICE_KEY: проверки базы пропущены.',
      );
      return;
    }
    _fail('Задайте SUPABASE_URL и SUPABASE_SERVICE_KEY');
  }
  final api = _Api(url, key);
  try {
    stdout.writeln('Проверка базы:');
    final (code, body) = await api.send(
      'GET',
      '/rest/v1/app_releases?platform=eq.$platform&select=version,build_number&order=build_number.desc&limit=1',
    );
    if (code != 200) {
      _fail('не удалось прочитать app_releases: $code ${utf8.decode(body)}');
    }
    final rows = jsonDecode(utf8.decode(body)) as List;
    if (rows.isNotEmpty) {
      final last = rows.first as Map;
      final lastBuild = last['build_number'] as int;
      if (build <= lastBuild) {
        _fail(
          'номер сборки $build не больше уже выпущенного ${last['version']}+$lastBuild. '
          'Увеличьте version в pubspec.yaml (например ${_next(last['version'] as String)}+${lastBuild + 1}) и пересоберите',
        );
      }
      _ok('номер сборки $build больше последнего выпущенного ($lastBuild)');
    } else {
      _ok('это первый выпуск для $platform');
    }

    if (dry) {
      stdout.writeln(
        'Пробный запуск: все проверки пройдены, ничего не загружено.',
      );
      return;
    }

    stdout.writeln('Загрузка в releases/$storagePath ...');
    final (upCode, upBody) = await api.send(
      'POST',
      '/storage/v1/object/releases/$storagePath',
      body: bytes,
      // Без перезаписи: у уже выпущенного файла должна оставаться своя контрольная сумма.
      headers: {'Content-Type': 'application/octet-stream'},
    );
    if (upCode >= 300) {
      _fail('загрузка не удалась: $upCode ${utf8.decode(upBody)}');
    }

    Future<void> rollback() async {
      await api.send('DELETE', '/storage/v1/object/releases/$storagePath');
    }

    final (dlCode, dlBody) = await api.send(
      'GET',
      '/storage/v1/object/releases/$storagePath',
    );
    if (dlCode != 200 || sha256.convert(dlBody).toString() != sum) {
      await rollback();
      _fail(
        'загруженный файл не совпал с исходным по SHA-256, загрузка отменена',
      );
    }
    _ok('файл загружен и сверен по SHA-256');

    final (insCode, insBody) = await api.send(
      'POST',
      '/rest/v1/app_releases',
      body: utf8.encode(
        jsonEncode({
          'platform': platform,
          'channel': 'stable',
          'version': version,
          'build_number': build,
          'download_path': storagePath,
          'sha256': sum,
          'size_bytes': bytes.length,
          'release_notes': a['notes'],
          'is_mandatory': a['mandatory'] == 'true',
        }),
      ),
      headers: {'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
    );
    if (insCode >= 300) {
      await rollback();
      _fail(
        'запись в app_releases не удалась, файл удалён: $insCode ${utf8.decode(insBody)}',
      );
    }
    _ok('запись в app_releases добавлена');
    stdout.writeln(
      'Готово: мастера увидят предложение обновиться при следующем запуске.\n'
      'Отменить выпуск: в app_releases поставить is_active = false у этой строки.',
    );
  } finally {
    api.close();
  }
}

/// 2.0.10 -> 2.0.11
String _next(String v) {
  final p = v.split('.');
  return [
    ...p.take(p.length - 1),
    '${(int.tryParse(p.last) ?? 0) + 1}',
  ].join('.');
}
