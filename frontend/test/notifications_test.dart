import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/nodos/data/live_updates_controller.dart';
import 'package:frontend/features/nodos/data/meeting_link.dart';
import 'package:frontend/features/nodos/data/notifications_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/notifications_panel.dart';
import 'meeting_link_test.dart' show FakeLinks, meeting;

Map<String, dynamic> item(
  String id, {
  String type = 'recordatorio_5',
  String node = 'n1',
  String nodeName = 'Ingeniería',
  bool read = false,
  String created = '2026-10-01T14:56:00Z',
}) => {
  'id': id,
  'tipo': type,
  'nodo_id': node,
  'nodo_nombre': nodeName,
  'reunion_id': '6eaec5ae-a89e-4dfa-bc76-40dc4bde44ce',
  'titulo': 'Daily $id',
  'programada_para': '2026-10-01T15:00:00Z',
  'created_at': created,
  'read_at': read ? '2026-10-01T15:01:00Z' : null,
  'reunion_estado': 'scheduled',
};

/// Captura la petición y responde con un cuerpo fijo.
class CaptureAdapter implements HttpClientAdapter {
  CaptureAdapter(this.body);
  final Map<String, dynamic> body;
  RequestOptions? last;
  Object? lastData;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    lastData = options.data;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class FakeNotifications extends NotificationsRepository {
  FakeNotifications(this.items);
  List<AppNotification> items;
  final read = <String>[];
  bool readAll = false;
  @override
  Future<List<AppNotification>> today({DateTime? now}) async => items;
  @override
  Future<void> markRead(List<String> ids) async => read.addAll(ids);
  @override
  Future<void> markAllRead() async => readAll = true;
}

Map<String, dynamic> snapshot({int unread = 0, String? latest}) => {
  'type': 'live_snapshot',
  'user_id': 'me',
  'presence': {'me': 'available'},
  'meetings': [],
  'notifications': {'unread': unread, 'latest': latest},
  'truncated': false,
};

void main() {
  test('reminder text uses the device time zone and type labels', () {
    final n = AppNotification.fromJson(item('a'));
    final local = DateTime.utc(2026, 10, 1, 15).toLocal();
    final hour =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    expect(n.message, '«Daily a» empieza a las $hour');
    expect(n.kindLabel, 'Recordatorio · 5 min antes');
    expect(
      AppNotification.fromJson(item('b', type: 'reunion_iniciada')).message,
      '«Daily b» ya comenzó',
    );
    expect(n.unread, isTrue);
    expect(n.markedRead().unread, isFalse);
  });

  test('today asks from local midnight and marks only what is sent', () async {
    final adapter = CaptureAdapter({
      'notificaciones': [item('a')],
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = adapter;
    final repo = NotificationsRepository(client: dio);
    final now = DateTime(2026, 10, 1, 9, 30);
    final items = await repo.today(now: now);
    expect(items.single.id, 'a');
    expect(
      adapter.last!.queryParameters['desde'],
      DateTime(2026, 10, 1).toUtc().toIso8601String(),
    );
    await repo.markRead(['a']);
    expect(adapter.last!.path, '/notificaciones/leidas');
    expect(adapter.lastData, {
      'ids': ['a'],
    });
    await repo.markAllRead();
    expect(adapter.lastData, {'todas': true});
  });

  test(
    'live snapshots update the count and announce only new arrivals',
    () async {
      final live = LiveUpdatesController(
        ticket: () async => throw StateError('offline'),
      );
      addTearDown(live.dispose);
      var arrivals = 0;
      final sub = live.notificationArrivals.listen((_) => arrivals++);
      addTearDown(sub.cancel);

      expect(live.applySnapshot(snapshot(unread: 2, latest: 'old')), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(live.unreadNotifications, 2);
      expect(arrivals, 0, reason: 'lo que ya existía no se anuncia');

      live.applySnapshot(snapshot(unread: 2, latest: 'old'));
      await Future<void>.delayed(Duration.zero);
      expect(arrivals, 0);

      live.applySnapshot(snapshot(unread: 3, latest: 'new'));
      await Future<void>.delayed(Duration.zero);
      expect(arrivals, 1);
      expect(live.unreadNotifications, 3);

      // Datos inválidos no rompen la instantánea ni el contador.
      final bad = snapshot()..['notifications'] = {'unread': -1};
      expect(live.applySnapshot(bad), isTrue);
      expect(live.unreadNotifications, 3);
    },
  );

  testWidgets('the bell shows the unread count', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NotificationsBell(unread: 3, onPressed: () {})),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.byTooltip('Notificaciones, 3 sin leer'), findsOneWidget);
  });

  Future<FakeNotifications> openPanel(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakeNotifications([
      AppNotification.fromJson(item('a', created: '2026-10-01T14:58:00Z')),
      AppNotification.fromJson(
        item('b', node: 'n2', nodeName: 'Redes', type: 'recordatorio_15'),
      ),
      AppNotification.fromJson(item('c', read: true)),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNotificationsPanel(
                context,
                repository: repo,
                meetings: FakeLinks(MeetingFound(meeting())),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('groups the day by node and filters unread', (tester) async {
    await openPanel(tester);
    expect(find.text('Ingeniería'), findsOneWidget);
    expect(find.text('Redes'), findsOneWidget);
    expect(find.textContaining('Daily'), findsNWidgets(3));
    await tester.tap(find.text('No leídas (2)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Daily c'), findsNothing);
    expect(find.textContaining('Daily a'), findsOneWidget);
  });

  testWidgets('opening a notification marks it read and shows the meeting', (
    tester,
  ) async {
    final repo = await openPanel(tester);
    await tester.tap(find.textContaining('Daily a'));
    await tester.pumpAndSettle();
    expect(repo.read, ['a']);
    expect(find.text('Revisión del Sprint 4'), findsOneWidget);
    await tester.tap(find.text('Cerrar').last);
    await tester.pumpAndSettle();
    expect(find.text('No leídas (1)'), findsOneWidget);
    await tester.tap(find.text('Marcar todas como leídas'));
    await tester.pumpAndSettle();
    expect(repo.readAll, isTrue);
    expect(find.text('No leídas'), findsOneWidget);
  });
}
