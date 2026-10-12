import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Текст с металлическим градиентом, как у надписи nox.drive.
class MetalText extends StatelessWidget {
  const MetalText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (r) => NoxColors.metal.createShader(r),
    child: Text(text, style: style.copyWith(color: Colors.white)),
  );
}
