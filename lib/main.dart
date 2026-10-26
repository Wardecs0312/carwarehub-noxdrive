import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/env.dart';
import 'app/server_route.dart';
import 'app/theme.dart';
import 'data/auth_repository.dart';
import 'data/catalog_repository.dart';
import 'features/admin/admin_repository.dart';
import 'features/auth/account_status_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/presence/presence_service.dart';
import 'features/stream/stream_banner.dart';
import 'features/update/update_ui.dart';
import 'features/update/updater.dart';
import 'jobs/job_backend.dart';
import 'jobs/job_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Env.hasSupabase) {
    // Мастера из России ходят через посредника (lib/app/server_route.dart).
    await resolveServerUrl();
    await Supabase.initialize(
      url: ServerRoute.url,
      publishableKey: Env.supabaseAnonKey,
    );
  }
  // Проверка установки обновления без входа (только для разработчика):
  // NOX_UPDATE_SELFTEST=<папка с новой версией> — через 3 с программа ставит её через update.bat.
  final selfTest = Updater.supported
      ? Platform.environment['NOX_UPDATE_SELFTEST']
      : null;
  if (selfTest != null && selfTest.isNotEmpty) {
    Timer(
      const Duration(seconds: 3),
      () => Updater.applyAndRestart(Directory(selfTest)),
    );
  } else {
    // Остатки прошлого обновления (*.nox-old, временные папки) убираются в фоне.
    unawaited(Updater.cleanupOldFiles());
    // Недокачанные файлы прошлого запуска (программу закрыли посреди загрузки).
    if (Env.hasSupabase) {
      unawaited(SupabaseJobBackend.store.cleanupPartials());
    }
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
    // «В сети» для админ-панели: вход, затем отметка раз в минуту.
    ref.watch(presenceProvider);
    final update = ref.watch(updateProvider).value;
    // Обязательное обновление не прерывает услугу, которая уже идёт: экран обновления
    // появится, когда она закончится.
    final jobRunning =
        ref.watch(jobControllerProvider.select((j) => j.phase)) ==
        JobPhase.running;
    if (update != null && update.isMandatory && !jobRunning) {
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
