import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../jobs/job_controller.dart';
import 'rustore_patch.dart';

/// Окно выполнения услуги: только плавная шкала прогресса и итог. Никаких консолей и логов.
Future<void> showJobDialog(BuildContext context) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => const _JobDialog(),
);

class _JobDialog extends ConsumerWidget {
  const _JobDialog();

  Future<void> _confirmStop(BuildContext context, WidgetRef ref) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Остановить услугу?'),
        content: const Text(
          'Текущий шаг прервётся. Уже установленное на автомобиле останется. '
          'Повтор на этом автомобиле бесплатный.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Продолжить'),
          ),
          FilledButton(
            key: const Key('job-stop-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Остановить'),
          ),
        ],
      ),
    );
    if (yes == true) ref.read(jobControllerProvider.notifier).cancel();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(jobControllerProvider);
    final running = job.phase == JobPhase.running;
    final ok = job.phase == JobPhase.success;

    void close() {
      ref.read(jobControllerProvider.notifier).reset();
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
                  job.serviceTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 22),
                if (running || ok) ...[
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: job.progress),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOut,
                    builder: (_, v, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        key: const Key('job-progress'),
                        value: v,
                        minHeight: 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    ok ? 'Услуга успешно выполнена' : job.stepTitle,
                    style: TextStyle(
                      color: ok ? NoxColors.ok : NoxColors.metalMid,
                    ),
                  ),
                  if (ok && job.message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        job.message!,
                        style: const TextStyle(color: NoxColors.warn),
                      ),
                    ),
                  if (ok && job.serviceCode == 'rustore')
                    const Padding(
                      padding: EdgeInsets.only(top: 18),
                      child: RustorePatch(),
                    ),
                ] else ...[
                  Row(
                    children: [
                      const Icon(Icons.error_outline, color: NoxColors.bad),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          job.message ?? 'Не удалось выполнить услугу',
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (job.phase == JobPhase.failed && job.refundable)
                      TextButton(
                        onPressed: () => ref
                            .read(jobControllerProvider.notifier)
                            .requestRefund(),
                        child: const Text('Запросить возврат'),
                      ),
                    if (running)
                      TextButton.icon(
                        key: const Key('job-stop'),
                        onPressed: job.stepTitle == 'Остановка...'
                            ? null
                            : () => _confirmStop(context, ref),
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Остановить'),
                      ),
                    if (!running)
                      FilledButton(
                        onPressed: close,
                        child: Text(ok ? 'Готово' : 'Закрыть'),
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
