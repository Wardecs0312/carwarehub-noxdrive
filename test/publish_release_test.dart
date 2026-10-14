import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/publish_release.dart';

const _url = 'https://abcdefgh.supabase.co';

/// Строка версии в ресурсах exe хранится в UTF-16.
List<int> _utf16(String s) => [
  for (final c in s.codeUnits) ...[c & 0xff, c >> 8],
];

List<int> _zip({
  String exeVersion = '2.0.11+11',
  String appSo = 'flutter app $_url',
  Set<String> skip = const {},
}) {
  final files = <String, List<int>>{
    'carwarehub_noxdrive.exe': [0, 1, ..._utf16(exeVersion), 2],
    'flutter_windows.dll': [1],
    'data/app.so': utf8.encode(appSo),
    'data/icudtl.dat': [1],
    'adb/adb.exe': [1],
    'adb/AdbWinApi.dll': [1],
    'adb/AdbWinUsbApi.dll': [1],
    'scrcpy/scrcpy.exe': [1],
  };
  final a = Archive();
  files.forEach((name, bytes) {
    if (!skip.contains(name)) a.addFile(ArchiveFile.bytes(name, bytes));
  });
  return ZipEncoder().encode(a);
}

List<String> _check(List<int> zip) =>
    checkWindowsZip(zip, version: '2.0.11', build: 11, supabaseUrl: _url);

void main() {
  test('правильный архив проходит все проверки', () {
    expect(_check(_zip()), isEmpty);
  });

  test('версия внутри exe не совпадает с pubspec: выпуск остановлен', () {
    final problems = _check(_zip(exeVersion: '2.0.7+7'));
    expect(problems.single, contains('версия внутри'));
  });

  test('сборка без адреса Supabase (демо-режим) не публикуется', () {
    final problems = _check(_zip(appSo: 'flutter app'));
    expect(problems.single, contains('демо-режиме'));
  });

  test('без adb или scrcpy в корне архива выпуск остановлен', () {
    final problems = _check(_zip(skip: {'adb/adb.exe', 'scrcpy/scrcpy.exe'}));
    expect(problems, hasLength(2));
  });

  test('не zip-файл отклоняется понятной ошибкой', () {
    expect(_check([1, 2, 3]).single, contains('не является zip'));
  });
}
