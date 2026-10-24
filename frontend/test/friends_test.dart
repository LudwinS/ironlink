import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/presence/live_presence.dart';
import 'package:frontend/core/theme/app_colors.dart';
import 'package:frontend/features/nodos/data/direct_messages_repository.dart';
import 'package:frontend/features/nodos/data/live_updates_controller.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/direct_chats_workspace.dart';
import 'package:frontend/features/nodos/presentation/widgets/workspace_navigation.dart';
import 'package:frontend/features/social/data/friends_repository.dart';
import 'package:frontend/features/social/presentation/friends_workspace.dart';
import 'package:frontend/features/social/presentation/people_search_section.dart';
import 'package:frontend/features/social/providers/friends_provider.dart';

/// Registra cada petición y responde según la ruta.
class RouteAdapter implements HttpClientAdapter {
  final calls = <String>[];
  final bodies = <Object?>[];
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final query = options.uri.query;
    calls.add(
      '${options.method} ${options.path}${query.isEmpty ? '' : '?$query'}',
    );
    bodies.add(options.data);
    final Map<String, dynamic> body = switch (options.path) {
      '/usuarios/buscar' => {
        'success': true,
        'usuarios': [person('u1', 'Bea Ruiz', 'recibida', request: 'r9')],
      },
      '/amigos' => {
        'success': true,
        'amigos': [
          {
            'id': 'u2',
            'nombre': 'Carlos',
            'avatar_url': null,
            'avatar_color': '#00E5FF',
            'status_text': null,
            'desde': '2026-10-01T10:00:00Z',
            'nodos_comunes': [
              {'id': 'n1', 'nombre': 'Ingeniería'},
            ],
          },
        ],
      },
      '/amigos/solicitudes' when options.method == 'GET' => {
        'success': true,
        'recibidas': [request('r1', 'u3', 'Dora')],
        'enviadas': [request('r2', 'u4', 'Eva')],
      },
      '/amigos/solicitudes' =>
        status == 200
            ? {'success': true, 'estado': 'aceptada', 'solicitud_id': 'r5'}
            : {'success': false, 'message': 'Ya son amigos.'},
      '/bloqueados' => {
        'success': true,
        'bloqueados': [
          {
            'id': 'u8',
            'nombre': 'Iván',
            'avatar_url': null,
            'avatar_color': null,
            'desde': '2026-10-02T09:00:00Z',
          },
        ],
      },
      '/amigos/privacidad' => {
        'success': true,
        'solicitudes_de': options.method == 'PUT'
            ? (options.data as Map)['solicitudes_de']
            : 'nodos',
      },
      _ => {'success': true},
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      options.method == 'POST' && options.path == '/amigos/solicitudes'
          ? status
          : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> person(
  String id,
  String name,
  String amistad, {
  String? request,
  bool shares = false,
  bool blocked = false,
}) => {
  'id': id,
  'nombre': name,
  'avatar_url': null,
  'avatar_color': '#00E5FF',
  'amistad': amistad,
  'solicitud_id': request,
  'comparte_nodo': shares,
  'bloqueado': blocked,
};

Map<String, dynamic> request(String id, String user, String name) => {
  'id': id,
  'user_id': user,
  'nombre': name,
  'avatar_url': null,
  'avatar_color': null,
  'comparte_nodo': false,
  'created_at': '2026-10-02T09:00:00Z',
};

class FakeFriends extends FriendsRepository {
  FakeFriends() : super(client: Dio());
  List<PersonResult> people = [];
  List<Friend> friendList = [];
  FriendRequests pending = const FriendRequests();
  List<BlockedUser> blockedList = [];
  RequestPrivacy privacyValue = RequestPrivacy.everyone;
  final log = <String>[];

  @override
  Future<List<BlockedUser>> blocked() async => blockedList;

  @override
  Future<void> block(String userId) async {
    log.add('block $userId');
    final name = [
      ...friendList.where((f) => f.id == userId).map((f) => f.name),
      ...people.where((p) => p.id == userId).map((p) => p.name),
    ].firstOrNull;
    friendList = friendList.where((f) => f.id != userId).toList();
    blockedList = [...blockedList, BlockedUser(id: userId, name: name ?? '')];
  }

  @override
  Future<void> unblock(String userId) async {
    log.add('unblock $userId');
    blockedList = blockedList.where((b) => b.id != userId).toList();
  }

  @override
  Future<RequestPrivacy> privacy() async => privacyValue;

  @override
  Future<RequestPrivacy> setPrivacy(RequestPrivacy value) async {
    log.add('privacy ${value.wire}');
    return privacyValue = value;
  }

  @override
  Future<List<PersonResult>> search(String query) async {
    log.add('search $query');
    return people;
  }

  @override
  Future<List<Friend>> friends() async => friendList;

  @override
  Future<FriendRequests> requests() async => pending;

  @override
  Future<({Friendship status, String? requestId})> send(String userId) async {
    log.add('send $userId');
    return (status: Friendship.sent, requestId: 'new');
  }

  FriendRequests _without(String id) => FriendRequests(
    received: pending.received.where((r) => r.id != id).toList(),
    sent: pending.sent.where((r) => r.id != id).toList(),
  );

  @override
  Future<void> accept(String requestId) async {
    log.add('accept $requestId');
    final accepted = pending.received.where((r) => r.id == requestId);
    friendList = [
      ...friendList,
      for (final r in accepted) Friend(id: r.userId, name: r.name),
    ];
    pending = _without(requestId);
  }

  @override
  Future<void> reject(String requestId) async {
    log.add('reject $requestId');
    pending = _without(requestId);
  }

  @override
  Future<void> cancel(String requestId) async {
    log.add('cancel $requestId');
    pending = _without(requestId);
  }

  @override
  Future<void> remove(String userId) async {
    log.add('remove $userId');
    friendList = friendList.where((f) => f.id != userId).toList();
  }
}

/// Chat de amistad en memoria.
class FakeFriendChats extends DirectMessagesRepository {
  final log = <String>[];
  final messages = <DirectMessage>[];

  @override
  Future<List<DirectMessage>> friendHistory(String peerId) async {
    log.add('history $peerId');
    return List.of(messages);
  }

  @override
  Future<DirectMessage> friendSend(String peerId, String text) async {
    log.add('send $peerId $text');
    final message = DirectMessage(
      id: 'm${messages.length}',
      senderId: 'me',
      recipientId: peerId,
      content: text,
      kind: 'text',
      createdAt: DateTime.now(),
    );
    messages.add(message);
    return message;
  }
}

FriendRequest req(String id, String user, String name, {bool out = false}) =>
    FriendRequest(
      id: id,
      userId: user,
      name: name,
      createdAt: DateTime.utc(2026, 10, 2),
      outgoing: out,
    );

Widget host(FakeFriends repo, Widget child, {double scale = 1}) =>
    ProviderScope(
      overrides: [
        friendsOwnIdProvider.overrideWithValue('me'),
        friendsRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );

void main() {
  tearDown(LivePresence.clear);

  test('el repositorio usa las rutas y cuerpos de la API', () async {
    final adapter = RouteAdapter();
    final repo = FriendsRepository(
      client: Dio(BaseOptions(baseUrl: 'http://api.test'))
        ..httpClientAdapter = adapter,
    );
    final people = await repo.search('  Bea ');
    expect(people.single.friendship, Friendship.received);
    expect(people.single.requestId, 'r9');
    final friends = await repo.friends();
    expect(friends.single.sharedNodes.single.name, 'Ingeniería');
    final requests = await repo.requests();
    expect(requests.received.single.outgoing, isFalse);
    expect(requests.sent.single.outgoing, isTrue);
    final sent = await repo.send('u7');
    expect(sent.status, Friendship.friends, reason: 'aceptada automáticamente');
    await repo.accept('r1');
    await repo.reject('r1');
    await repo.cancel('r2');
    await repo.remove('u2');
    final blocked = await repo.blocked();
    expect(blocked.single.name, 'Iván');
    await repo.block('u8');
    await repo.unblock('u8');
    expect(await repo.privacy(), RequestPrivacy.sharedNodes);
    expect(await repo.setPrivacy(RequestPrivacy.nobody), RequestPrivacy.nobody);
    expect(adapter.calls, [
      'GET /usuarios/buscar?q=Bea',
      'GET /amigos',
      'GET /amigos/solicitudes',
      'POST /amigos/solicitudes',
      'POST /amigos/solicitudes/r1/aceptar',
      'POST /amigos/solicitudes/r1/rechazar',
      'DELETE /amigos/solicitudes/r2',
      'DELETE /amigos/u2',
      'GET /bloqueados',
      'PUT /bloqueados/u8',
      'DELETE /bloqueados/u8',
      'GET /amigos/privacidad',
      'PUT /amigos/privacidad',
    ]);
    expect(adapter.bodies[3], {'user_id': 'u7'});
    expect(adapter.bodies.last, {'solicitudes_de': 'nadie'});
    expect(FriendsRepository.isEmailQuery('ana@iron.link'), isTrue);
    expect(FriendsRepository.isEmailQuery('Ana Mena'), isFalse);

    adapter.status = 409;
    await expectLater(
      repo.send('u2'),
      throwsA(
        isA<FriendsException>().having(
          (e) => e.message,
          'message',
          'Ya son amigos.',
        ),
      ),
    );
  });

  testWidgets(
    'la búsqueda muestra personas con su estado y las acciones lo cambian',
    (tester) async {
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = FakeFriends()
        ..people = [
          PersonResult.fromJson(
            person('a', 'Ana Sol', 'ninguna', shares: true),
          ),
          PersonResult.fromJson(
            person('b', 'Bea Ruiz', 'recibida', request: 'r1'),
          ),
          PersonResult.fromJson(
            person('c', 'Carlos Paz', 'enviada', request: 'r2'),
          ),
          PersonResult.fromJson(person('d', 'Dora Luz', 'amigos')),
        ];
      String query = 'a';
      late StateSetter update;
      await tester.pumpWidget(
        host(
          repo,
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  PeopleSearchSection(query: query, debounce: Duration.zero),
                ],
              );
            },
          ),
          scale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('PERSONAS'),
        findsNothing,
        reason: 'mínimo 2 caracteres',
      );
      expect(repo.log, isEmpty);

      update(() => query = 'an');
      await tester.pumpAndSettle();
      expect(repo.log, ['search an']);
      expect(find.text('PERSONAS'), findsOneWidget);
      expect(find.text('Comparten un nodo'), findsOneWidget);
      expect(find.text('Agregar amigo'), findsOneWidget);
      expect(find.text('Aceptar'), findsOneWidget);
      expect(find.text('Solicitud enviada'), findsOneWidget);
      expect(find.text('Amigos'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'sin desbordes a 390 px');

      await tester.tap(find.text('Agregar amigo'));
      await tester.pumpAndSettle();
      expect(repo.log, contains('send a'));
      expect(find.text('Agregar amigo'), findsNothing);
      expect(find.text('Solicitud enviada'), findsNWidgets(2));

      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();
      expect(repo.log, contains('accept r1'));
      expect(find.text('Amigos'), findsNWidgets(2));

      // Enviada y Amigos no admiten acción.
      await tester.tap(find.text('Solicitud enviada').first);
      await tester.pumpAndSettle();
      expect(repo.log.where((l) => l.startsWith('send')).length, 1);
    },
  );

  testWidgets('pendientes: aceptar, rechazar y cancelar', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeFriends()
      ..pending = FriendRequests(
        received: [req('r1', 'u1', 'Bea Ruiz'), req('r2', 'u2', 'Carlos Paz')],
        sent: [req('r3', 'u3', 'Dora Luz', out: true)],
      );
    await tester.pumpWidget(
      host(repo, FriendsWorkspace(onOpenChat: (_) {}), scale: 1.3),
    );
    await tester.pumpAndSettle();
    expect(find.text('Aún no tienes amigos'), findsNothing);
    await tester.tap(find.text('Pendientes'));
    await tester.pumpAndSettle();
    expect(find.text('RECIBIDAS — 2'), findsOneWidget);
    expect(find.text('ENVIADAS — 1'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Aceptar solicitud de Bea Ruiz'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rechazar solicitud de Carlos Paz'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancelar solicitud a Dora Luz'));
    await tester.pumpAndSettle();
    expect(repo.log, ['accept r1', 'reject r2', 'cancel r3']);
    expect(find.text('No hay solicitudes pendientes'), findsOneWidget);

    // La persona aceptada aparece en «Todos».
    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    expect(find.text('Bea Ruiz'), findsOneWidget);
  });

  testWidgets(
    'el chat de amistad no exige nodo común; bloquear y desbloquear',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <String>[];
      final repo = FakeFriends()
        ..friendList = const [
          Friend(
            id: 'u1',
            name: 'Bea Ruiz',
            sharedNodes: [SharedNode('n1', 'Ingeniería')],
          ),
          Friend(id: 'u2', name: 'Carlos Paz'),
        ];
      LivePresence.values.value = {'u1': 'available', 'u2': 'offline'};
      await tester.pumpWidget(
        host(
          repo,
          FriendsWorkspace(onOpenChat: (friend) => opened.add(friend.id)),
          scale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('EN LÍNEA — 1'), findsOneWidget);
      expect(find.text('Carlos Paz'), findsNothing);
      await tester.tap(find.byTooltip('Enviar mensaje a Bea Ruiz'));
      expect(opened, ['u1']);

      await tester.tap(find.text('Todos'));
      await tester.pumpAndSettle();
      // Sin nodo en común el chat sigue disponible.
      await tester.tap(find.byTooltip('Enviar mensaje a Carlos Paz'));
      expect(opened, ['u1', 'u2']);
      await tester.tap(find.text('Carlos Paz'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pueden chatear igualmente'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Enviar mensaje'));
      await tester.pumpAndSettle();
      expect(opened, ['u1', 'u2', 'u2']);

      await tester.tap(find.text('Carlos Paz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Eliminar amigo').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Eliminar amigo'));
      await tester.pumpAndSettle();
      expect(repo.log, ['remove u2']);
      expect(find.text('Carlos Paz'), findsNothing);

      // Bloquear desde el menú pide confirmación y quita a la persona.
      await tester.tap(find.byTooltip('Más opciones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bloquear'));
      await tester.pumpAndSettle();
      expect(find.text('¿Bloquear a Bea Ruiz?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
      await tester.pumpAndSettle();
      expect(repo.log, ['remove u2', 'block u1']);
      expect(find.text('Aún no tienes amigos'), findsOneWidget);

      await tester.tap(find.text('Bloqueados'));
      await tester.pumpAndSettle();
      expect(find.text('BLOQUEADOS — 1'), findsOneWidget);
      expect(find.text('Bea Ruiz'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Desbloquear'));
      await tester.pumpAndSettle();
      expect(repo.log.last, 'unblock u1');
      expect(find.text('No has bloqueado a nadie'), findsOneWidget);
    },
  );

  testWidgets('bloquear desde el perfil y ajustar la privacidad a 390 px', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeFriends()
      ..friendList = const [Friend(id: 'u1', name: 'Bea Ruiz')];
    await tester.pumpWidget(
      host(repo, FriendsWorkspace(onOpenChat: (_) {}), scale: 1.3),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bloqueados'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'cuatro pestañas a 390 px');

    await tester.tap(find.byTooltip('Privacidad de solicitudes'));
    await tester.pumpAndSettle();
    expect(find.text('Quién puede enviarte solicitudes'), findsOneWidget);
    expect(find.text('Quienes comparten un nodo contigo'), findsOneWidget);
    await tester.tap(find.text('Nadie'));
    await tester.pumpAndSettle();
    expect(repo.log, ['privacy nadie']);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Nadie'),
        matching: find.byIcon(Icons.radio_button_checked_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Todos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bea Ruiz'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Bloquear'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
    await tester.pumpAndSettle();
    expect(repo.log.last, 'block u1');
  });

  testWidgets('búsqueda: correo completo, bloquear y desbloquear', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeFriends()
      ..people = [
        PersonResult.fromJson(person('a', 'Ana Sol', 'ninguna')),
        PersonResult.fromJson(
          person('b', 'Bea Ruiz', 'ninguna', blocked: true),
        ),
      ];
    String query = 'Ana';
    late StateSetter update;
    await tester.pumpWidget(
      host(
        repo,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                PeopleSearchSection(query: query, debounce: Duration.zero),
              ],
            );
          },
        ),
        scale: 1.3,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bloqueada'), findsOneWidget);
    expect(find.text('Desbloquear'), findsOneWidget);
    expect(find.text('Agregar amigo'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Desbloquear'));
    await tester.pumpAndSettle();
    expect(repo.log.last, 'unblock b');
    expect(find.text('Agregar amigo'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Más opciones para Ana Sol'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bloquear'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Bloquear'));
    await tester.pumpAndSettle();
    expect(repo.log.last, 'block a');
    expect(find.text('Desbloquear'), findsOneWidget);

    // Un correo sin coincidencia exacta explica que no hay parciales.
    repo.people = [];
    update(() => query = 'ana@iron');
    // El temporizador de la búsqueda se crea al reconstruir: se deja correr.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(repo.log.last, 'search ana@iron');
    expect(find.textContaining('Escribe el correo completo'), findsOneWidget);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('abrir el chat de un amigo siempre funciona a $width px', (
      tester,
    ) async {
      tester.view
        ..physicalSize = Size(width, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final chats = FakeFriendChats();
      final nodes = <Nodo>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directOwnUserIdProvider.overrideWithValue('me'),
            directRepositoryProvider.overrideWithValue(chats),
            directContactsProvider(nodes).overrideWith((ref) async => []),
            directChatRequestProvider.overrideWith(
              (ref) => const DirectChatTarget.friend(
                userId: 'u2',
                name: 'Carlos Paz',
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppColors.theme(),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: Scaffold(body: DirectChatsWorkspace(nodos: nodes)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('No se encontró el chat'), findsNothing);
      expect(find.text('Chat de amistad'), findsOneWidget);
      expect(find.byTooltip('Llamar'), findsNothing);
      expect(find.text('Aquí empieza la conversación'), findsOneWidget);
      expect(chats.log, ['history u2']);
      await tester.enterText(find.byType(TextField), 'Hola, Carlos');
      await tester.tap(find.byTooltip('Enviar mensaje'));
      await tester.pumpAndSettle();
      expect(chats.log, contains('send u2 Hola, Carlos'));
      expect(find.text('Hola, Carlos'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('la bandeja convierte las conversaciones de amistad en chats', () {
    final conversation = FriendConversation.fromJson({
      'user_id': 'u2',
      'nombre': 'Carlos Paz',
      'avatar_url': null,
      'avatar_color': null,
      'no_leidos': 3,
      'ultimo': {
        'id': 'm1',
        'sender_id': 'u2',
        'recipient_id': 'me',
        'content': 'Hola',
        'kind': 'text',
        'reunion_id': null,
        'created_at': '2026-10-02T09:00:00Z',
        'read_at': null,
      },
    });
    final contact = DirectContact.friendOf(
      userId: conversation.userId,
      name: conversation.name,
      messages: [conversation.latest],
      unread: conversation.unread,
    );
    expect(contact.isFriend, isTrue);
    expect(contact.key, 'amigo:u2');
    expect(contact.origin, 'Amigos');
    expect(contact.unread('me'), 3, reason: 'el servidor cuenta los no leídos');
    expect(contact.latest!.content, 'Hola');
  });

  test('el canal en vivo trae el contador de solicitudes', () {
    final live = LiveUpdatesController(ticket: () async => 't');
    addTearDown(live.dispose);
    expect(
      live.applySnapshot({
        'type': 'live_snapshot',
        'user_id': 'me',
        'presence': {'me': 'available'},
        'meetings': [],
        'friends': {'pending': 3, 'unread_messages': 4},
        'truncated': false,
      }),
      isTrue,
    );
    expect(live.pendingFriendRequests, 3);
    expect(live.unreadFriendMessages, 4);
    // Servidores anteriores no lo envían.
    live.applySnapshot({
      'type': 'live_snapshot',
      'user_id': 'me',
      'presence': {'me': 'available'},
      'meetings': [],
      'truncated': false,
    });
    expect(live.pendingFriendRequests, 0);
    expect(live.unreadFriendMessages, 0);
  });

  testWidgets('el destino Amigos muestra las solicitudes recibidas', (
    tester,
  ) async {
    expect(workspaceLabels[WorkspaceDestination.amigos.index], 'Amigos');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: workspaceNavIcon(
            WorkspaceDestination.amigos.index,
            pendingFriends: 2,
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: workspaceNavIcon(
            WorkspaceDestination.chats.index,
            pendingFriends: 2,
            unreadChats: 5,
          ),
        ),
      ),
    );
    expect(find.text('5'), findsOneWidget, reason: 'no leídos de amistad');
    expect(find.text('2'), findsNothing);
  });
}
