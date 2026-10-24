import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/security/secure_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final values = <String, String>{};
  Future<void> save(String refresh) => SecureVault.saveAuthData(
    accessToken: 'access',
    refreshToken: refresh,
    username: 'Test',
    email: 'test@example.invalid',
    role: 'MEMBER',
    userId: 'user',
    rememberMe: true,
  );
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          final key = args['key'] as String;
          if (call.method == 'write') values[key] = args['value'] as String;
          if (call.method == 'delete') values.remove(key);
          if (call.method == 'read') return values[key];
          return null;
        });
    await SecureVault.clearAuthData();
  });
  tearDown(() async {
    await SecureVault.clearAuthData();
  });

  test(
    'rotation keeps profile and remember-me and stores one token pair',
    () async {
      await save('old');
      final generation = SecureVault.generation;
      expect(
        await SecureVault.replaceTokens('old', 'new-access', 'new-refresh'),
        true,
      );
      expect(await SecureVault.getUsername(), 'Test');
      expect(await SecureVault.getRememberMe(), true);
      expect(SecureVault.generation, generation);
      expect(jsonDecode(values['session_tokens']!), {
        'access_token': 'new-access',
        'refresh_token': 'new-refresh',
      });
    },
  );
  test(
    'new login prevents an older refresh response from replacing credentials',
    () async {
      await save('old');
      await save('another-session');
      expect(await SecureVault.replaceTokens('old', 'stale', 'stale'), false);
      expect(await SecureVault.getRefreshToken(), 'another-session');
    },
  );
  test('queued logout wins over a pending token write', () async {
    await save('old');
    final pending = SecureVault.replaceTokens('old', 'new', 'new');
    final cleared = SecureVault.clearAuthData();
    await pending;
    await cleared;
    expect(await SecureVault.getAccessToken(), isNull);
    expect(await SecureVault.getRefreshToken(), isNull);
    expect(values, isEmpty);
  });
  test('legacy tokens are readable until the first rotation', () async {
    values['access_token'] = 'legacy-access';
    values['refresh_token'] = 'legacy-refresh';
    expect(await SecureVault.getAccessToken(), 'legacy-access');
    expect(
      await SecureVault.replaceTokens('legacy-refresh', 'new', 'rotated'),
      true,
    );
    expect(jsonDecode(values['session_tokens']!)['refresh_token'], 'rotated');
  });
}
