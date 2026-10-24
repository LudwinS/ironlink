import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/features/nodos/data/calendar_repository.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/data/reuniones_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/calendar_workspace.dart';
import 'package:frontend/features/nodos/presentation/widgets/create_reunion_dialog.dart';
import 'notifications_test.dart' show CaptureAdapter;

final node = Nodo(
  id: 'n1',
  nombre: 'Ingeniería',
  tokenAcceso: 't',
  creadorId: 'owner',
  estado: 'active',
  miembrosCount: 3,
  createdAt: DateTime(2026, 9, 1),
);

const members = [
  NodoMiembro(userId: 'ana', name: 'Ana Rivas', email: 'a@x', rol: 'MEMBER'),
  NodoMiembro(userId: 'beto', name: 'Beto Cruz', email: 'b@x', rol: 'MEMBER'),
];

Reunion meeting({
  String state = 'scheduled',
  String? answer,
  String creator = 'owner',
  String? serie,
}) => Reunion(
  id: 'm1',
  nodoId: 'n1',
  titulo: 'Daily',
  fechaInicio: DateTime(2026, 10, 5, 9),
  fechaFin: DateTime(2026, 10, 5, 9, 30),
  creadoPor: creator,
  creadorNombre: 'Organizador',
  createdAt: DateTime(2026, 10, 1),
  rtcEstado: state,
  miRespuesta: answer,
  serieId: serie,
  repeticion: serie == null ? null : 'weekly',
  invitados: 3,
  aceptados: 1,
);

/// Registra lo que la app pide al servidor.
class FakeMeetings extends ReunionesRepository {
  FakeMeetings() : super(client: Dio());
  final created = <Map<String, Object?>>[];
  final updated = <Map<String, Object?>>[];

  /// Horas ocupadas que devuelve la consulta de disponibilidad.
  Map<String, List<BusyInterval>> busy = {};
  final availabilityCalls = <List<String>>[];
  final answers = <(String, bool)>[];
  final started = <String>[];
  int meetNowCalls = 0;

  @override
  Future<(Reunion, int)> createReunion({
    required String nodoId,
    required String titulo,
    String? descripcion,
    required DateTime fechaInicio,
    DateTime? fechaFin,
    String frecuencia = 'none',
    int ocurrencias = 1,
    List<String>? invitados,
    bool todoElDia = false,
    String? ubicacion,
  }) async {
    created.add({
      'todo_el_dia': todoElDia,
      'ubicacion': ubicacion,
      'nodo': nodoId,
      'titulo': titulo,
      'inicio': fechaInicio,
      'fin': fechaFin,
      'frecuencia': frecuencia,
      'ocurrencias': ocurrencias,
      'invitados': invitados,
    });
    return (meeting(), ocurrencias);
  }

  @override
  Future<Reunion> updateReunion({
    required String nodoId,
    required String reunionId,
    String? titulo,
    String? descripcion,
    String? ubicacion,
    DateTime? fechaInicio,
    DateTime? fechaFin,
    bool? todoElDia,
    List<String>? invitados,
    EditScope alcance = EditScope.una,
  }) async {
    updated.add({
      'id': reunionId,
      'titulo': titulo,
      'ubicacion': ubicacion,
      'inicio': fechaInicio,
      'fin': fechaFin,
      'todo_el_dia': todoElDia,
      'invitados': invitados,
      'alcance': alcance,
    });
    return meeting();
  }

  @override
  Future<Map<String, List<BusyInterval>>> fetchAvailability({
    required String nodoId,
    required DateTime desde,
    required DateTime hasta,
    required List<String> usuarios,
    String? excluir,
  }) async {
    availabilityCalls.add(usuarios);
    return {for (final u in usuarios) u: busy[u] ?? const []};
  }

  @override
  Future<Reunion> meetNow({
    required String nodoId,
    String? titulo,
    List<String> invitados = const [],
    bool privada = false,
  }) async {
    meetNowCalls++;
    return meeting(state: 'active');
  }

  @override
  Future<void> respond({
    required String nodoId,
    required String reunionId,
    required String respuesta,
    bool serie = false,
  }) async => answers.add((respuesta, serie));

  @override
  Future<void> startMeeting({
    required String nodoId,
    required String reunionId,
  }) async => started.add(reunionId);
}

class OneMeeting extends CalendarRepository {
  OneMeeting(this.reunion, {this.moderate = false});
  final Reunion reunion;
  final bool moderate;
  @override
  Future<CalendarResult> fetchMonth(DateTime month, {String? nodeId}) async =>
      CalendarResult([
        CalendarMeeting(
          reunion: reunion,
          nodeName: 'Ingeniería',
          canModerate: moderate,
          canJoin: reunion.rtcEstado == 'active',
        ),
      ]);
}

