import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Only server-originated permissions can change these privacy restrictions.
class RtcPermissions {
  const RtcPermissions({
    this.microphoneAllowed = true,
    this.cameraAllowed = true,
    this.kicked = false,
  });
  final bool microphoneAllowed, cameraAllowed, kicked;
  void restrictReceivedTracks(Iterable<MediaStreamTrack> tracks) {
    for (final track in tracks) {
      if (track.kind == 'audio') track.enabled = microphoneAllowed && !kicked;
      if (track.kind == 'video') track.enabled = cameraAllowed && !kicked;
    }
  }

  ({bool microphone, bool camera}) constrain({
    required bool microphone,
    required bool camera,
  }) => (
    microphone: microphone && microphoneAllowed && !kicked,
    camera: camera && cameraAllowed && !kicked,
  );
  static RtcPermissions? parse(dynamic value) {
    if (value is! Map ||
        value['microphone_allowed'] is! bool ||
        value['camera_allowed'] is! bool ||
        value['kicked'] is! bool) {
      return null;
    }
    return RtcPermissions(
      microphoneAllowed: value['microphone_allowed'] as bool,
      cameraAllowed: value['camera_allowed'] as bool,
      kicked: value['kicked'] as bool,
    );
  }
}
