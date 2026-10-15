import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../data/models.dart';
import '../shell/metal_text.dart';
import 'updater.dart';

/// Открывает загрузку установщика новой версии (приватный bucket `releases`, ссылка живёт 10 минут).
/// Это единственный файл, который сознательно скачивается на диск: установщик должен запуститься.
Future<void> openUpdate(AppRelease release) async {
  final url = await Supabase.instance.client.storage
      .from('releases')
      .createSignedUrl(release.downloadPath, 600);
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Обновление: на Windows скачивание и установка внутри программы, на остальных платформах ссылка.
Future<void> startUpdate(BuildContext context, AppRelease release) async {
  if (!Updater.supported) return openUpdate(release);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => UpdateDialog(release: release),
  );
}

/// Предложение обновиться (один раз за запуск, если обновление не обязательное).
class UpdateOffer extends StatefulWidget {
  const UpdateOffer(this.release, {super.key});
  final AppRelease release;

  @override
  State<UpdateOffer> createState() => _UpdateOfferState();
}

class _UpdateOfferState extends State<UpdateOffer> {
  static int? _offeredBuild;

  @override
  void initState() {
    super.initState();
    if (_offeredBuild != widget.release.buildNumber && Updater.supported) {
      _offeredBuild = widget.release.buildNumber;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) startUpdate(context, widget.release);
      });
    }
  }

  @override
  Widget build(BuildContext context) => UpdateBanner(widget.release);
}

enum _Stage { offer, downloading, installing, failed }

/// Окно обновления: что нового → скачивание с прогрессом → установка и перезапуск.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.release});
  final AppRelease release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  _Stage _stage = _Stage.offer;
  double _progress = 0;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _stage = _Stage.downloading;
      _progress = 0;
      _error = null;
    });
    try {
      final r = widget.release;
      final zip = await Updater.download(r, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _stage = _Stage.installing);
      await Updater.verify(zip, r.sha256);
      if (!Updater.isAndroid) await Updater.verifySignature(r);
      if (Updater.isAndroid) {
        // Android ставит APK только через системное окно «Установить».
        await Updater.installApk(zip);
        if (mounted) Navigator.pop(context);
        return;
      }
      final dir = await Updater.extract(zip, r);
      await Updater.applyAndRestart(dir);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final mb = r.sizeBytes == null
        ? ''
        : ' · ${(r.sizeBytes! / 1024 / 1024).toStringAsFixed(0)} МБ';
    return AlertDialog(
      icon: const Icon(Icons.system_update_alt, size: 36),
      title: Text('Новая версия ${r.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: switch (_stage) {
            _Stage.offer => [
              Text('Доступно обновление программы$mb.'),
              if (r.releaseNotes != null) ...[
                const SizedBox(height: 12),
                const Text(
                  'Что нового:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  r.releaseNotes!,
                  style: const TextStyle(color: NoxColors.metalMid),
                ),
              ],
            ],
            _Stage.downloading => [
              Text('Скачивание… ${(_progress * 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            ],
            _Stage.installing => [
              Text(
                Updater.isAndroid
                    ? 'Проверка файла. Затем Android покажет окно «Установить» — нажмите его.'
                    : 'Установка. Программа закроется и откроется заново.',
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(),
            ],
            _Stage.failed => [
              Text(
                'Не удалось обновить: $_error',
                style: const TextStyle(color: NoxColors.bad),
              ),
            ],
          },
        ),
      ),
      actions: switch (_stage) {
        _Stage.offer || _Stage.failed => [
          if (!r.isMandatory)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Позже'),
            ),
          FilledButton(
            onPressed: _run,
            child: Text(_stage == _Stage.failed ? 'Повторить' : 'Обновить'),
          ),
        ],
        _ => const [],
      },
    );
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
          onPressed: () => startUpdate(context, release),
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
            onPressed: () => startUpdate(context, release),
            child: const Text('Скачать обновление'),
          ),
        ],
      ),
    ),
  );
}
