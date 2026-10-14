import 'package:carwarehub_noxdrive/core/vin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('русские буквы-двойники заменяются латинскими', () {
    // «С» и «Н» здесь русские.
    expect(latinizeVin('LS5A3АВС1НА000000'), 'LS5A3ABC1HA000000');
    expect(isValidVin(latinizeVin('LS5A3АВС1НА000000')), isTrue);
  });

  test('латиница и цифры не меняются', () {
    expect(latinizeVin('LS5A3ABC1NA000123'), 'LS5A3ABC1NA000123');
  });

  test('прочая кириллица остаётся и отсеивается фильтром ввода', () {
    expect(latinizeVin('Ж'), 'Ж');
    expect(isValidVin('ЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖ'), isFalse);
  });
}
