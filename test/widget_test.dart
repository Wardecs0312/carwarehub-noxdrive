import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:carwarehub_noxdrive/main.dart';

void main() {
  testWidgets('показывает модели и услуги выбранной модели', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: NoxDriveApp()));
    await tester.pumpAndSettle();

    expect(find.text('Changan Q05'), findsOneWidget);
    await tester.tap(find.text('Changan Q05'));
    await tester.pumpAndSettle();
    expect(find.text('Русификация и установка приложений'), findsOneWidget);
  });
}
