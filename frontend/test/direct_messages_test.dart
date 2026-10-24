import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/nodos/data/direct_messages_repository.dart';

void main() {
  test('mensaje privado conserva remitente, destinatario y lectura', () {
    final message = DirectMessage.fromJson({
      'id': 'message-1',
      'sender_id': 'member-1',
      'recipient_id': 'member-2',
      'content': 'Hola',
      'kind': 'text',
      'reunion_id': null,
      'created_at': '2026-09-29T12:00:00Z',
      'read_at': '2026-09-29T12:01:00Z',
    });
    expect(message.senderId, 'member-1');
    expect(message.recipientId, 'member-2');
    expect(message.readAt, isNotNull);
  });

  test('invitación conserva la reunión para entrar a la llamada', () {
    final message = DirectMessage.fromJson({
      'id': 'message-2',
      'sender_id': 'member-1',
      'recipient_id': 'member-2',
      'content': 'Invitación a la videollamada: Sprint 3',
      'kind': 'call_invite',
      'reunion_id': 'room-1',
      'created_at': '2026-09-29T12:00:00Z',
      'read_at': null,
    });
    expect(message.kind, 'call_invite');
    expect(message.reunionId, 'room-1');
    expect(message.readAt, isNull);
  });
}
