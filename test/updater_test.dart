import 'dart:io';

import 'package:carwarehub_noxdrive/features/update/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'папка программы без права записи распознаётся (Program Files)',
    () async {
      final dir = await Directory.systemTemp.createTemp('nox_upd');
      addTearDown(() => dir.delete(recursive: true));
      expect(await Updater.canWrite(dir), isTrue);
      expect(
        await Updater.canWrite(
          Directory('${dir.path}${Platform.pathSeparator}нет'),
        ),
        isFalse,
      );
      if (Platform.isWindows) {
        expect(
          await Updater.canWrite(Directory(r'C:\Windows\System32')),
          isFalse,
        );
      }
    },
  );

  test('параметры для обновления с правами администратора: пути в кавычках, без перезапуска', () {
    expect(
      Updater.elevatedArgs(
        r'C:\Temp\nox_update_37\new',
        r'C:\Program Files\nox.drive',
        'carwarehub_noxdrive.exe',
        42,
      ),
      r'"C:\Temp\nox_update_37\new" "C:\Program Files\nox.drive" "carwarehub_noxdrive.exe" "42" nostart',
    );
    expect(Updater.updateBat, contains('if /i "%~5"=="nostart" exit /b 0'));
    expect(Updater.elevateBat, contains('-Verb RunAs -Wait'));
    expect(Updater.elevateBat, contains(r'start "" /D "%NOX_DST%"'));
  });
}
