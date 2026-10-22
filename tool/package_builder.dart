// Чистая логика сборки пакетов услуг из архива: без сети и без диска, поэтому покрыта тестами.
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;

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

/// Путь помощника перевода приборной панели на ГУ.
const clusterLanguageHelperPath =
    '/data/local/tmp/c281-polymeric-language-helper.jar';

/// [7] Перевод приборной панели на русский. Повторяет c281_language_switch.cmd из архива
/// «рестайлинг чанганы»: помощник кладётся в /data/local/tmp и через app_process отправляет
/// штатной службе polymeric_service язык приборки (ru = 23). Помощник при ошибке печатает ERROR,
/// поэтому шаг сам проверяет его ответ, иначе задание показало бы успех без перевода.
RecipePlan planClusterLanguage(List<int> jar, {required String prep}) {
  final pre = _lines([prep.trim(), 'setprop vecentek.model 1']);
  const run =
      'CLASSPATH=$clusterLanguageHelperPath app_process /system/bin C281PolymericLanguage set ru';
  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      PlanFile(key: 'cluster-language-helper.jar', bytes: jar, kind: 'bin'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      _push(
        'Загрузка помощника',
        'cluster-language-helper.jar',
        clusterLanguageHelperPath,
        hidden: true,
      ),
      _shell(
        'Перевод приборной панели на русский',
        'out=\$($run 2>&1); echo "\$out"; case "\$out" in *ERROR*) exit 1;; esac',
      ),
      _shell(
        'Очистка временных файлов',
        'rm -f $clusterLanguageHelperPath',
        hidden: true,
        ignoreErrors: true,
      ),
    ], ids),
  );
}

/// Строка таблицы оверлеев русификации Q07 (overlays.csv из архива «q07 ru»).
typedef Q07Overlay = ({
  String apk,
  String overlayPackage,
  String targetPackage,
  String label,
  String sha256,
});

/// Разбор CSV в кавычках: "Order","Apk","OverlayPackage","TargetPackage","Label","SHA256".
List<List<String>> _quotedCsv(List<int> bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  final rows = <List<String>>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    rows.add([
      for (final m in RegExp(r'"([^"]*)"').allMatches(line)) m.group(1)!,
    ]);
  }
  return rows;
}

final _pkgName = RegExp(r'^[A-Za-z0-9_.]+$');

String _safePkg(String p) {
  if (!_pkgName.hasMatch(p)) {
    throw RecipeException('Недопустимое имя пакета: $p');
  }
  return p;
}

/// Таблицы пакета Q07: 36 оверлеев (overlays.csv) и устаревшие оверлеи (legacy_overlays.csv).
({List<Q07Overlay> overlays, List<({String overlay, String target})> legacy})
q07Tables(Archive zip) {
  final table = _quotedCsv(requireFile(zip, 'overlays.csv'));
  if (table.isEmpty || table.first.length < 6) {
    throw RecipeException('overlays.csv: нет заголовка');
  }
  final overlays = <Q07Overlay>[
    for (final r in table.skip(1))
      if (r.length >= 6)
        (
          apk: r[1],
          overlayPackage: _safePkg(r[2]),
          targetPackage: _safePkg(r[3]),
          label: r[4],
          sha256: r[5].toLowerCase(),
        ),
  ];
  if (overlays.length != 36) {
    throw RecipeException(
      'overlays.csv: ожидалось 36 оверлеев, найдено ${overlays.length}',
    );
  }
  final legacy = [
    for (final r in _quotedCsv(requireFile(zip, 'legacy_overlays.csv')).skip(1))
      if (r.length >= 2) (overlay: _safePkg(r[0]), target: _safePkg(r[1])),
  ];
  return (overlays: overlays, legacy: legacy);
}

