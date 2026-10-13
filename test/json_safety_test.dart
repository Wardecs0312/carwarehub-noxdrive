import 'package:carwarehub_noxdrive/core/json.dart';
import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:carwarehub_noxdrive/features/admin/admin_repository.dart';
import 'package:carwarehub_noxdrive/jobs/job_models.dart';
import 'package:flutter_test/flutter_test.dart';

// Поля с null или пропущенные поля не должны давать
// «type 'Null' is not a subtype of type 'String' in type cast».
void main() {
  test('помощники: null, числа, строки', () {
    expect(str(null), '');
    expect(str(5), '5');
    expect(strOrNull(''), isNull);
    expect(intOr('12'), 12);
    expect(intOr(null, 7), 7);
    expect(boolOr(null), isFalse);
    expect(asMap('ошибка'), isEmpty);
    expect(
      () => requireStr({'a': null}, 'a', 'Тест'),
      throwsA(isA<Exception>()),
    );
  });

  test('каталог и релиз с пустыми полями', () {
    final m = CarModel.fromJson({'id': 1, 'code': null, 'title': null});
    expect(m.title, '');
    final s = ServiceItem.fromJson({'id': 2});
    expect(s.code, '');
    expect(s.priceCredits, 0);
    final r = AppRelease.fromJson({'build_number': null});
    expect(r.version, '');
    expect(r.minSupportedVersion, isNull);
  });

  test('админ-панель: мастер без имени и баланса, возврат без связей', () {
    final m = MasterRow.fromJson({
      'id': 'x',
      'name': null,
      'status': null,
      'master_balance': null,
    });
    expect(m.name, '');
    expect(m.credits, 0);
    final r = RefundRow.fromJson({'id': 'r', 'created_at': null});
    expect(r.masterName, '—');
    expect(r.vin, '');
    final st = StreamSessionRow.fromJson({'id': 's', 'sources': null});
    expect(st.sources, isEmpty);
  });

  test('задание: без job_id понятная ошибка, шаги без полей', () {
    expect(
      () => JobTicket.fromJson({'price': 1}),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'текст',
          contains('job_id'),
        ),
      ),
    );
    final step = JobStep.fromJson({'type': 'shell', 'title': null});
    expect(step.title, '');
    expect(step.cmd, isNull);
  });
}
