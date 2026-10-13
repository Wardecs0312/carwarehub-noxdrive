import 'dart:async';

import 'package:flutter/material.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// «с 14:32 · 05:12»: время начала трансляции (местное) и сколько она уже идёт.
String streamClockText(DateTime startedAt, DateTime now) {
  final start = startedAt.toLocal();
  var d = now.difference(startedAt);
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final dur = h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
  return 'с ${_two(start.hour)}:${_two(start.minute)} · $dur';
}

/// Таймер трансляции, обновляется раз в секунду.
class StreamClock extends StatefulWidget {
  const StreamClock({super.key, required this.startedAt, this.style});
  final DateTime startedAt;
  final TextStyle? style;

  @override
  State<StreamClock> createState() => _StreamClockState();
}

class _StreamClockState extends State<StreamClock> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    streamClockText(widget.startedAt, DateTime.now()),
    key: const Key('stream-clock'),
    style: (widget.style ?? const TextStyle()).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}
