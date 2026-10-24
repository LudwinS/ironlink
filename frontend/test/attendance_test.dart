import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/nodos/data/attendance_repository.dart';
import 'package:frontend/features/nodos/data/calendar_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/attendance_dialog.dart';
import 'package:frontend/features/nodos/presentation/widgets/calendar_workspace.dart';
import 'meeting_link_test.dart' show StatusAdapter, meeting;

final reportJson = {
  'reunion_id': 'r',
  'titulo': 'Daily',
  'estado': 'active',
  'inicio': '2026-10-01T15:00:00Z',
  'fin': null,
  'duracion_segundos': 3600,
  'participantes': [
    {
      'user_id': 'ana',
      'nombre': 'Ana Rivas',
      'correo': 'ana@ironlink.dev',
      'sesiones': 2,
      'primera_entrada': '2026-10-01T15:00:00Z',
      'ultima_salida': null,
      'conectado_ahora': true,
      'segundos_conectado': 2700,
      'porcentaje': 75.0,
    },
    {
      'user_id': 'beto',
      'nombre': 'Beto Paz',
      'correo': 'beto@ironlink.dev',
      'sesiones': 1,
      'primera_entrada': '2026-10-01T15:10:00Z',
      'ultima_salida': '2026-10-01T15:20:00Z',
      'conectado_ahora': false,
      'segundos_conectado': 600,
      'porcentaje': 16.7,
    },
  ],
  'sesiones': [
    {
      'user_id': 'ana',
      'nombre': 'Ana Rivas',
      'correo': 'ana@ironlink.dev',
      'joined_at': '2026-10-01T15:00:00Z',
      'left_at': '2026-10-01T15:30:00Z',
      'salida': 'conexion_perdida',
      'segundos': 1800,
    },
    {
      'user_id': 'beto',
      'nombre': 'Beto Paz',
      'correo': 'beto@ironlink.dev',
      'joined_at': '2026-10-01T15:10:00Z',
      'left_at': '2026-10-01T15:20:00Z',
      'salida': 'expulsado',
      'segundos': 600,
    },
    {
      'user_id': 'ana',
      'nombre': 'Ana Rivas',
      'correo': 'ana@ironlink.dev',
      'joined_at': '2026-10-01T15:45:00Z',
      'left_at': null,
      'salida': null,
      'segundos': 900,
    },
  ],
};

class FakeAttendance extends AttendanceRepository {
  bool fail = false;
  int fetches = 0;
  @override
  Future<AttendanceReport> fetch(String nodeId, String reunionId) async {
    fetches++;
    if (fail) throw const AttendanceException('Sin permiso.');
    return AttendanceReport.fromJson(reportJson);
  }

  @override
  Future<Uint8List> csv(String nodeId, String reunionId) async =>
      Uint8List.fromList(utf8.encode('nombre\r\nAna\r\n'));
}

Future<void> open(
  WidgetTester tester,
  FakeAttendance repo, {
  Future<String?> Function(String, Uint8List)? save,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAttendanceDialog(
              context,
              meeting(state: 'active', moderate: true),
              repository: repo,
              saveFile: save ?? (_, _) async => '/tmp/a.csv',
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

void main() {
  test('durations read naturally', () {
    expect(formatDuration(42), '42 s');
    expect(formatDuration(600), '10 min');
    expect(formatDuration(3900), '1 h 05 min');
  });

  test('the repository parses the server report', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = StatusAdapter(200, {'asistencia': reportJson});
    final report = await AttendanceRepository(client: dio).fetch('n', 'r');
    expect(report.participants.first.percent, 75);
    expect(report.sessionsOf('ana'), hasLength(2));
    expect(report.sessions.last.open, isTrue);

    final denied = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = StatusAdapter(404, {'message': 'No existe.'});
    expect(
      () => AttendanceRepository(client: denied).fetch('n', 'r'),
      throwsA(
        isA<AttendanceException>().having((e) => e.message, 'm', 'No existe.'),
      ),
    );
  });

  testWidgets('shows time, share of the meeting and each entry and exit', (
    tester,
  ) async {
    await open(tester, FakeAttendance());
    expect(find.textContaining('2 participantes'), findsOneWidget);
    expect(
      find.textContaining('45 min · 75 % de la reunión · 2 entradas'),
      findsOneWidget,
    );
    expect(find.text('Conectado'), findsOneWidget);
    await tester.tap(find.text('Ana Rivas'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Conexión perdida'), findsOneWidget);
    expect(find.textContaining('→ ahora'), findsOneWidget);
    await tester.tap(find.text('Beto Paz'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Expulsado'), findsOneWidget);
  });

  testWidgets('exports the server CSV with a descriptive name', (tester) async {
    String? savedName;
    Uint8List? savedBytes;
    await open(
      tester,
      FakeAttendance(),
      save: (name, bytes) async {
        savedName = name;
        savedBytes = bytes;
        return '/tmp/asistencia.csv';
      },
    );
    await tester.tap(find.text('Exportar CSV'));
    await tester.pumpAndSettle();
    expect(
      savedName,
      startsWith('asistencia-revisión-del-sprint-4-2026-10-01'),
    );
    expect(savedName, endsWith('.csv'));
    expect(utf8.decode(savedBytes!), contains('Ana'));
    expect(find.text('CSV guardado en /tmp/asistencia.csv'), findsOneWidget);
  });

  testWidgets('errors are explicit and can be retried', (tester) async {
    final repo = FakeAttendance()..fail = true;
    await open(tester, repo);
    expect(find.text('Sin permiso.'), findsOneWidget);
    repo.fail = false;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('Ana Rivas'), findsOneWidget);
    expect(repo.fetches, 2);
  });

  testWidgets('only moderators see attendance, once the meeting started', (
    tester,
  ) async {
    for (final (state, moderate, visible) in [
      ('scheduled', true, false),
      ('active', true, true),
      ('ended', true, true),
      ('active', false, false),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey('$state$moderate'),
          home: Scaffold(
            body: CalendarWorkspace(
              nodos: const [],
              active: true,
              onJoin: (_) {},
              now: DateTime(2026, 10, 1),
              repository: _One(meeting(state: state, moderate: moderate)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Asistencia'),
        visible ? findsOneWidget : findsNothing,
        reason: '$state, moderador: $moderate',
      );
    }
  });
}

class _One extends CalendarRepository {
  _One(this.meeting);
  final CalendarMeeting meeting;
  @override
  Future<CalendarResult> fetchMonth(DateTime month, {String? nodeId}) async =>
      CalendarResult([meeting]);
}
