import 'package:carwarehub_noxdrive/features/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('на экране входа видна версия программы', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'nox.drive',
      packageName: 'nox',
      version: '2.0.18',
      buildNumber: '18',
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pumpAndSettle();
    expect(find.text('версия 2.0.18'), findsOneWidget);
  });
}
