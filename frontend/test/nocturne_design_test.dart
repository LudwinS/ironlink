import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/security/storage_facade.dart';
import 'package:frontend/core/theme/app_colors.dart';
import 'package:frontend/core/theme/theme_provider.dart';
import 'package:frontend/features/iam/data/iam_repository.dart';
import 'package:frontend/features/iam/presentation/forgot_password_screen.dart';
import 'package:frontend/features/iam/presentation/login_screen.dart';
import 'package:frontend/features/iam/presentation/register_screen.dart';
import 'package:frontend/features/iam/presentation/verification_screen.dart';
import 'package:frontend/features/iam/presentation/verification_success_screen.dart';
import 'package:frontend/features/iam/presentation/widgets/auth_layout.dart';
import 'package:frontend/features/iam/providers/auth_provider.dart';
import 'package:frontend/features/nodos/presentation/widgets/workspace_preferences.dart';

class FakeIamRepository extends IamRepository {
  String? loginError;
  final requested = <String>[];

  @override
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    if (loginError != null) throw Exception(loginError);
    return {
      'userId': 'u1',
      'username': 'Ana',
      'email': email,
      'role': 'MEMBER',
    };
  }

  @override
  Future<String> requestVerification({
    required String email,
    required String method,
  }) async {
    requested.add(method);
    return 'Enviado';
  }
}

class MemoryStorage implements VaultStorage {
  final values = <String, String>{};
  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> delete({required String key}) async => values.remove(key);
}

