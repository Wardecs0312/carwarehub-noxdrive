import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adb/adb_status.dart';
import '../../adb/adb_status_checker.dart';
import '../../app/theme.dart';

/// Индикатор в шапке: 🔴 ADB: Не подключено / 🟢 ADB: Подключено (Устройство активно).
class AdbStatusBadge extends ConsumerWidget {
  const AdbStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(adbStatusProvider).value ??
        const AdbStatus(AdbConnection.disconnected);
    final ready = status.isReady;
    final label = switch (status.connection) {
      AdbConnection.connected => 'ADB: Подключено (Устройство активно)',
      AdbConnection.unauthorized => 'ADB: Ожидает разрешения на ГУ',
      AdbConnection.adbMissing => 'ADB: Компонент не найден',
      AdbConnection.disconnected => 'ADB: Не подключено',
      AdbConnection.unsupported => 'Кабинет мастера',
    };
    final color = ready
        ? NoxColors.ok
        : status.connection == AdbConnection.unsupported
        ? NoxColors.metalMid
        : NoxColors.bad;
    return Tooltip(
      message: status.blockedHint ?? 'Автомобиль готов к работе',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: NoxColors.panelHi,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const Key('adb-dot'),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 8),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 13, letterSpacing: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}
