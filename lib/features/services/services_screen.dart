import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/catalog_repository.dart';
import '../../data/models.dart';

class ServicesScreen extends ConsumerWidget {
  const ServicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider);
    final selected = ref.watch(selectedModelProvider);
    final services = ref.watch(servicesProvider);
    final update = ref.watch(updateProvider).value;

    return Scaffold(
      body: Column(
        children: [
          if (update != null) _UpdateBanner(update),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CarWareHub NoxDrive',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 20),
                  models.when(
                    data: (list) => Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final m in list)
                          ChoiceChip(
                            label: Text(m.title),
                            selected: selected?.id == m.id,
                            onSelected: (_) =>
                                ref.read(selectedModelProvider.notifier).state =
                                    m,
                          ),
                      ],
                    ),
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('Не удалось загрузить модели: $e'),
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: selected == null
                        ? const Center(
                            child: Text('Выберите модель автомобиля'),
                          )
                        : services.when(
                            data: (list) => GridView(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 320,
                                    mainAxisExtent: 120,
                                    mainAxisSpacing: 14,
                                    crossAxisSpacing: 14,
                                  ),
                              children: [for (final s in list) _ServiceCard(s)],
                            ),
                            loading: () => const Center(
                              child: CircularProgressIndicator(),
                            ),
                            error: (e, _) => Center(
                              child: Text('Не удалось загрузить услуги: $e'),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard(this.service);
  final ServiceItem service;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {}, // запуск ADB-сценария будет на следующем этапе
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              service.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (service.priceCredits > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${service.priceCredits} кр.'),
              ),
          ],
        ),
      ),
    ),
  );
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner(this.release);
  final AppRelease release;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.primaryContainer,
    padding: const EdgeInsets.all(10),
    child: Text(
      'Доступна версия ${release.version}'
      '${release.isMandatory ? ' (обязательное обновление)' : ''}',
    ),
  );
}
