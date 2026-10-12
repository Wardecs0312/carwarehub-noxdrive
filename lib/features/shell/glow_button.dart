import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Главная кнопка с мягкой подсветкой в цвете металла. Выключенная кнопка без свечения.
class GlowButton extends StatelessWidget {
  const GlowButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      boxShadow: onPressed == null
          ? null
          : [
              BoxShadow(
                color: NoxColors.metalLight.withValues(alpha: 0.35),
                blurRadius: 18,
                spreadRadius: 0.5,
              ),
            ],
    ),
    child: FilledButton(onPressed: onPressed, child: Text(label)),
  );
}
