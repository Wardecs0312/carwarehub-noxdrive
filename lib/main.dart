import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/env.dart';
import 'app/theme.dart';
import 'features/services/services_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Env.hasSupabase) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
  }
  runApp(const ProviderScope(child: NoxDriveApp()));
}

class NoxDriveApp extends StatelessWidget {
  const NoxDriveApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CarWareHub NoxDrive',
    debugShowCheckedModeBanner: false,
    theme: buildDarkTheme(),
    home: const ServicesScreen(),
  );
}
