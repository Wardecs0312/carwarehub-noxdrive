import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme.dart';
import '../../data/auth_repository.dart';
import '../admin/admin_repository.dart';
import '../admin/admin_screen.dart';

/// Логин на сайте админки: почта или Telegram ID (цифры).
/// Админ, который входит в программу через Telegram, на сайте вводит свой Telegram ID:
/// его учётная запись хранится под служебной почтой `tg-ID@telegram.nox.drive`.
String adminLoginEmail(String input) {
  final s = input.trim().toLowerCase();
  return RegExp(r'^\d{4,15}$').hasMatch(s) ? 'tg-$s@telegram.nox.drive' : s;
}

/// Логин похож на Telegram-ник: «@nick» или «nick» без знака @ внутри.
bool isTelegramNick(String input) {
  final s = input.trim();
  return RegExp(r'^@?[A-Za-z][A-Za-z0-9_]{2,31}$').hasMatch(s);
}

/// Почта для входа: ник админа превращается в почту его учётной записи через базу.
Future<String?> resolveAdminLogin(String input) async {
  if (!isTelegramNick(input)) return adminLoginEmail(input);
  final email = await Supabase.instance.client.rpc(
    'admin_login_email',
    params: {'p_username': input.trim()},
  );
  return email is String && email.isNotEmpty ? email : null;
}

/// Сайт админки (отдельная сборка lib/main_admin.dart).
/// Вход один раз: сессия хранится в браузере и обновляется сама, пока админ не нажмёт «Выйти».
class AdminWebApp extends StatelessWidget {
  const AdminWebApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'nox.drive · Админ',
    debugShowCheckedModeBanner: false,
    theme: buildDarkTheme(),
    home: const AdminWebGate(),
  );
}

class AdminWebGate extends ConsumerWidget {
  const AdminWebGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session.isLoading) return const _Loading();
    if (session.value == null) return const AdminLoginScreen();
    final admin = ref.watch(isAdminProvider);
    return admin.when(
      loading: () => const _Loading(),
      error: (_, _) => const _NoAccess(),
      data: (ok) =>
          ok ? const AdminScreen(standalone: true) : const _NoAccess(),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _NoAccess extends StatelessWidget {
  const _NoAccess();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: NoxColors.bad),
            const SizedBox(height: 12),
            const Text(
              'Эта учётная запись не администратор',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('no-access-logout'),
              onPressed: signOut,
              child: const Text('Выйти'),
            ),
          ],
        ),
      ),
    ),
  );
}

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_login.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Введите логин и пароль');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = await resolveAdminLogin(_login.text);
      if (email == null) {
        setState(() => _error = 'Неверный логин или пароль');
        return;
      }
      await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: _password.text,
      );
    } on AuthException catch (e) {
      setState(
        () => _error = e.message.contains('Invalid login')
            ? 'Неверный логин или пароль'
            : e.message,
      );
    } catch (e) {
      setState(() => _error = 'Нет связи с сервером: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/brand/nox_bg.jpg', fit: BoxFit.cover),
        Container(color: Colors.black.withValues(alpha: 0.6)),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset('assets/brand/nox_logo.png', width: 260),
                    const SizedBox(height: 8),
                    const Text(
                      'АДМИН-ПАНЕЛЬ',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        letterSpacing: 4,
                        color: NoxColors.metalMid,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      key: const Key('admin-login'),
                      controller: _login,
                      autofillHints: const [AutofillHints.username],
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Почта, @ник или Telegram ID',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('admin-password'),
                      controller: _password,
                      obscureText: _hidden,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Пароль',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _hidden
                              ? 'Показать пароль'
                              : 'Скрыть пароль',
                          icon: Icon(
                            _hidden ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () => setState(() => _hidden = !_hidden),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        key: const Key('admin-login-error'),
                        style: const TextStyle(color: NoxColors.bad),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('admin-submit'),
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Войти'),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Пароль задаётся в программе nox.drive: Админ-панель → «Пароль для сайта».',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: NoxColors.metalMid, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
