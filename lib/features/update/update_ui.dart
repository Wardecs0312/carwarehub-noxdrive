import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../data/models.dart';
import '../shell/metal_text.dart';

/// Скачивает установщик новой версии из приватного bucket `releases`, сверяет контрольную сумму
/// и только потом запускает. Это единственный файл, который сознательно пишется на диск.
/// Если сумма не совпала, файл удаляется и установка не запускается.
Future<void> openUpdate(BuildContext context, AppRelease release) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));
  try {
    final url = await Supabase.instance.client.storage
        .from('releases')
        .createSignedUrl(release.downloadPath, 600);
    if (!canUseAdb) {
      // Браузер: скачать и проверить в приложении нельзя, отдаём ссылку как есть.
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return;
    }
    say('Скачиваю обновление...');
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}nox_update_${release.version}.exe',
    );
    final client = HttpClient();
    try {
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      if (resp.statusCode != 200) {
        throw Exception('сервер ответил кодом ${resp.statusCode}');
      }
      final sink = Sha256().newHashSink();
      final out = file.openWrite();
      await for (final chunk in resp) {
        sink.add(chunk);
        out.add(chunk);
      }
      await out.close();
      sink.close();
      final actual = (await sink.hash()).bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (actual != release.sha256) {
        await file.delete();
        throw Exception('контрольная сумма файла не совпала');
      }
    } finally {
      client.close(force: true);
    }
    await Process.start(file.path, const [], mode: ProcessStartMode.detached);
    exit(0);
  } catch (e) {
    say('Не удалось обновить: $e');
  }
}

class UpdateBanner extends StatelessWidget {
  const UpdateBanner(this.release, {super.key});
  final AppRelease release;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: NoxColors.panelHi,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Доступна версия ${release.version}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: () => openUpdate(context, release),
          child: const Text('Обновить'),
        ),
      ],
    ),
  );
}

/// Блокирующий экран для обязательного обновления.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen(this.release, {super.key});
  final AppRelease release;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MetalText(
            'nox.drive',
            style: TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text('Требуется обновление до версии ${release.version}'),
          if (release.releaseNotes != null) ...[
            const SizedBox(height: 8),
            Text(
              release.releaseNotes!,
              style: const TextStyle(color: NoxColors.metalMid),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => openUpdate(context, release),
            child: const Text('Скачать обновление'),
          ),
        ],
      ),
    ),
  );
}
