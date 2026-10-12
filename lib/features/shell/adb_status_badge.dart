import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adb/adb_status.dart';
import '../../adb/adb_status_checker.dart';

/// Индикатор в верхней панели: 🔴 Не подключено / 🟢 Подключено.
class AdbStatusBadge extends ConsumerWidget {
  const AdbStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(adbStatusProvider).value ??
        const AdbStatus(AdbConnection.disconnected);
    final ready = status.isReady;
    final label = ready
        ? 'Подключено${status.model != null ? ' · ${status.model}' : ''}'
        : (status.connection == AdbConnection.unauthorized
              ? 'Ожидает разрешения'
              : 'Не подключено');
    return Tooltip(
      message: status.blockedHint ?? 'Автомобиль готов к работе',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: const Key('adb-dot'),
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ready ? const Color(0xFF2EE66B) : const Color(0xFFE5484D),
            ),
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}
