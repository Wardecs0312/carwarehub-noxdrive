import 'package:carwarehub_noxdrive/data/auth_repository.dart';
import 'package:carwarehub_noxdrive/features/admin/admin_repository.dart';
import 'package:carwarehub_noxdrive/features/auth/account_status_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ожидание одобрения: статус перепроверяется сам, без кнопки', (
    tester,
  ) async {
    var checks = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          masterStatusProvider.overrideWith((ref) async {
            checks++;
            return 'pending';
          }),
          isAdminProvider.overrideWith((ref) async => false),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            ref.watch(masterStatusProvider);
            return const MaterialApp(
              home: AccountStatusScreen(status: 'pending'),
            );
          },
        ),
      ),
    );
    await tester.pump();
    final before = checks;
    await tester.pump(approvalPollInterval);
    await tester.pump();
    expect(checks, greaterThan(before));
    expect(find.textContaining('программа откроется сама'), findsOneWidget);
  });
}
