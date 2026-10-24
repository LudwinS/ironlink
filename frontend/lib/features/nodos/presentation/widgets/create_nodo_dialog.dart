import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../providers/nodos_provider.dart';
import 'dialog_text_field.dart';


class CreateNodoDialog extends ConsumerStatefulWidget {
  const CreateNodoDialog({super.key});

  @override
  ConsumerState<CreateNodoDialog> createState() => _CreateNodoDialogState();
}

class _CreateNodoDialogState extends ConsumerState<CreateNodoDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nombreCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _descCtrl.dispose();
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
                          color: AppColors.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.add_rounded,
                            color: AppColors.accent, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        'Crear nuevo nodo',
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Campo: Nombre
                  DialogTextField(
                    controller: _nombreCtrl,
                    maxLength: 100,
                    label: 'Nombre del nodo',
                    hint: 'Ej: Red de desarrollo',
                    autofocus: true,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'El nombre del nodo es requerido';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Campo: Descripción
                  DialogTextField(
                    controller: _descCtrl,
                    label: 'Descripción (opcional)',
                    hint: 'Una breve descripción del nodo...',
                    maxLines: 3,
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
                          backgroundColor: AppColors.accent,
                          foregroundColor: AppColors.bg,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          disabledBackgroundColor:
                              AppColors.accent.withValues(alpha: 0.4),
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
                                'Crear nodo',
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
    final nombre = _nombreCtrl.text.trim();
    setState(() => _submitting = true);
    final success = await ref.read(nodosProvider.notifier).createNodo(
          nombre: nombre,
          descripcion: _descCtrl.text.trim(),
        );
    if (mounted) {
      setState(() => _submitting = false);
      if (success) Navigator.pop(context);
    }
  }
}
