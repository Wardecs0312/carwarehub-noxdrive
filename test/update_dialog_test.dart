import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/features/update/update_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppRelease _release({bool mandatory = false}) => AppRelease.fromJson({
  'version': '2.1.0',
  'build_number': 3,
  'is_mandatory': mandatory,
  'download_path': 'windows/2.1.0+3.zip',
  'release_notes': 'Исправления',
  'sha256': 'ABC',
  'size_bytes': 33 * 1024 * 1024,
});

Future<void> _pump(WidgetTester tester, AppRelease r) => tester.pumpWidget(
  MaterialApp(home: Scaffold(body: UpdateDialog(release: r))),
);

void main() {
  test('релиз: контрольная сумма в нижнем регистре, размер', () {
    final r = _release();
    expect(r.sha256, 'abc');
    expect(r.sizeBytes, 33 * 1024 * 1024);
  });

  testWidgets('предложение: версия, что нового, «Позже» и «Обновить»', (
    tester,
  ) async {
    await _pump(tester, _release());
    expect(find.text('Новая версия 2.1.0'), findsOneWidget);
    expect(find.text('Исправления'), findsOneWidget);
    expect(find.textContaining('33 МБ'), findsOneWidget);
    expect(find.text('Позже'), findsOneWidget);
    expect(find.text('Обновить'), findsOneWidget);
  });

  testWidgets('обязательное обновление нельзя отложить', (tester) async {
    await _pump(tester, _release(mandatory: true));
    expect(find.text('Позже'), findsNothing);
    expect(find.text('Обновить'), findsOneWidget);
  });
}
