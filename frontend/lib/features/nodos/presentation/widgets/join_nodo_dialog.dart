import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../providers/nodos_provider.dart';
import 'dialog_text_field.dart';


class JoinNodoDialog extends ConsumerStatefulWidget {
  const JoinNodoDialog({super.key});

  @override
  ConsumerState<JoinNodoDialog> createState() => _JoinNodoDialogState();
}

class _JoinNodoDialogState extends ConsumerState<JoinNodoDialog> {
  final _formKey = GlobalKey<FormState>();
  final _tokenCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 420,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.line, width: 1),
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.accentText.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.link_rounded,
                            color: AppColors.accentText, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        'Unirse a un nodo',
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Ingresa el token de acceso de 32 caracteres proporcionado por el administrador del nodo.',
                    style: TextStyle(color: AppColors.textSubtle, fontSize: 13),
                  ),
                  const SizedBox(height: 20),

                  // Campo: Token
                  DialogTextField(
                    controller: _tokenCtrl,
                    label: 'Token de acceso',
                    hint: 'Ej: a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6',
                    autofocus: true,
                    maxLength: 64,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'El token de acceso es requerido';
                      }
                      if (value.trim().length < 8) {
                        return 'El token de acceso debe tener al menos 8 caracteres';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 28),

                  // Botones
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textMuted,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                        onPressed:
                            _submitting ? null : () => Navigator.pop(context),
                        child: const Text('Cancelar'),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentText,
                          foregroundColor: AppColors.bg,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          disabledBackgroundColor:
                              AppColors.accentText.withValues(alpha: 0.4),
                        ),
                        onPressed: _submitting ? null : _onSubmit,
                        child: _submitting
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.bg),
                              )
                            : const Text(
                                'Unirse',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;
    final token = _tokenCtrl.text.trim();
    setState(() => _submitting = true);
    final success = await ref.read(nodosProvider.notifier).joinNodo(token);
    if (mounted) {
      setState(() => _submitting = false);
      if (success) Navigator.pop(context);
    }
  }
}
