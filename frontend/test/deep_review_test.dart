import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/iam/providers/auth_provider.dart';
import 'package:frontend/features/iam/providers/profile_provider.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/providers/chat_provider.dart';
import 'package:frontend/features/nodos/providers/nodos_provider.dart';
import 'nocturne_design_test.dart' show FakeIamRepository;

final node = Nodo(
  id: 'n1',
  nombre: 'Equipo',
  tokenAcceso: 'token',
  creadorId: 'u1',
  estado: 'active',
  miembrosCount: 2,
  createdAt: DateTime.utc(2026, 10, 1),
);

Mensaje message(String id, int minute, {String author = 'u2'}) => Mensaje(
  id: id,
  nodoId: 'n1',
  userId: author,
  userName: 'Ana',
  contenido: id,
  createdAt: DateTime.utc(2026, 10, 1, 9, minute),
);

/// Simula el servidor: lista completa sin cursor, solo lo nuevo con cursor.
class PollingNodos extends NodosRepository {
  final server = <Mensaje>[];
  final cursors = <String?>[];
  int unreadFailures = 0;

  @override
  Future<List<Nodo>> fetchNodos() async => [node];

  @override
  Future<int> getUnreadCount(String nodoId) async {
    if (unreadFailures-- > 0) throw Exception('Sin conexión');
    return 4;
  }

  @override
  Future<MensajesPage> fetchMensajes(
    String nodoId, {
    String? subgrupoId,
    String? despuesDe,
  }) async {
    cursors.add(despuesDe);
    if (despuesDe == null) return MensajesPage(List.of(server));
    final i = server.indexWhere((m) => m.id == despuesDe);
    return MensajesPage(server.sublist(i + 1), incremental: true);
  }

  @override
  Future<Mensaje> sendMensaje(
    String nodoId,
    String contenido, {
    String? subgrupoId,
  }) async {
    final sent = message('propio', 30, author: 'u1');
    server.add(sent);
    return sent;
  }
}

class AccountProfiles extends FakeIamRepository {
  String name = 'Ana Rivas';
  @override
  Future<Map<String, dynamic>> fetchProfile() async => {
    'id': name,
    'name': name,
    'email': '$name@ironlink.dev',
  };
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'chat polling asks only for new messages and never duplicates',
    () async {
      final repo = PollingNodos()
        ..server.addAll([message('a', 1), message('b', 2)]);
      final container = ProviderContainer(
        overrides: [nodosRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      container.listen(chatMessagesProvider, (_, _) {});
      container.read(selectedNodoProvider.notifier).state = node;
      await Future<void>.delayed(Duration.zero);
      final chat = container.read(chatMessagesProvider.notifier);
      expect(container.read(chatMessagesProvider).mensajes.map((m) => m.id), [
        'a',
        'b',
      ]);

      // Llega un mensaje ajeno y después se envía uno propio.
      repo.server.add(message('c', 3));
      expect(await chat.sendMensaje('hola'), isTrue);
      await chat.loadMensajes(silent: true);
      // El cursor es el último recibido del servidor, no el propio enviado:
      // así el mensaje ajeno anterior no se pierde.
      expect(repo.cursors.last, 'b');
      expect(container.read(chatMessagesProvider).mensajes.map((m) => m.id), [
        'a',
        'b',
        'c',
        'propio',
      ]);
      await chat.loadMensajes(silent: true);
      expect(repo.cursors.last, 'propio');
      expect(container.read(chatMessagesProvider).mensajes, hasLength(4));
    },
  );

  test('a failed unread count keeps the last known badge', () async {
    final repo = PollingNodos();
    final container = ProviderContainer(
      overrides: [nodosRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    container.listen(nodosProvider, (_, _) {});
    final nodos = container.read(nodosProvider.notifier);
    await nodos.loadNodos();
    expect(container.read(unreadCountsProvider), {'n1': 4});
    repo.unreadFailures = 1;
    await nodos.fetchUnreadCounts();
    expect(container.read(unreadCountsProvider), {'n1': 4});
  });

  test('the profile is reloaded when another account signs in', () async {
    final repo = AccountProfiles();
    final container = ProviderContainer(
      overrides: [iamRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    container.listen(profileProvider, (_, _) {});
    final auth = container.read(authProvider.notifier);
    auth.state = AuthState(status: AuthStatus.authenticated, userId: 'a');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(profileProvider).profile?.name, 'Ana Rivas');

    repo.name = 'Beto Cruz';
    auth.state = AuthState(status: AuthStatus.unauthenticated);
    auth.state = AuthState(status: AuthStatus.authenticated, userId: 'b');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(profileProvider).profile?.name, 'Beto Cruz');
  });
}
