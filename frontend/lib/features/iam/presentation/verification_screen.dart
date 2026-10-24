import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/auth_provider.dart';
import 'widgets/auth_layout.dart';

enum _Phase { email, code, link }

/// Verificación del correo. Al llegar con un correo se envía el código de
/// inmediato (diseño «Verifica tu correo»); el enlace queda como alternativa.
class VerificationScreen extends ConsumerStatefulWidget {
  final String email;
  const VerificationScreen({super.key, required this.email});

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  late final _emailController = TextEditingController(text: widget.email);
  _Phase _phase = _Phase.email;
  String _code = '';
  int _codeAttempt = 0;
  String? _emailError, _codeError;
  AuthBanner? _banner;
  bool _busy = false;

  String get _email => _emailController.text.trim();

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(authProvider.notifier).clearFieldErrors();
      if (validateEmail(widget.email) == null) _request('code');
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  /// Pide un código o un enlace. Devuelve true si el servidor lo aceptó.
  Future<bool> _request(String method) async {
    final error = validateEmail(_emailController.text);
    if (error != null) {
      setState(() => _emailError = error);
      return false;
    }
    setState(() {
      _busy = true;
      _emailError = _codeError = null;
    });
    final ok = await ref
        .read(authProvider.notifier)
        .requestVerification(_email, method);
    if (!mounted) return ok;
    final auth = ref.read(authProvider);
    setState(() {
      _busy = false;
      if (ok) {
        _phase = method == 'code' ? _Phase.code : _Phase.link;
        _codeAttempt++;
        _code = '';
        _banner = AuthBanner(
          kind: AuthBannerKind.success,
          text: method == 'code'
              ? 'Código enviado a $_email.'
              : 'Enlace enviado a $_email.',
        );
      } else {
        _banner = AuthBanner(
          kind: AuthBannerKind.error,
          text: auth.errorMessage ?? 'No se pudo enviar. Inténtalo de nuevo.',
        );
      }
    });
    return ok;
  }

  Future<void> _verifyCode() async {
    if (_code.length < 6) {
      setState(() => _codeError = 'Faltan ${6 - _code.length} dígitos.');
      return;
    }
    setState(() {
      _busy = true;
      _banner = null;
    });
    final ok = await ref.read(authProvider.notifier).verifyEmail(_email, _code);
    if (!mounted) return;
    if (ok) return context.go('/verification-success');
    setState(() {
      _busy = false;
      _code = '';
      _codeAttempt++;
      _codeError =
          ref.read(authProvider).errorMessage ??
          'Código incorrecto. Revísalo o solicita uno nuevo.';
    });
  }

  /// Comprueba si la cuenta ya se activó desde el enlace del correo.
  Future<void> _checkLink() async {
    setState(() {
      _busy = true;
      _banner = null;
    });
    final ok = await ref.read(authProvider.notifier).verifyEmail(_email, '');
    if (!mounted) return;
    if (ok) return context.go('/verification-success');
    setState(() {
      _busy = false;
      _banner = const AuthBanner(
        kind: AuthBannerKind.warning,
        text:
            'Todavía no vemos la cuenta activada. Abre el enlace del correo y vuelve a intentarlo.',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final target = _email.isEmpty ? 'tu correo' : _email;
    final (title, subtitle) = switch (_phase) {
      _Phase.email => (
        'Verifica tu correo',
        'Escribe el correo de tu cuenta y te enviaremos un código.',
      ),
      _Phase.code => (
        'Verifica tu correo',
        'Escribe el código que enviamos a $target.',
      ),
      _Phase.link => (
        'Revisa tu correo',
        'Abre el enlace que enviamos a $target y vuelve aquí.',
      ),
    };

    return AuthLayout(
      viewKey: _phase,
      title: title,
      subtitle: subtitle,
      banner: _banner,
      onBack: () => context.go('/login'),
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
              onSubmitted: (_) => _request('code'),
            ),
            const SizedBox(height: 14),
            AuthPrimaryButton(
              label: 'Enviar código',
              loadingLabel: 'Enviando…',
              icon: Icons.arrow_forward,
              loading: _busy,
              onPressed: () => _request('code'),
            ),
          ],
        ),
        _Phase.code => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CodeInput(
              key: ValueKey(_codeAttempt),
              errorText: _codeError,
              onChanged: (c) => setState(() {
                _code = c;
                _codeError = null;
              }),
              onCompleted: (_) => _verifyCode(),
            ),
            const SizedBox(height: 8),
            ResendCode(onResend: () => _request('code')),
            const SizedBox(height: 14),
            AuthPrimaryButton(
              label: 'Verificar',
              loadingLabel: 'Verificando…',
              icon: Icons.arrow_forward,
              loading: _busy,
              onPressed: _verifyCode,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: AuthLink(
                label: 'Prefiero recibir un enlace',
                onTap: _busy ? null : () => _request('link'),
              ),
            ),
          ],
        ),
        _Phase.link => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'El enlace caduca pronto. Si no lo encuentras, revisa la carpeta de spam.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13.5),
            ),
            const SizedBox(height: 8),
            ResendCode(onResend: () => _request('link')),
            const SizedBox(height: 14),
            AuthPrimaryButton(
              label: 'Ya abrí el enlace',
              loadingLabel: 'Comprobando…',
              icon: Icons.check,
              loading: _busy,
              onPressed: _checkLink,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: AuthLink(
                label: 'Usar un código en su lugar',
                onTap: _busy ? null : () => _request('code'),
              ),
            ),
          ],
        ),
      },
    );
  }
}
