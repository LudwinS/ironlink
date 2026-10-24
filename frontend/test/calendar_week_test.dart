import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/features/nodos/data/calendar_repository.dart';
import 'package:frontend/features/nodos/data/reuniones_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/calendar_workspace.dart';
import 'package:frontend/features/nodos/presentation/widgets/create_reunion_dialog.dart';
import 'meeting_scheduling_test.dart'
    show FakeMeetings, members, node, pumpDialog;
import 'notifications_test.dart' show CaptureAdapter;

/// Lunes 5 de octubre de 2026.
final monday = DateTime(2026, 10, 5);

Reunion room(
  String id,
  String titulo,
  DateTime start,
  Duration length, {
  bool allDay = false,
  String? serie,
  String? ubicacion,
  List<String> asistentes = const ['ana', 'beto'],
}) => Reunion(
  id: id,
  nodoId: 'n1',
  titulo: titulo,
  fechaInicio: start,
  fechaFin: start.add(length),
  creadoPor: 'owner',
  creadorNombre: 'Organizador',
  createdAt: DateTime(2026, 10, 1),
  serieId: serie,
  repeticion: serie == null ? null : 'weekly',
  todoElDia: allDay,
  ubicacion: ubicacion,
  asistentes: asistentes,
  invitados: asistentes.length + 1,
);

final week = [
  room(
    'm1',
    'Daily',
    DateTime(2026, 10, 5, 9),
    const Duration(minutes: 30),
    ubicacion: 'Sala Norte',
  ),
  room(
    'w2',
    'Revisión',
    DateTime(2026, 10, 7, 14),
    const Duration(minutes: 90),
  ),
  room(
    'f3',
    'Feria',
    DateTime(2026, 10, 6),
    const Duration(days: 1),
    allDay: true,
  ),
];

class WeekCalendar extends CalendarRepository {
  final months = <DateTime>[];
  @override
  Future<CalendarResult> fetchMonth(DateTime month, {String? nodeId}) async {
    months.add(month);
    return CalendarResult([
      for (final r in week)
        if (r.fechaInicio.month == month.month)
          CalendarMeeting(
            reunion: r,
            nodeName: 'Ingeniería',
            canModerate: true,
            canJoin: false,
          ),
    ]);
  }
}

