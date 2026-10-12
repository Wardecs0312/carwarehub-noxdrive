import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'job_models.dart';

/// Выбор файлов .apk на компьютере мастера через стандартный проводник Windows.
abstract class ApkPicker {
  Future<List<CustomApk>> pick();
}

class FilePickerApkPicker implements ApkPicker {
  @override
  Future<List<CustomApk>> pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Выберите APK для установки',
      type: FileType.custom,
      allowedExtensions: const ['apk'],
    );
    return [
      for (final f in files)
        if (f.path != null && File(f.path!).existsSync())
          CustomApk(
            path: f.path!,
            name: f.name,
            sizeBytes: File(f.path!).lengthSync(),
          ),
    ];
  }
}

final apkPickerProvider = Provider<ApkPicker>((_) => FilePickerApkPicker());
