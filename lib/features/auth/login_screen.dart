import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../data/auth_repository.dart';

/// Вход, регистрация по почте и вход/регистрация через Telegram.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _tgCode = TextEditingController();

  /// Вход через Telegram ждёт код из бота (nonce этого входа).
  String? _tgCodeNonce;
  bool _register = false;
  bool _busy = false;
  String? _error;
  String? _info;

  /// Идёт ожидание подтверждения в Telegram.
  Timer? _tgTimer;

  void _setMode(bool register) => setState(() {
    _register = register;
    _error = null;
    _info = null;
  });

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() => _run(() async {
    if (!_register) {
      await signIn(_email.text, _password.text);
      return;
    }
    if (_name.text.trim().isEmpty || _email.text.trim().isEmpty) {
      throw Exception('Укажите имя и почту');
    }
    final needConfirm = await signUp(
      name: _name.text,
      phone: _phone.text,
      email: _email.text,
      password: _password.text,
    );
    if (needConfirm && mounted) {
      setState(() {
        _register = false;
        _info =
            'Мы отправили письмо на ${_email.text.trim()}. Откройте ссылку из письма, затем войдите.';
      });
    }
  });

  Future<void> _telegram() => _run(() async {
    final start = await telegramStart();
    await launchUrl(
      Uri.parse(start.link),
      mode: LaunchMode.externalApplication,
    );
    if (!mounted) return;
    setState(
      () => _info = 'Нажмите «Старт» в Telegram-боте, затем вернитесь сюда.',
    );
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    _tgTimer?.cancel();
    _tgTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (DateTime.now().isAfter(deadline)) {
        t.cancel();
        if (mounted) setState(() => _info = null);
        return;
      }
      try {
        // При успехе сессия меняется, и приложение само уходит с экрана входа.
        switch (await telegramPoll(start.nonce)) {
          case TelegramPoll.pending:
            break;
          case TelegramPoll.done:
            t.cancel();
          case TelegramPoll.needCode:
            t.cancel();
            if (mounted) {
              setState(() {
                _tgCodeNonce = start.nonce;
                _tgCode.clear();
                _info =
                    'Бот прислал в Telegram 6-значный код. Введите его здесь.';
              });
            }
        }
      } catch (e) {
        t.cancel();
        if (mounted) {
          setState(() {
            _info = null;
            _error = e.toString().replaceFirst('Exception: ', '');
          });
        }
      }
    });
  });

  void _cancelTelegram() {
    _tgTimer?.cancel();
    setState(() {
      _tgTimer = null;
      _tgCodeNonce = null;
      _info = null;
    });
  }

  /// Завершение входа через Telegram кодом из бота.
  Future<void> _submitTgCode() async {
    final nonce = _tgCodeNonce;
    if (nonce == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await telegramPoll(nonce, code: _tgCode.text.trim());
    } on TelegramCodeException catch (e) {
      if (mounted) setState(() => _error = '$e');
    } catch (e) {
      if (mounted) {
        setState(() {
          _tgCodeNonce = null;
          _info = null;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _tgTimer?.cancel();
    _tgCode.dispose();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final waitingTg = (_tgTimer?.isActive ?? false) || _tgCodeNonce != null;
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/brand/nox_bg.jpg',
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
          Container(color: Colors.black.withValues(alpha: 0.55)),
          // Версия программы: мастер и поддержка сразу видят, обновилась ли программа.
          const Positioned(right: 12, bottom: 8, child: _AppVersionLabel()),
          Center(
            // На телефоне клавиатура съедает полэкрана, поэтому форма прокручивается.
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_register || waitingTg)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('login-back'),
                          onPressed: waitingTg
                              ? _cancelTelegram
                              : () => _setMode(false),
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: const Text('Назад'),
                        ),
                      ),
                    Image.asset('assets/brand/nox_logo.png', width: 300),
                    const SizedBox(height: 20),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Вход')),
                        ButtonSegment(value: true, label: Text('Регистрация')),
                      ],
                      selected: {_register},
                      onSelectionChanged: _busy || waitingTg
                          ? null
                          : (s) => _setMode(s.first),
                    ),
                    const SizedBox(height: 16),
                    if (_register) ...[
                      TextField(
                        key: const Key('reg-name'),
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Имя'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('reg-phone'),
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: 'Телефон'),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      key: const Key('login-email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Почта'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('login-password'),
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Пароль'),
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_tgCodeNonce != null) ...[
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('tg-code'),
                        controller: _tgCode,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24, letterSpacing: 8),
                        decoration: const InputDecoration(
                          labelText: 'Код из Telegram-бота',
                          counterText: '',
                        ),
                        onSubmitted: (_) => _submitTgCode(),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('tg-code-submit'),
                          onPressed: _busy ? null : _submitTgCode,
                          child: const Text('Подтвердить код'),
                        ),
                      ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: NoxColors.bad),
                        ),
                      ),
                    if (_info != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _info!,
                          style: const TextStyle(color: NoxColors.ok),
                        ),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy || waitingTg ? null : _submit,
                        child: Text(_register ? 'Зарегистрироваться' : 'Войти'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: waitingTg
                          ? OutlinedButton(
                              onPressed: _cancelTelegram,
                              child: const Text('Отменить вход через Telegram'),
                            )
                          : OutlinedButton.icon(
                              key: const Key('login-telegram'),
                              onPressed: _busy ? null : _telegram,
                              icon: const Icon(Icons.send),
                              label: const Text('Войти через Telegram'),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// «версия 2.0.18» в углу экрана входа.
class _AppVersionLabel extends StatelessWidget {
  const _AppVersionLabel();

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
    future: PackageInfo.fromPlatform(),
    builder: (context, snap) {
      final info = snap.data;
      if (info == null) return const SizedBox.shrink();
      return Text(
        'версия ${info.version}',
        key: const Key('login-version'),
        style: const TextStyle(color: NoxColors.metalMid, fontSize: 12),
      );
    },
  );
}