Future<WeekCalendar> pumpWeek(
  WidgetTester tester, {
  double width = 1280,
  double textScale = 1,
  FakeMeetings? meetings,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final calendar = WeekCalendar();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: CalendarWorkspace(
          nodos: [node],
          active: true,
          repository: calendar,
          meetings: meetings ?? FakeMeetings(),
          now: monday,
          onJoin: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Semana'));
  await tester.pumpAndSettle();
  return calendar;
}

void main() {
  tearDown(LivePresence.clear);

  test(
    'location, all-day, edit scope and availability travel in the JSON',
    () async {
      final adapter = CaptureAdapter({
        'reunion': {
          'id': 'm1',
          'nodo_id': 'n1',
          'titulo': 'Daily',
          'todo_el_dia': true,
          'ubicacion': 'Sala Norte',
          'asistentes': ['ana'],
        },
        'usuarios': [
          {
            'user_id': 'ana',
            'ocupado': [
              {'inicio': '2026-10-05T15:00:00Z', 'fin': '2026-10-05T16:00:00Z'},
            ],
          },
        ],
      });
      final repo = ReunionesRepository(
        client: Dio(BaseOptions(baseUrl: 'http://test'))
          ..httpClientAdapter = adapter,
      );
      final (created, _) = await repo.createReunion(
        nodoId: 'n1',
        titulo: 'Feria',
        fechaInicio: DateTime(2026, 10, 6),
        fechaFin: DateTime(2026, 10, 7),
        todoElDia: true,
        ubicacion: 'Sala Norte',
      );
      expect(created.todoElDia, isTrue);
      expect(created.ubicacion, 'Sala Norte');
      expect(created.asistentes, ['ana']);
      var sent = adapter.lastData as Map;
      expect(sent['ubicacion'], 'Sala Norte');
      expect(sent['todo_el_dia'], true);

      await repo.updateReunion(
        nodoId: 'n1',
        reunionId: 'm1',
        ubicacion: 'Sala 3',
        fechaInicio: DateTime(2026, 10, 5, 10),
        invitados: ['beto'],
        alcance: EditScope.siguientes,
      );
      expect(adapter.last!.method, 'PUT');
      expect(adapter.last!.path, '/nodos/n1/reuniones/m1');
      sent = adapter.lastData as Map;
      expect(sent['alcance'], 'siguientes');
      expect(sent['ubicacion'], 'Sala 3');
      expect(sent['invitados'], ['beto']);
      expect(sent.containsKey('titulo'), isFalse, reason: 'sin cambios');
      expect(
        sent['zona_minutos'],
        DateTime(2026, 10, 5, 10).timeZoneOffset.inMinutes,
      );

      final busy = await repo.fetchAvailability(
        nodoId: 'n1',
        desde: DateTime(2026, 10, 5),
        hasta: DateTime(2026, 10, 6),
        usuarios: ['ana', 'beto'],
        excluir: 'm1',
      );
      expect(adapter.last!.path, '/nodos/n1/disponibilidad');
      expect(adapter.last!.queryParameters['usuarios'], 'ana,beto');
      expect(adapter.last!.queryParameters['excluir'], 'm1');
      expect(
        busy['ana']!.single.start,
        DateTime.parse('2026-10-05T15:00:00Z').toLocal(),
      );
    },
  );

  testWidgets('the week view places meetings by day, hour and duration', (
    tester,
  ) async {
    final calendar = await pumpWeek(tester);
    expect(find.text('5 – 11 oct 2026'), findsOneWidget);
    expect(calendar.months.last, DateTime(2026, 10));
    final daily = find.byKey(const ValueKey('week-event-m1'));
    final review = find.byKey(const ValueKey('week-event-w2'));
    expect(daily, findsOneWidget);
    expect(review, findsOneWidget);
    // Lunes a las 9:00, media hora.
    final nine = tester.getTopLeft(find.byKey(const ValueKey('week-hour-9')));
    expect(tester.getTopLeft(daily).dy, closeTo(nine.dy, 1));
    expect(tester.getSize(daily).height, closeTo(24, 1));
    final mondayHeader = tester.getCenter(
      find.byKey(const ValueKey('week-day-0')),
    );
    expect(tester.getCenter(daily).dx, closeTo(mondayHeader.dx, 20));
    // Miércoles de 14:00 a 15:30.
    final two = tester.getTopLeft(find.byKey(const ValueKey('week-hour-14')));
    expect(tester.getTopLeft(review).dy, closeTo(two.dy, 1));
    expect(tester.getSize(review).height, closeTo(72, 1));
    final wednesday = tester.getCenter(
      find.byKey(const ValueKey('week-day-2')),
    );
    expect(tester.getCenter(review).dx, closeTo(wednesday.dx, 20));
  });

  testWidgets('all-day events sit in the top strip, without hours', (
    tester,
  ) async {
    await pumpWeek(tester);
    final strip = find.byKey(const ValueKey('week-all-day'));
    expect(
      find.descendant(of: strip, matching: find.text('Feria')),
      findsOneWidget,
    );
    final eight = tester.getTopLeft(find.byKey(const ValueKey('week-hour-8')));
    expect(tester.getTopLeft(find.text('Feria')).dy, lessThan(eight.dy));
    expect(find.textContaining('00:00'), findsNothing);
  });

  testWidgets('a week meeting opens with the card actions; navigation works', (
    tester,
  ) async {
    LivePresence.selfId = 'owner';
    final meetings = FakeMeetings();
    final calendar = await pumpWeek(tester, meetings: meetings);
    await tester.tap(find.byKey(const ValueKey('week-event-m1')));
    await tester.pumpAndSettle();
    expect(find.text('Organiza: Organizador'), findsOneWidget);
    expect(find.text('Sala Norte'), findsOneWidget);
    expect(find.text('Editar'), findsOneWidget);
    await tester.tap(find.text('Iniciar reunión'));
    await tester.pumpAndSettle();
    expect(meetings.started, ['m1']);
    expect(find.text('Organiza: Organizador'), findsNothing, reason: 'cerrado');

    await tester.tap(find.byTooltip('Semana siguiente'));
    await tester.pumpAndSettle();
    expect(find.text('12 – 18 oct 2026'), findsOneWidget);
    expect(find.byKey(const ValueKey('week-event-m1')), findsNothing);
    await tester.tap(find.byTooltip('Semana anterior'));
    await tester.tap(find.byTooltip('Semana anterior'));
    await tester.pumpAndSettle();
    // 28 sep – 4 oct toca dos meses: se piden ambos.
    expect(find.text('28 sep – 4 oct 2026'), findsOneWidget);
    expect(calendar.months.reversed.take(2), {
      DateTime(2026, 9),
      DateTime(2026, 10),
    });
    await tester.tap(find.text('Hoy'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('week-event-m1')), findsOneWidget);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('the week fits $width px at 130 percent text', (tester) async {
      await pumpWeek(tester, width: width, textScale: 1.3);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('week-event-m1')), findsOneWidget);
      if (width < 700) {
        // Agenda por días en pantallas estrechas.
        expect(find.text('Lunes 5 de octubre · Hoy'), findsOneWidget);
        expect(find.text('Sin reuniones'), findsWidgets);
        expect(find.textContaining('Todo el día'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('week-event-w2')));
        await tester.pumpAndSettle();
        expect(find.text('Organiza: Organizador'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('editing a series asks the scope and sends it', (tester) async {
    final repo = FakeMeetings();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CreateReunionDialog(
            editing: room(
              'm1',
              'Daily',
              DateTime(2026, 10, 5, 9),
              const Duration(minutes: 30),
              serie: 's1',
              ubicacion: 'Sala Norte',
            ),
            repository: repo,
            loadMembers: (_) async => members,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Editar reunión'), findsOneWidget);
    expect(find.text('Repetición'), findsNothing);
    expect(find.text('Se repite cada semana'), findsOneWidget);
    expect(find.text('Sala Norte'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'Daily nueva');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Editar reunión periódica'), findsOneWidget);
    await tester.tap(find.text('Esta y las siguientes'));
    await tester.pumpAndSettle();
    final sent = repo.updated.single;
    expect(sent['alcance'], EditScope.siguientes);
    expect(sent['titulo'], 'Daily nueva');
    expect(sent['ubicacion'], 'Sala Norte');
    expect(sent['inicio'], isNull, reason: 'el horario no cambió');
    expect(sent['invitados'], isNull, reason: 'los asistentes no cambiaron');
  });

  testWidgets('a single meeting is edited without asking; attendees change', (
    tester,
  ) async {
    final repo = FakeMeetings();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CreateReunionDialog(
            editing: room(
              'm1',
              'Daily',
              DateTime(2026, 10, 5, 9),
              const Duration(minutes: 30),
              asistentes: const ['ana'],
            ),
            repository: repo,
            loadMembers: (_) async => members,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beto Cruz'));
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Editar reunión periódica'), findsNothing);
    final sent = repo.updated.single;
    expect(sent['alcance'], EditScope.una);
    expect((sent['invitados'] as List)..sort(), ['ana', 'beto']);
  });

  testWidgets('all-day with a location hides the hours and sends both', (
    tester,
  ) async {
    final repo = FakeMeetings();
    await pumpDialog(tester, repo);
    await tester.enterText(find.byType(TextFormField).first, 'Feria');
    await tester.tap(find.text('Todo el día'));
    await tester.pumpAndSettle();
    expect(find.text('Inicio'), findsNothing);
    expect(find.text('Duración:'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Ubicación (opcional)'),
      'Auditorio',
    );
    await tester.tap(find.text('Programar'));
    await tester.pumpAndSettle();
    final sent = repo.created.single;
    expect(sent['todo_el_dia'], isTrue);
    expect(sent['ubicacion'], 'Auditorio');
    final start = sent['inicio'] as DateTime;
    expect((start.hour, start.minute), (0, 0));
    expect(sent['fin'], DateTime(start.year, start.month, start.day + 1));
  });

  testWidgets('availability shows who has another meeting at that time', (
    tester,
  ) async {
    final repo = FakeMeetings();
    final day = DateTime.now().add(const Duration(days: 3));
    repo.busy = {
      'ana': [
        BusyInterval(
          DateTime(day.year, day.month, day.day, 9),
          DateTime(day.year, day.month, day.day, 10),
        ),
      ],
    };
    await pumpDialog(tester, repo);
    // Todo el nodo: Ana y Beto. La reunión propuesta es a las 9:00.
    expect(repo.availabilityCalls.last, ['ana', 'beto']);
    expect(find.text('Disponibilidad de los asistentes'), findsOneWidget);
    expect(find.text('Ana tiene otra reunión a esa hora'), findsOneWidget);
    expect(find.text('Beto tiene otra reunión a esa hora'), findsNothing);
    // Solo con Beto ya no hay choque.
    await tester.tap(find.text('Personas específicas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beto Cruz'));
    await tester.pumpAndSettle();
    expect(repo.availabilityCalls.last, ['beto']);
    expect(find.text('Ana tiene otra reunión a esa hora'), findsNothing);
    expect(find.text('Todos están libres a esa hora.'), findsOneWidget);
  });
}
