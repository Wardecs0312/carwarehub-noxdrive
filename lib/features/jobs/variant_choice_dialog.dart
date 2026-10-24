import 'dart:ui';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/models.dart';
import '../shell/glow_button.dart';

/// Окно выбора варианта услуги (например, штатный или кастомный голос).
/// Возвращает выбранную услугу или null, если мастер отменил. Дальше идёт обычное
/// окно «Подтвердите загрузку», точная цена считается там.
Future<ServiceItem?> showVariantChoiceDialog(
  BuildContext context, {
  required ServiceItem service,
  required List<ServiceItem> variants,
  int? deviceSdk,
}) => showDialog<ServiceItem>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.6),
  builder: (_) => _VariantChoiceDialog(
    options: [service, ...variants],
    title: service.title,
    deviceSdk: deviceSdk,
  ),
);

class _VariantChoiceDialog extends StatefulWidget {
  const _VariantChoiceDialog({
    required this.options,
    required this.title,
    this.deviceSdk,
  });
  final List<ServiceItem> options;
  final String title;

  /// Версия Android головного устройства (SDK); варианты, которым её мало, недоступны.
  final int? deviceSdk;

  @override
  State<_VariantChoiceDialog> createState() => _VariantChoiceDialogState();
}

class _VariantChoiceDialogState extends State<_VariantChoiceDialog> {
  ServiceItem? _chosen;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(24),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          key: const Key('variant-choice'),
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: NoxColors.panel.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: NoxColors.metalMid.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Выберите вариант',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                widget.title,
                style: const TextStyle(color: NoxColors.metalMid),
              ),
              const SizedBox(height: 18),
              for (final o in widget.options)
                _Option(
                  service: o,
                  selected: _chosen?.id == o.id,
                  problem: sdkProblem(o.code, widget.deviceSdk),
                  onTap: () => setState(() => _chosen = o),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Отмена'),
                  ),
                  const SizedBox(width: 12),
                  GlowButton(
                    key: const Key('variant-next'),
                    label: 'Далее',
                    onPressed: _chosen == null
                        ? null
                        : () => Navigator.of(context).pop(_chosen),
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

class _Option extends StatelessWidget {
  const _Option({
    required this.service,
    required this.selected,
    required this.onTap,
    this.problem,
  });
  final ServiceItem service;
  final bool selected;
  final VoidCallback onTap;

  /// Почему вариант не подходит этой машине (тогда его нельзя выбрать).
  final String? problem;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Opacity(
      opacity: problem == null ? 1 : 0.5,
      child: InkWell(
        key: Key('variant-${service.code}'),
        borderRadius: BorderRadius.circular(14),
        onTap: problem == null ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? NoxColors.metalLight
                  : NoxColors.metalMid.withValues(alpha: 0.35),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? NoxColors.metalLight : NoxColors.metalMid,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(service.choiceLabel),
                    const SizedBox(height: 2),
                    Text(
                      problem ??
                          (service.priceCredits > 0
                              ? '${service.priceCredits} кр.'
                              : 'Входит в пакет, без доплаты'),
                      style: TextStyle(
                        color: problem == null
                            ? NoxColors.metalMid
                            : NoxColors.warn,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
