import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:frontend/features/nodos/data/rtc_screen_share.dart';
import 'package:frontend/features/nodos/presentation/widgets/rtc_presentation_layout.dart';

class TestTrack extends MediaStreamTrack {
  TestTrack(this.name);
  final String name;
  int stops = 0;
  @override
  String get kind => 'video';
  @override
  bool enabled = true;
  @override
  Future<void> stop() async => stops++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestStream extends MediaStream {
  TestStream(this.tracks) : super('test', 'local');
  final List<MediaStreamTrack> tracks;
  int disposals = 0;
  @override
  List<MediaStreamTrack> getVideoTracks() => tracks;
  @override
  List<MediaStreamTrack> getTracks() => tracks;
  @override
  Future<void> dispose() async => disposals++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late TestTrack camera, display;
  late TestStream stream;
  late RtcScreenShare sharing;
  late List<MediaStreamTrack?> sent;
  late int changed, fatal;
  setUp(() {
    camera = TestTrack('camera')..enabled = false;
    display = TestTrack('display');
    stream = TestStream([display]);
    sent = [];
    changed = 0;
    fatal = 0;
    sharing = RtcScreenShare(
      cameraTrack: () => camera,
      replaceTrack: (track) async => sent.add(track),
      onChanged: () => changed++,
      onRestoreFailure: () => fatal++,
    );
  });

  test('start/stop restores the disabled camera without stopping it', () async {
    await sharing.start(() async => stream);
    expect(sharing.active, true);
    expect(sharing.videoTrack, display);
    expect(sent, [display]);
    await sharing.stop();
    expect(sent, [display, camera]);
    expect(sharing.active, false);
    expect(camera.enabled, false);
    expect(camera.stops, 0);
    expect(display.stops, 1);
    expect(display.onEnded, null);
    expect(stream.disposals, 1);
    expect(changed, 2);
    expect(fatal, 0);
  });

  test(
    'cancelled OS permission leaves the call intact and can retry',
    () async {
      await expectLater(
        sharing.start(() async => throw StateError('denied')),
        throwsStateError,
      );
      expect(sent, isEmpty);
      expect(sharing.active, false);
      await sharing.start(() async => stream);
      expect(sharing.active, true);
      await sharing.close();
    },
  );

  test('closing while permission is pending revokes the late stream', () async {
    final capture = Completer<MediaStream>();
    final started = Completer<void>();
    final start = sharing.start(() {
      started.complete();
      return capture.future;
    });
    await started.future;
    final close = sharing.close();
    capture.complete(stream);
    await start;
    await close;
    expect(sent, isEmpty);
    expect(stream.disposals, 1);
    expect(display.stops, 1);
    expect(sharing.active, false);
  });

  test('duplicate starts never open another capture', () async {
    var captures = 0;
    Future<MediaStream> capture() async {
      captures++;
      return stream;
    }

    await Future.wait([sharing.start(capture), sharing.start(capture)]);
    expect(captures, 1);
    expect(sent, [display]);
    await sharing.close();
  });
  test(
    'moderator video block during permission prompt revokes the late capture',
    () async {
      var allowed = true;
      final pending = Completer<MediaStream>(), entered = Completer<void>();
      final start = sharing.start(() {
        entered.complete();
        return pending.future;
      }, canPublish: () => allowed);
      await entered.future;
      allowed = false;
      pending.complete(stream);
      await start;
      expect(sent, isEmpty);
      expect(sharing.active, false);
      expect(display.stops, 1);
      expect(stream.disposals, 1);
    },
  );

  test(
    'close during sender replacement releases capture without publishing it',
    () async {
      final entered = Completer<void>(), replacement = Completer<void>();
      sharing = RtcScreenShare(
        cameraTrack: () => camera,
        replaceTrack: (_) async {
          entered.complete();
          await replacement.future;
        },
        onChanged: () => changed++,
        onRestoreFailure: () => fatal++,
      );
      final start = sharing.start(() async => stream);
      final rejected = expectLater(start, throwsStateError);
      await entered.future;
      final close = sharing.close();
      replacement.complete();
      await rejected;
      await close;
      expect(changed, 0);
      expect(sharing.active, false);
      expect(display.stops, 1);
      expect(stream.disposals, 1);
    },
  );

  test(
    'source ending during replacement rolls back without publishing',
    () async {
      sharing = RtcScreenShare(
        cameraTrack: () => camera,
        replaceTrack: (track) async {
          sent.add(track);
          if (identical(track, display)) display.onEnded!();
        },
        onChanged: () => changed++,
        onRestoreFailure: () => fatal++,
      );
      await expectLater(sharing.start(() async => stream), throwsStateError);
      await sharing.serialized(() async {});
      expect(sent, [display, camera]);
      expect(changed, 0);
      expect(sharing.active, false);
      expect(stream.disposals, 1);
    },
  );

  test(
    'publication failure does not retain a disposed display stream',
    () async {
      sharing = RtcScreenShare(
        cameraTrack: () => camera,
        replaceTrack: (track) async => sent.add(track),
        onChanged: () => throw StateError('signaling closed'),
        onRestoreFailure: () => fatal++,
      );
      await expectLater(sharing.start(() async => stream), throwsStateError);
      expect(sharing.active, false);
      expect(sent, [display, camera]);
      expect(stream.disposals, 1);
    },
  );

  test(
    'new peers wait for replacement and receive the active display track',
    () async {
      final capture = Completer<MediaStream>();
      final start = sharing.start(() => capture.future);
      MediaStreamTrack? peerTrack;
      final peer = sharing.serialized(() async {
        peerTrack = sharing.videoTrack;
      });
      capture.complete(stream);
      await start;
      await peer;
      expect(peerTrack, display);
      await sharing.stop();
      await sharing.serialized(() async {
        peerTrack = sharing.videoTrack;
      });
      expect(peerTrack, camera);
    },
  );

  test('OS ended event restores camera and releases the display', () async {
    await sharing.start(() async => stream);
    display.onEnded!();
    await sharing.serialized(() async {});
    expect(sent, [display, camera]);
    expect(sharing.active, false);
    expect(display.stops, 1);
    expect(stream.disposals, 1);
  });

  test(
    'partial mesh replacement failure rolls back and stops capture',
    () async {
      sharing = RtcScreenShare(
        cameraTrack: () => camera,
        replaceTrack: (track) async {
          sent.add(track);
          if (identical(track, display)) {
            throw StateError('second sender failed');
          }
        },
        onChanged: () => changed++,
        onRestoreFailure: () => fatal++,
      );
      await expectLater(sharing.start(() async => stream), throwsStateError);
      expect(sent, [display, camera]);
      expect(sharing.active, false);
      expect(display.stops, 1);
      expect(stream.disposals, 1);
      expect(changed, 0);
      expect(fatal, 0);
    },
  );

  test(
    'failed camera restoration fails closed and still disposes capture',
    () async {
      sharing = RtcScreenShare(
        cameraTrack: () => camera,
        replaceTrack: (track) async {
          if (identical(track, camera)) throw StateError('restore');
        },
        onChanged: () => changed++,
        onRestoreFailure: () => fatal++,
      );
      await sharing.start(() async => stream);
      await sharing.stop();
      expect(fatal, 1);
      expect(sharing.active, false);
      expect(display.stops, 1);
      expect(stream.disposals, 1);
    },
  );

  test(
    'invalid display stream is disposed without replacing a sender',
    () async {
      final empty = TestStream([]);
      await expectLater(sharing.start(() async => empty), throwsStateError);
      expect(empty.disposals, 1);
      expect(sent, isEmpty);
    },
  );

  test(
    'close releases once, never restores camera or starts another capture',
    () async {
      await sharing.start(() async => stream);
      await sharing.close();
      await sharing.close();
      await sharing.start(() async => throw StateError('must not run'));
      expect(sent, [display]);
      expect(display.stops, 1);
      expect(stream.disposals, 1);
    },
  );

  for (final width in [320.0, 390.0, 800.0, 1280.0]) {
    testWidgets('presentation fits width $width with three participant tiles', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RtcPresentationLayout(
              presentation: const ColoredBox(
                color: Colors.black,
                child: Center(child: Text('Pantalla compartida')),
              ),
              participants: [
                for (var i = 0; i < 3; i++)
                  Center(child: Text('Participante $i')),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Pantalla compartida'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
