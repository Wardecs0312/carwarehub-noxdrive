import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

/// Команда, которая разрешает RuStore устанавливать приложения.
const rustorePatchCommand =
    'adb shell appops set ru.vk.store REQUEST_INSTALL_PACKAGES allow';

/// Кнопка «Патч для RuStore» в окне итога: раскрывает поле с командой (копируется одной кнопкой,
/// галочка подтверждает копирование) и короткую инструкцию.
class RustorePatch extends StatefulWidget {
  const RustorePatch({super.key});

  @override
  State<RustorePatch> createState() => _RustorePatchState();
}

class _RustorePatchState extends State<RustorePatch> {
  var _open = false;
  var _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(const ClipboardData(text: rustorePatchCommand));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          key: const Key('rustore-patch'),
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(_open ? Icons.expand_less : Icons.build_outlined),
          label: const Text('Патч для RuStore'),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                        decoration: BoxDecoration(
                          color: NoxColors.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: NoxColors.border),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: SelectableText(
                                rustorePatchCommand,
                                key: Key('rustore-command'),
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            IconButton(
                              key: const Key('rustore-copy'),
                              tooltip: _copied ? 'Скопировано' : 'Копировать',
                              onPressed: _copy,
                              icon: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 150),
                                child: _copied
                                    ? const Icon(
                                        Icons.check_circle,
                                        key: Key('rustore-copied'),
                                        color: NoxColors.ok,
                                      )
                                    : const Icon(Icons.copy_rounded),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'После установки RuStore:\n'
                        '1. Скопируйте команду кнопкой справа.\n'
                        '2. Откройте «Пуск», наберите cmd, нажмите правой кнопкой '
                        '«Командная строка» → «Запуск от имени администратора».\n'
                        '3. Вставьте команду (правая кнопка мыши или Ctrl+V) и нажмите Enter.\n'
                        '4. Если ответа нет и ошибок нет — готово: RuStore может '
                        'устанавливать приложения.',
                        style: TextStyle(
                          color: NoxColors.metalMid,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
