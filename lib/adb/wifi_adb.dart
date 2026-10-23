import 'dart:io';

import 'package:flutter_riverpod/legacy.dart';

/// Команда на ГУ: все IPv4-адреса по одному на строку (`5: wlan0    inet 172.20.10.3/28 ...`).
const wifiIpCommand = 'ip -o -f inet addr show';

/// Порт ADB по Wi-Fi (`adb tcpip 5555`).
const wifiAdbPort = 5555;

/// IP машины в сети Wi-Fi из вывода [wifiIpCommand]. Внутренняя сеть машины (eth*),
/// loopback и мобильная связь пропускаются; wlan* важнее точки доступа (ap*, swlan*).
String? wifiAddressFrom(String output) {
  final found = <(int, String)>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final m = RegExp(r'^\s*\d+:\s+(\S+)\s+inet\s+(\d{1,3}(?:\.\d{1,3}){3})')
        .firstMatch(line);
    if (m == null) continue;
    final name = m.group(1)!;
    final ip = m.group(2)!;
    if (ip.startsWith('127.')) continue;
    final rank = name.startsWith('wlan')
        ? 0
        : name.startsWith('swlan') || name.startsWith('ap')
        ? 1
        : null;
    if (rank != null) found.add((rank, ip));
  }
  if (found.isEmpty) return null;
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return found.first.$2;
}

/// Машина подключена по сети (`172.20.10.3:5555`), а не кабелем.
bool isNetworkSerial(String serial) =>
    RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}:\d+$').hasMatch(serial);

/// Адрес из поля ввода мастера: `172.20.10.3` или `172.20.10.3:5555`. null, если это не IPv4.
String? normalizeWifiAddress(String input) {
  final m = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$')
      .firstMatch(input.trim());
  if (m == null) return null;
  if (m.group(1)!.split('.').any((p) => int.parse(p) > 255)) return null;
  final port = int.tryParse(m.group(2) ?? '') ?? wifiAdbPort;
  if (port < 1 || port > 65535) return null;
  return '${m.group(1)}:$port';
}

/// Удалось ли `adb connect`: adb пишет «connected to …» или «already connected to …»
/// и возвращает 0 даже при неудаче («failed to connect», «cannot connect»).
bool adbConnectSucceeded(String output) =>
    RegExp(
      r'(^|\s)(already )?connected to ',
      multiLine: true,
    ).hasMatch(output) &&
    !RegExp(r'failed|cannot|unable', caseSensitive: false).hasMatch(output);

/// Последний адрес машины по Wi-Fi: подставляется в окно «Подключить по Wi-Fi».
final lastWifiAddressProvider = StateProvider<String?>((ref) => null);

/// Файл с последним адресом: `%APPDATA%\nox.drive\wifi_adb.txt`.
File? _wifiFile() {
  final base = Platform.environment['APPDATA'];
  if (base == null) return null;
  return File(
    '$base${Platform.pathSeparator}nox.drive${Platform.pathSeparator}wifi_adb.txt',
  );
}

Future<String?> loadWifiAddress() async {
  try {
    final f = _wifiFile();
    if (f == null || !await f.exists()) return null;
    return normalizeWifiAddress(await f.readAsString());
  } on FileSystemException {
    return null;
  }
}

Future<void> saveWifiAddress(String address) async {
  // В тестах файл мастера на этом компьютере не трогаем.
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  try {
    final f = _wifiFile();
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(address);
  } on FileSystemException {
    // не сохранилось: мастер введёт адрес сам
  }
}
