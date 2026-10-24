import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/auth_provider.dart';
import 'widgets/auth_layout.dart';

/// Confirmación tras verificar el correo. La verificación no inicia sesión,
/// así que el siguiente paso es entrar con las credenciales.
class VerificationSuccessScreen extends ConsumerWidget {
  const VerificationSuccessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final data = auth.verifiedUserData;
    final name = (data?['name'] ?? auth.username ?? '').toString();
    final email = (data?['email'] ?? auth.email ?? '').toString();

    return AuthLayout(
      viewKey: 'verified',
      title: 'Cuenta verificada',
      subtitle: name.isEmpty
          ? 'Todo listo. Inicia sesión para entrar a tus conversaciones.'
          : 'Todo listo, $name. Inicia sesión para entrar a tus conversaciones.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (email.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.line),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline, color: AppColors.accentText),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      email,
                      style: TextStyle(color: AppColors.text, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          AuthPrimaryButton(
            label: 'Iniciar sesión',
            loadingLabel: '',
            icon: Icons.arrow_forward,
            loading: false,
            onPressed: () =>
                context.go('/login?email=${Uri.encodeComponent(email)}'),
          ),
        ],
      ),
    );
  }
}
