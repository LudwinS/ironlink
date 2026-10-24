import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:frontend/features/nodos/data/rtc_audio_devices.dart';
import 'package:frontend/features/nodos/data/rtc_permissions.dart';
import 'package:frontend/features/nodos/presentation/widgets/rtc_audio_devices_dialog.dart';

MediaDeviceInfo device(String kind, String id) =>
    MediaDeviceInfo(kind: kind, deviceId: id, label: 'Dispositivo $id');

class ReceivedTrack extends MediaStreamTrack {
  ReceivedTrack(this.kind);
  @override
  final String kind;
  @override
  bool enabled = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'receiver enforces server audio/video restrictions even if sender ignores them',
    () {
      final audio = ReceivedTrack('audio'), video = ReceivedTrack('video');
      const deniedAudio = RtcPermissions(microphoneAllowed: false);
      deniedAudio.restrictReceivedTracks([audio, video]);
      expect(audio.enabled, false);
      expect(video.enabled, true);
      const deniedVideo = RtcPermissions(cameraAllowed: false);
      deniedVideo.restrictReceivedTracks([audio, video]);
      expect(audio.enabled, true);
      expect(video.enabled, false);
      const kicked = RtcPermissions(kicked: true);
      kicked.restrictReceivedTracks([audio, video]);
      expect(audio.enabled, false);
      expect(video.enabled, false);
    },
  );
  test(
    'granting permission never activates a previously disabled camera or microphone',
    () {
      const grant = RtcPermissions();
      expect(grant.constrain(microphone: false, camera: false), (
        microphone: false,
        camera: false,
      ));
      const mute = RtcPermissions(microphoneAllowed: false);
      expect(mute.constrain(microphone: true, camera: true), (
        microphone: false,
        camera: true,
      ));
      const blockVideo = RtcPermissions(cameraAllowed: false);
      expect(blockVideo.constrain(microphone: true, camera: true), (
        microphone: true,
        camera: false,
      ));
      const kicked = RtcPermissions(kicked: true);
      expect(kicked.constrain(microphone: true, camera: true), (
        microphone: false,
        camera: false,
      ));
    },
  );
  late RtcAudioDevices audio;
  late List<MediaDeviceInfo> found;
  late List<String> routed;
  setUp(() {
    found = [
      device('audioinput', 'mic1'),
      device('audioinput', 'mic2'),
      device('audiooutput', 'speaker'),
      device('videoinput', 'camera'),
    ];
    routed = [];
    audio = RtcAudioDevices(
      enumerate: () async => found,
      selectInput: (id) async => routed.add('input:$id'),
      selectOutput: (id) async => routed.add('output:$id'),
    );
  });
  tearDown(() {
    audio.close();
    audio.dispose();
  });

  test(
    'only real audio devices are listed and duplicates are removed',
    () async {
      found.add(device('audioinput', 'mic1'));
      found.add(device('audioinput', ''));
      await audio.refresh();
      expect(audio.devices.length, 3);
      expect(audio.inputId, null); // No claim about the current native default.
      expect(audio.outputId, null);
      expect(routed, isEmpty);
    },
  );
  test(
    'input/output selection is independent and unavailable IDs are ignored',
    () async {
      await audio.refresh();
      await audio.select('audioinput', 'missing');
      await audio.select('audioinput', 'mic2');
      await audio.select('audiooutput', 'speaker');
      expect(routed, ['input:mic2', 'output:speaker']);
      expect(audio.inputId, 'mic2');
      expect(audio.outputId, 'speaker');
    },
  );
  test(
    'failed native selection preserves the previous confirmed device',
    () async {
      audio = RtcAudioDevices(
        enumerate: () async => found,
        selectInput: (id) async {
          if (id == 'mic2') throw StateError('disconnected');
        },
        selectOutput: (_) async {},
      );
      await audio.refresh();
      await audio.select('audioinput', 'mic1');
      await audio.select('audioinput', 'mic2');
      expect(audio.inputId, 'mic1');
      expect(audio.error, isNotNull);
      expect(audio.busy, false);
    },
  );
  test(
    'pending selection is not reported as successful and duplicate actions are ignored',
    () async {
      final pending = Completer<void>();
      audio = RtcAudioDevices(
        enumerate: () async => found,
        selectInput: (id) {
          routed.add(id);
          return pending.future;
        },
        selectOutput: (_) async {},
      );
      await audio.refresh();
      final select = audio.select('audioinput', 'mic1');
      expect(audio.busy, true);
      expect(audio.inputId, null);
      await audio.select('audioinput', 'mic2');
      expect(routed, ['mic1']);
      pending.complete();
      await select;
      expect(audio.inputId, 'mic1');
    },
  );
  test(
    'disconnected selected device is cleared without silently changing routes',
    () async {
      await audio.refresh();
      await audio.select('audioinput', 'mic1');
      found = [device('audioinput', 'mic2')];
      await audio.refresh();
      expect(audio.inputId, null);
      expect(routed, ['input:mic1']);
    },
  );
  test(
    'close while listing drops the result and never notifies disposed listeners',
    () async {
      final pending = Completer<List<MediaDeviceInfo>>();
      audio = RtcAudioDevices(
        enumerate: () => pending.future,
        selectInput: (_) async {},
        selectOutput: (_) async {},
      );
      var notifications = 0;
      audio.addListener(() => notifications++);
      final refresh = audio.refresh();
      audio.close();
      pending.complete(found);
      await refresh;
      expect(audio.devices, isEmpty);
      expect(notifications, 1);
      await audio.select('audioinput', 'mic1');
      expect(routed, isEmpty);
    },
  );
  test('enumeration failure is explicit and can be retried', () async {
    var fail = true;
    audio = RtcAudioDevices(
      enumerate: () async {
        if (fail) throw StateError('native');
        return found;
      },
      selectInput: (_) async {},
      selectOutput: (_) async {},
    );
    await audio.refresh();
    expect(audio.error, isNotNull);
    fail = false;
    await audio.refresh();
    expect(audio.error, null);
    expect(audio.devices.length, 3);
  });
  test(
    'server permissions reject malformed values rather than granting access',
    () {
      for (final value in [
        null,
        'allowed',
        {},
        {'microphone_allowed': 'true', 'camera_allowed': true, 'kicked': false},
      ]) {
        expect(RtcPermissions.parse(value), null);
      }
      final denied = RtcPermissions.parse({
        'microphone_allowed': false,
        'camera_allowed': false,
        'kicked': false,
      })!;
      expect(denied.microphoneAllowed, false);
      expect(denied.cameraAllowed, false);
      expect(denied.kicked, false);
    },
  );
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('audio selector fits width $width at 130 percent text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await audio.refresh();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(body: RtcAudioDevicesDialog(devices: audio)),
        ),
      );
      expect(find.text('Dispositivos de audio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
