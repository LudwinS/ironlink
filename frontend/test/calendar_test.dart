import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/features/nodos/data/calendar_repository.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/data/reuniones_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/calendar_workspace.dart';

final now = DateTime(2026, 10, 1);
final node = Nodo(
  id: 'node',
  nombre: 'Ingeniería de software',
  tokenAcceso: '',
  creadorId: 'owner',
  estado: 'active',
  miembrosCount: 3,
  createdAt: now,
  rol: 'MEMBER',
);
CalendarMeeting event(
  String id, {
  int day = 1,
  String state = 'scheduled',
  bool canJoin = true,
}) => CalendarMeeting(
  reunion: Reunion(
    id: id,
    nodoId: 'node',
    titulo: 'Reunión $id',
    fechaInicio: DateTime(2026, 10, day, 9),
    creadoPor: 'owner',
    creadorNombre: 'Organizador',
    createdAt: now,
    rtcEstado: state,
  ),
  nodeName: node.nombre,
  canModerate: false,
  canJoin: canJoin,
);

class FakeCalendar extends CalendarRepository {
  final calls = <(DateTime, String?)>[];
  CalendarResult result = CalendarResult([
    event('one'),
    event('two', day: 2, state: 'active'),
  ]);
  bool fail = false;
  Completer<CalendarResult>? pending;
  @override
  Future<CalendarResult> fetchMonth(DateTime month, {String? nodeId}) async {
    calls.add((month, nodeId));
    if (fail) throw StateError('unavailable');
    if (pending != null) return pending!.future;
    return result;
  }
}

Widget page(
  FakeCalendar repository, {
  bool active = true,
  ValueChanged<CalendarMeeting>? onJoin,
  List<Nodo>? nodes,
}) => MaterialApp(
  home: Scaffold(
    body: CalendarWorkspace(
      nodos: nodes ?? [node],
      active: active,
      repository: repository,
      now: now,
      onJoin: onJoin ?? (_) {},
    ),
  ),
);

