import 'package:dio/dio.dart';

abstract interface class SessionTokens {
  int get generation;
  Future<String?> access();
  Future<String?> refresh();
  Future<bool> replace(String expectedRefresh, String access, String refresh);
  Future<void> clear();
}

/// Comparte una renovación entre solicitudes y limita cada petición a un reintento.
class SessionInterceptor extends Interceptor {
  SessionInterceptor(this.client, this.authClient, this.tokens);
  final Dio client;
  final Dio authClient;
  final SessionTokens tokens;
  Future<String?>? _refreshing;
  bool _loggingOut = false;
  static const _public = {
    '/login',
    '/register',
    '/refresh',
    '/logout',
    '/request-verification',
    '/verify-email',
    '/forgot-password',
    '/reset-password',
  };
  bool _isPublic(String path) =>
      _public.contains(path) || path.startsWith('/verify-link/');

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      options.extra.putIfAbsent('sessionGeneration', () => tokens.generation);
      if (!_isPublic(options.path) && !_loggingOut) {
        final access = await tokens.access();
        if (access != null && access.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $access';
        }
      }
      handler.next(options);
    } catch (error) {
      handler.reject(DioException(requestOptions: options, error: error));
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final error = err;
    final request = error.requestOptions;
    final data = error.response?.data;
    if (_loggingOut ||
        request.extra['sessionGeneration'] != tokens.generation ||
        _isPublic(request.path) ||
        request.extra['sessionRetried'] == true ||
        error.response?.statusCode != 401 ||
        data is! Map ||
        data['code'] != 'invalid_access_token') {
      handler.next(error);
      return;
    }
    try {
      var access = await tokens.access();
      if (access == null) {
        handler.next(error);
        return;
      }
      if (request.headers['Authorization'] == 'Bearer $access') {
        final pending = _refreshing ??= _renew();
        try {
          access = await pending;
        } finally {
          if (identical(_refreshing, pending)) _refreshing = null;
        }
      }
      if (_loggingOut ||
          request.extra['sessionGeneration'] != tokens.generation ||
          access == null ||
          await tokens.access() != access) {
        handler.next(error);
        return;
      }
      final retry = request.copyWith(
        headers: {...request.headers, 'Authorization': 'Bearer $access'},
        extra: {...request.extra, 'sessionRetried': true},
      );
      handler.resolve(await client.fetch<dynamic>(retry));
    } on DioException catch (failure) {
      handler.next(failure);
    } catch (failure) {
      handler.next(DioException(requestOptions: request, error: failure));
    }
  }

  Future<String?> _renew() async {
    final oldRefresh = await tokens.refresh();
    if (oldRefresh == null || oldRefresh.isEmpty) {
      await tokens.clear();
      return null;
    }
    try {
      final response = await authClient.post<dynamic>(
        '/refresh',
        data: {'refresh_token': oldRefresh},
      );
      final data = response.data;
      if (data is! Map ||
          data['success'] != true ||
          data['access_token'] is! String ||
          data['refresh_token'] is! String ||
          (data['access_token'] as String).isEmpty ||
          (data['refresh_token'] as String).isEmpty) {
        throw const FormatException('Respuesta de renovación inválida');
      }
      final access = data['access_token'] as String;
      return await tokens.replace(
            oldRefresh,
            access,
            data['refresh_token'] as String,
          )
          ? access
          : null;
    } on DioException catch (error) {
      // Una caída de red o del servidor no elimina la sesión local.
      if (error.response?.statusCode == 401 &&
          await tokens.refresh() == oldRefresh) {
        await tokens.clear();
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    _loggingOut = true;
    try {
      try {
        await _refreshing;
      } catch (_) {
        /* Revocar el token disponible. */
      }
      final refresh = await tokens.refresh();
      if (refresh != null) {
        await authClient.post<dynamic>(
          '/logout',
          data: {'refresh_token': refresh},
        );
      }
    } finally {
      try {
        await tokens.clear();
      } finally {
        _loggingOut = false;
      }
    }
  }
}
