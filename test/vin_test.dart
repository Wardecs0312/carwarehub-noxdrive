import 'package:carwarehub_noxdrive/core/vin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('русские буквы-двойники заменяются латинскими', () {
    // «С» и «Н» здесь русские.
    expect(latinizeVin('LS5A3АВС4НА000000'), 'LS5A3ABC4HA000000');
    expect(isValidVin(latinizeVin('LS5A3АВС4НА000000')), isTrue);
  });

  test('латиница и цифры не меняются', () {
    expect(latinizeVin('LS5A3ABC4NA000123'), 'LS5A3ABC4NA000123');
  });

  test('прочая кириллица остаётся и отсеивается фильтром ввода', () {
    expect(latinizeVin('Ж'), 'Ж');
    expect(isValidVin('ЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖЖ'), isFalse);
  });

  test('контрольная цифра: настоящий VIN проходит, опечатка в одном знаке — нет', () {
    expect(isValidVin('LS5A3ABC4NA000123'), isTrue);
    expect(vinCheckDigit('LS5A3ABC4NA000123'), '4');
    // Тот же VIN с неверным 9-м знаком (так в истории попадали выдуманные VIN и опечатки).
    expect(isValidVin('LS5A3ABC1NA000123'), isFalse);
    expect(vinProblem('LS5A3ABC1NA000123'), contains('не сходится контрольная цифра'));
    expect(isValidVin('LS5A3ABC4NA000124'), isFalse);
  });

  test('контрольная цифра X', () {
    expect(vinCheckDigit('LS5A3ABCXNA000000'), 'X');
    expect(isValidVin('LS5A3ABCXNA000000'), isTrue);
  });

  test('подсказка: буквы I, O, Q и неполный VIN', () {
    expect(vinProblem('LS5A3ABC4NA00012O'), 'В VIN нет букв I, O, Q');
    expect(vinProblem('LS5A3ABC4NA'), isNull);
    expect(vinProblem('LS5A3ABC4NA000123'), isNull);
  });

  test('VIN с ГУ: первый настоящий ответ, пустые, null и выдуманные пропускаются', () {
    expect(pickVin(['null', '', '  ', 'LS5A3ABC1NA000123', 'ls5a3abc4na000123 ']),
        'LS5A3ABC4NA000123');
    expect(pickVin(['null', '', '28738BPPBPP3PB3PB']), isNull);
    expect(pickVin(const []), isNull);
  });

  test('модель по началу VIN: LS4ASE — UNI-Z, LS6CME — Q05, незнакомое — нет', () {
    expect(modelCodeForVin('LS4ASE2E2TB000001'), 'uni-z');
    expect(modelCodeForVin('LS6CME0F7TB000002'), 'q05');
    expect(modelCodeForVin('LJ8B3C1D9PA000003'), isNull);
    // Ненастоящий VIN модель не определяет.
    expect(modelCodeForVin('LS6CME0F0TB000002'), isNull);
  });

  test('чтение VIN с ГУ: только команды чтения', () {
    for (final c in vinReadCommands) {
      expect(c.startsWith('settings get ') || c.startsWith('getprop '), isTrue, reason: c);
    }
  });
}
