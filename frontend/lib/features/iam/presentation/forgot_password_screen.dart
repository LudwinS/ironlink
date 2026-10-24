import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import 'widgets/auth_layout.dart';

enum _Phase { email, reset, done }

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  final String initialEmail;
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  late final _emailController = TextEditingController(
    text: widget.initialEmail,
  );
  final _passwordController = TextEditingController();
  _Phase _phase = _Phase.email;
  String _code = '';
  int _codeAttempt = 0;
  bool _showPassword = false;
  bool _busy = false;
  String? _emailError, _codeError, _passwordError;
  AuthBanner? _banner;

  String get _email => _emailController.text.trim();

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(authProvider.notifier).clearFieldErrors());
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<bool> _requestCode() async {
    final error = validateEmail(_emailController.text);
    if (error != null) {
      setState(() => _emailError = error);
      return false;
    }
    setState(() {
      _busy = true;
      _banner = null;
    });
    final ok = await ref.read(authProvider.notifier).forgotPassword(_email);
    if (!mounted) return ok;
    setState(() {
      _busy = false;
      if (ok) {
        _phase = _Phase.reset;
        _code = '';
        _codeAttempt++;
        _banner = AuthBanner(
          kind: AuthBannerKind.success,
          text: 'Código enviado a $_email.',
        );
      } else {
        _banner = AuthBanner(
          kind: AuthBannerKind.error,
          text:
              ref.read(authProvider).errorMessage ??
              'No se pudo enviar el código. Inténtalo de nuevo.',
        );
      }
    });
    return ok;
  }

  Future<void> _reset() async {
    final codeError = _code.length < 6
        ? 'Faltan ${6 - _code.length} dígitos.'
        : null;
    final passwordError = PasswordRules.validate(_passwordController.text);
    setState(() {
      _codeError = codeError;
      _passwordError = passwordError;
    });
    if (codeError != null || passwordError != null) return;

    setState(() {
      _busy = true;
      _banner = null;
    });
    final ok = await ref
        .read(authProvider.notifier)
        .resetPassword(_email, _code, _passwordController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _phase = _Phase.done;
        _passwordController.clear();
      } else {
        _code = '';
        _codeAttempt++;
        _codeError =
            ref.read(authProvider).errorMessage ??
            'Código incorrecto. Revísalo o solicita uno nuevo.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final target = _email.isEmpty ? 'tu correo' : _email;
    final (title, subtitle) = switch (_phase) {
      _Phase.email => (
        'Recupera tu contraseña',
        'Te enviaremos un código para crear una nueva.',
      ),
      _Phase.reset => (
        'Crea una nueva contraseña',
        'Escribe el código que enviamos a $target y tu nueva contraseña.',
      ),
      _Phase.done => (
        'Contraseña actualizada',
        'Ya puedes usar tu nueva contraseña. Las sesiones abiertas en otros dispositivos ya no podrán renovarse.',
      ),
    };

    return AuthLayout(
      viewKey: _phase,
      title: title,
      subtitle: subtitle,
      banner: _banner,
      onBack: _phase == _Phase.done ? null : () => context.go('/login'),
      child: switch (_phase) {
        _Phase.email => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthField(
              label: 'Correo electrónico',
              controller: _emailController,
              hint: 'correo@organizacion.com',
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autofocus: true,
              errorText: _emailError,
              onChanged: (_) => setState(() => _emailError = null),
              onSubmitted: (_) => _requestCode(),
            ),
            const SizedBox(height: 14),
            AuthPrimaryButton(
              label: 'Enviar código',
              loadingLabel: 'Enviando…',
              icon: Icons.arrow_forward,
              loading: _busy,
              onPressed: _requestCode,
            ),
          ],
        ),
        _Phase.reset => AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CodeInput(
                key: ValueKey(_codeAttempt),
                errorText: _codeError,
                onChanged: (c) => setState(() {
                  _code = c;
                  _codeError = null;
                }),
              ),
              const SizedBox(height: 8),
              ResendCode(onResend: _requestCode),
              const SizedBox(height: 14),
              AuthField(
                label: 'Nueva contraseña',
                controller: _passwordController,
                hint: 'Mínimo 8 caracteres',
                obscure: !_showPassword,
                autofillHints: const [AutofillHints.newPassword],
                errorText: _passwordError,
                onChanged: (_) => setState(() => _passwordError = null),
                onSubmitted: (_) => _reset(),
                suffix: PasswordToggle(
                  visible: _showPassword,
                  onToggle: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
                helper: PasswordStrengthBar(password: _passwordController.text),
              ),
              const SizedBox(height: 14),
              AuthPrimaryButton(
                label: 'Guardar contraseña',
                loadingLabel: 'Verificando…',
                icon: Icons.arrow_forward,
                loading: _busy,
                onPressed: _reset,
              ),
            ],
          ),
        ),
        _Phase.done => AuthPrimaryButton(
          label: 'Iniciar sesión',
          loadingLabel: '',
          icon: Icons.arrow_forward,
          loading: false,
          onPressed: () =>
              context.go('/login?email=${Uri.encodeComponent(_email)}'),
        ),
      },
    );
  }
}
