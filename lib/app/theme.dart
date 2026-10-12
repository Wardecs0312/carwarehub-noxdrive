import 'package:flutter/material.dart';

const kAccent = Color(0xFF2EE6A6);
const kBg = Color(0xFF0E1116);
const kPanel = Color(0xFF171B22);

ThemeData buildDarkTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: kBg,
  colorScheme: ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
    surface: kPanel,
  ),
  cardTheme: CardThemeData(
    color: kPanel,
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  ),
);