/// Общая часть скриптов Q07: пользователи AAOS (0 и текущий) и состояние оверлея.
/// Как в батнике: состояние берётся из `cmd overlay list --user U <целевое приложение>`.
const _q07ShellHead = r'''
u=$(am get-current-user 2>/dev/null | tr -dc 0-9)
[ -z "$u" ] && u=$(cmd activity get-current-user 2>/dev/null | tr -dc 0-9)
if [ -z "$u" ]; then echo "Error: current user not read"; exit 1; fi
users=0
[ "$u" != 0 ] && users="0 $u"
st() {
  out=$(cmd overlay list --user "$3" "$2" 2>/dev/null | sed 's/^ *//')
  if printf '%s\n' "$out" | grep -qxF "[x] $1"; then echo enabled
  elif printf '%s\n' "$out" | grep -qxF "[ ] $1"; then echo disabled
  elif printf '%s\n' "$out" | grep -qxF -- "--- $1"; then echo error
  else echo missing; fi
}
''';

/// Функция включения одного оверлея (refresh_one_user батника).
const _q07EnableFunction = r'''
ok=0; bad=0
en() {
  o=$1; t=$2; applicable=0; fail=0
  for usr in $users; do
    s=$(st "$o" "$t" "$usr")
    if [ "$s" = missing ]; then
      if pm path --user "$usr" "$t" 2>/dev/null | grep -q '^package:'; then
        cmd package install-existing --user "$usr" "$o" >/dev/null 2>&1
        s=$(st "$o" "$t" "$usr")
        if [ "$s" = missing ]; then applicable=$((applicable+1)); fail=1; echo "FAIL $o user $usr: not registered"; continue; fi
      else
        continue
      fi
    fi
    applicable=$((applicable+1))
    cmd overlay disable --user "$usr" "$o" >/dev/null 2>&1
    if ! cmd overlay enable --user "$usr" "$o" >/dev/null 2>&1; then fail=1; echo "FAIL $o user $usr: enable"; continue; fi
    [ "$(st "$o" "$t" "$usr")" = enabled ] || { fail=1; echo "FAIL $o user $usr: state"; }
  done
  if [ "$applicable" -eq 0 ]; then fail=1; echo "FAIL $o: no user"; fi
  if [ "$fail" -eq 0 ]; then ok=$((ok+1)); else bad=$((bad+1)); fi
}
''';

const _q07RestartLauncher = r'''
for usr in $users; do
  am force-stop --user "$usr" com.incall.apps.dlp >/dev/null 2>&1
  am force-stop --user "$usr" com.incall.apps.sdalauncher >/dev/null 2>&1
done
am start --user "$u" -n com.incall.apps.sdalauncher/com.incall.apps.model_main.MainActivity >/dev/null 2>&1
''';

const _q07EnableResult = r'''
echo "overlays ok: $ok, failed: $bad, users: $users"
if [ "$bad" -ne 0 ]; then echo "Error: $bad overlays not enabled"; exit 1; fi
''';

/// Сколько оверлеев включает одна часть скрипта (у `adb shell` в программе предел 60 секунд).
const _q07EnablePart = 4;

/// Сколько оверлеев останавливает одна часть скрипта.
const _q07QuiescePart = 8;

List<List<T>> _parts<T>(List<T> items, int size) => [
  for (var i = 0; i < items.length; i += size)
    items.sublist(i, i + size > items.length ? items.length : i + size),
];

/// Включение 36 оверлеев (Enable_Final_Overlays.bat): выключить устаревшие, затем для каждого
/// пользователя выключить и включить оверлей; если оверлей у пользователя не зарегистрирован,
/// а целевое приложение есть, сначала `install-existing`. Ошибка, если оверлей не включился
/// ни у одного пользователя или не включился там, где должен. Части по [_q07EnablePart]
/// оверлеев: устаревшие выключаются в первой, DLP и лаунчер перезапускаются в последней.
List<String> q07EnableScripts(
  List<Q07Overlay> overlays,
  List<({String overlay, String target})> legacy,
) {
  final parts = _parts(overlays, _q07EnablePart);
  return [
    for (var i = 0; i < parts.length; i++)
      (() {
        final b = StringBuffer(_q07ShellHead);
        if (i == 0) {
          b.writeln(r'for usr in $users; do');
          for (final l in legacy) {
            b.writeln(
              '  cmd overlay disable --user "\$usr" ${l.overlay} >/dev/null 2>&1',
            );
          }
          b.writeln('done');
        }
        b.write(_q07EnableFunction);
        for (final o in parts[i]) {
          b.writeln('en ${o.overlayPackage} ${o.targetPackage}');
        }
        if (i == parts.length - 1) b.write(_q07RestartLauncher);
        b.write(_q07EnableResult);
        return b.toString();
      })(),
  ];
}

