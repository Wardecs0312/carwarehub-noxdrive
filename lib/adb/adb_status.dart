enum AdbConnection {
  /// adb.exe не найден или не запускается
  adbMissing,

  /// ГУ не обнаружено
  disconnected,

  /// ГУ видно, но отладка не разрешена на самом устройстве
  unauthorized,

  /// ГУ готово к работе
  connected,

  /// Платформа без доступа к USB (PWA в браузере): доступен только кабинет
  unsupported,
}

class AdbStatus {
  const AdbStatus(this.connection, {this.serial, this.model});

  final AdbConnection connection;
  final String? serial;
  final String? model;

  bool get isReady => connection == AdbConnection.connected;

  /// Подсказка для заблокированных кнопок запуска услуг.
  String? get blockedHint => switch (connection) {
    AdbConnection.connected => null,
    AdbConnection.unauthorized =>
      'Разрешите отладку по USB на экране автомобиля',
    AdbConnection.adbMissing =>
      'Не найден компонент ADB. Переустановите программу',
    AdbConnection.disconnected => 'Подключите автомобиль по USB/ADB',
    AdbConnection.unsupported =>
      'Услуги запускаются в программе для Windows или Android',
  };

  @override
  bool operator ==(Object other) =>
      other is AdbStatus &&
      other.connection == connection &&
      other.serial == serial &&
      other.model == model;

  @override
  int get hashCode => Object.hash(connection, serial, model);
}
