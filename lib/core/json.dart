/// Безопасное чтение полей из JSON (ответы Supabase и Edge Functions).
/// Вместо `j['x'] as String`, которое падает с «type 'Null' is not a subtype of type 'String'»,
/// когда поле отсутствует или пришёл ответ с ошибкой.
library;

/// Строка или '' (null и не-строки приводятся через toString()).
String str(Object? v) => v?.toString() ?? '';

/// Строка или null, если поля нет или оно пустое.
String? strOrNull(Object? v) {
  final s = v?.toString();
  return s == null || s.isEmpty ? null : s;
}

/// Обязательное поле ответа сервера: понятная ошибка вместо падения приведения типа.
String requireStr(Map<dynamic, dynamic>? j, String key, String what) {
  final s = strOrNull(j?[key]);
  if (s == null) throw Exception('$what: сервер не вернул «$key»');
  return s;
}

/// Целое число или [fallback] (принимает и строку «12»).
int intOr(Object? v, [int fallback = 0]) =>
    v is num ? v.toInt() : int.tryParse(str(v)) ?? fallback;

/// Логическое значение или false.
bool boolOr(Object? v, [bool fallback = false]) => v is bool ? v : fallback;

/// Дата или «сейчас», если поле пустое или в неверном формате.
DateTime dateOrNow(Object? v) =>
    DateTime.tryParse(str(v))?.toLocal() ?? DateTime.now();

/// Ответ функции как Map (если пришло что-то другое, например текст ошибки, то пустой Map).
Map<String, dynamic> asMap(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry(k.toString(), val)) : {};