/// Временная подготовка (prepare_vecentek батника). Прежние значения сохраняются в файл;
/// если файл остался после прерванной установки, исходные значения не перезаписываются.
const _q07PrepareBody = r'''
f=/data/local/tmp/nox_q07_state
if [ ! -f "$f" ]; then
  {
    echo "vm=$(getprop vecentek.model)"
    echo "dd=$(getprop debug.ro.debuggable)"
    echo "av=$(settings get global verifier_verify_adb_installs)"
    echo "pv=$(settings get global package_verifier_enable)"
    echo "nm=$(settings --user "$u" get secure install_non_market_apps)"
    echo "u=$u"
  } > "$f" || { echo "Error: state not saved"; exit 1; }
fi
setprop vecentek.model 1 && setprop debug.ro.debuggable 1 \
  && settings put global verifier_verify_adb_installs 0 \
  && settings put global package_verifier_enable 0 \
  && settings --user "$u" put secure install_non_market_apps 1 \
  || { echo "Error: prepare failed"; exit 1; }
echo "prepared"
''';

/// Возврат настроек (restore_vecentek батника).
const q07RestoreScript = r'''
f=/data/local/tmp/nox_q07_state
[ -f "$f" ] || { echo "nothing to restore"; exit 0; }
g() { sed -n "s/^$1=//p" "$f" | head -n 1; }
vm=$(g vm); dd=$(g dd); av=$(g av); pv=$(g pv); nm=$(g nm); u=$(g u)
setprop vecentek.model "$vm"
setprop debug.ro.debuggable "$dd"
rs() { if [ -z "$2" ] || [ "$2" = null ]; then settings delete global "$1"; else settings put global "$1" "$2"; fi; }
rs verifier_verify_adb_installs "$av"
rs package_verifier_enable "$pv"
if [ -z "$nm" ] || [ "$nm" = null ]; then settings --user "$u" delete secure install_non_market_apps
else settings --user "$u" put secure install_non_market_apps "$nm"; fi
rm -f "$f"
echo "restored"
''';

/// Остановка уже включённых финальных оверлеев перед обновлением (quiesce батника),
/// части по [_q07QuiescePart] оверлеев.
List<String> q07QuiesceScripts(List<Q07Overlay> overlays) => [
  for (final part in _parts(overlays, _q07QuiescePart)) _q07Quiesce(part),
];

String _q07Quiesce(List<Q07Overlay> overlays) {
  final b = StringBuffer(_q07ShellHead)..writeln('bad=0');
  for (final o in overlays) {
    final p = o.overlayPackage, t = o.targetPackage;
    b.writeln(
      'for usr in \$users; do if [ "\$(st $p $t \$usr)" = enabled ]; then '
      'cmd overlay disable --user "\$usr" $p >/dev/null 2>&1; '
      '[ "\$(st $p $t \$usr)" = enabled ] && bad=\$((bad+1)); fi; done',
    );
  }
  b.writeln(
    'if [ "\$bad" -ne 0 ]; then echo "Error: \$bad overlays not stopped"; exit 1; fi',
  );
  return b.toString();
}

const _q07Tmp = '/data/local/tmp/nox_q07_';

/// Скрипт Q07 кладётся на ГУ файлом и выполняется через `adb shell`: так программа получает
/// вывод и код выхода. run_script идёт через `adb exec-in`, который их не возвращает,
/// и проваленное включение перевода выглядело бы успехом.
List<Map<String, dynamic>> _q07Run(String title, String key) {
  final path = '$_q07Tmp$key';
  const log = '${_q07Tmp}log';
  return [
    _push(title, key, path, hidden: true),
    _shell(
      title,
      'sh $path > $log 2>&1; rc=\$?; '
      'if [ \$rc -eq 0 ]; then cat $log; else cat $log >&2; fi; '
      'rm -f $path $log; exit \$rc',
    ),
  ];
}

