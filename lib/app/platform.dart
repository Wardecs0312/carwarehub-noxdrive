import 'package:flutter/foundation.dart';

/// Можно ли на этой платформе работать с автомобилем по ADB.
/// В браузере (PWA) доступен только кабинет мастера.
/// Android добавится вместе с ADB через OTG.
bool get canUseAdb =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
