// Чистая логика сборки пакета услуги из архива: без сети и без диска, поэтому покрыта тестами.
import 'package:archive/archive.dart';

class PayloadFile {
  PayloadFile({required this.name, required this.bytes, required this.kind});
  final String name;
  final List<int> bytes;

  /// 'apk' или 'sh'
  final String kind;
}

/// Все .apk из папки [dir] архива (в батнике это `for %%F in (soft\*.apk)`),
/// в алфавитном порядке без учёта регистра, как их перебирает Windows.
List<PayloadFile> collectApks(Archive archive, {String dir = 'soft'}) {
  final prefix = '${dir.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '')}/';
  final found = <PayloadFile>[];
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final path = f.name.replaceAll('\\', '/');
    // допускаем лишнюю корневую папку внутри архива: nox/soft/app.apk
    final idx = path.toLowerCase().indexOf(prefix.toLowerCase());
    if (idx < 0) continue;
    final rest = path.substring(idx + prefix.length);
    if (rest.contains('/') || !rest.toLowerCase().endsWith('.apk')) continue;
    found.add(
      PayloadFile(name: rest, bytes: f.readBytes() ?? const [], kind: 'apk'),
    );
  }
  found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return found;
}

String apkTitle(String fileName) =>
    'Установка: ${fileName.replaceAll(RegExp(r'\.apk$', caseSensitive: false), '')}';

/// Шаги сценария. [preScriptId] и [apkIds] это id строк таблицы payloads.
/// Приложения ставятся с выдачей разрешений (`-g`), как в `adb install -r -g`.
List<Map<String, dynamic>> buildSteps({
  String? preScriptId,
  required List<({String id, String name})> apks,
  bool reboot = false,
}) => [
  if (preScriptId != null)
    {
      'type': 'run_script',
      'title': 'Подготовка системы',
      'payload_id': preScriptId,
    },
  for (final a in apks)
    {
      'type': 'install_apk',
      'title': apkTitle(a.name),
      'payload_id': a.id,
      'grant': true,
    },
  if (reboot) {'type': 'reboot', 'title': 'Перезагрузка'},
];
