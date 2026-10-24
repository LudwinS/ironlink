import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';

/// Confirmación antes de bloquear a [name]. Devuelve `true` si se confirma.
Future<bool> confirmBlock(BuildContext context, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('¿Bloquear a $name?'),
      content: const Text(
        'No podrá encontrarte, enviarte solicitudes ni escribirte. Si son '
        'amigos, dejarán de serlo y se borrarán las solicitudes pendientes. '
        'No se le avisará. Puedes desbloquearla cuando quieras desde '
        'Amigos › Bloqueados.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Bloquear'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
