import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/catalog_repository.dart';
import '../../data/models.dart';

/// Карточка цены для выбранной модели: доступные пакеты и активации, недоступное помечено «Н/Д»,
/// внизу итоговая стоимость всего доступного. Цена в рублях = кредиты на балансе.
class PriceCard extends ConsumerWidget {
  const PriceCard({super.key, required this.model});
  final CarModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(priceGroupsProvider).value ?? const <PriceGroup>[];
    if (groups.isEmpty) return const SizedBox.shrink();
    final available = groups.where((g) => g.availableFor(model.code)).toList();
    final totalCredits = available.fold<int>(0, (s, g) => s + g.priceCredits);
    final totalRub = available.fold<int>(0, (s, g) => s + g.priceRub);
    final totalUsd = available.fold<int>(0, (s, g) => s + g.priceUsd);
    const muted = TextStyle(color: NoxColors.metalMid, fontSize: 13);

    return Container(
      key: const Key('price-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NoxColors.panelHi,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NoxColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Стоимость для ${model.title}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          for (final g in groups) ...[
            _GroupRow(group: g, modelCode: model.code),
            const Divider(height: 20, color: NoxColors.border),
          ],
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Итого за всё доступное',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 12),
              _Price(
                credits: '$totalCredits кр.',
                money: '${formatRub(totalRub)} / \$$totalUsd',
                keyPrefix: 'price-total',
                big: true,
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Списываются кредиты с баланса мастера. Доступ оплачивается один раз на VIN: повторные услуги на этот VIN бесплатны.',
            style: muted,
          ),
        ],
      ),
    );
  }
}

/// Цена в кредитах крупно, под ней рубли и доллары для справки.
class _Price extends StatelessWidget {
  const _Price({
    required this.credits,
    required this.money,
    this.keyPrefix,
    this.big = false,
  });
  final String credits;
  final String money;
  final String? keyPrefix;
  final bool big;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(
        credits,
        key: keyPrefix == null ? null : Key(keyPrefix!),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: big ? 18 : 15,
          color: NoxColors.metalLight,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      Text(
        money,
        key: keyPrefix == null ? null : Key('$keyPrefix-money'),
        style: const TextStyle(fontSize: 12, color: NoxColors.metalMid),
      ),
    ],
  );
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.group, required this.modelCode});
  final PriceGroup group;
  final String modelCode;

  @override
  Widget build(BuildContext context) {
    final ok = group.availableFor(modelCode);
    final dim = ok ? NoxColors.metalLight : NoxColors.metalDark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.title,
                    style: TextStyle(fontWeight: FontWeight.w600, color: dim),
                  ),
                  if (group.description != null && group.items.length < 2)
                    Text(
                      group.description!,
                      style: const TextStyle(
                        color: NoxColors.metalMid,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (ok)
              _Price(
                credits: '${group.priceCredits} кр.',
                money: '${formatRub(group.priceRub)} / \$${group.priceUsd}',
              )
            else
              const Text(
                'Н/Д',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: NoxColors.bad,
                ),
              ),
          ],
        ),
        if (group.items.length > 1) ...[
          const SizedBox(height: 6),
          for (final i in group.items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    ok && !i.naModels.contains(modelCode)
                        ? Icons.check
                        : Icons.remove,
                    size: 16,
                    color: ok && !i.naModels.contains(modelCode)
                        ? NoxColors.ok
                        : NoxColors.metalDark,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      i.naModels.contains(modelCode)
                          ? '${i.title} — Н/Д'
                          : i.title,
                      style: TextStyle(
                        fontSize: 13,
                        color: i.naModels.contains(modelCode)
                            ? NoxColors.metalDark
                            : NoxColors.metalMid,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
