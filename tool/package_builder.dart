// Чистая логика сборки пакетов услуг из архива: без сети и без диска, поэтому покрыта тестами.
import 'package:archive/archive.dart';

/// Файл, который нужно зашифровать и загрузить. [key] связывает файл с шагами сценария.
class PlanFile {
  PlanFile({required this.key, required this.bytes, required this.kind});
  final String key;
  final List<int> bytes;

  /// 'apk', 'sh' или 'bin'
  final String kind;
}

/// Результат разбора архива под конкретную услугу.
class RecipePlan {
  RecipePlan({required this.files, required this.steps});
  final List<PlanFile> files;

  /// Строит шаги сценария, когда известны id загруженных файлов (ключ файла -> id в таблице payloads).
  final List<Map<String, dynamic>> Function(Map<String, String> ids) steps;
}

class RecipeException implements Exception {
  RecipeException(this.message);
  final String message;
  @override
  String toString() => message;
}

List<String> _segments(String path) =>
    path.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList();

/// Файлы внутри папки [dir] архива (папка может лежать под лишней корневой папкой).
/// Возвращает пары (путь относительно [dir], содержимое). Сортировка без учёта регистра.
List<({String rel, List<int> bytes})> filesInDir(
  Archive archive,
  String dir, {
  bool recursive = true,
}) {
  final out = <({String rel, List<int> bytes})>[];
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final seg = _segments(f.name);
    final i = seg.indexWhere((s) => s.toLowerCase() == dir.toLowerCase());
    if (i < 0 || i == seg.length - 1) continue;
    final rest = seg.sublist(i + 1);
    if (!recursive && rest.length > 1) continue;
    out.add((rel: rest.join('/'), bytes: f.readBytes() ?? const []));
  }
  out.sort((a, b) => a.rel.toLowerCase().compareTo(b.rel.toLowerCase()));
  return out;
}

/// Все .apk прямо в папке [dir] (в батнике `for %%F in (soft\*.apk)`), в алфавитном порядке.
List<({String name, List<int> bytes})> apksInDir(Archive archive, String dir) =>
    [
      for (final f in filesInDir(archive, dir, recursive: false))
        if (f.rel.toLowerCase().endsWith('.apk')) (name: f.rel, bytes: f.bytes),
    ];

/// Файл по относительному пути (например 'SpeechHMI.apk' или 'WT_ThemeResourcesDay/WT_ThemeResourcesDay.apk').
List<int> requireFile(Archive archive, String relPath) {
  final want = _segments(relPath).map((s) => s.toLowerCase()).toList();
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final seg = _segments(f.name).map((s) => s.toLowerCase()).toList();
    if (seg.length < want.length) continue;
    final tail = seg.sublist(seg.length - want.length);
    if (tail.join('/') == want.join('/')) return f.readBytes() ?? const [];
  }
  throw RecipeException('В архиве не найден файл: $relPath');
}

List<int> _text(String s) => s.codeUnits;

String apkTitle(String fileName) =>
    'Установка: ${fileName.replaceAll(RegExp(r'\.apk$', caseSensitive: false), '')}';

Map<String, dynamic> _installStep(
  String key,
  String name, {
  bool grant = false,
  bool downgrade = false,
}) => {
  'type': 'install_apk',
  'title': apkTitle(name),
  'payload_key': key,
  if (grant) 'grant': true,
  if (downgrade) 'downgrade': true,
};

Map<String, dynamic> _shell(
  String title,
  String cmd, {
  bool hidden = false,
  bool ignoreErrors = false,
}) => {
  'type': 'shell',
  'title': title,
  'cmd': cmd,
  if (hidden) 'hidden': true,
  if (ignoreErrors) 'ignore_errors': true,
};

Map<String, dynamic> _push(
  String title,
  String key,
  String remote, {
  bool hidden = false,
}) => {
  'type': 'push_file',
  'title': title,
  'payload_key': key,
  'remote_path': remote,
  if (hidden) 'hidden': true,
};

/// Подставляет id загруженных файлов вместо payload_key.
List<Map<String, dynamic>> _resolve(
  List<Map<String, dynamic>> steps,
  Map<String, String> ids,
) => [
  for (final s in steps)
    {
      for (final e in s.entries)
        if (e.key != 'payload_key') e.key: e.value,
      if (s.containsKey('payload_key'))
        'payload_id':
            ids[s['payload_key']] ??
            (throw RecipeException('Нет id для ${s['payload_key']}')),
    },
];

String _lines(List<String> l) => '${l.join('\n')}\n';

/// [1] Русификация: подготовка, затем все .apk из soft/ с выдачей разрешений (`adb install -r -g`).
/// Без папки soft/ пакет состоит только из подготовки: приложения мастер добавляет сам («Добавить свои APK»).
/// [prep] содержит строку(и) доступа (disable-verify) и хранится только у администратора.
RecipePlan planRussify(Archive zip, {required String prep}) {
  final apks = apksInDir(zip, 'soft');
  final pre = _lines([
    prep.trim(),
    'am start -n com.android.settings/.Settings',
    'setprop vecentek.model 1',
  ]);
  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      for (final a in apks)
        PlanFile(key: 'soft/${a.name}', bytes: a.bytes, kind: 'apk'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      for (final a in apks) _installStep('soft/${a.name}', a.name, grant: true),
    ], ids),
  );
}

