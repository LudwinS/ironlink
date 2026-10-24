import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/theme/app_colors.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/data/direct_messages_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/direct_chats_workspace.dart';
import 'package:frontend/features/nodos/presentation/widgets/workspace_navigation.dart';

final node = Nodo(
  id: 'node-1',
  nombre: 'Sprint 3 · Ingeniería',
  tokenAcceso: '',
  creadorId: 'own',
  estado: 'active',
  miembrosCount: 3,
  createdAt: DateTime(2026, 9, 30),
  rol: 'OWNER',
);
const peer = NodoMiembro(
  userId: 'peer',
  name: 'Ana Mena',
  email: 'ana@example.test',
  rol: 'MEMBER',
);
final received = DirectMessage(
  id: 'm1',
  senderId: 'peer',
  recipientId: 'own',
  content: '¿Revisamos el Sprint 3?',
  kind: 'text',
  createdAt: DateTime(2026, 9, 30, 9, 38),
);
final sent = DirectMessage(
  id: 'm2',
  senderId: 'own',
  recipientId: 'peer',
  content: 'Sí, terminemos la práctica.',
  kind: 'text',
  createdAt: DateTime(2026, 9, 30, 9, 40),
  readAt: DateTime(2026, 9, 30, 9, 41),
);
final contact = DirectContact(node, peer, [received, sent]);

class FakeDirectRepository extends DirectMessagesRepository {
  bool failSend = false;
  int historyCalls = 0, sendCalls = 0;
  Completer<DirectMessage>? pending;
  String? lastText;
  @override
  Future<List<DirectMessage>> history(String nodoId, String peerId) async {
    historyCalls++;
    return [received, sent];
  }

  @override
  Future<DirectMessage> sendText(
    String nodoId,
    String peerId,
    String text,
  ) async {
    sendCalls++;
    lastText = text;
    if (failSend) throw StateError('network');
    if (pending != null) return pending!.future;
    return DirectMessage(
      id: 'new',
      senderId: 'own',
      recipientId: peerId,
      content: text,
      kind: 'text',
      createdAt: DateTime.now(),
    );
  }
}

ThemeData get theme => AppColors.theme();

Widget conversation(
  FakeDirectRepository repo, {
  String draft = '',
  bool active = true,
  ValueChanged<String>? onDraft,
}) => ProviderScope(
  child: MaterialApp(
    theme: theme,
    home: Scaffold(
      body: DirectConversation(
        contact: contact,
        ownId: 'own',
        repository: repo,
        draft: draft,
        active: active,
        onBack: () {},
        onSent: () {},
        onDraft: onDraft ?? (_) {},
        onReplyDraft: (_) {},
      ),
    ),
  ),
);

