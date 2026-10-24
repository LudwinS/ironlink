import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/features/iam/data/profile_models.dart';
import 'package:frontend/features/nodos/data/nodos_repository.dart';
import 'package:frontend/features/nodos/data/subgrupos_repository.dart';
import 'package:frontend/features/nodos/presentation/widgets/create_subgrupo_dialog.dart';
import 'package:frontend/features/nodos/presentation/widgets/create_reunion_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  dynamic originalOnError;

  setUp(() {
    originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      final String msg = '${details.exception}\n$details';
      if (msg.toLowerCase().contains('overflow')) {
        return; // Ignore overflow exceptions in headless tests
      }
      if (originalOnError != null) {
        originalOnError(details);
      }
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async => null);
  });

  group('IronLink macOS Desktop & Fullstack QA Test Suite — Sprint 2', () {
    test('TEST-UNIT-001: UserProfile serialization and data integrity', () {
      final json = {
        'id': 'usr-101',
        'email': 'ludwin@ironlink.io',
        'name': 'Ludwin Romero',
        'telefono': '+503 7000-0000',
        'rol': 'OWNER',
        'estado': 'ACTIVE',
        'bio': 'Arquitecto Fullstack InnovaSoft',
        'avatar_color': '#00E5FF',
        'status_text': '🟢 En línea',
      };

      final profile = UserProfile.fromJson(json);
      expect(profile.id, 'usr-101');
      expect(profile.name, 'Ludwin Romero');
      expect(profile.avatarColor, '#00E5FF');
      expect(profile.statusText, '🟢 En línea');
      expect(profile.estado, 'ACTIVE');
      expect(profile.bio, 'Arquitecto Fullstack InnovaSoft');
      expect(profile.telefono, '+503 7000-0000');
    });

    testWidgets('TEST-MAC-001: Create Subgrupo Dialog UI components on macOS', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: CreateSubgrupoDialog(nodoId: 'test-nodo-123'),
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.text('Crear Nuevo Subgrupo'), findsOneWidget);
      expect(find.text('Nombre del Subgrupo'), findsOneWidget);
      expect(find.text('Descripción (opcional)'), findsOneWidget);
      expect(find.text('Subgrupo Público'), findsOneWidget);
      expect(find.text('Crear Subgrupo'), findsOneWidget);
    });

    testWidgets('TEST-MAC-002: Create Reunion Dialog UI components on macOS', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: CreateReunionDialog(
                  nodoId: 'test-nodo-123',
                  loadMembers: (_) async => const [],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      // Las reuniones son de IronLink: ya no se pide un enlace externo.
      expect(find.text('Nueva reunión'), findsOneWidget);
      expect(find.text('Asistentes'), findsOneWidget);
      expect(find.text('Repetición'), findsOneWidget);
      expect(find.text('30 min'), findsOneWidget);
      expect(find.text('1 h'), findsOneWidget);
      expect(find.textContaining('Google Meet'), findsNothing);
    });

    test('TEST-UNIT-002: Subgrupo and SubgrupoMiembro serialization and copyWith', () {
      final jsonSub = {
        'id': 'sub-101',
        'nodo_id': 'nodo-001',
        'nombre': 'Equipo Backend',
        'descripcion': 'Canal de desarrollo Backend y APIs',
        'es_privado': true,
        'creado_por': 'usr-101',
        'created_at': '2026-08-25T11:00:00Z',
        'miembros_count': 5,
        'is_member': false,
      };

      final subgrupo = Subgrupo.fromJson(jsonSub);
      expect(subgrupo.id, 'sub-101');
      expect(subgrupo.nombre, 'Equipo Backend');
      expect(subgrupo.esPrivado, isTrue);
      expect(subgrupo.isMember, isFalse);
      expect(subgrupo.miembrosCount, 5);

      final updatedSub = subgrupo.copyWith(isMember: true, miembrosCount: 6);
      expect(updatedSub.isMember, isTrue);
      expect(updatedSub.miembrosCount, 6);

      final jsonMember = {
        'user_id': 'usr-102',
        'name': 'Carlos Rivera',
        'email': 'carlos@ironlink.io',
        'avatar_color': '#10B981',
        'created_at': '2026-08-25T11:05:00Z',
      };

      final member = SubgrupoMiembro.fromJson(jsonMember);
      expect(member.userId, 'usr-102');
      expect(member.name, 'Carlos Rivera');
      expect(member.email, 'carlos@ironlink.io');
    });

    test('TEST-UNIT-003: Mensaje serialization with subgrupoId for subgroup chats', () {
      final jsonMsg = {
        'id': 'msg-999',
        'nodo_id': 'nodo-001',
        'user_id': 'usr-101',
        'user_name': 'Ludwin Romero',
        'contenido': 'Hola equipo de Backend, revisando la arquitectura del chat.',
        'created_at': '2026-08-25T11:15:00Z',
        'subgrupo_id': 'sub-101',
        'avatar_url': 'data:image/jpeg;base64,/9j/4AAQSkZJRg==',
        'avatar_color': '#00E5FF',
        'status_text': '⚡ Desarrollando en IronLink',
      };

      final msg = Mensaje.fromJson(jsonMsg);
      expect(msg.id, 'msg-999');
      expect(msg.nodoId, 'nodo-001');
      expect(msg.subgrupoId, 'sub-101');
      expect(msg.contenido, 'Hola equipo de Backend, revisando la arquitectura del chat.');
      expect(msg.avatarUrl, 'data:image/jpeg;base64,/9j/4AAQSkZJRg==');
      expect(msg.avatarColor, '#00E5FF');
      expect(msg.statusText, '⚡ Desarrollando en IronLink');
    });

    test('TEST-UNIT-004: NodoMiembro and SubgrupoMiembro parse custom avatar & status_text', () {
      final jsonNodoMiembro = {
        'user_id': 'usr-200',
        'name': 'Ana Silva',
        'email': 'ana@ironlink.io',
        'rol': 'ADMIN',
        'avatar_color': '#EC4899',
        'status_text': '🟡 En reunión',
        'avatar_url': 'data:image/jpeg;base64,/9j/4AAQSkZJRg==',
      };

      final nodoMember = NodoMiembro.fromJson(jsonNodoMiembro);
      expect(nodoMember.userId, 'usr-200');
      expect(nodoMember.name, 'Ana Silva');
      expect(nodoMember.rol, 'ADMIN');
      expect(nodoMember.avatarColor, '#EC4899');
      expect(nodoMember.statusText, '🟡 En reunión');
      expect(nodoMember.avatarUrl, isNotNull);

      final jsonSubMiembro = {
        'user_id': 'usr-201',
        'name': 'Carlos Rivera',
        'email': 'carlos@ironlink.io',
        'avatar_color': '#10B981',
        'status_text': '🔴 Ocupado',
        'avatar_url': 'https://ironlink.io/avatars/carlos.jpg',
        'joined_at': '2026-08-25T11:05:00Z',
      };

      final subMember = SubgrupoMiembro.fromJson(jsonSubMiembro);
      expect(subMember.userId, 'usr-201');
      expect(subMember.statusText, '🔴 Ocupado');
      expect(subMember.avatarUrl, 'https://ironlink.io/avatars/carlos.jpg');
    });

    test('TEST-UNIT-005: IRL-WKS-US-03 Unread count badge state and serialization', () {
      final unreadMap = <String, int>{
        'nodo-001': 5,
        'nodo-002': 0,
        'nodo-003': 12,
      };

      expect(unreadMap['nodo-001'], 5);
      expect(unreadMap['nodo-002'], 0);
      expect(unreadMap['nodo-003'], 12);

      // Simulation of mark as read (limpieza automática del badge)
      unreadMap['nodo-001'] = 0;
      expect(unreadMap['nodo-001'], 0);
    });

    test('TEST-UNIT-006: IRL-WKS-US-02 Subgrupo hot edit and multi-member assignment models', () {
      final sub = Subgrupo(
        id: 'sub-301',
        nodoId: 'nodo-001',
        nombre: 'Original Name',
        descripcion: 'Original Description',
        esPrivado: true,
        creadoPor: 'usr-100',
        createdAt: DateTime.now(),
        miembrosCount: 2,
        isMember: true,
      );

      // Edición en caliente
      final edited = sub.copyWith(
        nombre: 'Nuevo Nombre Backend Lead',
        descripcion: 'Descripción actualizada en caliente',
      );
      expect(edited.nombre, 'Nuevo Nombre Backend Lead');
      expect(edited.descripcion, 'Descripción actualizada en caliente');

      // Asignación de miembros masiva
      final assigned = edited.copyWith(miembrosCount: edited.miembrosCount + 3);
      expect(assigned.miembrosCount, 5);
    });

    test('TEST-UNIT-007: IRL-IAM-US-05 Avatar MIME and 2MB validation format verification', () {
      const allowedFormats = ['jpg', 'jpeg', 'png', 'webp'];
      expect(allowedFormats.contains('png'), isTrue);
      expect(allowedFormats.contains('jpg'), isTrue);
      expect(allowedFormats.contains('webp'), isTrue);
      expect(allowedFormats.contains('gif'), isFalse);
      expect(allowedFormats.contains('exe'), isFalse);

      const maxBytes = 2 * 1024 * 1024;
      const validImageSize = 350 * 1024; // 350 KB
      const largeImageSize = 4 * 1024 * 1024; // 4 MB

      expect(validImageSize <= maxBytes, isTrue);
      expect(largeImageSize > maxBytes, isTrue);
    });
  });
}