void main() {
  tearDown(LivePresence.clear);
  test(
    'calendar repository uses local month bounds converted to UTC and server permissions',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost'));
      RequestOptions? request;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'truncated': true,
                  'reuniones': [
                    {
                      'id': 'meeting',
                      'nodo_id': 'node',
                      'nodo_nombre': 'Nodo',
                      'titulo': 'Planificación',
                      'fecha_inicio': '2026-10-01T15:00:00Z',
                      'creado_por': 'owner',
                      'creador_nombre': 'Owner',
                      'created_at': '2026-09-30T15:00:00Z',
                      'rtc_estado': 'active',
                      'can_join': true,
                      'can_moderate': false,
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final result = await CalendarRepository(
        client: dio,
      ).fetchMonth(DateTime(2026, 10, 12), nodeId: 'node');
      expect(request!.path, '/calendar/meetings');
      expect(
        request!.queryParameters['from'],
        DateTime(2026, 10).toUtc().toIso8601String(),
      );
      expect(
        request!.queryParameters['to'],
        DateTime(2026, 11).toUtc().toIso8601String(),
      );
      expect(request!.queryParameters['node_id'], 'node');
      expect(result.truncated, true);
      expect(result.meetings.single.canJoin, true);
      expect(result.meetings.single.canModerate, false);
      dio.close();
    },
  );
  for (final width in [320.0, 390.0, 800.0, 1280.0]) {
    testWidgets(
      'calendar fits $width px at 130 percent text and filters a date',
      (tester) async {
        // Alto suficiente para la agenda con sus acciones; se mide el ancho.
        tester.view.physicalSize = Size(width, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = FakeCalendar();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: CalendarWorkspace(
                nodos: [node],
                active: true,
                repository: repo,
                now: now,
                onJoin: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Reunión one'), findsOneWidget);
        expect(find.text('Reunión two'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '1'));
        await tester.pumpAndSettle();
        expect(find.text('Reunión one'), findsOneWidget);
        expect(find.text('Reunión two'), findsNothing);
        await tester.tap(find.text('Todo el mes'));
        await tester.pumpAndSettle();
        expect(find.text('Reunión two'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'inactive calendar does not fetch; activation loads and ignores late results after exit',
    (tester) async {
      final repo = FakeCalendar();
      await tester.pumpWidget(page(repo, active: false));
      expect(repo.calls, isEmpty);
      repo.pending = Completer<CalendarResult>();
      await tester.pumpWidget(page(repo));
      await tester.pump();
      expect(repo.calls.length, 1);
      await tester.pumpWidget(page(repo, active: false));
      repo.pending!.complete(repo.result);
      await tester.pumpAndSettle();
      expect(find.text('Reunión one'), findsNothing);
    },
  );
  testWidgets('newer month wins over a delayed previous month', (tester) async {
    final repo = FakeCalendar();
    repo.pending = Completer<CalendarResult>();
    final old = repo.pending!;
    await tester.pumpWidget(page(repo));
    await tester.pump();
    repo.pending = null;
    repo.result = const CalendarResult([]);
    await tester.tap(find.byTooltip('Mes siguiente'));
    await tester.pumpAndSettle();
    expect(repo.calls.last.$1, DateTime(2026, 11));
    old.complete(CalendarResult([event('stale')]));
    await tester.pumpAndSettle();
    expect(find.text('Reunión stale'), findsNothing);
    expect(find.text('Noviembre 2026'), findsOneWidget);
  });
  testWidgets(
    'authorization roster removal clears data and reloads without old filter',
    (tester) async {
      final repo = FakeCalendar();
      await tester.pumpWidget(page(repo));
      await tester.pumpAndSettle();
      expect(find.text('Reunión one'), findsOneWidget);
      repo.result = const CalendarResult([]);
      await tester.pumpWidget(page(repo, nodes: []));
      await tester.pumpAndSettle();
      expect(find.text('Reunión one'), findsNothing);
      expect(repo.calls.length, 2);
    },
  );
  testWidgets('node dropdown sends filter to server', (tester) async {
    final repo = FakeCalendar();
    await tester.pumpWidget(page(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(node.nombre).last);
    await tester.pumpAndSettle();
    expect(repo.calls.last.$2, 'node');
  });
  testWidgets('failure is explicit and retry recovers without stale meetings', (
    tester,
  ) async {
    final repo = FakeCalendar()..fail = true;
    await tester.pumpWidget(page(repo));
    await tester.pumpAndSettle();
    expect(find.text('No se pudo cargar el calendario.'), findsOneWidget);
    expect(find.text('Reunión one'), findsNothing);
    repo.fail = false;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('Reunión one'), findsOneWidget);
  });
  testWidgets(
    'join uses actual meeting, respects server denial and active call presence',
    (tester) async {
      final repo = FakeCalendar();
      repo.result = CalendarResult([event('live', state: 'active')]);
      CalendarMeeting? joined;
      await tester.pumpWidget(page(repo, onJoin: (e) => joined = e));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Unirse ahora'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unirse ahora'));
      expect(joined?.reunion.id, 'live');
      LivePresence.selfId = 'self';
      LivePresence.values.value = {'self': 'in_call'};
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Unirse ahora'))
            .onPressed,
        isNull,
      );
      LivePresence.clear();
      repo.result = CalendarResult([
        event('kicked', state: 'active', canJoin: false),
      ]);
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Actualizar calendario'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Unirse ahora'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('truncated and empty responses are visible', (tester) async {
    final repo = FakeCalendar()
      ..result = const CalendarResult([], truncated: true);
    await tester.pumpWidget(page(repo));
    await tester.pumpAndSettle();
    expect(find.textContaining('primeras 500'), findsOneWidget);
    expect(find.text('No hay reuniones en este intervalo.'), findsOneWidget);
  });
}
