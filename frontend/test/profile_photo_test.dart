import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/widgets/avatar_viewer.dart';
import 'package:frontend/core/widgets/user_avatar.dart';
import 'package:frontend/features/iam/providers/auth_provider.dart';
import 'package:frontend/features/nodos/presentation/widgets/workspace_navigation.dart';
import 'nocturne_design_test.dart' show FakeIamRepository;

// PNG de 1×1 píxel, en el mismo formato data URI que guarda el backend.
const photo =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

class ProfileRepository extends FakeIamRepository {
  ProfileRepository(this.avatarUrl);
  final String? avatarUrl;

  @override
  Future<Map<String, dynamic>> fetchProfile() async => {
    'id': 'u1',
    'name': 'Ana Rivas',
    'email': 'ana@ironlink.dev',
    'avatar_color': '#9184D9',
    'avatar_url': avatarUrl,
  };
}

Future<void> pumpNavigation(WidgetTester tester, String? avatarUrl) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          iamRepositoryProvider.overrideWithValue(ProfileRepository(avatarUrl)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: WorkspaceNavigation(
              selected: 3,
              onSelect: (_) {},
              nodos: const [],
              onOpenNodo: (_) {},
              onAddNodo: () {},
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('decodes the stored data URI with its file extension', () async {
    final image = await AvatarImage.load(photo);
    expect(image, isNotNull);
    expect(image!.extension, 'png');
    expect(image.bytes.take(4), [0x89, 0x50, 0x4E, 0x47]);
    expect(await AvatarImage.load(null), isNull);
    expect(await AvatarImage.load('  '), isNull);
  });

  test('corrupt or non-image photos load as null without throwing', () async {
    // Base64 truncado: longitud inválida.
    expect(
      await AvatarImage.load('data:image/png;base64,iVBORw0KGgo='),
      isNull,
    );
    expect(await AvatarImage.load('data:image/png;base64,iVBORw0K%%%'), isNull);
    // Base64 válido, pero el contenido es texto, no una imagen.
    expect(
      await AvatarImage.load('data:image/png;base64,aG9sYSBtdW5kbw=='),
      isNull,
    );
    // La extensión sale del contenido aunque el tipo declarado sea otro.
    final png = await AvatarImage.load(
      photo.replaceFirst('image/png', 'image/jpeg'),
    );
    expect(png?.extension, 'png');
  });

  test(
    'accepts complete JPEGs, with trailing padding, and rejects cut ones',
    () async {
      final jpg = img.encodeJpg(img.Image(width: 8, height: 8));
      String uri(List<int> bytes) =>
          'data:image/jpeg;base64,${base64Encode(bytes)}';
      expect((await AvatarImage.load(uri(jpg)))?.extension, 'jpg');
      expect(
        (await AvatarImage.load(uri([...jpg, 0, 0, 0])))?.extension,
        'jpg',
      );
      expect(
        await AvatarImage.load(uri(jpg.sublist(0, jpg.length ~/ 2))),
        isNull,
      );
    },
  );

  testWidgets('the viewer reports a photo that could not be read', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: UserAvatar(
              name: 'Ana Rivas',
              avatarUrl: 'data:image/png;base64,aG9sYQ==',
              viewable: true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();
    expect(
      find.text('No se pudo cargar la foto de Ana Rivas.'),
      findsOneWidget,
    );
    expect(find.text('Descargar'), findsNothing);
  });

  testWidgets('the «Tú» destination shows the account photo', (tester) async {
    await pumpNavigation(tester, photo);
    final you = find.byType(ProfileNavIcon);
    expect(you, findsOneWidget);
    expect(
      find.descendant(of: you, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.person_outline_rounded), findsNothing);
  });

  testWidgets('without a photo the destination shows initials', (tester) async {
    await pumpNavigation(tester, null);
    expect(
      find.descendant(
        of: find.byType(ProfileNavIcon),
        matching: find.text('AR'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a viewable avatar opens the photo with a download action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: UserAvatar(
              name: 'Ana Rivas',
              avatarUrl: photo,
              viewable: true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();
    expect(find.byType(AvatarViewer), findsOneWidget);
    expect(find.text('Descargar'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Foto de perfil de Ana Rivas'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.byType(AvatarViewer), findsNothing);
  });

  testWidgets('without a photo the viewer explains it and offers no download', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: UserAvatar(name: 'Ana Rivas', viewable: true)),
        ),
      ),
    );
    await tester.tap(find.byType(UserAvatar));
    await tester.pumpAndSettle();
    expect(find.text('Ana Rivas no tiene foto de perfil.'), findsOneWidget);
    expect(find.text('Descargar'), findsNothing);
  });

  testWidgets('avatars are not tappable unless marked viewable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: UserAvatar(name: 'Ana', avatarUrl: photo),
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(UserAvatar),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
  });

  test('navigation order lists every destination once with «Tú» last', () {
    expect(
      [...workspaceNavOrder]..sort(),
      List.generate(workspaceLabels.length, (i) => i),
    );
    expect(workspaceNavOrder.last, WorkspaceDestination.tu.index);
  });
}
