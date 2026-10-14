/// VIN: 17 символов, латиница и цифры, без I, O, Q.
final _vinRe = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

String normalizeVin(String raw) => raw.trim().toUpperCase();

/// Русские буквы, неотличимые на вид от латинских. В VIN кириллицы быть не может,
/// поэтому такая замена безопасна и исправляет частую ошибку при копировании.
const _lookalikes = {
  'А': 'A', 'В': 'B', 'Е': 'E', 'К': 'K', 'М': 'M', 'Н': 'H',
  'О': 'O', 'Р': 'P', 'С': 'C', 'Т': 'T', 'Х': 'X', 'У': 'Y',
};

String latinizeVin(String raw) => [
  for (final r in raw.runes)
    _lookalikes[String.fromCharCode(r).toUpperCase()] ?? String.fromCharCode(r),
].join();

bool isValidVin(String raw) => _vinRe.hasMatch(normalizeVin(raw));