void main() {
  test('contact keys preserve node authorization and Unicode initials', () {
    expect(contact.key, 'node-1:peer');
    expect(contact.unread('own'), 1);
    expect(initials('Álvaro Ramírez'), 'ÁR');
    expect(initials(''), '?');
  });

  for (final width in [320.0, 390.0, 800.0, 1280.0]) {
    testWidgets(
      'chat responsive at $width px, 130% text, without suppressed errors',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repo = FakeDirectRepository();
        final nodes = [node];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              directOwnUserIdProvider.overrideWithValue('own'),
              directRepositoryProvider.overrideWithValue(repo),
              directContactsProvider(
                nodes,
              ).overrideWith((ref) async => [contact]),
            ],
            child: MaterialApp(
              theme: theme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 800),
                  textScaler: TextScaler.linear(1.3),
                ),
                child: Scaffold(
                  body: Row(
                    children: [
                      if (width >= 600)
                        WorkspaceNavigation(
                          selected: 0,
                          onSelect: (_) {},
                          nodos: nodes,
                          onOpenNodo: (_) {},
                          onAddNodo: () {},
                        ),
                      Expanded(child: DirectChatsWorkspace(nodos: nodes)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Chats'), findsOneWidget);
        await tester.tap(find.text('Ana Mena').first);
        await tester.pumpAndSettle();
        expect(find.text('¿Revisamos el Sprint 3?'), findsOneWidget);
        expect(find.text(' Leído'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('failed sends preserve drafts and allow explicit retry', (
    tester,
  ) async {
    final repo = FakeDirectRepository()..failSend = true;
    String draft = '';
    await tester.pumpWidget(conversation(repo, onDraft: (v) => draft = v));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'No perder este borrador');
    await tester.tap(find.byTooltip('Enviar mensaje'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No enviado.'), findsOneWidget);
    expect(draft, 'No perder este borrador');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      draft,
    );
    repo.failSend = false;
    await tester.tap(find.byTooltip('Enviar mensaje'));
    await tester.pumpAndSettle();
    expect(repo.sendCalls, 2);
    expect(draft, '');
    expect(find.text('No perder este borrador'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a successful send does not delete text written while waiting', (
    tester,
  ) async {
    final repo = FakeDirectRepository()..pending = Completer<DirectMessage>();
    await tester.pumpWidget(conversation(repo));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Primero');
    await tester.tap(find.byTooltip('Enviar mensaje'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Segundo borrador');
    repo.pending!.complete(sent);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Segundo borrador',
    );
    expect(repo.sendCalls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden conversations do not fetch history or mark read', (
    tester,
  ) async {
    final repo = FakeDirectRepository();
    await tester.pumpWidget(conversation(repo, active: false));
    await tester.pump(const Duration(seconds: 12));
    expect(repo.historyCalls, 0);
    await tester.pumpWidget(conversation(repo));
    await tester.pumpAndSettle();
    expect(repo.historyCalls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'long press quote sends actual text without fake thread capabilities',
    (tester) async {
      final repo = FakeDirectRepository();
      await tester.pumpWidget(conversation(repo));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('¿Revisamos el Sprint 3?'));
      await tester.pumpAndSettle();
      expect(find.text('Responder con cita'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Sí');
      await tester.tap(find.byTooltip('Enviar mensaje'));
      await tester.pumpAndSettle();
      expect(repo.lastText, '> ¿Revisamos el Sprint 3?\n\nSí');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('draft survives switching between conversations', (tester) async {
    final nodes = [node];
    final repo = FakeDirectRepository();
    const secondPeer = NodoMiembro(
      userId: 'other',
      name: 'Luis Castro',
      email: 'luis@example.test',
      rol: 'MEMBER',
    );
    final second = DirectContact(node, secondPeer, [sent]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directOwnUserIdProvider.overrideWithValue('own'),
          directRepositoryProvider.overrideWithValue(repo),
          directContactsProvider(
            nodes,
          ).overrideWith((ref) async => [contact, second]),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(body: DirectChatsWorkspace(nodos: nodes)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana Mena'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Borrador para Ana');
    await tester.tap(find.text('Luis Castro'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.tap(find.text('Ana Mena'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Borrador para Ana',
    );
    await tester.pumpWidget(const SizedBox());
  });

  if (const bool.fromEnvironment('IRONLINK_RENDER_PREVIEW')) {
    testWidgets('render implemented desktop layout for visual review', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final text = FontLoader('IronLinkPreview')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '/System/Library/Fonts/Supplemental/Arial.ttf',
                ).readAsBytes(),
              ),
            ),
          );
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ).readAsBytes(),
              ),
            ),
          );
        await text.load();
        await icons.load();
      });
      final nodes = [node];
      final repo = FakeDirectRepository();
      final key = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            directOwnUserIdProvider.overrideWithValue('own'),
            directRepositoryProvider.overrideWithValue(repo),
            directContactsProvider(
              nodes,
            ).overrideWith((ref) async => [contact]),
          ],
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'IronLinkPreview'),
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: AppColors.bg,
                  child: Row(
                    children: [
                      WorkspaceNavigation(
                        selected: 0,
                        onSelect: (_) {},
                        nodos: nodes,
                        onOpenNodo: (_) {},
                        onAddNodo: () {},
                      ),
                      Expanded(child: DirectChatsWorkspace(nodos: nodes)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ana Mena'));
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/private/tmp/ironlink-claude-desktop.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
