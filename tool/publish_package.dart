// Публикация пакета услуги: разбор архива по рецепту (tool/package_builder.dart), шифрование каждого файла,
// загрузка в приватный bucket `payloads`, записи в таблицах payloads и scenarios.
// Запускать на компьютере администратора. Ключ service_role нужен только здесь и никогда
// не попадает в приложение и в репозиторий.
//
//   export SUPABASE_URL=https://<project>.supabase.co
//   export SUPABASE_SERVICE_KEY=<service_role key>
//   dart run tool/publish_package.dart --recipe russify --source storage:firmwares/nox.zip \
//       --prep tool/local/prep.sh --models all [--firmware '%'] [--dry-run]
//
//   --recipe  russify | voice | sysapps | cluster
//   --source  путь к локальному файлу или storage:<bucket>/<путь> (архив nox.zip; для cluster сам .apk)
//   --prep    файл с командой доступа ADB (строка с disable-verify), только у администратора, папка tool/local/ не в git
//   --models  all или коды моделей через запятую (q05,uni-z,...)
//   --firmware шаблон LIKE для ro.build.display.id головного устройства ('%' = любая прошивка)
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

  Future<List<int>> _raw(
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
    final bytes = <int>[await for (final c in resp) ...c];
    if (resp.statusCode >= 300) {
      throw Exception(
        '$method $path: ${resp.statusCode} ${utf8.decode(bytes, allowMalformed: true)}',
      );
    }
    return bytes;
  }

  Future<dynamic> _json(
    String method,
    String path, {
    List<int>? body,
    Map<String, String>? headers,
  }) async {
    final bytes = await _raw(method, path, body: body, headers: headers);
    return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
  }

  Future<List<dynamic>> select(String path) async =>
      (await _json('GET', '/rest/v1/$path')) as List;

  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, dynamic> row,
  ) async {
    final res = await _json(
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

  Future<void> upload(String bucket, String path, List<int> bytes) => _raw(
    'POST',
    '/storage/v1/object/$bucket/$path',
    body: bytes,
    headers: {'Content-Type': 'application/octet-stream', 'x-upsert': 'true'},
  );

  Future<List<int>> download(String bucket, String path) =>
      _raw('GET', '/storage/v1/object/$bucket/$path');
}

Never _fail(String msg, [int code = 64]) {
  stderr.writeln(msg);
  exit(code);
}

Future<void> main(List<String> argv) async {
  final a = _parseArgs(argv);
  final dry = a['dry-run'] == 'true';
  final recipe = a['recipe'];
  final source = a['source'];
  if (recipe == null || source == null) {
    _fail('Нужны параметры --recipe и --source. См. описание в начале файла.');
  }
  const known = ['russify', 'voice', 'sysapps', 'cluster'];
  if (!known.contains(recipe)) {
    _fail('Неизвестный рецепт $recipe. Доступны: ${known.join(', ')}');
  }
  if (recipe != 'cluster' && a['prep'] == null) {
    _fail('Для $recipe нужен --prep (файл с командой доступа ADB)');
  }

  final url = Platform.environment['SUPABASE_URL'];
  final key = Platform.environment['SUPABASE_SERVICE_KEY'];
  final needNet = !dry || source.startsWith('storage:');
  if (needNet && (url == null || key == null)) {
    _fail('Задайте переменные окружения SUPABASE_URL и SUPABASE_SERVICE_KEY');
  }
  final api = needNet ? _Api(url!, key!) : null;

  // 1. Источник
  List<int> data;
  if (source.startsWith('storage:')) {
    final full = source.substring('storage:'.length);
    final slash = full.indexOf('/');
    if (slash < 0) _fail('Формат: storage:<bucket>/<путь>');
    stdout.writeln('Скачиваю $full ...');
    data = await api!.download(
      full.substring(0, slash),
      full.substring(slash + 1),
    );
  } else {
    data = await File(source).readAsBytes();
  }
  final prep = a['prep'] == null ? '' : await File(a['prep']!).readAsString();

  // 2. Разбор по рецепту
  RecipePlan plan;
  try {
    plan = switch (recipe) {
      'cluster' => planCluster(data),
      'russify' => planRussify(ZipDecoder().decodeBytes(data), prep: prep),
      'sysapps' => planSystemApps(ZipDecoder().decodeBytes(data), prep: prep),
      _ => planVoice(ZipDecoder().decodeBytes(data), prep: prep),
    };
  } on RecipeException catch (e) {
    _fail('Ошибка разбора: $e', 1);
  }

  final mb =
      plan.files.fold<int>(0, (s, f) => s + f.bytes.length) / 1024 / 1024;
  stdout.writeln(
    'Рецепт $recipe: файлов ${plan.files.length}, ${mb.toStringAsFixed(1)} МБ',
  );
  final previewSteps = plan.steps({for (final f in plan.files) f.key: 'id'});
  stdout.writeln('Шаги сценария (${previewSteps.length}), видимые мастеру:');
  for (final s in previewSteps.where((s) => s['hidden'] != true)) {
    stdout.writeln('  • ${s['title']}');
  }
  if (dry) {
    stdout.writeln('Пробный запуск: ничего не загружено.');
    return;
  }
  api!;

  // 3. Модели и прошивки
  final serviceId =
      (await api.select(
            'services?code=eq.${Uri.encodeQueryComponent(recipe)}&select=id',
          )).first['id']
          as int;
  final modelFilter = a['models'] ?? 'all';
  final models = await api.select(
    'car_models?select=id,code&is_active=eq.true',
  );
  final selected = modelFilter == 'all'
      ? models
      : models
            .where(
              (m) => modelFilter
                  .split(',')
                  .map((e) => e.trim())
                  .contains(m['code']),
            )
            .toList();
  if (selected.isEmpty) _fail('Модели не найдены: $modelFilter', 1);
  final pattern = a['firmware'] ?? '%';

  // 4. Загрузка файлов
  final ids = <String, String>{};
  for (final f in plan.files) {
    final k = PayloadCipher.generateKey();
    final enc = await PayloadCipher(k).encrypt(f.bytes);
    final path =
        '$recipe/${DateTime.now().millisecondsSinceEpoch}_${ids.length}.enc';
    await api.upload('payloads', path, enc);
    final row = await api.insert('payloads', {
      'storage_path': path,
      'kind': f.kind,
      'size_bytes': f.bytes.length,
      'sha256': _hex((await Sha256().hash(f.bytes)).bytes),
      'enc_key': base64Encode(k),
    });
    ids[f.key] = row['id'] as String;
    stdout.write('\rЗагружено ${ids.length}/${plan.files.length}');
  }
  stdout.writeln();

  // 5. Сценарии
  final steps = plan.steps(ids);
  for (final m in selected) {
    final modelId = m['id'] as int;
    final fw = await api.select(
      'firmwares?model_id=eq.$modelId&version_pattern=eq.${Uri.encodeQueryComponent(pattern)}&select=id',
    );
    final firmwareId = fw.isNotEmpty
        ? fw.first['id'] as int
        : (await api.insert('firmwares', {
                'model_id': modelId,
                'version_pattern': pattern,
              }))['id']
              as int;
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
    stdout.writeln('  ${m['code']}: сценарий версии $version');
  }
  stdout.writeln('Готово.');
}
