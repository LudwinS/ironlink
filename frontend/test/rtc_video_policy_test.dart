import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:frontend/features/nodos/data/rtc_prejoin.dart';
import 'package:frontend/features/nodos/data/rtc_video_policy.dart';

class PolicyTrack extends MediaStreamTrack {
  PolicyTrack(this.kind);
  @override
  final String kind;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PolicySender extends RTCRtpSender {
  PolicySender(String kind, this.parameters) : track = PolicyTrack(kind);
  @override
  final MediaStreamTrack track;
  @override
  final RTCRtpParameters parameters;
  int updates = 0;
  @override
  Future<bool> setParameters(RTCRtpParameters parameters) async {
    updates++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PolicyConnection extends RTCPeerConnection {
  PolicyConnection(this.videoSenders);
  final List<RTCRtpSender> videoSenders;
  @override
  Future<List<RTCRtpSender>> getSenders() async => videoSenders;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('$platform capture has explicit positive FPS in lobby and call', () {
      debugDefaultTargetPlatformOverride = platform;
      final constraints = rtcVideoConstraints(deviceId: 'camera');
      expect(constraints, RtcVideoPolicy.constraints(deviceId: 'camera'));
      expect(constraints['frameRate'], 15);
      expect(constraints['width'], 640);
      expect(constraints['height'], 480);
      expect(constraints['deviceId'], 'camera');
      expect(RtcVideoPolicy.constraints().containsKey('deviceId'), false);
    });
  }

  test('desktop capture also never requests zero FPS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(RtcVideoPolicy.constraints()['frameRate'], 24);
  });

  test('two mobile video senders have a bounded total bitrate', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final first = PolicySender(
      'video',
      RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 1)]),
    );
    final second = PolicySender(
      'video',
      RTCRtpParameters(encodings: [RTCRtpEncoding(ssrc: 2)]),
    );
    final audio = PolicySender(
      'audio',
      RTCRtpParameters(encodings: [RTCRtpEncoding()]),
    );
    await RtcVideoPolicy.apply(PolicyConnection([first, audio]));
    await RtcVideoPolicy.apply(PolicyConnection([second]));
    expect(first.parameters.encodings!.single.maxBitrate, 500000);
    expect(second.parameters.encodings!.single.maxBitrate, 500000);
    expect(first.parameters.encodings!.single.maxFramerate, 15);
    expect(first.updates, 1);
    expect(second.updates, 1);
    expect(audio.updates, 0);
  });

  test('negotiated encoding identity and stricter limits are preserved', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final encoding = RTCRtpEncoding(
      ssrc: 123,
      rid: 'camera',
      maxBitrate: 200000,
      maxFramerate: 10,
      scaleResolutionDownBy: 2,
    );
    final parameters = RTCRtpParameters(
      transactionId: 'negotiation',
      encodings: [encoding],
    );
    expect(RtcVideoPolicy.constrain(parameters), true);
    expect(parameters.transactionId, 'negotiation');
    expect(parameters.encodings, [same(encoding)]);
    expect(encoding.ssrc, 123);
    expect(encoding.rid, 'camera');
    expect(encoding.maxBitrate, 200000);
    expect(encoding.maxFramerate, 10);
    expect(encoding.scaleResolutionDownBy, 2);
  });

  test('missing encodings are not invented before negotiation', () {
    expect(RtcVideoPolicy.constrain(RTCRtpParameters()), false);
    final parameters = RTCRtpParameters(encodings: []);
    expect(RtcVideoPolicy.constrain(parameters), false);
    expect(parameters.encodings, isEmpty);
  });
}
