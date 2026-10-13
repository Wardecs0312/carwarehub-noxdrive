// Публикация новой версии программы для автообновления (таблица app_releases + bucket releases).
// Запускать на компьютере администратора; ключ service_role только в переменных окружения.
//
//   SUPABASE_URL=https://<project>.supabase.co SUPABASE_SERVICE_KEY=<service_role>
//   dart run tool/publish_release.dart --file build/nox-windows.zip --platform windows \
//       --notes "Что нового" [--mandatory] [--dry-run]
//
// Версия и номер сборки берутся из pubspec.yaml (version: 2.0.0+2). Номер сборки должен расти:
// программа предлагает обновление, когда build_number в базе больше её собственного.
// Windows: zip содержимого папки Release (exe, data\, adb\, scrcpy\ в корне архива). Android: .apk.
import 'dart:convert';
import 'dart:io';

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
  stderr.writeln(m);
  exit(64);
}

Future<void> main(List<String> argv) async {
  final a = _args(argv);
  final path = a['file'] ?? _fail('Нужен --file');
  final platform = a['platform'] ?? 'windows';
  if (!['windows', 'android'].contains(platform)) {
    _fail('--platform: windows или android');
  }
  final file = File(path);
  if (!file.existsSync()) _fail('Файл не найден: $path');

  final pubspec = File('pubspec.yaml').readAsStringSync();
  final m = RegExp(
    r'^version:\s*([0-9.]+)\+(\d+)',
    multiLine: true,
  ).firstMatch(pubspec);
  if (m == null) _fail('В pubspec.yaml нет version: X.Y.Z+N');
  final version = m.group(1)!;
  final build = int.parse(m.group(2)!);

  final bytes = file.readAsBytesSync();
  final sum = sha256.convert(bytes).toString();
  final ext = path.toLowerCase().endsWith('.apk') ? 'apk' : 'zip';
  final storagePath = '$platform/$version+$build.$ext';
  stdout.writeln(
    'Версия $version (сборка $build), $platform, '
    '${(bytes.length / 1024 / 1024).toStringAsFixed(1)} МБ, sha256 $sum',
  );
  if (a['dry-run'] == 'true') {
    stdout.writeln('Пробный запуск: ничего не загружено.');
    return;
  }

  final url = Platform.environment['SUPABASE_URL'];
  final key = Platform.environment['SUPABASE_SERVICE_KEY'];
  if (url == null || key == null) {
    _fail('Задайте SUPABASE_URL и SUPABASE_SERVICE_KEY');
  }
  final http = HttpClient();
  Future<String> send(
    String method,
    String p,
    List<int> body,
    Map<String, String> headers,
  ) async {
    final req = await http.openUrl(method, Uri.parse('$url$p'));
    req.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key');
    headers.forEach(req.headers.set);
    req.add(body);
    final resp = await req.close();
    final text = await utf8.decodeStream(resp);
    if (resp.statusCode >= 300) {
      _fail('$method $p: ${resp.statusCode} $text');
    }
    return text;
  }

  stdout.writeln('Загрузка в releases/$storagePath ...');
  await send('POST', '/storage/v1/object/releases/$storagePath', bytes, {
    'Content-Type': 'application/octet-stream',
    'x-upsert': 'true',
  });
  await send(
    'POST',
    '/rest/v1/app_releases',
    utf8.encode(
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
    {'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
  );
  http.close();
  stdout.writeln(
    'Готово: мастера увидят предложение обновиться при следующем запуске.',
  );
}
