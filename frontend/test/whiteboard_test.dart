import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/nodos/data/whiteboard_controller.dart';
import 'package:frontend/features/nodos/presentation/widgets/whiteboard_page.dart';
import 'notifications_test.dart' show CaptureAdapter;

Map<String, dynamic> strokeJson(String id, String user, {double x = .5}) => {
  'id': id,
  'user_id': user,
  'datos': {
    'puntos': [
      [x, .5],
      [x + .01, .51],
    ],
    'color': '#9184d9',
    'grosor': 4,
  },
};

class FakeBoard extends WhiteboardRepository {
  FakeBoard({this.draw = true, this.moderate = false, this.strokes = const []});
  bool draw, moderate, failAdd = false;
  List<Map<String, dynamic>> strokes;
  final added = <List<Offset>>[];
  final deleted = <String>[];
  bool cleared = false;
  bool? everyone;
  int seq = 0;
  int boardSeq = 0;
  int loads = 0;
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> load(String n, String r, String? s) async {
    loads++;
    if (gate != null) await gate!.future;
    return {
      'trazos': strokes,
      'puede_dibujar': draw,
      'puede_moderar': moderate,
      'todos_dibujan': false,
      'seq': boardSeq,
    };
  }

  @override
  Future<Map<String, dynamic>> add(
    String n,
    String r,
    String? s,
    List<Offset> points,
    String color,
    double width,
  ) async {
    if (failAdd) throw const WhiteboardException('La pizarra está llena.');
    added.add(points);
    return {'trazo': strokeJson('srv-${seq++}', 'me')};
  }

  @override
  Future<void> delete(String n, String r, String id) async => deleted.add(id);
  @override
  Future<void> clear(String n, String r, String? s) async => cleared = true;
  @override
  Future<void> setEveryone(String n, String r, String? s, bool v) async =>
      everyone = v;
}

WhiteboardController controller(
  FakeBoard repo, {
  Stream<Map<String, dynamic>>? events,
}) => WhiteboardController(
  nodeId: 'n',
  reunionId: 'r',
  salaId: null,
  ownUserId: 'me',
  events: events ?? const Stream.empty(),
  repository: repo,
);

