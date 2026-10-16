import 'dart:io';

/// Имя компьютера мастера (видно админу в истории входов).
Future<String> deviceName() async => Platform.localHostname;
