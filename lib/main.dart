import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/env.dart';
import 'app/theme.dart';
import 'data/auth_repository.dart';
import 'data/catalog_repository.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/update/update_ui.dart';

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
    title: 'nox.drive',
    debugShowCheckedModeBanner: false,
    theme: buildDarkTheme(),
    home: const _AppGate(),
  );
}

/// Обязательное обновление, затем вход, затем основной экран.
class _AppGate extends ConsumerWidget {
  const _AppGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateProvider).value;
    if (update != null && update.isMandatory) {
      return UpdateRequiredScreen(update);
    }

    if (Env.hasSupabase) {
      final session = ref.watch(sessionProvider);
      if (session.isLoading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (session.value == null) return const LoginScreen();
    }

    return Column(
      children: [
        if (update != null) UpdateBanner(update),
        const Expanded(child: HomeScreen()),
      ],
    );
  }
}
