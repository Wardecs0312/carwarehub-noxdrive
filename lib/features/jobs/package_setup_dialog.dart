import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/models.dart';
import '../../jobs/apk_picker.dart';
import '../../jobs/custom_apk_store.dart';
import '../../jobs/job_controller.dart';
import '../../jobs/job_models.dart';
import '../shell/glow_button.dart';

/// Окно «Настройка пакета установки» перед стартом услуг установки.
/// Возвращает список своих APK мастера (с отметками) или null, если мастер отменил запуск.
Future<List<CustomApk>?> showPackageSetupDialog(
  BuildContext context, {
  required ServiceItem service,
  required CarModel model,
  required String vin,
}) => showDialog<List<CustomApk>>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.6),
  builder: (_) => _PackageSetupDialog(service: service, model: model, vin: vin),
);

class _PackageSetupDialog extends ConsumerStatefulWidget {
  const _PackageSetupDialog({
    required this.service,
    required this.model,
    required this.vin,
  });
  final ServiceItem service;
  final CarModel model;
  final String vin;

  @override
  ConsumerState<_PackageSetupDialog> createState() =>
      _PackageSetupDialogState();
}

class _PackageSetupDialogState extends ConsumerState<_PackageSetupDialog> {
  final List<CustomApk> _apks = [];

  @override
  void initState() {
    super.initState();
    // Свои APK, добавленные раньше, остаются в списке вместе с галочками.
    ref.read(customApkStoreProvider).load().then((saved) {
      if (!mounted) return;
      setState(() {
        for (final a in saved) {
          if (_apks.every((e) => e.path != a.path)) _apks.add(a);
        }
      });
    });
  }

  /// Изменение списка сразу запоминается на компьютере мастера.
  void _change(VoidCallback fn) {
    setState(fn);
    ref.read(customApkStoreProvider).save(List.of(_apks));
  }

  Future<void> _add() async {
    final picked = await ref.read(apkPickerProvider).pick();
    if (!mounted) return;
    _change(() {
      for (final a in picked) {
        if (_apks.every((e) => e.path != a.path)) _apks.add(a);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(
      packagePreviewProvider((
        serviceId: widget.service.id,
        modelId: widget.model.id,
        vin: widget.vin,
      )),
    );
    final selected = _apks.where((a) => a.selected).length;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: NoxColors.panel.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: NoxColors.metalMid.withValues(alpha: 0.35),
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.06),
                  Colors.white.withValues(alpha: 0.01),
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Настройка пакета установки',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.service.title,
                  style: const TextStyle(color: NoxColors.metalMid),
                ),
                const SizedBox(height: 22),
                const _Label('Основной пакет'),
                preview.when(
                  data: (p) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in p.items) _MainItem(item),
                      if (p.items.isEmpty)
                        const Text('Состав пакета не указан'),
                      const SizedBox(height: 6),
                      Text(
                        p.repeat
                            ? 'Повторная установка для этого VIN бесплатна'
                            : (p.price > 0
                                  ? 'Стоимость: ${p.price} кр.'
                                  : 'Бесплатно'),
                        style: const TextStyle(
                          color: NoxColors.metalMid,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  ),
                  error: (e, _) => Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: NoxColors.bad,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.toString(),
                          style: const TextStyle(color: NoxColors.bad),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const Divider(height: 1),
                const SizedBox(height: 18),
                const _Label('Дополнительные APK мастера'),
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Список запоминается: добавленные файлы остаются, пока вы их не уберёте',
                    style: TextStyle(color: NoxColors.metalMid, fontSize: 12),
                  ),
                ),
                Flexible(
                  child: _apks.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'Свои файлы не добавлены',
                            style: TextStyle(color: NoxColors.metalMid),
                          ),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (var i = 0; i < _apks.length; i++)
                              _ApkRow(
                                apk: _apks[i],
                                onToggle: (v) => _change(
                                  () =>
                                      _apks[i] = _apks[i].copyWith(selected: v),
                                ),
                                onRemove: () =>
                                    _change(() => _apks.removeAt(i)),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('add-apk'),
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить свои APK'),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 12),
                    GlowButton(
                      label: selected == 0
                          ? 'Начать установку'
                          : 'Начать установку (+$selected)',
                      onPressed: preview.hasValue
                          ? () => Navigator.of(context).pop(List.of(_apks))
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 3,
        color: NoxColors.metalMid,
      ),
    ),
  );
}

class _MainItem extends StatelessWidget {
  const _MainItem(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        const Icon(
          Icons.check_box,
          size: 20,
          color: NoxColors.metalMid,
        ), // выбран по умолчанию, не снимается
        const SizedBox(width: 10),
        Expanded(child: Text(title)),
      ],
    ),
  );
}

class _ApkRow extends StatelessWidget {
  const _ApkRow({
    required this.apk,
    required this.onToggle,
    required this.onRemove,
  });
  final CustomApk apk;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  String get _size {
    final mb = apk.sizeBytes / (1024 * 1024);
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} МБ'
        : '${(apk.sizeBytes / 1024).ceil()} КБ';
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Checkbox(
        value: apk.selected,
        onChanged: (v) => onToggle(v ?? false),
        activeColor: NoxColors.metalLight,
        checkColor: NoxColors.bg,
      ),
      Expanded(child: Text(apk.name, overflow: TextOverflow.ellipsis)),
      Text(
        _size,
        style: const TextStyle(color: NoxColors.metalMid, fontSize: 12),
      ),
      IconButton(
        tooltip: 'Убрать из списка',
        icon: const Icon(Icons.close, size: 18, color: NoxColors.metalMid),
        onPressed: onRemove,
      ),
    ],
  );
}
