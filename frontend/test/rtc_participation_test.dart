import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/nodos/data/rtc_participation.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 15);
  test('legacy or malformed server capabilities keep new signals disabled', () {
    expect(RtcParticipation.capabilities(null), isEmpty);
    expect(RtcParticipation.capabilities('reaction'), isEmpty);
    expect(
      RtcParticipation.capabilities(['hand_state', 'reaction', 'kick_peer', 4]),
      {'hand_state', 'reaction'},
    );
    expect(
      RtcParticipation.capabilities([
        'microphone_state',
        'hand_state',
        'reaction',
        'screen_state',
      ]),
      RtcParticipation.signalTypes,
    );
  });
  test('screen state is independent of microphone and requires a boolean', () {
    final state = RtcParticipation();
    expect(state.apply('screen_state', {'enabled': 'true'}, now), false);
    expect(state.screenSharing, false);
    state.apply('microphone_state', {'enabled': false}, now);
    expect(state.apply('screen_state', {'enabled': true}, now), true);
    expect(state.screenSharing, true);
    expect(state.microphoneEnabled, false);
    state.apply('screen_state', {'enabled': false}, now);
    expect(state.screenSharing, false);
  });
  test('hand states preserve queue order until lowered', () {
    final state = RtcParticipation();
    expect(state.apply('hand_state', {'raised': true}, now), true);
    expect(state.handRaisedAt, now);
    state.apply('hand_state', {
      'raised': true,
    }, now.add(const Duration(seconds: 5)));
    expect(state.handRaisedAt, now);
    state.apply('hand_state', {'raised': false}, now);
    expect(state.handRaised, false);
    expect(state.handRaisedAt, null);
    state.apply('hand_state', {
      'raised': true,
    }, now.add(const Duration(seconds: 6)));
    expect(state.handRaisedAt, now.add(const Duration(seconds: 6)));
  });
  test('silencing uses a real boolean and rejects strings', () {
    final state = RtcParticipation();
    expect(state.apply('microphone_state', {'enabled': 'false'}, now), false);
    expect(state.microphoneEnabled, true);
    expect(state.apply('microphone_state', {'enabled': false}, now), true);
    expect(state.microphoneEnabled, false);
    state.apply('microphone_state', {'enabled': true}, now);
    expect(state.microphoneEnabled, true);
  });
  test('all approved reactions last exactly three seconds', () {
    for (final emoji in RtcParticipation.reactions) {
      final state = RtcParticipation();
      expect(state.apply('reaction', {'emoji': emoji}, now), true);
      expect(
        state.visibleReaction(now.add(const Duration(milliseconds: 2999))),
        emoji,
      );
      expect(state.visibleReaction(now.add(const Duration(seconds: 3))), null);
    }
  });
  test(
    'local reaction rate is bounded and invalid values cannot consume cooldown',
    () {
      final state = RtcParticipation();
      expect(state.react('invalid', now), false);
      expect(state.react('👏', now), true);
      expect(
        state.react('👍', now.add(const Duration(milliseconds: 999))),
        false,
      );
      expect(state.reaction, '👏');
      expect(state.react('👍', now.add(const Duration(seconds: 1))), true);
      expect(state.reaction, '👍');
    },
  );
  test('participant instances are isolated and reactions are disposable', () {
    final a = RtcParticipation(), b = RtcParticipation();
    a.apply('hand_state', {'raised': true}, now);
    a.apply('reaction', {'emoji': '👏'}, now);
    expect(b.handRaised, false);
    expect(b.reaction, null);
    a.clearReaction();
    expect(a.visibleReaction(now), null);
    expect(a.handRaised, true);
  });
  test('unknown events do not mutate state', () {
    final state = RtcParticipation();
    expect(state.apply('kick_peer', {'raised': true}, now), false);
    expect(state.apply('hand_state', {'raised': null}, now), false);
    expect(state.apply('reaction', {'emoji': '<script>'}, now), false);
    expect(state.handRaised, false);
    expect(state.reaction, null);
  });
}
