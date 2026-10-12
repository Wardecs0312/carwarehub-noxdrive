/// VIN: 17 символов, латиница и цифры, без I, O, Q.
final _vinRe = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

String normalizeVin(String raw) => raw.trim().toUpperCase();

bool isValidVin(String raw) => _vinRe.hasMatch(normalizeVin(raw));
