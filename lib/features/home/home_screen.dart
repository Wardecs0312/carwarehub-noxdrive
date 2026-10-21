import '../../app/platform.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../adb/adb_status.dart';
import '../../adb/adb_status_checker.dart';
import '../../app/theme.dart';
import '../../core/vin.dart';
import '../../data/catalog_repository.dart';
import '../../data/models.dart';
import '../../jobs/job_controller.dart';
import '../../jobs/job_models.dart';
import '../jobs/job_dialog.dart';
import '../jobs/package_setup_dialog.dart';
import '../shell/nox_header.dart';
import 'price_card.dart';

final vinProvider = StateProvider<String>((_) => '');

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Выбрали модель — файлы её услуг скачиваются в фоне заранее (как у батника:
    // к приезду машины всё уже на диске, услуга идёт без ожидания интернета).
    ref.listen(selectedModelProvider, (_, m) {
      if (m == null || !canUseAdb) return;
      unawaited(
        ref.read(jobBackendProvider).prefetchModel(m.id).catchError((_) {}),
      );
    });
    final models = ref.watch(modelsProvider);
    final selected = ref.watch(selectedModelProvider);
    final services = ref.watch(servicesProvider);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.16,
              child: Image.asset(
                'assets/brand/nox_bg.jpg',
                fit: BoxFit.cover,
                alignment: Alignment.bottomCenter,
              ),
            ),
          ),
          Column(
            children: [
              const NoxHeader(),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(
                    MediaQuery.sizeOf(context).width < kNarrowWidth ? 16 : 28,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionTitle('1. VIN автомобиля'),
                      const _VinField(),
                      const SizedBox(height: 28),
                      const _SectionTitle('2. Модель Changan'),
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
                                    ref
                                            .read(
                                              selectedModelProvider.notifier,
                                            )
                                            .state =
                                        m,
                              ),
                          ],
                        ),
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) =>
                            Text('Не удалось загрузить модели: $e'),
                      ),
                      if (selected != null) ...[
                        const SizedBox(height: 20),
                        PriceCard(model: selected),
                      ],
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          const Expanded(child: _SectionTitle('3. Услуга')),
                          if (selected != null)
                            TextButton.icon(
                              key: const Key('back-to-models'),
                              onPressed: () =>
                                  ref
                                          .read(selectedModelProvider.notifier)
                                          .state =
                                      null,
                              icon: const Icon(Icons.arrow_back, size: 18),
                              label: const Text('Назад'),
                            ),
                        ],
                      ),
                      if (selected == null)
                        const Text(
                          'Выберите модель автомобиля',
                          style: TextStyle(color: NoxColors.metalMid),
                        )
                      else
                        services.when(
                          data: (list) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _BlockedReason(),
                              GridView(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 340,
                                      mainAxisExtent: 120,
                                      mainAxisSpacing: 14,
                                      crossAxisSpacing: 14,
                                    ),
                                children: [
                                  for (var i = 0; i < list.length; i++)
                                    _ServiceCard(
                                      index: i + 1,
                                      service: list[i],
                                      model: selected,
                                    ),
                                ],
                              ),
                            ],
                          ),
                          loading: () => const LinearProgressIndicator(),
                          error: (e, _) =>
                              Text('Не удалось загрузить услуги: $e'),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        letterSpacing: 3,
        color: NoxColors.metalMid,
      ),
    ),
  );
}

class _VinField extends ConsumerStatefulWidget {
  const _VinField();

  @override
  ConsumerState<_VinField> createState() => _VinFieldState();
}

/// Поле VIN. При подключении ГУ программа сама читает VIN с машины (только чтение настроек и
/// свойств системы), вписывает его и выбирает модель по началу VIN. Введённый мастером VIN
/// не перезаписывается.
class _VinFieldState extends ConsumerState<_VinField> {
  late final TextEditingController _ctrl;

