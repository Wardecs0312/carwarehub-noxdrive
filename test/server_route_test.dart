import 'package:carwarehub_noxdrive/app/server_route.dart';
import 'package:flutter_test/flutter_test.dart';

const _direct = 'https://abc.supabase.co';
const _proxy = 'https://1-2-3-4.sslip.io';

void main() {
  test('из России — через посредника, из других стран — напрямую', () {
    expect(
      chooseServerUrl(direct: _direct, proxy: _proxy, countryCode: 'RU'),
      _proxy,
    );
    expect(
      chooseServerUrl(direct: _direct, proxy: _proxy, countryCode: 'ru'),
      _proxy,
    );
    expect(
      chooseServerUrl(direct: _direct, proxy: _proxy, countryCode: 'KG'),
      _direct,
    );
  });

  test('страна не определилась или посредника нет — напрямую, как раньше', () {
    expect(chooseServerUrl(direct: _direct, proxy: _proxy), _direct);
    expect(chooseServerUrl(direct: _direct, countryCode: 'RU'), _direct);
    // Посредник без https не используется: ключи входа не должны идти открытым текстом.
    expect(
      chooseServerUrl(
        direct: _direct,
        proxy: 'http://1.2.3.4',
        countryCode: 'RU',
      ),
      _direct,
    );
  });

  test('ручной выбор NOX_SERVER главнее страны', () {
    expect(
      chooseServerUrl(
        direct: _direct,
        proxy: _proxy,
        countryCode: 'KG',
        override: 'ru',
      ),
      _proxy,
    );
    expect(
      chooseServerUrl(
        direct: _direct,
        proxy: _proxy,
        countryCode: 'RU',
        override: 'direct',
      ),
      _direct,
    );
  });
}
