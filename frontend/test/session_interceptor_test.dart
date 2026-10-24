import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/network/session_interceptor.dart';

class MemoryTokens implements SessionTokens {
  String? accessToken = 'old-access';
  String? refreshToken = 'old-refresh';
  @override
  int generation = 0;
  @override
  Future<String?> access() async => accessToken;
  @override
  Future<String?> refresh() async => refreshToken;
  @override
  Future<void> clear() async {
    generation++;
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<bool> replace(String expected, String access, String refresh) async {
    if (refreshToken != expected) return false;
    accessToken = access;
    refreshToken = refresh;
    return true;
  }
}

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody response(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);
ResponseBody expired() => response(401, {'code': 'invalid_access_token'});
ResponseBody renewed() => response(200, {
  'success': true,
  'access_token': 'new-access',
  'refresh_token': 'new-refresh',
});

void main() {
  late Dio api;
  late Dio auth;
  late MemoryTokens tokens;
  late SessionInterceptor session;
  late int renewals;
  setUp(() {
    tokens = MemoryTokens();
    renewals = 0;
    api = Dio(BaseOptions(baseUrl: 'http://example.invalid'));
    auth = Dio(BaseOptions(baseUrl: 'http://example.invalid'));
    session = SessionInterceptor(api, auth, tokens);
    api.interceptors.add(session);
    api.httpClientAdapter = FakeAdapter(
      (r) async => r.headers['Authorization'] == 'Bearer new-access'
          ? response(200, {'ok': true})
          : expired(),
    );
    auth.httpClientAdapter = FakeAdapter((r) async {
      renewals++;
      return renewed();
    });
  });
  tearDown(() {
    api.close(force: true);
    auth.close(force: true);
  });

  test('renews once and replays the original method, body and query', () async {
    api.httpClientAdapter = FakeAdapter((r) async {
      if (r.headers['Authorization'] != 'Bearer new-access') return expired();
      expect(r.method, 'POST');
      expect(r.data, {'contenido': 'hello'});
      expect(r.queryParameters, {'subgrupo_id': 'group'});
      return response(201, {'ok': true});
    });
    expect(
      (await api.post<dynamic>(
        '/nodos/1/mensajes',
        data: {'contenido': 'hello'},
        queryParameters: {'subgrupo_id': 'group'},
      )).statusCode,
      201,
    );
    expect(renewals, 1);
    expect(tokens.refreshToken, 'new-refresh');
  });

  test('concurrent failures share one refresh request', () async {
    final release = Completer<void>();
    auth.httpClientAdapter = FakeAdapter((r) async {
      renewals++;
      await release.future;
      return renewed();
    });
    final pending = List.generate(8, (_) => api.get<dynamic>('/nodos'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    release.complete();
    final results = await Future.wait(pending);
    expect(results.every((r) => r.statusCode == 200), true);
    expect(renewals, 1);
  });

  test('late failure uses the token already renewed', () async {
    final late = Completer<void>();
    api.httpClientAdapter = FakeAdapter((r) async {
      if (r.headers['Authorization'] == 'Bearer new-access') {
        return response(200, {});
      }
      if (r.path == '/late') await late.future;
      return expired();
    });
    final pending = api.get<dynamic>('/late');
    await api.get<dynamic>('/nodos');
    late.complete();
    await pending;
    expect(renewals, 1);
  });

  test('invalid refresh clears local session', () async {
    auth.httpClientAdapter = FakeAdapter(
      (r) async => response(401, {'success': false}),
    );
    await expectLater(api.get<dynamic>('/nodos'), throwsA(isA<DioException>()));
    expect(tokens.accessToken, isNull);
    expect(tokens.refreshToken, isNull);
  });

  test('server outage preserves local session', () async {
    auth.httpClientAdapter = FakeAdapter((r) async => response(503, {}));
    await expectLater(api.get<dynamic>('/nodos'), throwsA(isA<DioException>()));
    expect(tokens.accessToken, 'old-access');
    expect(tokens.refreshToken, 'old-refresh');
  });

  test(
    'public login and business 401 never refresh or erase session',
    () async {
      await expectLater(
        api.post<dynamic>('/login'),
        throwsA(isA<DioException>()),
      );
      api.httpClientAdapter = FakeAdapter(
        (r) async => response(401, {'message': 'wrong password'}),
      );
      await expectLater(
        api.put<dynamic>('/users/me/password'),
        throwsA(isA<DioException>()),
      );
      expect(renewals, 0);
      expect(tokens.accessToken, 'old-access');
    },
  );

  test('persistent access rejection cannot loop indefinitely', () async {
    var requests = 0;
    api.httpClientAdapter = FakeAdapter((r) async {
      requests++;
      return expired();
    });
    await expectLater(api.get<dynamic>('/nodos'), throwsA(isA<DioException>()));
    expect(requests, 2);
    expect(renewals, 1);
  });

  test(
    'a response from an earlier login cannot replay as a new user',
    () async {
      final received = Completer<void>();
      final release = Completer<void>();
      api.httpClientAdapter = FakeAdapter((r) async {
        received.complete();
        await release.future;
        return expired();
      });
      final pending = api.get<dynamic>('/nodos');
      final assertion = expectLater(pending, throwsA(isA<DioException>()));
      await received.future;
      tokens.generation++;
      tokens.accessToken = 'other-access';
      tokens.refreshToken = 'other-refresh';
      release.complete();
      await assertion;
      expect(renewals, 0);
      expect(tokens.accessToken, 'other-access');
    },
  );

  test('logout waits for rotation and revokes the replacement', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    String? revoked;
    auth.httpClientAdapter = FakeAdapter((r) async {
      if (r.path == '/refresh') {
        started.complete();
        await release.future;
        return renewed();
      }
      revoked = (r.data as Map)['refresh_token'] as String;
      return response(204, {});
    });
    final assertion = expectLater(
      api.get<dynamic>('/nodos'),
      throwsA(isA<DioException>()),
    );
    await started.future;
    final logout = session.logout();
    release.complete();
    await logout;
    await assertion;
    expect(revoked, 'new-refresh');
    expect(tokens.accessToken, isNull);
  });

  test(
    'offline logout clears local state and reports revocation failure',
    () async {
      auth.httpClientAdapter = FakeAdapter(
        (r) async => throw DioException(
          requestOptions: r,
          type: DioExceptionType.connectionError,
        ),
      );
      await expectLater(session.logout(), throwsA(isA<DioException>()));
      expect(tokens.accessToken, isNull);
    },
  );
}
