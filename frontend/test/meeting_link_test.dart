import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/features/nodos/data/calendar_repository.dart';
import 'package:frontend/features/nodos/data/meeting_link.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/data/reuniones_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/calendar_workspace.dart';
import 'package:frontend/features/nodos/presentation/widgets/meeting_link_widgets.dart';

const id = '6eaec5ae-a89e-4dfa-bc76-40dc4bde44ce';

CalendarMeeting meeting({String state = 'scheduled', bool moderate = false}) =>
    CalendarMeeting(
      reunion: Reunion(
        id: id,
        nodoId: 'node',
        titulo: 'Revisión del Sprint 4',
        fechaInicio: DateTime(2026, 10, 1, 9),
        creadoPor: 'owner',
        creadorNombre: 'Organizador',
        createdAt: DateTime(2026, 9, 30),
        rtcEstado: state,
      ),
      nodeName: 'Ingeniería',
      canModerate: moderate,
      canJoin: true,
    );

class FakeLinks extends MeetingLinkRepository {
  FakeLinks(this.result);
  MeetingLookup result;
  int calls = 0;
  @override
  Future<MeetingLookup> resolve(String reunionId) async {
    calls++;
    return result;
  }
}

class FakeNodos extends NodosRepository {
  final sent = <(String, String)>[];
  @override
  Future<Mensaje> sendMensaje(
    String nodoId,
    String contenido, {
    String? subgrupoId,
  }) async {
    sent.add((nodoId, contenido));
    throw Exception('Sin conexión');
  }
}

/// Responde a GET /reuniones/{id} con un estado y cuerpo fijos.
class StatusAdapter implements HttpClientAdapter {
  StatusAdapter(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
  @override
  void close({bool force = false}) {}
}

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  tearDown(() => LivePresence.values.value = {});

  test('links carry only the meeting id and are found inside text', () {
    final link = MeetingLink.forMeeting(id);
    expect(link, endsWith('/#/reunion/$id'));
    expect(link, isNot(contains('token')));
    expect(MeetingLink.find('Únete: $link ¡nos vemos!'), id);
    expect(MeetingLink.find('Únete: ${link.toUpperCase()}'), id);
    expect(MeetingLink.find('/reunion/no-es-un-id'), isNull);
    expect(MeetingLink.find('/reunion/${id}0'), isNull);
    expect(MeetingLink.announcement(meeting()), contains(link));
  });

  test('the repository maps forbidden and missing to one message', () async {
    Future<MeetingLookup> withStatus(int status, Map<String, dynamic> body) {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = StatusAdapter(status, body);
      return MeetingLinkRepository(client: dio).resolve(id);
    }

    final found = await withStatus(200, {
      'reunion': {
        'id': id,
        'nodo_id': 'node',
        'nodo_nombre': 'Ingeniería',
        'titulo': 'Revisión',
        'fecha_inicio': '2026-10-01T15:00:00Z',
        'creado_por': 'owner',
        'creador_nombre': 'Organizador',
        'created_at': '2026-09-30T15:00:00Z',
        'rtc_estado': 'active',
        'can_moderate': false,
        'can_join': true,
      },
    });
    expect((found as MeetingFound).meeting.canJoin, isTrue);
    final missing = await withStatus(404, {'message': 'No existe.'});
    expect((missing as MeetingUnavailable).message, 'No existe.');
    final down = await withStatus(503, {});
    expect((down as MeetingUnavailable).message, contains('conexión'));
  });

  testWidgets('an active shared meeting can be joined with one click', (
    tester,
  ) async {
    CalendarMeeting? joined;
    final links = FakeLinks(MeetingFound(meeting(state: 'active')));
    await tester.pumpWidget(
      host(
        MeetingLinkCard(
          reunionId: id,
          repository: links,
          onJoin: (m) => joined = m,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unirse'));
    await tester.pumpAndSettle();
    expect(joined?.reunion.id, id);
    // Al volver se consulta de nuevo el estado de la reunión.
    expect(links.calls, 2);
  });

  testWidgets('cannot join while already in a call', (tester) async {
    LivePresence.selfId = 'me';
    LivePresence.values.value = {'me': 'in_call'};
    await tester.pumpWidget(
      host(
        MeetingLinkCard(
          reunionId: id,
          repository: FakeLinks(MeetingFound(meeting(state: 'active'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
    expect(find.text('Ya estás en una llamada'), findsOneWidget);
  });

  testWidgets('scheduled and unavailable meetings explain why', (tester) async {
    await tester.pumpWidget(
      host(
        MeetingLinkCard(
          reunionId: id,
          repository: FakeLinks(MeetingFound(meeting())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('cuando un moderador la inicie'),
      findsOneWidget,
    );
    expect(find.text('Unirse'), findsNothing);

    await tester.pumpWidget(
      host(
        MeetingLinkCard(
          key: const ValueKey('other'),
          reunionId: id,
          repository: FakeLinks(const MeetingUnavailable('No tienes acceso.')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No tienes acceso.'), findsOneWidget);
  });

  testWidgets('messages without a meeting link render unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const MessageWithMeetingLink(
          text: 'Hola equipo',
          child: Text('Hola equipo'),
        ),
      ),
    );
    expect(find.byType(MeetingLinkCard), findsNothing);
  });

  testWidgets('share dialog copies the link and reports a failed post', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    final nodos = FakeNodos();
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMeetingShareDialog(
              context,
              meeting(moderate: true),
              repository: nodos,
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copiar enlace'));
    await tester.pumpAndSettle();
    expect(copied, MeetingLink.forMeeting(id));
    expect(find.text('Enlace copiado.'), findsOneWidget);
    await tester.tap(find.text('Publicar en el canal'));
    await tester.pumpAndSettle();
    expect(nodos.sent.single.$1, 'node');
    expect(nodos.sent.single.$2, contains(MeetingLink.forMeeting(id)));
    expect(find.text('Sin conexión'), findsOneWidget);
  });

  testWidgets('anyone in the node can share; only moderators cancel', (
    tester,
  ) async {
    for (final moderate in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(moderate),
          home: Scaffold(
            body: CalendarWorkspace(
              nodos: const [],
              active: true,
              onJoin: (_) {},
              now: DateTime(2026, 10, 1),
              repository: _OneMeeting(meeting(moderate: moderate)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Como en un calendario de equipo, cualquier integrante copia el
      // enlace; el backend sigue exigiendo pertenecer al nodo para abrirlo.
      expect(find.text('Compartir enlace'), findsOneWidget);
      expect(
        find.text('Cancelar'),
        moderate && meeting(moderate: moderate).reunion.rtcEstado == 'scheduled'
            ? findsOneWidget
            : findsNothing,
      );
    }
  });
}

class _OneMeeting extends CalendarRepository {
  _OneMeeting(this.meeting);
  final CalendarMeeting meeting;
  @override
  Future<CalendarResult> fetchMonth(DateTime month, {String? nodeId}) async =>
      CalendarResult([meeting]);
}
