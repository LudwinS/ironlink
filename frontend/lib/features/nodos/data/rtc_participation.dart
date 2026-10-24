/// Ephemeral participant state. No audio, media, tokens or identifiers are stored.
class RtcParticipation {
  static const reactions = ['👏', '👍', '❤️', '🎉', '😀', '😮'];
  static const reactionLifetime = Duration(seconds: 3);
  static const reactionCooldown = Duration(seconds: 1);
  static const signalTypes = {
    'microphone_state',
    'hand_state',
    'reaction',
    'screen_state',
  };

  static Set<String> capabilities(dynamic value) {
    if (value is! List) return {};
    return value
        .whereType<String>()
        .where((type) => signalTypes.contains(type) || type == 'moderation')
        .toSet();
  }

  bool microphoneEnabled = true;
  bool screenSharing = false;
  bool handRaised = false;
  DateTime? handRaisedAt;
  String? reaction;
  DateTime? reactionUntil;
  DateTime? _lastReactionSent;

  bool apply(String type, Map<String, dynamic> payload, DateTime now) {
    switch (type) {
      case 'screen_state':
        if (payload['enabled'] is! bool) return false;
        screenSharing = payload['enabled'] as bool;
        return true;
      case 'microphone_state':
        if (payload['enabled'] is! bool) return false;
        microphoneEnabled = payload['enabled'] as bool;
        return true;
      case 'hand_state':
        if (payload['raised'] is! bool) return false;
        final raised = payload['raised'] as bool;
        // Repeated 'raised' updates do not let a participant move in the queue.
        if (raised && !handRaised) handRaisedAt = now;
        if (!raised) handRaisedAt = null;
        handRaised = raised;
        return true;
      case 'reaction':
        if (!reactions.contains(payload['emoji'])) return false;
        reaction = payload['emoji'] as String;
        reactionUntil = now.add(reactionLifetime);
        return true;
      default:
        return false;
    }
  }

  bool react(String emoji, DateTime now) {
    if (!reactions.contains(emoji)) return false;
    if (_lastReactionSent != null &&
        now.difference(_lastReactionSent!) < reactionCooldown) {
      return false;
    }
    _lastReactionSent = now;
    return apply('reaction', {'emoji': emoji}, now);
  }

  String? visibleReaction(DateTime now) =>
      reactionUntil != null && now.isBefore(reactionUntil!) ? reaction : null;
  void clearReaction() {
    reaction = null;
    reactionUntil = null;
  }
}
