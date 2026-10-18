import 'dart:async';
import 'dart:io';

/// Ход скачивания: получено байт и сколько всего (если сервер сообщил размер).
typedef DownloadProgress = void Function(int got, int? total);

/// Скачивает файл сценария по пути в хранилище и пишет его в [target].
typedef PayloadDownloader = Future<void> Function(
  String storagePath,
  File target,
  DownloadProgress progress,
);

/// Локальный кэш файлов сценариев. Файлы лежат на диске в том виде, в каком пришли
/// с сервера, то есть ЗАШИФРОВАННЫМИ: без ключа из задания их не прочитать.
///
/// Зачем: раньше каждый файл каждый раз скачивался заново, по одному, с новым соединением.
/// Голосовое управление (почти 400 файлов) шло 30+ минут. Теперь повторная услуга берёт
/// файлы с диска, а новые скачиваются заранее по [concurrency] штуки параллельно.
class PayloadStore {
  PayloadStore(
    this.dir,
    this._download, {
    this.concurrency = 6,
    this.maxBytes = 4 << 30,
  });

  final Directory dir;
  final PayloadDownloader _download;
  final int concurrency;

  /// Предел размера кэша: самые старые файлы удаляются (по умолчанию 4 ГБ).
  final int maxBytes;

  final _inflight = <String, Future<File>>{};
  final _listeners = <String, List<DownloadProgress>>{};
  var _active = 0;
  final _waiters = <Completer<void>>[];

  /// Имя файла в кэше: путь хранилища без «/» и опасных символов.
  File fileFor(String storagePath) => File(
    '${dir.path}${Platform.pathSeparator}'
    '${storagePath.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}',
  );

  /// Файл на диске (из кэша или после скачивания). Повторный вызов ждёт ту же загрузку.
  Future<File> ensure(String storagePath) =>
      _inflight[storagePath] ??= _load(storagePath).whenComplete(() {
        // Без фигурных скобок remove вернул бы этот же Future, и whenComplete ждал бы сам себя.
        _inflight.remove(storagePath);
      });

  /// Есть ли файл уже на диске.
  Future<bool> isCached(String storagePath) async {
    final f = fileFor(storagePath);
    return await f.exists() && await f.length() > 0;
  }

  /// Дождаться файла, показывая ход скачивания. true — файл пришлось скачивать.
  Future<bool> fetch(String storagePath, {DownloadProgress? onProgress}) async {
    if (!_inflight.containsKey(storagePath) && await isCached(storagePath)) {
      return false;
    }
    if (onProgress != null) {
      (_listeners[storagePath] ??= []).add(onProgress);
    }
    try {
      await ensure(storagePath);
    } finally {
      _listeners[storagePath]?.remove(onProgress);
    }
    return true;
  }

  /// Недокачанные файлы прошлых запусков (программу закрыли посреди загрузки).
  Future<void> cleanupPartials() async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.part')) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }

  /// Начать заранее скачивать файлы, которые понадобятся следующими шагам.
  void prefetch(Iterable<String> paths) {
    for (final p in paths) {
      unawaited(ensure(p).then((_) {}, onError: (_) {}));
    }
  }

  /// Файл оказался битым (не прошёл проверку при расшифровке): удалить, чтобы скачать заново.
  Future<void> invalidate(String storagePath) async {
    try {
      await fileFor(storagePath).delete();
    } on FileSystemException {
      // уже удалён
    }
  }

  Stream<List<int>> open(String storagePath) async* {
    final f = await ensure(storagePath);
    yield* f.openRead();
  }

  Future<File> _load(String storagePath) async {
    final f = fileFor(storagePath);
    if (await f.exists() && await f.length() > 0) {
      // отметка «недавно использован» для очистки старых файлов
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
      return f;
    }
    await _slot();
    try {
      await dir.create(recursive: true);
      final tmp = File('${f.path}.part');
      try {
        await _download(storagePath, tmp, (got, total) {
          for (final l in List.of(_listeners[storagePath] ?? const [])) {
            l(got, total);
          }
        });
        await tmp.rename(f.path);
      } catch (_) {
        try {
          await tmp.delete();
        } catch (_) {}
        rethrow;
      }
      return f;
    } finally {
      _release();
    }
  }

  Future<void> _slot() async {
    while (_active >= concurrency) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;
  }

  void _release() {
    _active--;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  /// Удаляет самые давно использованные файлы, пока кэш больше [maxBytes].
  Future<void> trim() async {
    if (!await dir.exists()) return;
    final files = <File, FileStat>{};
    await for (final e in dir.list()) {
      if (e is File && !e.path.endsWith('.part')) files[e] = await e.stat();
    }
    var total = files.values.fold<int>(0, (s, st) => s + st.size);
    final oldest = files.entries.toList()
      ..sort((a, b) => a.value.modified.compareTo(b.value.modified));
    for (final e in oldest) {
      if (total <= maxBytes) break;
      if (_inflight.containsKey(e.key.path)) continue;
      try {
        await e.key.delete();
        total -= e.value.size;
      } catch (_) {}
    }
  }
}
