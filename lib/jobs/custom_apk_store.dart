import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import 'job_models.dart';

/// Свои APK мастера, которые он добавил в окне «Настройка пакета установки».
/// Список запоминается: добавил один раз, и он остаётся (вместе с галочками) при следующих
/// услугах и после перезапуска программы, пока мастер сам не уберёт файл из списка.
abstract class CustomApkStore {
  Future<List<CustomApk>> load();
  Future<void> save(List<CustomApk> apks);
}

/// Хранение в `%APPDATA%\nox.drive\custom_apks.json` на компьютере мастера.
/// Файлы, которых больше нет на диске, при загрузке пропускаются: поставить их всё равно нельзя.
class FileCustomApkStore implements CustomApkStore {
  FileCustomApkStore({File? file}) : _file = file ?? _defaultFile();

  final File? _file;

  static File? _defaultFile() {
    final base = Platform.environment['APPDATA'];
    if (base == null || base.isEmpty) return null;
    final sep = Platform.pathSeparator;
    return File('$base${sep}nox.drive${sep}custom_apks.json');
  }

  @override
  Future<List<CustomApk>> load() async {
    final f = _file;
    if (f == null || !await f.exists()) return [];
    try {
      final rows = jsonDecode(await f.readAsString()) as List;
      return [
        for (final r in rows.whereType<Map>())
          if (File(str(r['path'])).existsSync())
            CustomApk(
              path: str(r['path']),
              name: str(r['name']),
              sizeBytes: File(str(r['path'])).lengthSync(),
              selected: boolOr(r['selected'], true),
            ),
      ];
    } catch (_) {
      return []; // повреждённый файл не должен мешать работе
    }
  }

  @override
  Future<void> save(List<CustomApk> apks) async {
    final f = _file;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode([
        for (final a in apks)
          {'path': a.path, 'name': a.name, 'selected': a.selected},
      ]),
    );
  }
}

final customApkStoreProvider = Provider<CustomApkStore>(
  (_) => FileCustomApkStore(),
);
