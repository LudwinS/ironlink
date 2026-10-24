import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/nodos/data/breakout_repository.dart';
import 'package:frontend/features/nodos/data/reuniones_repository.dart';
import 'package:frontend/features/nodos/data/rtc_call_controller.dart';
import 'package:frontend/features/nodos/presentation/widgets/breakout_dialog.dart';
import 'notifications_test.dart' show CaptureAdapter;

Map<String, dynamic> stateJson({bool open = false}) => {
  'salas': open
      ? [
          {
            'id': 's1',
            'nombre': 'Sala 1',
            'miembros': [
              {'user_id': 'ana', 'nombre': 'Ana'},
            ],
          },
        ]
      : [],
  'mi_sala': null,
  'puede_moderar': true,
  'capacidad_por_sala': 3,
  'conectados': [
    {'user_id': 'me', 'nombre': 'Yo', 'sala_id': null},
    {'user_id': 'ana', 'nombre': 'Ana', 'sala_id': open ? 's1' : null},
    {'user_id': 'beto', 'nombre': 'Beto', 'sala_id': null},
    {'user_id': 'carla', 'nombre': 'Carla', 'sala_id': null},
    {'user_id': 'dani', 'nombre': 'Dani', 'sala_id': null},
  ],
};

class FakeBreakouts extends BreakoutRepository {
  bool isOpen = false;
  List<BreakoutDraft>? opened;
  bool closed = false;
  @override
  Future<BreakoutState> fetch(String nodeId, String reunionId) async =>
      BreakoutState.fromJson(stateJson(open: isOpen));
  @override
  Future<BreakoutState> open(
    String nodeId,
    String reunionId,
    List<BreakoutDraft> rooms,
  ) async {
    opened = rooms;
    isOpen = true;
    return BreakoutState.fromJson(stateJson(open: true));
  }

  @override
  Future<BreakoutState> close(String nodeId, String reunionId) async {
    closed = true;
    isOpen = false;
    return BreakoutState.fromJson(stateJson());
  }
}

