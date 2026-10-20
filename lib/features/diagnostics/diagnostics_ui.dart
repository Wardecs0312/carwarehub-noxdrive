import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../adb/adb_status.dart';
import '../../adb/adb_status_checker.dart';
import '../../app/theme.dart';
import '../../jobs/job_controller.dart';
import 'diagnostics.dart';

const diagConfirmText =
    'Программа прочитает сведения о головном устройстве (модель, прошивку, '
    'список приложений, экраны и службы приборной панели) и отправит их администратору. '
    'На автомобиле ничего не меняется, кредиты не списываются.';

/// Кнопка «Диагностика (только чтение)». Отдельно от платных услуг: VIN и модель не нужны.
class DiagnosticsButton extends ConsumerWidget {
  const DiagnosticsButton({super.key, required this.vin});

  /// VIN из поля на главном экране (если введён верно, попадёт в отчёт).
  final String vin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adb =
        ref.watch(adbStatusProvider).value ??
        const AdbStatus(AdbConnection.disconnected);
    final busy = ref.watch(jobControllerProvider).phase == JobPhase.running;
    final hint = adb.blockedHint ?? (busy ? 'Идёт услуга' : null);
    final button = OutlinedButton.icon(
      key: const Key('diagnostics-button'),
      onPressed: hint == null ? () => _start(context, ref) : null,
      icon: const Icon(Icons.troubleshoot),
      label: const Text('Диагностика (только чтение)'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        hint == null ? button : Tooltip(message: hint, child: button),
        const SizedBox(height: 8),
        const Text(
          'Если что-то не получается: программа соберёт сведения о машине для администратора. '
          'Ничего не меняет.',
          style: TextStyle(color: NoxColors.metalMid, fontSize: 13),
        ),
      ],
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Диагностика'),
        content: const Text(diagConfirmText),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('diagnostics-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Начать'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    ref.read(diagnosticsControllerProvider.notifier).run(vin: vin);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DiagnosticsDialog(),
    );
  }
}

class _DiagnosticsDialog extends ConsumerWidget {
  const _DiagnosticsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(diagnosticsControllerProvider);
    final running = s.phase == DiagPhase.running;
    final sent = s.phase == DiagPhase.sent;

    void close() {
      ref.read(diagnosticsControllerProvider.notifier).reset();
      Navigator.of(context).pop();
    }

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: NoxColors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: NoxColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Диагностика (только чтение)',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 22),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    key: const Key('diagnostics-progress'),
                    value: s.progress.clamp(0, 1),
                    minHeight: 10,
                  ),
                ),
                const SizedBox(height: 12),
                if (running)
                  Text(
                    s.stepTitle,
                    style: const TextStyle(color: NoxColors.metalMid),
                  )
                else if (sent)
                  const Text(
                    'Готово. Сведения отправлены администратору.',
                    key: Key('diagnostics-sent'),
                    style: TextStyle(color: NoxColors.ok),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: NoxColors.warn),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.report == null
                              ? (s.message ?? 'Диагностика не выполнена')
                              : 'Сведения собраны, но не отправлены: ${s.message}. '
                                    'Скопируйте отчёт и пришлите администратору.',
                          key: const Key('diagnostics-not-sent'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 24),
                // Wrap, а не Row: на узком окне кнопки переносятся, а не вылезают за край.
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!running && s.report != null)
                      TextButton.icon(
                        key: const Key('diagnostics-copy'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: s.report!.toText()),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(content: Text('Отчёт скопирован')),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Скопировать отчёт'),
                      ),
                    if (!running)
                      FilledButton(
                        key: const Key('diagnostics-close'),
                        onPressed: close,
                        child: Text(sent ? 'Готово' : 'Закрыть'),
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