void main() {
  test('strokes and colors parse from the server format', () {
    final s = WhiteboardStroke.fromJson(strokeJson('a', 'u'));
    expect(s.points.first, const Offset(.5, .5));
    expect(s.width, 4);
    expect(parseHexColor('#9184d9'), const Color(0xFF9184D9));
  });

  test('requests send normalized points and the channel', () async {
    final adapter = CaptureAdapter({'trazo': strokeJson('a', 'me')});
    final repo = WhiteboardRepository(
      client: Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = adapter,
    );
    await repo.add('n', 'r', 's1', [const Offset(.1, .2)], '#9184d9', 4);
    expect(adapter.last!.path, '/nodos/n/reuniones/r/pizarra/trazos');
    expect(adapter.lastData, {
      'sala_id': 's1',
      'puntos': [
        [.1, .2],
      ],
      'color': '#9184d9',
      'grosor': 4.0,
    });
    await repo.load('n', 'r', 's1');
    expect(adapter.last!.queryParameters, {'sala_id': 's1'});
  });

  test('live events add once, delete, clear and update permissions', () async {
    final events = StreamController<Map<String, dynamic>>();
    final board = controller(FakeBoard(draw: false), events: events.stream);
    addTearDown(board.dispose);
    await board.load();
    events
      ..add({'op': 'stroke', 'trazo': strokeJson('a', 'other')})
      ..add({'op': 'stroke', 'trazo': strokeJson('a', 'other')})
      ..add({'op': 'stroke', 'trazo': strokeJson('b', 'other')});
    await Future<void>.delayed(Duration.zero);
    expect(board.strokes.map((s) => s.id), ['a', 'b']);
    events.add({'op': 'delete', 'id': 'a'});
    await Future<void>.delayed(Duration.zero);
    expect(board.strokes.map((s) => s.id), ['b']);
    expect(board.canDraw, isFalse);
    events.add({'op': 'permissions', 'todos_dibujan': true});
    await Future<void>.delayed(Duration.zero);
    expect(board.canDraw, isTrue);
    events.add({'op': 'clear'});
    await Future<void>.delayed(Duration.zero);
    expect(board.strokes, isEmpty);
    await events.close();
  });

  test('a sequence gap reloads the board; older events are ignored', () async {
    final events = StreamController<Map<String, dynamic>>();
    final repo = FakeBoard(draw: false)..boardSeq = 5;
    final board = controller(repo, events: events.stream);
    addTearDown(board.dispose);
    await board.load();
    expect(repo.loads, 1);
    events
      ..add({'seq': 4, 'op': 'clear'}) // ya incluido en la carga
      ..add({'seq': 6, 'op': 'stroke', 'trazo': strokeJson('a', 'x')});
    await Future<void>.delayed(Duration.zero);
    expect(board.strokes.map((s) => s.id), ['a']);
    expect(repo.loads, 1);
    // Se pierde el 7: al recibir el 8 se recarga el lienzo completo.
    repo
      ..strokes = [
        strokeJson('a', 'x'),
        strokeJson('b', 'x'),
        strokeJson('c', 'x'),
      ]
      ..boardSeq = 8;
    events.add({'seq': 8, 'op': 'stroke', 'trazo': strokeJson('c', 'x')});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(repo.loads, 2);
    expect(board.strokes.map((s) => s.id), ['a', 'b', 'c']);
    await events.close();
  });

  test('events that arrive while loading are applied after it', () async {
    final events = StreamController<Map<String, dynamic>>();
    final repo = FakeBoard(draw: false)
      ..boardSeq = 2
      ..gate = Completer<void>();
    final board = controller(repo, events: events.stream);
    addTearDown(board.dispose);
    final loading = board.load();
    events
      ..add({'seq': 2, 'op': 'clear'})
      ..add({'seq': 3, 'op': 'stroke', 'trazo': strokeJson('nuevo', 'x')});
    await Future<void>.delayed(Duration.zero);
    repo.gate!.complete();
    await loading;
    expect(board.strokes.map((s) => s.id), ['nuevo']);
    await events.close();
  });

  test('drawing is optimistic and rolled back on failure', () async {
    final repo = FakeBoard();
    final board = controller(repo);
    addTearDown(board.dispose);
    await board.load();
    final pending = board.addStroke([const Offset(.1, .1)], '#9184d9', 4);
    expect(board.strokes.single.pending, isTrue);
    await pending;
    expect(board.strokes.single.id, 'srv-0');
    repo.failAdd = true;
    await board.addStroke([const Offset(.2, .2)], '#9184d9', 4);
    expect(board.strokes.map((s) => s.id), ['srv-0']);
    expect(board.error, 'La pizarra está llena.');
  });

  test('people undo only their own strokes; moderators delete any', () async {
    final repo = FakeBoard(
      strokes: [strokeJson('mine', 'me'), strokeJson('theirs', 'other')],
    );
    final board = controller(repo);
    addTearDown(board.dispose);
    await board.load();
    expect(board.canDelete(board.strokes.last), isFalse);
    await board.undo();
    expect(repo.deleted, ['mine']);
    expect(board.canUndo, isFalse);

    final moderated = controller(
      FakeBoard(moderate: true, strokes: [strokeJson('theirs', 'other')]),
    );
    addTearDown(moderated.dispose);
    await moderated.load();
    expect(moderated.canDelete(moderated.strokes.single), isTrue);
  });

  test('the eraser finds the stroke under the pointer', () async {
    final board = controller(
      FakeBoard(strokes: [strokeJson('a', 'me', x: .2), strokeJson('b', 'me')]),
    );
    addTearDown(board.dispose);
    await board.load();
    const canvas = Size(1000, 562.5);
    expect(board.hit(const Offset(.5, .5), canvas)?.id, 'b');
    expect(board.hit(const Offset(.2, .5), canvas)?.id, 'a');
    expect(board.hit(const Offset(.9, .9), canvas), isNull);
  });

  Future<void> pump(
    WidgetTester tester,
    WhiteboardController board, {
    Future<String?> Function(String, Uint8List)? save,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: WhiteboardPage(
          controller: board,
          title: 'Pizarra',
          saveFile: save,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('viewers see the board but cannot draw', (tester) async {
    final board = controller(
      FakeBoard(draw: false, strokes: [strokeJson('a', 'x')]),
    );
    addTearDown(board.dispose);
    await pump(tester, board);
    expect(
      find.text('Solo quien modera puede dibujar en esta pizarra.'),
      findsOneWidget,
    );
    expect(find.text('Lápiz'), findsNothing);
    expect(find.bySemanticsLabel('Pizarra con 1 trazo'), findsOneWidget);
  });

  testWidgets('dragging draws a stroke that is sent when finished', (
    tester,
  ) async {
    final repo = FakeBoard();
    final board = controller(repo);
    addTearDown(board.dispose);
    await pump(tester, board);
    final canvas = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is WhiteboardPainter,
    );
    await tester.dragFrom(tester.getCenter(canvas), const Offset(120, 40));
    await tester.pumpAndSettle();
    expect(repo.added, hasLength(1));
    expect(repo.added.single.length, greaterThan(1));
    expect(repo.added.single.every((p) => p.dx >= 0 && p.dx <= 1), isTrue);
    expect(board.strokes.single.id, 'srv-0');
  });

  testWidgets('moderators control permissions, clear and export', (
    tester,
  ) async {
    final repo = FakeBoard(moderate: true, strokes: [strokeJson('a', 'x')]);
    final board = controller(repo);
    addTearDown(board.dispose);
    String? savedName;
    Uint8List? savedBytes;
    await pump(
      tester,
      board,
      save: (name, bytes) async {
        savedName = name;
        savedBytes = bytes;
        return '/tmp/pizarra.png';
      },
    );
    await tester.tap(find.text('Todos pueden dibujar'));
    await tester.pumpAndSettle();
    expect(repo.everyone, isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Exportar como imagen'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(savedName, startsWith('pizarra-'));
    expect(savedBytes!.sublist(1, 4), [0x50, 0x4E, 0x47]);
    await tester.tap(find.text('Limpiar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Limpiar'));
    await tester.pumpAndSettle();
    expect(repo.cleared, isTrue);
    expect(board.strokes, isEmpty);
  });
}
