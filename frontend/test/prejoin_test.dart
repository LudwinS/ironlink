import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/data/reuniones_repository.dart';
import 'package:frontend/features/nodos/data/rtc_call_controller.dart';
import 'package:frontend/features/nodos/data/rtc_prejoin.dart';
import 'package:frontend/features/nodos/presentation/rtc_call_page.dart';

class FakeTrack extends MediaStreamTrack {
  FakeTrack(this.kind);
  @override
  final String kind;
  @override
  bool enabled = true;
  int stops = 0;
  @override
  Future<void> stop() async => stops++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeStream extends MediaStream {
  FakeStream(this.tracks) : super('preview', 'local');
  final List<FakeTrack> tracks;
  int disposals = 0;
  @override
  List<MediaStreamTrack> getTracks() => tracks;
  @override
  List<MediaStreamTrack> getVideoTracks() =>
      tracks.where((t) => t.kind == 'video').toList();
  @override
  List<MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();
  @override
  Future<void> dispose() async => disposals++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Dispositivos simulados: sin permiso de cámara, cualquier pedido de video
/// falla como lo haría `getUserMedia`.
class FakeMedia extends RtcMediaAccess {
  FakeMedia({this.cameraAllowed = true});
  final bool cameraAllowed;
  final requests = <Map<String, dynamic>>[];
  final opened = <FakeStream>[];

  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) async {
    requests.add(constraints);
    if (constraints.containsKey('video') && !cameraAllowed) {
      throw Exception('NotAllowedError');
    }
    final stream = FakeStream([
      if (constraints['audio'] != null) FakeTrack('audio'),
      if (constraints['video'] != null) FakeTrack('video'),
    ]);
    opened.add(stream);
    return stream;
  }

  @override
  Future<List<MediaDeviceInfo>> enumerateDevices() async => [];
  @override
  bool get canRouteAudio => false;
  @override
  Future<RTCVideoRenderer?> createRenderer() async => null;
}

class FakeCall extends RtcCallController {
  FakeCall({required super.microphoneEnabled, required super.cameraEnabled})
    : super('n', 'r', ReunionesRepository());
  MediaStream? joinedWith;
  int joins = 0;
  @override
  Future<void> join({MediaStream? media}) async {
    joins++;
    joinedWith = media;
  }
}

class EmptyMembers extends NodosRepository {
  @override
  Future<List<NodoMiembro>> fetchMiembros(String nodoId) async => [];
}

final reunion = Reunion(
  id: 'r',
  nodoId: 'n',
  titulo: 'Revisión del sprint',
  fechaInicio: DateTime(2026, 10, 2, 10),
  creadoPor: 'u',
  creadorNombre: 'Ana',
  createdAt: DateTime(2026, 10, 1),
);

void main() {
  late FakeMedia media;
  late List<FakeCall> calls;

  RtcCallPage page() => RtcCallPage(
    reunion: reunion,
    canEnd: false,
    media: media,
    membersRepository: EmptyMembers(),
    callFactory:
        (target, {required microphoneEnabled, required cameraEnabled}) {
          final call = FakeCall(
            microphoneEnabled: microphoneEnabled,
            cameraEnabled: cameraEnabled,
          );
          calls.add(call);
          return call;
        },
  );

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.pump();
    await tester.pump();
  }

  Switch switchOf(WidgetTester tester, String key) =>
      tester.widget<Switch>(find.byKey(Key(key)));

  setUp(() {
    media = FakeMedia();
    calls = [];
  });