Future<void> pumpDialog(WidgetTester tester, FakeMeetings repo) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CreateReunionDialog(
          nodoId: 'n1',
          initialDate: DateTime.now().add(const Duration(days: 3)),
          repository: repo,
          loadMembers: (_) async => members,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(LivePresence.clear);

  test(
    'the repository sends IronLink meetings without an external link',
    () async {
      final adapter = CaptureAdapter({
        'reunion': {'id': 'm1', 'nodo_id': 'n1', 'titulo': 'Daily'},
        'ocurrencias': 4,
      });
      final repo = ReunionesRepository(
        client: Dio(BaseOptions(baseUrl: 'http://test'))
          ..httpClientAdapter = adapter,
      );
      final start = DateTime(2026, 10, 5, 9);
      final (_, count) = await repo.createReunion(
        nodoId: 'n1',
        titulo: 'Daily',
        fechaInicio: start,
        fechaFin: start.add(const Duration(minutes: 30)),
        frecuencia: 'weekly',
        ocurrencias: 4,
        invitados: ['ana'],
      );
      expect(count, 4);
      final sent = adapter.lastData as Map;
      expect(sent.containsKey('enlace_reunion'), isFalse);
      expect(sent['repeticion'], {'frecuencia': 'weekly', 'ocurrencias': 4});
      expect(sent['invitados'], ['ana']);
      expect(sent['zona_minutos'], start.timeZoneOffset.inMinutes);

      await repo.meetNow(nodoId: 'n1', invitados: ['ana'], privada: true);
      expect(adapter.last!.path, '/nodos/n1/reuniones/ahora');
      expect(adapter.lastData, {
        'invitados': ['ana'],
        'privada': true,
      });

      await repo.respond(nodoId: 'n1', reunionId: 'm1', respuesta: 'tentativa');
      expect(adapter.last!.method, 'PUT');
      expect(adapter.last!.path, '/nodos/n1/reuniones/m1/respuesta');

      await repo.deleteReunion(nodoId: 'n1', reunionId: 'm1', serie: true);
      expect(adapter.last!.queryParameters, {'serie': true});
    },
  );

  testWidgets('a weekly meeting with specific attendees, no link field', (
    tester,
  ) async {
    final repo = FakeMeetings();
    await pumpDialog(tester, repo);
    expect(find.textContaining('Enlace'), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, 'Daily Scrum');
    await tester.tap(find.text('45 min'));
    await tester.tap(find.text('Personas específicas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana Rivas'));
    await tester.tap(find.text('No se repite'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Cada semana el').last);
    await tester.pumpAndSettle();
    expect(find.text('Termina después de 4 reuniones'), findsOneWidget);
    await tester.tap(find.byTooltip('Una reunión más'));
    await tester.pump();
    await tester.tap(find.text('Programar'));
    await tester.pumpAndSettle();
    final sent = repo.created.single;
    expect(sent['titulo'], 'Daily Scrum');
    expect(sent['frecuencia'], 'weekly');
    expect(sent['ocurrencias'], 5);
    expect(sent['invitados'], ['ana']);
    expect(
      (sent['fin'] as DateTime).difference(sent['inicio'] as DateTime),
      const Duration(minutes: 45),
    );
  });

  testWidgets('specific attendees require at least one person', (tester) async {
    final repo = FakeMeetings();
    await pumpDialog(tester, repo);
    await tester.enterText(find.byType(TextFormField).first, 'Retro');
    await tester.tap(find.text('Personas específicas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Programar'));
    await tester.pumpAndSettle();
    expect(
      find.text('Invita al menos a una persona o elige todo el nodo.'),
      findsOneWidget,
    );
    expect(repo.created, isEmpty);
  });

  Future<void> pumpCalendar(
    WidgetTester tester,
    CalendarRepository calendar,
    FakeMeetings meetings, {
    ValueChanged<CalendarMeeting>? onJoin,
  }) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CalendarWorkspace(
            nodos: [node],
            active: true,
            repository: calendar,
            meetings: meetings,
            now: DateTime(2026, 10, 1),
            onJoin: onJoin ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('invitees answer from the calendar, for the whole series', (
    tester,
  ) async {
    LivePresence.selfId = 'ana';
    final meetings = FakeMeetings();
    await pumpCalendar(
      tester,
      OneMeeting(meeting(answer: 'pendiente', serie: 's1')),
      meetings,
    );
    expect(find.textContaining('09:00 – 09:30'), findsOneWidget);
    expect(find.text('Serie'), findsOneWidget);
    expect(find.text('1/3 asistirán'), findsOneWidget);
    await tester.tap(find.text('Asistiré'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Toda la serie'));
    await tester.pumpAndSettle();
    expect(meetings.answers, [('aceptada', true)]);
  });

  testWidgets('the organizer starts a scheduled meeting from the calendar', (
    tester,
  ) async {
    LivePresence.selfId = 'owner';
    final meetings = FakeMeetings();
    CalendarMeeting? joined;
    await pumpCalendar(
      tester,
      OneMeeting(meeting(answer: 'aceptada'), moderate: true),
      meetings,
      onJoin: (m) => joined = m,
    );
    expect(find.text('Asistiré'), findsNothing, reason: 'organiza');
    await tester.tap(find.text('Iniciar reunión'));
    await tester.pumpAndSettle();
    expect(meetings.started, ['m1']);
    expect(joined!.canJoin, isTrue);
    expect(joined!.reunion.rtcEstado, 'active');
  });

  testWidgets('meet now starts a call right away', (tester) async {
    final meetings = FakeMeetings();
    CalendarMeeting? joined;
    await pumpCalendar(
      tester,
      OneMeeting(meeting()),
      meetings,
      onJoin: (m) => joined = m,
    );
    await tester.tap(find.text('Reunirse ahora'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empezar reunión'));
    await tester.pumpAndSettle();
    expect(meetings.meetNowCalls, 1);
    expect(joined!.canJoin, isTrue);
    expect(joined!.canModerate, isTrue);
  });

  test('repetition options describe the chosen date', () {
    final monday = DateTime(2026, 10, 5);
    final options = repetitionOptions(monday);
    expect(options['weekly'], 'Cada semana el lunes');
    expect(options['monthly'], 'Cada mes el día 5');
    expect(repetitionLabel('weekdays'), 'Se repite de lunes a viernes');
  });
}
