// Публикация пакета услуги: архив с .apk, шифрование каждого файла, загрузка в приватный
// bucket `payloads`, записи в таблицах payloads и scenarios.
// Запускать на компьютере администратора. Ключ service_role нужен только здесь и никогда
// не попадает в приложение и в репозиторий.
//
//   export SUPABASE_URL=https://<project>.supabase.co
//   export SUPABASE_SERVICE_KEY=<service_role key>
//   dart run tool/publish_package.dart --zip nox.zip --service russify --model q05 \
//       --firmware '%' --pre-script tool/local/russify_pre.sh [--soft-dir soft] [--reboot] [--dry-run]
//
// --firmware: шаблон LIKE для сравнения с ro.build.display.id головного устройства ('%' = любая прошивка).
// --pre-script: sh-скрипт, который выполняется на ГУ до установки приложений (отдельный файл, хранится
//   только у администратора, лежит в tool/local/, эта папка исключена из git).
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:carwarehub_noxdrive/security/payload_cipher.dart';
import 'package:cryptography/cryptography.dart';

import 'package_builder.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) continue;
    final key = args[i].substring(2);
    final isFlag = i + 1 >= args.length || args[i + 1].startsWith('--');
    out[key] = isFlag ? 'true' : args[++i];
  }
  return out;
}

class _Api {
  _Api(this.base, this.key);
  final String base;
  final String key;
  final _http = HttpClient();

  Future<dynamic> _send(
    String method,
    String path, {
    List<int>? body,
    Map<String, String>? headers,
  }) async {
    final req = await _http.openUrl(method, Uri.parse('$base$path'));
    req.headers
      ..set('apikey', key)
      ..set('Authorization', 'Bearer $key');
    headers?.forEach(req.headers.set);
    if (body != null) req.add(body);
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode >= 300) {
      throw Exception('$method $path: ${resp.statusCode} $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<List<dynamic>> select(String path) async =>
      (await _send('GET', '/rest/v1/$path')) as List;

  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, dynamic> row,
  ) async {
    final res = await _send(
      'POST',
      '/rest/v1/$table',
      body: utf8.encode(jsonEncode(row)),
      headers: {
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
      },
    ) as List;
    return Map<String, dynamic>.from(res.first as Map);
  }

  Future<void> upload(String bucket, String path, List<int> bytes) => _send(
    'POST',
    '/storage/v1/object/$bucket/$path',
    body: bytes,
    headers: {'Content-Type': 'application/octet-stream', 'x-upsert': 'true'},
  );
}

Future<void> main(List<String> argv) async {
  final a = _parseArgs(argv);
  final dry = a['dry-run'] == 'true';
  for (final required in ['zip', 'service', 'model']) {
    if (a[required] == null) {
      stderr.writeln(
        'Не указан параметр --$required. См. описание в начале файла tool/publish_package.dart',
      );
      exit(64);
    }
  }
  final url = Platform.environment['SUPABASE_URL'];
  final key = Platform.environment['SUPABASE_SERVICE_KEY'];
  if (!dry && (url == null || key == null)) {
    stderr.writeln(
      'Задайте переменные окружения SUPABASE_URL и SUPABASE_SERVICE_KEY',
    );
    exit(64);
  }

  final archive = ZipDecoder().decodeBytes(await File(a['zip']!).readAsBytes());
  final apks = collectApks(archive, dir: a['soft-dir'] ?? 'soft');
  if (apks.isEmpty) {
    stderr.writeln('В архиве нет .apk в папке ${a['soft-dir'] ?? 'soft'}/');
    exit(1);
  }
  final files = [
    if (a['pre-script'] != null)
      PayloadFile(
        name: 'pre.sh',
        bytes: await File(a['pre-script']!).readAsBytes(),
        kind: 'sh',
      ),
    ...apks,
  ];

  stdout.writeln('К публикации (${files.length}):');
  for (final f in files) {
    stdout.writeln(
      '  ${f.kind.padRight(3)} ${f.name}  ${(f.bytes.length / 1024 / 1024).toStringAsFixed(1)} МБ',
    );
  }
  if (dry) {
    stdout.writeln('Пробный запуск: ничего не загружено.');
    return;
  }

  final api = _Api(url!, key!);
  final serviceId =
      (await api.select(
            'services?code=eq.${Uri.encodeQueryComponent(a['service']!)}&select=id',
          )).first['id']
          as int;
  final modelId =
      (await api.select(
            'car_models?code=eq.${Uri.encodeQueryComponent(a['model']!)}&select=id',
          )).first['id']
          as int;
  final pattern = a['firmware'] ?? '%';
  final fwRows = await api.select(
    'firmwares?model_id=eq.$modelId&version_pattern=eq.${Uri.encodeQueryComponent(pattern)}&select=id',
  );
  final firmwareId = fwRows.isNotEmpty
      ? fwRows.first['id'] as int
      : (await api.insert('firmwares', {
              'model_id': modelId,
              'version_pattern': pattern,
            }))['id']
            as int;

  final ids = <String, String>{};
  for (final f in files) {
    final k = PayloadCipher.generateKey();
    final enc = await PayloadCipher(k).encrypt(f.bytes);
    final path =
        '${a['service']}/${DateTime.now().millisecondsSinceEpoch}_${f.name}.enc';
    await api.upload('payloads', path, enc);
    final row = await api.insert('payloads', {
      'storage_path': path,
      'kind': f.kind,
      'size_bytes': f.bytes.length,
      'sha256': _hex((await Sha256().hash(f.bytes)).bytes),
      'enc_key': base64Encode(k),
    });
    ids[f.name] = row['id'] as String;
    stdout.writeln('  загружено: ${f.name}');
  }

  final steps = buildSteps(
    preScriptId: ids['pre.sh'],
    apks: [for (final f in apks) (id: ids[f.name]!, name: f.name)],
    reboot: a['reboot'] == 'true',
  );
  final last = await api.select(
    'scenarios?service_id=eq.$serviceId&firmware_id=eq.$firmwareId&select=version&order=version.desc&limit=1',
  );
  final version = last.isEmpty ? 1 : (last.first['version'] as int) + 1;
  await api.insert('scenarios', {
    'service_id': serviceId,
    'firmware_id': firmwareId,
    'version': version,
    'steps': steps,
  });
  stdout.writeln('Готово: сценарий версии $version, шагов: ${steps.length}.');
}
