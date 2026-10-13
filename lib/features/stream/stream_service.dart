import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../adb/hu_mirror.dart';
import '../../core/json.dart';

/// Доступ к комнате LiveKit, выданный Edge Function `stream-token`.
class StreamAccess {
  const StreamAccess({required this.url, required this.token});
  final String url;
  final String token;
}

class StreamException implements Exception {
  StreamException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _errors = {
  'STREAMING_NOT_CONFIGURED':
      'Сервер трансляций ещё не подключён (нужны ключи LiveKit в Supabase)',
  'NO_STREAM_REQUEST': 'Нет активного запроса трансляции',
  'UNAUTHORIZED': 'Войдите заново',
};

/// Токен для мастера (без [masterId]) или для админа (комната мастера [masterId]).
Future<StreamAccess> fetchStreamAccess({String? masterId}) async {
  try {
    final r = await Supabase.instance.client.functions.invoke(
      'stream-token',
      body: {'master_id': ?masterId},
    );
    final data = asMap(r.data);
    final url = strOrNull(data['url']);
    final token = strOrNull(data['token']);
    if (url == null || token == null) {
      throw StreamException('Сервер трансляций вернул неполный ответ');
    }
    return StreamAccess(url: url, token: token);
  } on FunctionException catch (e) {
    final code = str(asMap(e.details)['error']);
    throw StreamException(
      _errors[code] ??
          (e.status == 404
              ? 'Сервер трансляций ещё не подключён: функция stream-token не опубликована'
              : 'Ошибка сервера трансляций: ${code.isEmpty ? e.status : code}'),
    );
  }
}

/// Какие источники может отдать это устройство.
/// Экран ГУ (`screen-hu`) идёт отдельным путём через ADB (этап 3), здесь не публикуется.
bool canPublishSource(String source) => switch (source) {
  'screen-laptop' => _windows,
  'screen-hu' => _windows && HuMirror.available,
  'camera' => true,
  _ => false,
};

bool get _windows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Публикация трансляции мастером. Одна комната на мастера: `master-<uuid>`.
class StreamPublisher {
  Room? _room;
  HuMirror? _mirror;
  String? sessionId;

  /// Серийный номер подключённого ГУ (для источника `screen-hu`), задаётся перед [start].
  String? huSerial;

  bool get isActive => _room != null;

  /// Подключается и публикует доступные источники. Возвращает список опубликованных.
  Future<List<String>> start(String sessionId, List<String> sources) async {
    await stop();
    final access = await fetchStreamAccess();
    final room = Room(
      roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
    );
    await room.connect(access.url, access.token);
    _room = room;
    this.sessionId = sessionId;

    final published = <String>[];
    for (final s in sources.where(canPublishSource)) {
      try {
        final track = await _createTrack(s);
        await room.localParticipant!.publishVideoTrack(
          track,
          publishOptions: VideoPublishOptions(name: s),
        );
        published.add(s);
      } catch (e) {
        // Нет веб-камеры и т.п.: остальные источники продолжают работать.
        debugPrint('stream source $s failed: $e');
      }
    }
    if (published.isEmpty) {
      await stop();
      throw StreamException('На этом устройстве нет доступных источников');
    }
    await Supabase.instance.client.rpc(
      'master_stream_status',
      params: {'p_id': sessionId, 'p_status': 'live'},
    );
    return published;
  }

  Future<LocalVideoTrack> _createTrack(String source) async {
    if (source == 'screen-hu') return _createHuTrack();
    if (source == 'screen-laptop') {
      // Главный экран Windows без диалога выбора: мастер видит плашку трансляции.
      final screens = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen],
      );
      if (screens.isEmpty) throw StreamException('Экран не найден');
      return LocalVideoTrack.createScreenShareTrack(
        ScreenShareCaptureOptions(
          sourceId: screens.first.id,
          maxFrameRate: 10,
          params: VideoParametersPresets.screenShareH720FPS15,
        ),
      );
    }
    return LocalVideoTrack.createCameraTrack(
      const CameraCaptureOptions(
        cameraPosition: CameraPosition.back,
        params: VideoParametersPresets.h540_169,
      ),
    );
  }

  /// Экран ГУ: окно scrcpy на ноутбуке захватывается как отдельный источник.
  Future<LocalVideoTrack> _createHuTrack() async {
    final serial = huSerial;
    if (serial == null) throw StreamException('ГУ не подключено по ADB');
    _mirror = await HuMirror.start(serial);
    // Окно появляется не сразу: ждём его в списке окон до 10 секунд.
    for (var i = 0; i < 20; i++) {
      final windows = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Window],
      );
      final w = windows
          .where((s) => s.name == HuMirror.windowTitle)
          .firstOrNull;
      if (w != null) {
        return LocalVideoTrack.createScreenShareTrack(
          ScreenShareCaptureOptions(
            sourceId: w.id,
            maxFrameRate: 15,
            params: VideoParametersPresets.screenShareH720FPS15,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StreamException('Окно экрана ГУ не появилось');
  }

  Future<void> stop() async {
    _mirror?.stop();
    _mirror = null;
    final room = _room;
    _room = null;
    sessionId = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
  }
}
