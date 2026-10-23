import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adb/adb_executor.dart';
import '../../adb/adb_status.dart';
import '../../adb/adb_status_checker.dart';
import '../../adb/wifi_adb.dart';
import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../jobs/job_controller.dart';

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
    // Машины нет: по клику можно подключиться к ней по Wi-Fi (после «Открыть ADB по Wi-Fi»).
    final canWifi =
        canUseAdb && status.connection == AdbConnection.disconnected;
    final badge = Container(
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
          Text(label, style: const TextStyle(fontSize: 13, letterSpacing: 0.3)),
          if (canWifi) ...[
            const SizedBox(width: 8),
            const Icon(Icons.wifi, size: 16, color: NoxColors.metalMid),
          ],
        ],
      ),
    );
    return Tooltip(
      message: canWifi
          ? 'Нажмите, чтобы подключиться к машине по Wi-Fi'
          : status.blockedHint ?? 'Автомобиль готов к работе',
      child: canWifi
          ? InkWell(
              key: const Key('adb-wifi-open'),
              borderRadius: BorderRadius.circular(999),
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => const WifiConnectDialog(),
              ),
              child: badge,
            )
          : badge,
    );
  }
}

/// «Подключить по Wi-Fi»: `adb connect <IP машины>:5555`. Работает, пока на машине открыт
/// ADB по Wi-Fi (кнопка «Открыть ADB по Wi-Fi») и она не перезагружалась.
class WifiConnectDialog extends ConsumerStatefulWidget {
  const WifiConnectDialog({super.key});

  @override
  ConsumerState<WifiConnectDialog> createState() => _WifiConnectDialogState();
}

class _WifiConnectDialogState extends ConsumerState<WifiConnectDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final last = ref.read(lastWifiAddressProvider);
    if (last != null) {
      _ctrl.text = last;
    } else {
      loadWifiAddress().then((a) {
        if (a != null && mounted && _ctrl.text.isEmpty) _ctrl.text = a;
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final address = normalizeWifiAddress(_ctrl.text);
    if (address == null) {
      setState(() => _error = 'Введите IP машины, например 172.20.10.3');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(adbExecutorProvider).connect(address);
      ref.read(lastWifiAddressProvider.notifier).state = address;
      await saveWifiAddress(address);
      if (mounted) Navigator.pop(context);
    } on AdbException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Не подключилось: $e\nКомпьютер должен быть в той же сети Wi-Fi, '
              'что и машина, а ADB по Wi-Fi на машине открыт после последней перезагрузки.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Подключить по Wi-Fi'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'IP машины показывает кнопка «Открыть ADB по Wi-Fi» в журнале услуги.',
            style: TextStyle(color: NoxColors.metalMid),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('adb-wifi-address'),
            controller: _ctrl,
            autofocus: true,
            enabled: !_busy,
            decoration: const InputDecoration(hintText: '172.20.10.3'),
            onSubmitted: (_) => _connect(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: NoxColors.bad)),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        key: const Key('adb-wifi-connect'),
        onPressed: _busy ? null : _connect,
        child: Text(_busy ? 'Подключение...' : 'Подключить'),
      ),
    ],
  );
}
