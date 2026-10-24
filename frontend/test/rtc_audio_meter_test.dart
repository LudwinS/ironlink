import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:frontend/features/nodos/data/rtc_call_controller.dart';

void main() {
  test('el medidor usa audioLevel y descarta estadísticas de vídeo', () {
    final meter = RtcAudioMeter();
    final reports = [
      StatsReport('video', 'inbound-rtp', 1, {
        'kind': 'video',
        'audioLevel': 0.9,
      }),
      StatsReport('audio', 'inbound-rtp', 1, {
        'kind': 'audio',
        'audioLevel': 0.08,
      }),
    ];
    expect(meter.sample(reports), closeTo(0.08, 0.0001));
  });

  test('calcula nivel RMS cuando solo hay energía acumulada', () {
    final meter = RtcAudioMeter();
    expect(
      meter.sample([
        StatsReport('audio', 'inbound-rtp', 1, {
          'mediaType': 'audio',
          'totalAudioEnergy': 1.0,
          'totalSamplesDuration': 10.0,
        }),
      ]),
      0,
    );
    expect(
      meter.sample([
        StatsReport('audio', 'inbound-rtp', 2, {
          'mediaType': 'audio',
          'totalAudioEnergy': 1.04,
          'totalSamplesDuration': 11.0,
        }),
      ]),
      closeTo(0.2, 0.0001),
    );
  });
}