/// Файлы и шаги для скриптов, разбитых на части: «Название (1 из 9)».
({List<PlanFile> files, List<Map<String, dynamic>> steps}) _q07Parts(
  String title,
  String name,
  List<String> scripts,
) {
  final files = <PlanFile>[];
  final steps = <Map<String, dynamic>>[];
  for (var i = 0; i < scripts.length; i++) {
    final key = '$name${i + 1}.sh';
    files.add(PlanFile(key: key, bytes: utf8.encode(scripts[i]), kind: 'sh'));
    steps.addAll(
      _q07Run(
        scripts.length == 1 ? title : '$title (${i + 1} из ${scripts.length})',
        key,
      ),
    );
  }
  return (files: files, steps: steps);
}

const _dlpRoot = '/resources/custormer/ivi/Lamb';
const _dlpFiles = [
  'lamb_json.json',
  'cast_video_kara_json.json',
  'guide_json.json',
];

/// Q07, кнопка 1 «Подготовка русификации» = пункт 1 FunkyDev Q07 Language Tool
/// (Install_Final_Overlays.bat): временная подготовка системы, остановка прежних оверлеев,
/// установка 36 APK (SHA-256 сверяется по overlays.csv), тексты DLP (az, ru), включение
/// оверлеев для пользователей 0 и текущего, возврат настроек. config.example.json не используется.
RecipePlan planQ07Prepare(Archive zip) {
  final t = q07Tables(zip);
  final files = <PlanFile>[];
  for (final o in t.overlays) {
    final bytes = requireFile(zip, 'apks/${o.apk}');
    if (crypto.sha256.convert(bytes).toString() != o.sha256) {
      throw RecipeException('Контрольная сумма не совпала: ${o.apk}');
    }
    files.add(PlanFile(key: 'apks/${o.apk}', bytes: bytes, kind: 'apk'));
  }
  for (final lang in ['az', 'ru']) {
    for (final name in _dlpFiles) {
      files.add(
        PlanFile(
          key: 'dlp/$lang/$name',
          bytes: requireFile(zip, 'dlp_dynamic/$lang/$name'),
          kind: 'bin',
        ),
      );
    }
  }
  final quiesce = _q07Parts(
    'Остановка прежнего перевода',
    'quiesce',
    q07QuiesceScripts(t.overlays),
  );
  final enable = _q07Parts(
    'Включение перевода',
    'enable',
    q07EnableScripts(t.overlays, t.legacy),
  );
  files.addAll([
    PlanFile(
      key: 'prepare.sh',
      bytes: utf8.encode(_q07ShellHead + _q07PrepareBody),
      kind: 'sh',
    ),
    ...quiesce.files,
    ...enable.files,
    PlanFile(
      key: 'restore.sh',
      bytes: utf8.encode(q07RestoreScript),
      kind: 'sh',
    ),
  ]);
  return RecipePlan(
    files: files,
    steps: (ids) => _resolve([
      ..._q07Run('Подготовка системы', 'prepare.sh'),
      ...quiesce.steps,
      for (final o in t.overlays)
        {
          'type': 'install_apk',
          'title': 'Установка перевода: ${o.label}',
          'payload_key': 'apks/${o.apk}',
        },
      _shell(
        'Тексты DLP',
        'test -f $_dlpRoot/skin_nor/lamb_json.json && mkdir -p $_dlpRoot/skin_az $_dlpRoot/skin_ru',
        hidden: true,
      ),
      for (final lang in ['az', 'ru'])
        for (final name in _dlpFiles)
          _push(
            'Тексты DLP',
            'dlp/$lang/$name',
            '$_dlpRoot/skin_$lang/$name',
            hidden: true,
          ),
      _shell(
        'Тексты DLP',
        'chmod 644 $_dlpRoot/skin_az/*.json $_dlpRoot/skin_ru/*.json',
        hidden: true,
      ),
      ...enable.steps,
      ..._q07Run('Возврат настроек системы', 'restore.sh'),
    ], ids),
  );
}