void main() {
  reconnectionTests();
  test('targets parse the server assignment and compare by id', () {
    expect(BreakoutTarget.parse(null).isMain, isTrue);
    final room = BreakoutTarget.parse({'id': 's1', 'nombre': 'Diseño'});
    expect(room.name, 'Diseño');
    expect(room, const BreakoutTarget('s1', 'otro nombre'));
    expect(room == BreakoutTarget.main, isFalse);
  });

  test('distribution alternates rooms and respects capacity', () {
    final people = ['a', 'b', 'c', 'd', 'e'];
    var (rooms, left) = BreakoutRepository.distribute(people, 2, 3);
    expect(rooms.map((r) => r.members), [
      ['a', 'c', 'e'],
      ['b', 'd'],
    ]);
    expect(left, isEmpty);
    (rooms, left) = BreakoutRepository.distribute(people, 2, 2);
    expect(left, ['e']);
    expect(rooms.first.name, 'Sala 1');
  });

  test('opening rooms sends names and members', () async {
    final adapter = CaptureAdapter(stateJson(open: true));
    final repo = BreakoutRepository(
      client: Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = adapter,
    );
    final state = await repo.open('n', 'r', [
      BreakoutDraft('Diseño', ['ana']),
    ]);
    expect(adapter.last!.method, 'PUT');
    expect(adapter.last!.path, '/nodos/n/reuniones/r/salas');
    expect(adapter.lastData, {
      'salas': [
        {
          'nombre': 'Diseño',
          'miembros': ['ana'],
        },
      ],
    });
    expect(state.open, isTrue);
    expect(state.rooms.single.members.single.name, 'Ana');
    expect(state.connected.firstWhere((p) => p.userId == 'ana').salaId, 's1');
  });

  test('the call learns about assignments for other rooms only', () async {
    final main = RtcCallController('n', 'r', ReunionesRepository());
    addTearDown(main.dispose);
    await main.handleForTest(
      '{"type":"breakout","version":1,"sala":{"id":"s1","nombre":"Diseño"}}',
    );
    expect(main.pendingBreakout?.name, 'Diseño');
    await main.handleForTest('{"type":"breakout","version":1,"sala":null}');
    expect(main.pendingBreakout, isNull, reason: 'ya está en la principal');

    final inRoom = RtcCallController(
      'n',
      'r',
      ReunionesRepository(),
      salaId: 's1',
    );
    addTearDown(inRoom.dispose);
    await inRoom.handleForTest(
      '{"type":"breakout","version":1,"sala":{"id":"s1","nombre":"Diseño"}}',
    );
    expect(inRoom.pendingBreakout, isNull);
    await inRoom.handleForTest('{"type":"breakout","version":1,"sala":null}');
    expect(inRoom.pendingBreakout?.isMain, isTrue);
  });

  Future<BreakoutTarget?> openDialog(
    WidgetTester tester,
    FakeBreakouts repo,
    void Function(Future<BreakoutTarget?>) onResult,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onResult(
                showBreakoutDialog(
                  context,
                  nodoId: 'n',
                  reunionId: 'r',
                  ownUserId: 'me',
                  repository: repo,
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return null;
  }

  testWidgets('moderators plan rooms automatically and open them', (
    tester,
  ) async {
    final repo = FakeBreakouts();
    await openDialog(tester, repo, (_) {});
    // El moderador no se reparte a sí mismo.
    expect(find.text('Yo'), findsNothing);
    expect(find.text('Ana'), findsOneWidget);
    await tester.tap(find.text('Abrir salas'));
    await tester.pumpAndSettle();
    expect(repo.opened!.map((r) => r.members), [
      ['ana', 'carla'],
      ['beto', 'dani'],
    ]);
    expect(find.text('Cerrar todas las salas'), findsOneWidget);
  });

  testWidgets('a room over capacity cannot be opened', (tester) async {
    final repo = FakeBreakouts();
    await openDialog(tester, repo, (_) {});
    await tester.tap(find.byTooltip('Menos salas'));
    await tester.pumpAndSettle();
    // Con una sala caben 3; la cuarta persona queda en la principal.
    expect(find.textContaining('supera'), findsNothing);
    await tester.tap(find.text('Sala principal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sala 1').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('supera el máximo de 3'), findsOneWidget);
    final open = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Abrir salas'),
    );
    expect(open.onPressed, isNull);
  });

  testWidgets('open rooms can be visited or closed', (tester) async {
    final repo = FakeBreakouts()..isOpen = true;
    Future<BreakoutTarget?>? result;
    await openDialog(tester, repo, (r) => result = r);
    expect(find.text('Ana (en la sala)'), findsOneWidget);
    await tester.tap(find.text('Visitar'));
    await tester.pumpAndSettle();
    expect((await result)?.id, 's1');

    await openDialog(tester, repo, (r) => result = r);
    await tester.tap(find.text('Cerrar todas las salas'));
    await tester.pumpAndSettle();
    expect(repo.closed, isTrue);
    expect(find.text('Abrir salas'), findsOneWidget);
  });
}

class _TicketRefused extends ReunionesRepository {
  int calls = 0;
  @override
  Future<String> issueRtcTicket({
    required String nodoId,
    required String reunionId,
    String? salaId,
  }) async {
    calls++;
    throw DioException(
      requestOptions: RequestOptions(path: '/rtc-ticket'),
      response: Response(
        requestOptions: RequestOptions(path: '/rtc-ticket'),
        statusCode: 403,
      ),
    );
  }
}

void reconnectionTests() {
  test(
    'a session renewal reconnects and explains when the meeting ended',
    () async {
      final repo = _TicketRefused();
      final call = RtcCallController('n', 'r', repo);
      addTearDown(call.dispose);
      await call.handleForTest('{"type":"session_renew"}');
      await call.signalingLostForTest();
      expect(repo.calls, 1, reason: 'pidió un pase nuevo sin esperar');
      expect(call.error, 'La reunión terminó o ya no tienes acceso a ella.');
    },
  );

  test('a call opened elsewhere is not reconnected', () async {
    final repo = _TicketRefused();
    final call = RtcCallController('n', 'r', repo);
    addTearDown(call.dispose);
    await call.handleForTest('{"type":"replaced"}');
    await call.signalingLostForTest();
    expect(repo.calls, 0);
    expect(
      call.error,
      'Entraste a esta llamada desde otra ventana o dispositivo.',
    );
  });
}
