/// VIN: 17 символов, латиница и цифры, без I, O, Q.
final _vinRe = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

String normalizeVin(String raw) => raw.trim().toUpperCase();

/// Русские буквы, неотличимые на вид от латинских. В VIN кириллицы быть не может,
/// поэтому такая замена безопасна и исправляет частую ошибку при копировании.
const _lookalikes = {
  'А': 'A',
  'В': 'B',
  'Е': 'E',
  'К': 'K',
  'М': 'M',
  'Н': 'H',
  'О': 'O',
  'Р': 'P',
  'С': 'C',
  'Т': 'T',
  'Х': 'X',
  'У': 'Y',
};

String latinizeVin(String raw) => [
  for (final r in raw.runes)
    _lookalikes[String.fromCharCode(r).toUpperCase()] ?? String.fromCharCode(r),
].join();

/// Значения букв и цифр для контрольной цифры VIN (ISO 3779 / ГОСТ, в Китае обязательна).
const _translit = {
  'A': 1, 'B': 2, 'C': 3, 'D': 4, 'E': 5, 'F': 6, 'G': 7, 'H': 8,
  'J': 1, 'K': 2, 'L': 3, 'M': 4, 'N': 5, 'P': 7, 'R': 9,
  'S': 2, 'T': 3, 'U': 4, 'V': 5, 'W': 6, 'X': 7, 'Y': 8, 'Z': 9,
};
const _weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

/// Каким должен быть 9-й знак VIN (контрольная цифра): '0'–'9' или 'X'.
String vinCheckDigit(String vin) {
  final v = normalizeVin(vin);
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    final c = v[i];
    final n = int.tryParse(c) ?? _translit[c]!;
    sum += n * _weights[i];
  }
  final r = sum % 11;
  return r == 10 ? 'X' : '$r';
}

/// Записан ли VIN правильными знаками: 17 символов, латиница и цифры, без I, O, Q.
bool hasVinFormat(String raw) => _vinRe.hasMatch(normalizeVin(raw));

/// Настоящий VIN: правильный формат и сходится контрольная цифра (9-й знак).
/// Выдуманный или набранный с опечаткой VIN почти всегда её не проходит.
bool isValidVin(String raw) {
  final v = normalizeVin(raw);
  return hasVinFormat(v) && v[8] == vinCheckDigit(v);
}

/// Что не так с VIN из 17 знаков (для подсказки мастеру) или null, если всё верно.
String? vinProblem(String raw) {
  final v = normalizeVin(raw);
  if (v.length != 17) return null;
  if (!hasVinFormat(v)) return 'В VIN нет букв I, O, Q';
  if (v[8] != vinCheckDigit(v)) {
    return 'Такого VIN не существует: проверьте знаки (не сходится контрольная цифра)';
  }
  return null;
}

/// Где головное устройство Changan/Tinnove хранит VIN, в порядке проверки.
/// На прошивке SWC.5328 (C281MCA2) VIN лежит в настройках system: `VIN` и `ca.car.vin`;
/// системные свойства заполнены не на всех прошивках, но их читает штатная служба ГУ.
/// Всё только чтение: `settings get` и `getprop` ничего на ГУ не меняют.
const vinReadCommands = [
  'settings get system VIN',
  'settings get system ca.car.vin',
  'getprop persist.vendor.car.VIN',
  'getprop ro.mb.can.vin',
  'getprop persist.sys.mcutoapp.vin',
  'getprop persist.wt.dvin',
];

/// Первый ответ, похожий на настоящий VIN (пустые строки и `null` пропускаются).
String? pickVin(Iterable<String> answers) {
  for (final a in answers) {
    final v = normalizeVin(latinizeVin(a));
    if (v.isEmpty || v == 'NULL') continue;
    if (isValidVin(v)) return v;
  }
  return null;
}

/// Начало VIN (производитель + код модели) -> код модели в каталоге. Собрано по заданиям мастеров
/// на сервере: LS4ASE… всегда UNI-Z, LS6CME… — Q05 (головное устройство у них одинаковое,
/// C281MCA2, поэтому модель различается только по VIN). CS75 Pro, CS55 Plus и UNI-V
/// добавятся, когда появятся их VIN; до этого модель выбирает мастер.
const vinModelPrefixes = {
  'LS4ASE': 'uni-z',
  'LS6CME': 'q05',
};

/// Код модели по VIN или null, если начало VIN незнакомое.
String? modelCodeForVin(String vin) {
  final v = normalizeVin(vin);
  if (!isValidVin(v)) return null;
  for (final e in vinModelPrefixes.entries) {
    if (v.startsWith(e.key)) return e.value;
  }
  return null;
}