  /// VIN, вписанный программой, и для какого ГУ уже читали.
  String? _autoVin;
  String? _readFor;
  String? _note;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(vinProvider));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _detect(ref.read(adbStatusProvider).value),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _detect(AdbStatus? status) async {
    if (!canUseAdb || status == null || !mounted) return;
    final serial = status.serial;
    if (!status.isReady || serial == null) {
      // ГУ отключили: следующая машина будет прочитана заново.
      if (status.connection == AdbConnection.disconnected) _readFor = null;
      return;
    }
    if (_readFor == serial) return;
    _readFor = serial;
    bool typedByMaster() {
      final v = ref.read(vinProvider);
      return v.isNotEmpty && v != _autoVin;
    }

    if (typedByMaster()) return;
    final executor = ref.read(adbExecutorProvider);
    try {
      // Без разблокировки ГУ Changan бесконечно спрашивает пароль на любую команду adb shell.
      await executor.unlock(serial);
    } catch (_) {}
    final vin = await executor.readVin(serial);
    if (!mounted || vin == null || typedByMaster()) return;

    _autoVin = vin;
    _ctrl.text = vin;
    ref.read(vinProvider.notifier).state = vin;
    var note = 'VIN определён с машины';
    final code = modelCodeForVin(vin);
    if (code != null && ref.read(selectedModelProvider) == null) {
      try {
        final models = await ref.read(modelsProvider.future);
        final model = models.where((m) => m.code == code).firstOrNull;
        if (model != null && mounted && ref.read(selectedModelProvider) == null) {
          ref.read(selectedModelProvider.notifier).state = model;
          note = '$note, модель: ${model.title}';
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _note = note);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(adbStatusProvider, (_, next) => _detect(next.value));
    // VIN могли сбросить извне (например, после услуги): поле показывает то же, что хранится.
    ref.listen(vinProvider, (_, v) {
      if (_ctrl.text != v) _ctrl.text = v;
    });
    final vin = ref.watch(vinProvider);
    final valid = isValidVin(vin);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: TextField(
        key: const Key('vin-field'),
        controller: _ctrl,
        maxLength: 17,
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [
          // Русские буквы-двойники (С, Н, К…) из мессенджеров заменяются латинскими, иначе фильтр
          // молча выбросил бы их, и счётчик показал бы 16/17 без объяснения.
          TextInputFormatter.withFunction(
            (o, n) => n.copyWith(text: latinizeVin(n.text)),
          ),
          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
          TextInputFormatter.withFunction(
            (o, n) => n.copyWith(text: n.text.toUpperCase()),
          ),
        ],
        style: const TextStyle(fontSize: 18, letterSpacing: 2),
        decoration: InputDecoration(
          // Не настоящий VIN, чтобы подсказку не принимали за введённое значение.
          hintText: '17 символов: латиница и цифры',
          helperText: vin.isNotEmpty && vin == _autoVin ? _note : null,
          counterText: '${vin.length}/17',
          suffixIcon: Icon(
            valid ? Icons.check_circle : Icons.circle_outlined,
            color: valid ? NoxColors.ok : NoxColors.metalDark,
          ),
          errorText: vinProblem(vin),
        ),
        onChanged: (v) => ref.read(vinProvider.notifier).state = v,
      ),
    );
  }
}

/// Почему услуги сейчас недоступны. Подсказка на карточке (Tooltip) на сенсорных экранах не видна,
/// поэтому причина дублируется строкой над кнопками.
String? serviceBlockedHint(AdbStatus adb, String vin) =>
    adb.blockedHint ??
    (isValidVin(vin) ? null : vinProblem(vin) ?? 'Введите VIN (17 символов)');

class _BlockedReason extends ConsumerWidget {
  const _BlockedReason();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adb =
        ref.watch(adbStatusProvider).value ??
        const AdbStatus(AdbConnection.disconnected);
    final hint = serviceBlockedHint(adb, ref.watch(vinProvider));
    if (hint == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: NoxColors.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              key: const Key('blocked-reason'),
              style: const TextStyle(color: NoxColors.metalLight),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends ConsumerWidget {
  const _ServiceCard({
    required this.index,
    required this.service,
    required this.model,
  });
  final int index;
  final ServiceItem service;
  final CarModel model;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adb =
        ref.watch(adbStatusProvider).value ??
        const AdbStatus(AdbConnection.disconnected);
    final vin = ref.watch(vinProvider);
    final busy = ref.watch(jobControllerProvider).phase == JobPhase.running;

    // Подсказка, почему кнопка заблокирована. ADB важнее всего остального.
    final hint = serviceBlockedHint(adb, vin);
    final enabled = hint == null && !busy;

    final card = Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled
              ? () async {
                  final v = normalizeVin(vin);
                  // Любая услуга начинается только после «Подтвердить загрузку».
                  final chosen = await showPackageSetupDialog(
                    context,
                    service: service,
                    model: model,
                    vin: v,
                    confirmOnly: !service.allowCustomApks,
                  );
                  if (chosen == null || !context.mounted) return;
                  final apks = service.allowCustomApks
                      ? chosen
                      : const <CustomApk>[];
                  ref
                      .read(jobControllerProvider.notifier)
                      .run(
                        service: service,
                        vin: v,
                        model: model,
                        customApks: apks,
                      );
                  if (context.mounted) showJobDialog(context);
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '0$index',
                  style: const TextStyle(
                    color: NoxColors.metalMid,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  service.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (service.priceCredits > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${service.priceCredits} кр.',
                      style: const TextStyle(color: NoxColors.metalMid),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return hint == null ? card : Tooltip(message: hint, child: card);
  }
}
