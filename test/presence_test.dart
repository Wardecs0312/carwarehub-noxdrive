import 'package:carwarehub_noxdrive/features/admin/admin_screen.dart';
import 'package:carwarehub_noxdrive/features/admin_web/admin_web_app.dart';
import 'package:carwarehub_noxdrive/features/presence/presence_models.dart';
import 'package:carwarehub_noxdrive/features/presence/presence_service.dart';
import 'package:carwarehub_noxdrive/features/stream/stream_service.dart';
import 'package:carwarehub_noxdrive/features/stream/stream_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Presence _p(DateTime lastSeen, {String activity = 'online'}) => Presence(
  masterId: 'm1',
  lastSeen: lastSeen,
  activity: activity,
  country: 'Кыргызстан',
  city: 'Бишкек',
);

void main() {
  final now = DateTime(2026, 10, 16, 12);

  test('в сети, если отмечался меньше 2 минут назад', () {
    expect(_p(now.subtract(const Duration(seconds: 70))).isOnline(now), isTrue);
    expect(_p(now.subtract(const Duration(minutes: 3))).isOnline(now), isFalse);
  });

  test('надписи присутствия', () {
    expect(presenceText(null, now), 'ещё не заходил в новую версию');
    expect(presenceText(_p(now), now), 'в сети');
    expect(
      presenceText(_p(now, activity: 'job'), now),
      'в сети · работает с машиной',
    );
    expect(
      presenceText(_p(now, activity: 'stream'), now),
      'в сети · идёт трансляция',
    );
    expect(
      presenceText(_p(now.subtract(const Duration(minutes: 5))), now),
      'был 5 мин назад',
    );
    expect(
      presenceText(_p(now.subtract(const Duration(hours: 3))), now),
      'был 3 ч назад',
    );
    expect(
      presenceText(_p(now.subtract(const Duration(days: 2))), now),
      'был 2 дн назад',
    );
    expect(_p(now).place, 'Кыргызстан, Бишкек');
    expect(placeText(null, ''), isNull);
  });

  test('занятие мастера: трансляция важнее услуги', () {
    expect(presenceActivity(jobRunning: false, streaming: false), 'online');
    expect(presenceActivity(jobRunning: true, streaming: false), 'job');
    expect(presenceActivity(jobRunning: true, streaming: true), 'stream');
  });

  test('логин сайта: Telegram ID превращается в служебную почту', () {
    expect(adminLoginEmail(' 8106761823 '), 'tg-8106761823@telegram.nox.drive');
    expect(adminLoginEmail('WardecsFly@Gmail.com'), 'wardecsfly@gmail.com');
    expect(siteLoginFor('tg-8106761823@telegram.nox.drive'), '8106761823');
    expect(siteLoginFor('wardecsfly@gmail.com'), 'wardecsfly@gmail.com');
    expect(isTelegramNick('@Wiqqq99'), isTrue);
    expect(isTelegramNick('Wiqqq99'), isTrue);
    expect(isTelegramNick('8106761823'), isFalse);
    expect(isTelegramNick('wardecsfly@gmail.com'), isFalse);
  });

  test('пароль сайта админки: не короче 12 символов, буквы и цифры', () {
    expect(sitePasswordProblem('abc123'), isNotNull);
    expect(sitePasswordProblem('abcdefghijklm'), isNotNull);
    expect(sitePasswordProblem('123456789012'), isNotNull);
    expect(sitePasswordProblem('nox2026drive'), isNull);
    expect(sitePasswordProblem('пароль2026дом'), isNull);
  });

  testWidgets('вход на сайт: пустые поля — понятная ошибка', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AdminLoginScreen()));
    await tester.tap(find.byKey(const Key('admin-submit')));
    await tester.pump();
    expect(find.text('Введите логин и пароль'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'трансляция: телефон горизонтально — на весь экран, первым экран ГУ',
    () {
      expect(isLandscapePhone(const Size(812, 375)), isTrue);
      expect(isLandscapePhone(const Size(375, 812)), isFalse);
      expect(isLandscapePhone(const Size(1920, 1080)), isFalse);
      expect(preferredSource(['camera', 'screen-hu']), 'screen-hu');
      expect(preferredSource(['camera']), 'camera');
    },
  );

  test('трансляция: стандартные настройки качества, сначала камера', () {
    expect(publishOptionsFor('screen-hu').name, 'screen-hu');
    expect(publishOptionsFor('screen-laptop').simulcast, isTrue);
    expect(publishOrder(['screen-hu', 'screen-laptop', 'camera']), [
      'camera',
      'screen-laptop',
      'screen-hu',
    ]);
  });

  test('ноутбук и ГУ показываются рядом, когда есть оба экрана', () {
    expect(canSplit(['screen-laptop', 'screen-hu', 'camera']), isTrue);
    expect(canSplit(['screen-laptop', 'camera']), isFalse);
    expect(canSplit(['screen-hu']), isFalse);
  });
}