/// [5] Системные приложения: подготовка, .apk из firmware/ (`adb install -r -d`), включение overlay.
RecipePlan planSystemApps(Archive zip, {required String prep}) {
  final apks = apksInDir(zip, 'firmware');
  if (apks.isEmpty) {
    throw RecipeException('В архиве нет .apk в папке firmware/');
  }
  final pre = _lines([prep.trim(), 'setprop vecentek.model 1']);
  const overlays = [
    'com.google.android.overlay.aiassistant',
    'com.google.android.overlay.visualizationservice',
    'com.google.android.overlay.carlauncher',
  ];
  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      for (final a in apks)
        PlanFile(key: 'firmware/${a.name}', bytes: a.bytes, kind: 'apk'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      for (final a in apks)
        _installStep('firmware/${a.name}', a.name, downgrade: true),
      for (var i = 0; i < overlays.length; i++)
        _shell(
          'Включение Overlay',
          'cmd overlay enable ${overlays[i]}',
          hidden: i > 0,
        ),
    ], ids),
  );
}

/// [6] Приложение для приборной панели: подготовка (как в [2] и [5]: доступ ADB и setprop),
/// затем один .apk с выдачей разрешений. В батнике для этой услуги ветки нет, подготовка добавлена по решению заказчика.
RecipePlan planCluster(List<int> apk, {required String prep}) {
  final pre = _lines([prep.trim(), 'setprop vecentek.model 1']);
  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      PlanFile(key: 'cluster.apk', bytes: apk, kind: 'apk'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      {
        'type': 'install_apk',
        'title': 'Установка приложения для приборной панели',
        'payload_key': 'cluster.apk',
        'grant': true,
      },
    ], ids),
  );
}

/// [2] Голосовое управление. Повторяет ветку :voice батника: файлы кладутся в /data/local/tmp,
/// SpeechHMI устанавливается, затем всё переносится в /resources/appdata/tinnove/, временные файлы удаляются.
RecipePlan planVoice(Archive zip, {required String prep}) {
  const tmp = '/data/local/tmp';
  const dest = '/resources/appdata/tinnove';
  final base = {
    'WT_SpeechMiddleware.apk': requireFile(zip, 'WT_SpeechMiddleware.apk'),
    'SpeechHMI.apk': requireFile(zip, 'SpeechHMI.apk'),
  };
  final iflytek = filesInDir(zip, 'IflytekSpeech');
  if (iflytek.isEmpty) {
    throw RecipeException('В архиве нет папки IflytekSpeech');
  }
  final themes = {
    'WT_ThemeResourcesDay.apk': requireFile(
      zip,
      'WT_ThemeResourcesDay/WT_ThemeResourcesDay.apk',
    ),
    'WT_ThemeResourcesNight.apk': requireFile(
      zip,
      'WT_ThemeResourcesNight/WT_ThemeResourcesNight.apk',
    ),
  };
  final dirs = <String>{'$tmp/IflytekSpeech'};
  for (final f in iflytek) {
    final seg = f.rel.split('/');
    for (var i = 1; i < seg.length; i++) {
      dirs.add('$tmp/IflytekSpeech/${seg.sublist(0, i).join('/')}');
    }
  }
  final pre = _lines([prep.trim(), 'setprop vecentek.model 1']);

  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      for (final e in base.entries)
        PlanFile(key: e.key, bytes: e.value, kind: 'apk'),
      for (final f in iflytek)
        PlanFile(key: 'IflytekSpeech/${f.rel}', bytes: f.bytes, kind: 'bin'),
      for (final e in themes.entries)
        PlanFile(key: e.key, bytes: e.value, kind: 'apk'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      _shell(
        'Загрузка ресурсов',
        'mkdir -p ${(dirs.toList()..sort()).map((d) => "'$d'").join(' ')}',
        hidden: true,
      ),
      for (var i = 0; i < base.length; i++)
        _push(
          'Загрузка основы',
          base.keys.elementAt(i),
          '$tmp/${base.keys.elementAt(i)}',
          hidden: i > 0,
        ),
      for (var i = 0; i < iflytek.length; i++)
        _push(
          'Загрузка ресурсов',
          'IflytekSpeech/${iflytek[i].rel}',
          '$tmp/IflytekSpeech/${iflytek[i].rel}',
          hidden: i > 0,
        ),
      for (final k in themes.keys)
        _push('Загрузка ресурсов', k, '$tmp/$k', hidden: true),
      _shell('Установка компонентов', 'pm install -g -r $tmp/SpeechHMI.apk'),
      _shell('Перемещение файлов', 'cp -r $tmp/IflytekSpeech $dest/'),
      _shell(
        'Перемещение файлов',
        'mv $tmp/SpeechHMI.apk $dest/',
        hidden: true,
      ),
      _shell(
        'Перемещение файлов',
        'mv $tmp/WT_SpeechMiddleware.apk $dest/',
        hidden: true,
      ),
      _shell(
        'Перемещение файлов',
        'mv $tmp/WT_ThemeResourcesDay.apk $dest/WT_ThemeResourcesDay/',
        hidden: true,
      ),
      _shell(
        'Перемещение файлов',
        'mv $tmp/WT_ThemeResourcesNight.apk $dest/WT_ThemeResourcesNight/',
        hidden: true,
      ),
      _shell(
        'Очистка временных файлов',
        'rm -rf $tmp/IflytekSpeech',
        ignoreErrors: true,
      ),
      _shell(
        'Очистка временных файлов',
        'rm $tmp/*.apk',
        hidden: true,
        ignoreErrors: true,
      ),
    ], ids),
  );
}
