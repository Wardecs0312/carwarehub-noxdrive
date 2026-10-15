import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme.dart';
import '../admin/admin_repository.dart';
import 'stream_clock.dart';
import 'stream_service.dart';

/// Просмотр трансляции мастера админом. Работает одинаково в PWA (телефон, ноутбук),
/// в Windows-приложении и в APK на ГУ: сетка из окон по источникам, нажатие разворачивает окно.
class StreamViewerScreen extends StatefulWidget {
  const StreamViewerScreen({
    super.key,
    required this.masterId,
    required this.masterName,
    this.sessionId,
  });

  final String masterId;
  final String masterName;

  /// Строка stream_sessions: для времени начала и кнопки «Завершить трансляцию».
  final String? sessionId;

  @override
  State<StreamViewerScreen> createState() => _StreamViewerScreenState();
}

class _StreamViewerScreenState extends State<StreamViewerScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _events;
  StreamSubscription<List<Map<String, dynamic>>>? _sessionSub;
  DateTime? _startedAt;
  bool _ending = false;
  String? _error;
  String? _expanded;

  /// Источники, которые не запустились у мастера, и причина (stream_sessions.source_errors).
  Map<String, dynamic> _sourceErrors = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
    _watchSession();
  }

  /// Время начала и статус трансляции в реальном времени; если её завершили
  /// (мастер или другой админ), окно просмотра закрывается.
  void _watchSession() {
    final id = widget.sessionId;
    if (id == null) return;
    _sessionSub = Supabase.instance.client
        .from('stream_sessions')
        .stream(primaryKey: ['id'])
        .eq('id', id)
        .listen((rows) {
          if (!mounted || rows.isEmpty) return;
          final r = rows.first;
          if (r['status'] == 'ended') {
            if (!_ending) Navigator.of(context).maybePop();
            return;
          }
          setState(() {
            _startedAt = DateTime.tryParse('${r['started_at']}');
            final errors = r['source_errors'];
            _sourceErrors = errors is Map
                ? Map<String, dynamic>.from(errors)
                : const {};
          });
        });
  }

  Future<void> _end() async {
    final id = widget.sessionId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Завершить трансляцию?'),
        content: Text('Трансляция у ${widget.masterName} остановится сразу.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _ending = true);
    try {
      await AdminRepository().endStream(id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _ending = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось завершить: $e')));
      }
    }
  }

  Future<void> _connect() async {
    try {
      final access = await fetchStreamAccess(masterId: widget.masterId);
      final room = Room(roomOptions: const RoomOptions(adaptiveStream: true));
      _events = room.createListener()
        ..on<RoomEvent>((_) {
          if (mounted) setState(() {});
        });
      await room.connect(access.url, access.token);
      if (!mounted) {
        await room.dispose();
        return;
      }
      setState(() => _room = room);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _events?.dispose();
    final room = _room;
    if (room != null) {
      unawaited(room.disconnect().then((_) => room.dispose()));
    }
    super.dispose();
  }

  /// Дорожки мастера по имени источника (screen-laptop, screen-hu, camera).
  Map<String, VideoTrack> _tracks() {
    final out = <String, VideoTrack>{};
    for (final p in _room?.remoteParticipants.values ?? <RemoteParticipant>[]) {
      for (final pub in p.videoTrackPublications) {
        final t = pub.track;
        if (t != null && pub.subscribed) out[pub.name] = t;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _tracks();
    final shown = _expanded != null && tracks.containsKey(_expanded)
        ? {_expanded!: tracks[_expanded]!}
        : tracks;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Трансляция: ${widget.masterName}'),
            if (_startedAt != null)
              StreamClock(
                startedAt: _startedAt!,
                style: const TextStyle(fontSize: 13, color: NoxColors.bad),
              )
            else if (widget.sessionId != null)
              const Text(
                'ожидание мастера',
                style: TextStyle(fontSize: 13, color: NoxColors.metalMid),
              ),
          ],
        ),
        actions: [
          if (widget.sessionId != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                key: const Key('end-stream'),
                style: FilledButton.styleFrom(backgroundColor: NoxColors.bad),
                onPressed: _ending ? null : _end,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Завершить трансляцию'),
              ),
            ),
        ],
      ),
      bottomNavigationBar: _sourceErrors.isEmpty
          ? null
          : Material(
              color: NoxColors.warn,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Не запустилось у мастера: ${describeStreamErrors(_sourceErrors)}',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
      body: _error != null
          ? _Message(_error!)
          : _room == null
          ? const Center(child: CircularProgressIndicator())
          : tracks.isEmpty
          ? const _Message(
              'Ожидание мастера… Трансляция начнётся, когда приложение мастера получит запрос.',
            )
          : LayoutBuilder(
              builder: (context, c) {
                // Телефон в портрете: окна друг под другом; ноутбук/ГУ: в ряд.
                final columns = shown.length == 1 || c.maxWidth < c.maxHeight
                    ? 1
                    : shown.length.clamp(1, 3);
                return GridView.count(
                  crossAxisCount: columns,
                  childAspectRatio: 16 / 9,
                  padding: const EdgeInsets.all(8),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: [
                    for (final e in shown.entries)
                      GestureDetector(
                        onTap: () => setState(
                          () => _expanded = _expanded == e.key ? null : e.key,
                        ),
                        child: _Tile(
                          label: streamSources[e.key] ?? e.key,
                          track: e.value,
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.track});
  final String label;
  final VideoTrack track;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        VideoTrackRenderer(track, fit: VideoViewFit.contain),
        Positioned(
          left: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: NoxColors.metalMid),
      ),
    ),
  );
}
