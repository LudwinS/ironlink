import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/iam/presentation/login_screen.dart';
import '../../features/iam/presentation/register_screen.dart';
import '../../features/iam/presentation/verification_screen.dart';
import '../../features/iam/presentation/verification_success_screen.dart';
import '../../features/iam/presentation/forgot_password_screen.dart';
import '../../features/nodos/presentation/dashboard_screen.dart';
import '../../features/nodos/presentation/widgets/meeting_link_widgets.dart';
import '../../features/iam/providers/auth_provider.dart';

final routerNotifierProvider = Provider<RouterNotifier>((ref) {
  final notifier = RouterNotifier();
  ref.listen<AuthState>(authProvider, (previous, next) {
    notifier.notify();
  });
  return notifier;
});

class RouterNotifier extends ChangeNotifier {
  void notify() {
    notifyListeners();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final routerNotifier = ref.watch(routerNotifierProvider);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: routerNotifier,
    redirect: (BuildContext context, GoRouterState state) {
      final authState = ref.read(authProvider);
      final isLoggedIn = authState.status == AuthStatus.authenticated;

      final isGoingToAuth =
          state.matchedLocation == '/login' ||
          state.matchedLocation == '/register' ||
          state.matchedLocation == '/verification' ||
          state.matchedLocation == '/verification-success' ||
          state.matchedLocation == '/forgot-password';

      // Un enlace de reunión abierto sin sesión se recuerda para después del
      // inicio de sesión. Solo se aceptan rutas internas de reunión.
      final from = state.uri.queryParameters['from'];
      final safeFrom =
          from != null && RegExp(r'^/reunion/[0-9a-fA-F-]{36}$').hasMatch(from)
          ? from
          : null;

      if (!isLoggedIn) {
        if (!isGoingToAuth) {
          return state.matchedLocation.startsWith('/reunion/')
              ? '/login?from=${Uri.encodeComponent(state.matchedLocation)}'
              : '/login';
        }
      } else {
        if (isGoingToAuth && state.matchedLocation != '/verification') {
          return safeFrom ?? '/home';
        }
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) =>
            LoginScreen(initialEmail: state.uri.queryParameters['email'] ?? ''),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/verification',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'] ?? '';
          return VerificationScreen(email: email);
        },
      ),
      GoRoute(
        path: '/verification-success',
        builder: (context, state) => const VerificationSuccessScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'] ?? '';
          return ForgotPasswordScreen(initialEmail: email);
        },
      ),
      GoRoute(
        path: '/reunion/:id',
        builder: (context, state) =>
            MeetingLinkScreen(reunionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const DashboardScreen(),
      ),
    ],
  );
});
