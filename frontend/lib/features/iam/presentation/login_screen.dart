import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import 'widgets/auth_layout.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.initialEmail = ''});
  final String initialEmail;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final _emailController = TextEditingController(
    text: widget.initialEmail,
  );
  final _passwordController = TextEditingController();
  bool _showPassword = false;
  bool _rememberMe = true;
  String? _emailError, _passwordError;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();

  String? _validateLoginEmail(String value) {
    // Se conserva el acceso con el usuario local «test» de desarrollo.
    if (value.trim().toLowerCase() == 'test') return null;
    return validateEmail(value);
  }

  void _clearErrors() {
    if (_emailError != null || _passwordError != null) {
      setState(() => _emailError = _passwordError = null);
    }
    if (ref.read(authProvider).errorMessage != null) {
      ref.read(authProvider.notifier).clearFieldErrors();
    }
  }

  Future<void> _submit() async {
    final emailError = _validateLoginEmail(_emailController.text);
    final passwordError = _passwordController.text.isEmpty
        ? 'Escribe tu contraseña.'
        : null;
    setState(() {
      _emailError = emailError;
      _passwordError = passwordError;
    });
    if (emailError != null || passwordError != null) return;
    await ref
        .read(authProvider.notifier)
        .login(_email, _passwordController.text, rememberMe: _rememberMe);
  }

  void _goVerification() {
    if (validateEmail(_emailController.text) != null) {
      setState(
        () => _emailError = 'Escribe tu correo para reenviar la verificación.',
      );
      return;
    }
    context.go('/verification?email=${Uri.encodeComponent(_email)}');
  }

  void _goForgot() =>
      context.go('/forgot-password?email=${Uri.encodeComponent(_email)}');

  /// Traduce el mensaje del servidor al aviso que corresponde en el diseño.
  AuthBanner? _banner(String? message) {
    if (message == null) return null;
    final lower = message.toLowerCase();
    if (lower.contains('verificada')) {
      return AuthBanner(
        kind: AuthBannerKind.warning,
        text:
            'Tu cuenta aún no está verificada. Te enviaremos un código a ${_email.isEmpty ? 'tu correo' : _email}.',
        actionLabel: 'Verificar ahora',
        onAction: _goVerification,
      );
    }
    if (lower.contains('credenciales')) {
      return AuthBanner(
        kind: AuthBannerKind.error,
        text:
            'Correo o contraseña incorrectos. Tras 5 intentos fallidos la cuenta se bloquea 15 minutos.',
        actionLabel: 'Restablecer contraseña',
        onAction: _goForgot,
      );
    }
    return AuthBanner(kind: AuthBannerKind.error, text: message);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final loading = auth.status == AuthStatus.loading;

    return AuthLayout(
      viewKey: 'login',
      title: 'Inicia sesión',
      subtitle: 'Accede con tus credenciales de IronLink.',
      banner: _banner(auth.errorMessage),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthField(
              label: 'Correo electrónico',
              controller: _emailController,
              hint: 'correo@organizacion.com',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              errorText: _emailError,
              onChanged: (_) => _clearErrors(),
            ),
            const SizedBox(height: 14),
            AuthField(
              label: 'Contraseña',
              trailingLabel: AuthLink(
                label: '¿La olvidaste?',
                onTap: _goForgot,
              ),
              controller: _passwordController,
              hint: '••••••••',
              obscure: !_showPassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              errorText: _passwordError,
              onChanged: (_) => _clearErrors(),
              onSubmitted: (_) => _submit(),
              suffix: PasswordToggle(
                visible: _showPassword,
                onToggle: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            const SizedBox(height: 14),
            AuthCheckbox(
              value: _rememberMe,
              onChanged: (v) => setState(() => _rememberMe = v),
              label: 'Mantener la sesión en este dispositivo',
            ),
            const SizedBox(height: 14),
            AuthPrimaryButton(
              label: 'Iniciar sesión',
              loadingLabel: 'Comprobando…',
              icon: Icons.login,
              loading: loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 20),
            AuthPrompt(
              text: '¿No tienes cuenta?',
              link: AuthLink(
                label: 'Crear cuenta',
                onTap: () => context.go('/register'),
              ),
            ),
            AuthPrompt(
              text: '¿No activaste tu cuenta?',
              link: AuthLink(
                label: 'Reenviar verificación',
                onTap: _goVerification,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