Future<void> pumpAuth(
  WidgetTester tester,
  Widget screen, {
  double width = 390,
  IronTheme theme = IronTheme.dark,
  FakeIamRepository? repository,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  AppColors.use(theme);
  addTearDown(() => AppColors.use(IronTheme.dark));
  // SecureVault encadena sus escrituras en un Future estático: la
  // comprobación inicial de sesión se ejecuta en tiempo real para que no
  // quede pendiente en el reloj simulado de una prueba anterior.
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          iamRepositoryProvider.overrideWithValue(
            repository ?? FakeIamRepository(),
          ),
        ],
        child: MaterialApp(
          theme: AppColors.theme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(1.3),
              disableAnimations: true,
            ),
            child: screen,
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

  final screens = <String, Widget Function()>{
    'login': () => const LoginScreen(),
    'register': () => const RegisterScreen(),
    'verification': () => const VerificationScreen(email: ''),
    'forgot': () => const ForgotPasswordScreen(),
    'verified': () => const VerificationSuccessScreen(),
  };

  for (final theme in IronTheme.values) {
    for (final width in [320.0, 390.0, 1280.0]) {
      for (final entry in screens.entries) {
        testWidgets(
          '${entry.key} fits at ${width.toInt()} px, ${theme.name}, text 130 %',
          (tester) async {
            await pumpAuth(tester, entry.value(), width: width, theme: theme);
            expect(tester.takeException(), isNull);
            final wide = width >= kAuthWideBreakpoint;
            expect(
              find.image(const AssetImage('assets/logo-nocturne.png')),
              wide ? findsOneWidget : findsNothing,
            );
          },
        );
      }
    }
  }

  testWidgets('an unverified account offers to verify from the banner', (
    tester,
  ) async {
    final repo = FakeIamRepository()
      ..loginError =
          'Tu cuenta no ha sido verificada. Revisa tu correo electrónico.';
    await pumpAuth(tester, const LoginScreen(), repository: repo);
    await tester.enterText(find.byType(TextField).at(0), 'ana@ironlink.dev');
    await tester.enterText(find.byType(TextField).at(1), 'Secreta1!');
    await tester.tap(find.text('Iniciar sesión').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('aún no está verificada'), findsOneWidget);
    expect(find.text('Verificar ahora'), findsOneWidget);
  });

  testWidgets('wrong credentials offer a password reset', (tester) async {
    final repo = FakeIamRepository()..loginError = 'Credenciales inválidas.';
    await pumpAuth(tester, const LoginScreen(), repository: repo);
    await tester.enterText(find.byType(TextField).at(0), 'ana@ironlink.dev');
    await tester.enterText(find.byType(TextField).at(1), 'mala');
    await tester.tap(find.text('Iniciar sesión').last);
    await tester.pumpAndSettle();
    expect(find.text('Restablecer contraseña'), findsOneWidget);
  });

  testWidgets('login validates fields before calling the server', (
    tester,
  ) async {
    await pumpAuth(tester, const LoginScreen());
    await tester.tap(find.text('Iniciar sesión').last);
    await tester.pumpAndSettle();
    expect(find.text('Escribe tu correo.'), findsOneWidget);
    expect(find.text('Escribe tu contraseña.'), findsOneWidget);
  });

  testWidgets('verification with an email requests a code right away', (
    tester,
  ) async {
    final repo = FakeIamRepository();
    await pumpAuth(
      tester,
      const VerificationScreen(email: 'ana@ironlink.dev'),
      repository: repo,
    );
    expect(repo.requested, ['code']);
    expect(find.text('Código enviado a ana@ironlink.dev.'), findsOneWidget);
    expect(find.textContaining('Puedes pedir otro en'), findsOneWidget);
  });

  testWidgets('pasting a code fills all six boxes', (tester) async {
    String? completed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeInput(onChanged: (_) {}, onCompleted: (c) => completed = c),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, '482913');
    await tester.pump();
    expect(completed, '482913');
    final values = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((f) => f.controller!.text)
        .join();
    expect(values, '482913');
  });

  test('password rules match the backend requirements', () {
    expect(PasswordRules.isValid('Secreta1!'), isTrue);
    expect(
      PasswordRules.validate('secreta'),
      'Añade al menos 8 caracteres, una mayúscula, un número y un símbolo.',
    );
    expect(PasswordRules.strength(''), 0);
    expect(PasswordRules.strength('Secreta1!'), 4);
  });

  testWidgets('the theme picker applies and stores the chosen palette', (
    tester,
  ) async {
    final storage = MemoryStorage();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          themeProvider.overrideWith((ref) => ThemeNotifier(storage)),
        ],
        child: const MaterialApp(home: Scaffold(body: ThemePicker())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claro'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ThemePicker)),
    );
    expect(container.read(themeProvider), IronTheme.light);
    expect(storage.values['ironlink_theme'], 'light');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  test('every palette keeps readable text on its ground', () {
    double luminance(Color c) => c.computeLuminance();
    double ratio(Color a, Color b) {
      final l1 = luminance(a), l2 = luminance(b);
      return (l1 > l2 ? l1 + .05 : l2 + .05) / (l1 > l2 ? l2 + .05 : l1 + .05);
    }

    for (final theme in IronTheme.values) {
      final p = IronPalette.of(theme);
      expect(ratio(p.text, p.bg), greaterThan(7), reason: theme.name);
      expect(
        ratio(p.textMuted, p.surface),
        greaterThan(4.5),
        reason: theme.name,
      );
      expect(
        ratio(p.accentText, p.surface),
        greaterThan(4.5),
        reason: theme.name,
      );
    }
  });

  testWidgets('chat background preference is applied and stored', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(
                home: ChatBackdrop(child: SizedBox.expand()),
              );
            },
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final mesh = find.descendant(
      of: find.byType(ChatBackdrop),
      matching: find.byType(CustomPaint),
    );
    expect(mesh, findsNothing);
    late bool saved;
    await tester.runAsync(() async {
      saved = await container
          .read(workspacePreferencesProvider.notifier)
          .update(chatBackground: ChatBackground.mesh);
    });
    await tester.pump();
    expect(saved, isTrue);
    expect(mesh, findsOneWidget);
    final stored = await tester.runAsync(
      () => const FlutterSecureStorage().read(key: 'workspace_prefs_guest'),
    );
    expect(stored, contains('"chatBackground":"mesh"'));
  });
}
