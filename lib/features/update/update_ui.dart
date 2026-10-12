import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../data/models.dart';
import '../shell/metal_text.dart';

/// Открывает загрузку установщика новой версии (приватный bucket `releases`, ссылка живёт 10 минут).
/// Это единственный файл, который сознательно скачивается на диск: установщик должен запуститься.
Future<void> openUpdate(AppRelease release) async {
  final url = await Supabase.instance.client.storage
      .from('releases')
      .createSignedUrl(release.downloadPath, 600);
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
          onPressed: () => openUpdate(release),
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
            onPressed: () => openUpdate(release),
            child: const Text('Скачать обновление'),
          ),
        ],
      ),
    ),
  );
}