/// Q07, кнопка 2 «Русификация» = пункт 2 (Enable_Final_Overlays.bat): выключить устаревшие
/// оверлеи, включить 36 финальных для пользователей 0 и текущего, перезапустить DLP и лаунчер;
/// затем одна перезагрузка (по инструкции архива, чтобы обновился кэш текстов).
RecipePlan planQ07Russify(Archive zip) {
  final t = q07Tables(zip);
  final enable = _q07Parts(
    'Включение перевода',
    'enable',
    q07EnableScripts(t.overlays, t.legacy),
  );
  return RecipePlan(
    files: enable.files,
    steps: (ids) => _resolve([
      ...enable.steps,
      {'type': 'reboot', 'title': 'Перезагрузка автомобиля'},
    ], ids),
  );
}

/// [2] Голосовое управление. Повторяет ветку :voice батника: файлы кладутся в /data/local/tmp,
/// SpeechHMI устанавливается, затем всё переносится в /resources/appdata/tinnove/, временные файлы удаляются.
///
/// [packed]: папка IflytekSpeech (сотни файлов) уходит одним .tar и распаковывается сразу
/// в /resources/appdata/tinnove/ — одна передача вместо сотен и без копирования на ГУ.
/// [themes] = false: без тем (на Q05 папок тем нет, 676 МБ передавались бы зря).
RecipePlan planVoice(
  Archive zip, {
  required String prep,
  bool packed = false,
  bool themes = true,
}) {
  if (packed) return _planVoicePacked(zip, prep: prep, themes: themes);
  return _planVoiceFiles(zip, prep: prep, themes: themes);
}

/// Имя архива ресурсов голоса на ГУ.
const voiceResourcesTar = 'IflytekSpeech.tar';

