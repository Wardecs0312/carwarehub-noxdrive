import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/env.dart';
import 'app/theme.dart';
import 'data/auth_repository.dart';
import 'data/catalog_repository.dart';
import 'features/admin/admin_repository.dart';
import 'features/auth/account_status_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/stream/stream_banner.dart';
import 'features/update/update_ui.dart';
import 'features/update/updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Env.hasSupabase) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
  }
  // Остатки прошлого обновления (*.nox-old, временные папки) убираются в фоне.
  unawaited(Updater.cleanupOldFiles());
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
      final status = ref.watch(masterStatusProvider).value;
      // Администратор входит сразу, даже если его строка мастера ещё не одобрена.
      final isAdmin = ref.watch(isAdminProvider).value ?? false;
      if (!isAdmin && (status == 'pending' || status == 'blocked')) {
        return AccountStatusScreen(status: status!);
      }
    }

    return Column(
      children: [
        if (update != null) UpdateOffer(update),
        const StreamBanner(),
        const Expanded(child: HomeScreen()),
      ],
    );
  }
}
