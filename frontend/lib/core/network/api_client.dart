import 'package:dio/dio.dart';
import '../security/secure_vault.dart';
import 'session_interceptor.dart';

class _VaultTokens implements SessionTokens {
  @override
  int get generation => SecureVault.generation;
  @override
  Future<String?> access() => SecureVault.getAccessToken();
  @override
  Future<String?> refresh() => SecureVault.getRefreshToken();
  @override
  Future<bool> replace(String expectedRefresh, String access, String refresh) =>
      SecureVault.replaceTokens(expectedRefresh, access, refresh);
  @override
  Future<void> clear() => SecureVault.clearAuthData();
}

class ApiClient {
  static const _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080',
  );
  static String get baseUrl => _baseUrl;
  static BaseOptions _options() => BaseOptions(
    baseUrl: _baseUrl,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
  );
  static final Dio instance = _initDio();
  static late final SessionInterceptor _session;
  static Dio _initDio() {
    final dio = Dio(_options());
    _session = SessionInterceptor(dio, Dio(_options()), _VaultTokens());
    dio.interceptors.add(_session);
    return dio;
  }

  static Future<void> logout() {
    // Fuerza el inicializador lazy antes de acceder al coordinador.
    final client = instance;
    return (client.interceptors.whereType<SessionInterceptor>().single)
        .logout();
  }
}
