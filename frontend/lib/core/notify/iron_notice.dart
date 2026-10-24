import 'package:flutter/material.dart';

/// Tipo de aviso: decide el icono, el color y cuánto dura por defecto.
enum NoticeKind {
  info,
  success,
  error,
  warning,
  message,
  meeting,
  friendRequest,
  reminder,
}

class NoticeAction {
  const NoticeAction(this.label, this.onPressed, {this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;
}

/// Un aviso dentro de la app (diseño «IronLink — Correos y notificaciones»).
class IronNotice {
  IronNotice({
    String? id,
    required this.kind,
    required this.title,
    this.subtitle,
    this.context,
    this.initials,
    IconData? icon,
    this.actions = const [],
    Duration? duration,
    int? priority,
  }) : assert(actions.length <= 2, 'Como mucho dos acciones'),
       id = id ?? 'notice-${_next++}',
       icon = icon ?? _icons[kind]!,
       duration = duration ?? _durationOf(kind, actions),
       priority = priority ?? _priorityOf(kind);

  static int _next = 0;

  /// Con el mismo id, un aviso repetido no vuelve a mostrarse mientras el
  /// anterior esté visible o en cola.
  final String id;
  final NoticeKind kind;
  final String title;
  final String? subtitle;

  /// Línea corta de contexto sobre el título, p. ej. «Reunión en curso · Nodo».
  final String? context;

  /// Iniciales para el avatar; sin ellas se usa [icon].
  final String? initials;
  final IconData icon;
  final List<NoticeAction> actions;
  final Duration duration;

  /// Uno de mayor prioridad reemplaza al visible.
  final int priority;

  bool get isAlert => kind == NoticeKind.error || kind == NoticeKind.warning;

  /// Los avisos que solo informan se descartan si otro los desplaza.
  bool get isTransient => switch (kind) {
    NoticeKind.info || NoticeKind.success => true,
    _ => false,
  };

  static const _icons = {
    NoticeKind.info: Icons.info_outline_rounded,
    NoticeKind.success: Icons.check_circle_outline_rounded,
    NoticeKind.error: Icons.error_outline_rounded,
    NoticeKind.warning: Icons.warning_amber_rounded,
    NoticeKind.message: Icons.chat_bubble_outline_rounded,
    NoticeKind.meeting: Icons.videocam_outlined,
    NoticeKind.friendRequest: Icons.person_add_alt_rounded,
    NoticeKind.reminder: Icons.event_outlined,
  };

  static Duration _durationOf(NoticeKind kind, List<NoticeAction> actions) =>
      switch (kind) {
        NoticeKind.meeting => const Duration(seconds: 30),
        NoticeKind.friendRequest ||
        NoticeKind.reminder => const Duration(seconds: 12),
        NoticeKind.error => const Duration(seconds: 7),
        _ when actions.isNotEmpty => const Duration(seconds: 8),
        _ => const Duration(seconds: 5),
      };

  static int _priorityOf(NoticeKind kind) => switch (kind) {
    NoticeKind.meeting => 3,
    NoticeKind.message || NoticeKind.friendRequest || NoticeKind.reminder => 2,
    NoticeKind.error || NoticeKind.warning => 1,
    _ => 0,
  };
}