RecipePlan _planVoicePacked(
  Archive zip, {
  required String prep,
  required bool themes,
}) {
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
  final tar = Archive();
  for (final f in iflytek) {
    tar.addFile(
      ArchiveFile.noCompress('IflytekSpeech/${f.rel}', f.bytes.length, f.bytes)
        ..mode = 0x1b6, // rw-rw-rw-, как после cp -r из батника
    );
  }
  final themeFiles = !themes
      ? <String, List<int>>{}
      : {
          'WT_ThemeResourcesDay.apk': requireFile(
            zip,
            'WT_ThemeResourcesDay/WT_ThemeResourcesDay.apk',
          ),
          'WT_ThemeResourcesNight.apk': requireFile(
            zip,
            'WT_ThemeResourcesNight/WT_ThemeResourcesNight.apk',
          ),
        };
  final pre = _lines([prep.trim(), 'setprop vecentek.model 1']);

  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      for (final e in base.entries)
        PlanFile(key: e.key, bytes: e.value, kind: 'apk'),
      PlanFile(key: voiceResourcesTar, bytes: TarEncoder().encode(tar), kind: 'bin'),
      for (final e in themeFiles.entries)
        PlanFile(key: e.key, bytes: e.value, kind: 'apk'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      for (var i = 0; i < base.length; i++)
        _push(
          'Загрузка основы',
          base.keys.elementAt(i),
          '$tmp/${base.keys.elementAt(i)}',
          hidden: i > 0,
        ),
      _push('Загрузка ресурсов', voiceResourcesTar, '$tmp/$voiceResourcesTar'),
      for (final k in themeFiles.keys)
        _push('Загрузка ресурсов', k, '$tmp/$k', hidden: true),
      _shell('Установка компонентов', 'pm install -g -r $tmp/SpeechHMI.apk'),
      _shell(
        'Перемещение файлов',
        'tar -xf $tmp/$voiceResourcesTar -C $dest/',
      ),
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
      for (final k in themeFiles.keys)
        _shell(
          'Перемещение файлов',
          'mv $tmp/$k $dest/${k.replaceAll('.apk', '')}/',
          hidden: true,
          ignoreErrors: true,
        ),
      _shell(
        'Очистка временных файлов',
        'rm -f $tmp/$voiceResourcesTar',
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

RecipePlan _planVoiceFiles(
  Archive zip, {
  required String prep,
  bool themes = true,
}) {
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
  final themeFiles = !themes
      ? <String, List<int>>{}
      : {
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
      for (final e in themeFiles.entries)
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
      for (final k in themeFiles.keys)
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
      // На части прошивок Q05 (SWC.5328) папок тем нет и mv падает «Is a directory».
      // Батник этого не замечает и идёт дальше, поэтому и здесь ошибка не останавливает услугу.
      for (final k in themeFiles.keys)
        _shell(
          'Перемещение файлов',
          'mv $tmp/$k $dest/${k.replaceAll('.apk', '')}/',
          hidden: true,
          ignoreErrors: true,
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

/// Один APK с выдачей разрешений (Q07: звук мотора, СГУ). Перед установкой проверка
/// Vecentek как у остальных услуг (`setprop vecentek.model 1`, сбрасывается перезагрузкой).
RecipePlan planSingleApk(List<int> apk, {required String title}) {
  if (apk.length < 4 || apk[0] != 0x50 || apk[1] != 0x4B) {
    throw RecipeException('Файл не похож на APK');
  }
  return RecipePlan(
    files: [PlanFile(key: 'app.apk', bytes: apk, kind: 'apk')],
    steps: (ids) => _resolve([
      _shell('Подготовка системы', 'setprop vecentek.model 1', hidden: true),
      {
        'type': 'install_apk',
        'title': title,
        'payload_key': 'app.apk',
        'grant': true,
      },
    ], ids),
  );
}

/// Компонент голосового помощника MMVoice (скрытый системный адаптер).
const mmVoiceInteraction =
    'com.android.mmvoice.assistantbridge/com.mmservice.voice.assistantbridge.MmVoiceInteractionService';

/// Служба MMVoice, которая ловит кнопку голоса на руле.
const mmVoiceKeyAccessibility =
    'com.mmservice.voice/com.q07.offlineassistant.Cs55VoiceKeyAccessibilityService';

/// [2б] Кастомный голос MMVoice. Повторяет 1.INSTALL_MMVOICE.bat из архива MMVOICE_2026:
/// адаптер, основное приложение, выбор помощника по умолчанию, служба кнопки на руле.
/// Штатные приложения не удаляются и не меняются.
RecipePlan planCustomVoice(Archive zip, {required String prep}) {
  final adapter = requireFile(zip, 'MMVoice-SystemAdapter.apk');
  final main = requireFile(zip, 'MMVoice.apk');
  final pre = _lines([prep.trim(), 'setprop vecentek.model 1']);
  // Служба добавляется к уже включённым, а не заменяет их (как в батнике).
  const access =
      'cur=\$(settings get secure enabled_accessibility_services); '
      'case "\$cur" in *$mmVoiceKeyAccessibility*) ;; '
      'null|"") settings put secure enabled_accessibility_services $mmVoiceKeyAccessibility ;; '
      '*) settings put secure enabled_accessibility_services "\$cur:$mmVoiceKeyAccessibility" ;; esac; '
      'settings put secure accessibility_enabled 1';
  return RecipePlan(
    files: [
      PlanFile(key: 'pre.sh', bytes: _text(pre), kind: 'sh'),
      PlanFile(key: 'MMVoice-SystemAdapter.apk', bytes: adapter, kind: 'apk'),
      PlanFile(key: 'MMVoice.apk', bytes: main, kind: 'apk'),
    ],
    steps: (ids) => _resolve([
      {
        'type': 'run_script',
        'title': 'Подготовка системы',
        'payload_key': 'pre.sh',
      },
      _installStep('MMVoice-SystemAdapter.apk', 'MMVoice-SystemAdapter.apk'),
      _installStep('MMVoice.apk', 'MMVoice.apk', grant: true),
      _shell(
        'Выбор голосового помощника',
        'settings put secure voice_interaction_service $mmVoiceInteraction && '
            'settings put secure assistant $mmVoiceInteraction',
      ),
      _shell('Кнопка голоса на руле', access),
    ], ids),
  );
}