  testWidgets('el lobby aparece antes de conectar a la sala', (tester) async {
    await open(tester);
    expect(find.text('Revisión del sprint'), findsOneWidget);
    expect(find.text('Unirse ahora'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(switchOf(tester, 'prejoin-camera').value, isTrue);
    expect(switchOf(tester, 'prejoin-microphone').value, isTrue);
    // Solo se pidió la vista previa; ninguna conexión a la sala.
    expect(media.requests, hasLength(1));
    expect(calls, isEmpty);
    expect(find.text('Salir'), findsNothing);
  });

  testWidgets(
    'los interruptores fijan el estado inicial y se reutiliza el stream',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('prejoin-camera')));
      await tester.tap(find.byKey(const Key('prejoin-microphone')));
      await tester.pump();
      expect(switchOf(tester, 'prejoin-camera').value, isFalse);
      expect(switchOf(tester, 'prejoin-microphone').value, isFalse);
      final preview = media.opened.single;
      expect(preview.tracks.every((t) => !t.enabled), isTrue);

      await tester.tap(find.byKey(const Key('prejoin-join')));
      await tester.pump();
      await tester.pump();

      final call = calls.single;
      expect(call.cameraEnabled, isFalse);
      expect(call.microphoneEnabled, isFalse);
      expect(call.participation.microphoneEnabled, isFalse);
      expect(call.joins, 1);
      // La llamada recibe el mismo stream: la cámara no se abre dos veces.
      expect(identical(call.joinedWith, preview), isTrue);
      expect(media.requests, hasLength(1));
      expect(preview.tracks.every((t) => t.stops == 0), isTrue);
      expect(find.text('Salir'), findsOneWidget);
      expect(find.text('Unirse ahora'), findsNothing);
    },
  );

  testWidgets('entrar sin tocar nada conserva cámara y micrófono activos', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('prejoin-join')));
    await tester.pump();
    expect(calls.single.cameraEnabled, isTrue);
    expect(calls.single.microphoneEnabled, isTrue);
  });

  testWidgets('Cancelar no conecta y libera la cámara', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => page())),
            child: const Text('Abrir reunión'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir reunión'));
    await tester.pumpAndSettle();
    expect(find.text('Unirse ahora'), findsOneWidget);

    await tester.tap(find.byKey(const Key('prejoin-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('Abrir reunión'), findsOneWidget);
    expect(calls, isEmpty);
    final preview = media.opened.single;
    expect(preview.tracks.every((t) => t.stops == 1), isTrue);
    expect(preview.disposals, 1);
  });

  testWidgets('sin permiso de cámara se puede entrar con la cámara apagada', (
    tester,
  ) async {
    media = FakeMedia(cameraAllowed: false);
    await open(tester);
    expect(find.byKey(const Key('prejoin-notice')), findsOneWidget);
    expect(find.textContaining('Puedes entrar con la cámara'), findsOneWidget);
    expect(find.text('Cámara no disponible'), findsOneWidget);
    final camera = switchOf(tester, 'prejoin-camera');
    expect(camera.value, isFalse);
    expect(camera.onChanged, isNull);

    await tester.tap(find.byKey(const Key('prejoin-join')));
    await tester.pump();

    final call = calls.single;
    expect(call.cameraEnabled, isFalse);
    expect(call.microphoneEnabled, isTrue);
    final stream = call.joinedWith as FakeStream;
    expect(stream.tracks.map((t) => t.kind), ['audio']);
  });

  for (final (width, scale) in [(390.0, 1.3), (1280.0, 1.3), (390.0, 1.0)]) {
    testWidgets(
      'el lobby se adapta a ${width.toInt()} px con texto al ${(scale * 100).round()} %',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 844),
              textScaler: TextScaler.linear(scale),
            ),
            child: MaterialApp(home: page()),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('Cancelar'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Unirse ahora'), findsOneWidget);
      },
    );
  }

  test('la llamada apaga la cámara si el stream no trae video', () {
    final call = RtcCallController('n', 'r', ReunionesRepository());
    final audioOnly = FakeStream([FakeTrack('audio')]);
    call.applyInitialMediaForTest(audioOnly);
    expect(call.cameraEnabled, isFalse);
    expect(call.hasCamera, isFalse);
    expect(call.microphoneEnabled, isTrue);
    call.toggleCamera();
    expect(call.cameraEnabled, isFalse);
  });

  test('el estado inicial se aplica a las pistas recibidas', () {
    final call = RtcCallController(
      'n',
      'r',
      ReunionesRepository(),
      microphoneEnabled: false,
      cameraEnabled: true,
    );
    final stream = FakeStream([FakeTrack('audio'), FakeTrack('video')]);
    call.applyInitialMediaForTest(stream);
    expect(stream.tracks.first.enabled, isFalse);
    expect(stream.tracks.last.enabled, isTrue);
    expect(call.participation.microphoneEnabled, isFalse);
    // Volver a activar el micrófono sigue funcionando.
    call.toggleMicrophone();
    expect(stream.tracks.first.enabled, isTrue);
  });
}
