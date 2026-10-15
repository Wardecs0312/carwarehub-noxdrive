import 'dart:async';

import 'package:carwarehub_noxdrive/data/auth_repository.dart';
import 'package:carwarehub_noxdrive/data/catalog_repository.dart';
import 'package:carwarehub_noxdrive/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _mandatory = AppRelease(
  version: '2.0.15',
  buildNumber: 15,
  isMandatory: true,
  downloadPath: 'windows/2.0.15+15.zip',
);

/// Как настоящая база: список версий виден только после входа.
class _FakeCatalog extends CatalogRepository {
  bool loggedIn = false;
  int calls = 0;

  @override
  Future<AppRelease?> availableUpdate() async {
    calls++;
    return loggedIn ? _mandatory : null;
  }
}

Session _session(String userId) => Session(
  accessToken: 'token',
  tokenType: 'bearer',
  user: User(
    id: userId,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-10-15T00:00:00Z',
  ),
);

void main() {
  test(
    'после входа обязательное обновление находится без перезапуска',
    () async {
      final catalog = _FakeCatalog();
      final sessions = StreamController<Session?>();
      final c = ProviderContainer(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(catalog),
          sessionProvider.overrideWith((_) => sessions.stream),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(sessions.close);
      c.listen(updateProvider, (_, _) {});

      sessions.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(await c.read(updateProvider.future), isNull, reason: 'до входа');

      catalog.loggedIn = true;
      sessions.add(_session('master-1'));
      await Future<void>.delayed(Duration.zero);
      final update = await c.read(updateProvider.future);
      expect(update?.isMandatory, isTrue, reason: 'после входа');
      expect(catalog.calls, greaterThanOrEqualTo(2));
    },
  );

  test('обновление токена той же сессии не вызывает лишних проверок', () async {
    final catalog = _FakeCatalog()..loggedIn = true;
    final sessions = StreamController<Session?>();
    final c = ProviderContainer(
      overrides: [
        catalogRepositoryProvider.overrideWithValue(catalog),
        sessionProvider.overrideWith((_) => sessions.stream),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(sessions.close);
    c.listen(updateProvider, (_, _) {});

    sessions.add(_session('master-1'));
    await Future<void>.delayed(Duration.zero);
    await c.read(updateProvider.future);
    final before = catalog.calls;

    sessions.add(_session('master-1')); // тот же пользователь, новый токен
    await Future<void>.delayed(Duration.zero);
    await c.read(updateProvider.future);
    expect(catalog.calls, before);
  });
}
