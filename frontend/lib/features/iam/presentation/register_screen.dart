import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import 'widgets/auth_layout.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;
  bool _acceptedTerms = false;
  Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    // Un error de otra pantalla de acceso no debe aparecer aquí.
    Future.microtask(() => ref.read(authProvider.notifier).clearFieldErrors());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// El backend exige prefijo internacional; sin «+» se asume El Salvador.
  String get _phone {
    final raw = _phoneController.text.trim().replaceAll(RegExp(r'[\s-]'), '');
    return raw.startsWith('+') ? raw : '+503$raw';
  }

  void _clear(String field) {
    if (_errors.containsKey(field)) {
      setState(() => _errors = {..._errors}..remove(field));
    }
  }

  Map<String, String> _validate() {
    final phoneDigits = _phone.substring(1);
    return {
      if (_nameController.text.trim().length < 2) 'name': 'Escribe tu nombre.',
      'email': ?validateEmail(_emailController.text),
      if (_phoneController.text.trim().isEmpty)
        'phone': 'Escribe tu teléfono.'
      else if (phoneDigits.length < 7 || phoneDigits.length > 16)
        'phone':
            'Revisa el número: incluye el prefijo, por ejemplo +50312345678.',
      'password': ?PasswordRules.validate(_passwordController.text),
      if (!_acceptedTerms)
        'terms': 'Debes aceptar los términos para continuar.',
    };
  }

  Future<void> _submit() async {
    final errors = _validate();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) return;

    final email = _emailController.text.trim();
    final ok = await ref
        .read(authProvider.notifier)
        .register(
          name: _nameController.text.trim(),
          email: email,
          phone: _phone,
          password: _passwordController.text,
        );
    if (!mounted) return;
    if (ok) {
      context.go('/verification?email=${Uri.encodeComponent(email)}');
    } else {
      final server = ref.read(authProvider).fieldErrors;
      if (server != null) setState(() => _errors = {..._errors, ...server});
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final loading = auth.status == AuthStatus.loading;
    // Los errores por campo se muestran junto a cada campo; el aviso general
    // queda para los que no corresponden a ninguno.
    final generalError = auth.fieldErrors == null ? auth.errorMessage : null;

    return AuthLayout(
      viewKey: 'register',
      title: 'Crea tu cuenta',
      subtitle: 'Tardarás menos de un minuto. Después verificarás tu correo.',
      onBack: () => context.go('/login'),
      banner: generalError == null
          ? null
          : AuthBanner(kind: AuthBannerKind.error, text: generalError),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthField(
              label: 'Nombre completo',
              controller: _nameController,
              hint: 'Ana Rivas',
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.name],
              errorText: _errors['name'],
              onChanged: (_) => _clear('name'),
            ),
            const SizedBox(height: 14),
            AuthField(
              label: 'Correo electrónico',
              controller: _emailController,
              hint: 'correo@organizacion.com',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              errorText: _errors['email'],
              onChanged: (_) => _clear('email'),
            ),
            const SizedBox(height: 14),
            AuthField(
              label: 'Teléfono',
              controller: _phoneController,
              hint: '+503 7000 0000',
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.telephoneNumber],
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
              ],
              errorText: _errors['phone'],
              onChanged: (_) => _clear('phone'),
            ),
            const SizedBox(height: 14),
            AuthField(
              label: 'Contraseña',
              controller: _passwordController,
              hint: 'Mínimo 8 caracteres',
              obscure: !_showPassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              errorText: _errors['password'],
              onChanged: (_) {
                _clear('password');
                setState(() {});
              },
              onSubmitted: (_) => _submit(),
              suffix: PasswordToggle(
                visible: _showPassword,
                onToggle: () => setState(() => _showPassword = !_showPassword),
              ),
              helper: PasswordStrengthBar(password: _passwordController.text),
            ),
            const SizedBox(height: 14),
            AuthCheckbox(
              value: _acceptedTerms,
              onChanged: (v) => setState(() {
                _acceptedTerms = v;
                _errors = {..._errors}..remove('terms');
              }),
              label: 'Acepto los términos de uso y la política de privacidad',
            ),
            if (_errors['terms'] case final e?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AuthErrorText(e),
              ),
            const SizedBox(height: 14),
            AuthPrimaryButton(
              label: 'Crear cuenta',
              loadingLabel: 'Creando cuenta…',
              icon: Icons.arrow_forward,
              loading: loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 20),
            AuthPrompt(
              text: '¿Ya tienes cuenta?',
              link: AuthLink(
                label: 'Inicia sesión',
                onTap: () => context.go('/login'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
