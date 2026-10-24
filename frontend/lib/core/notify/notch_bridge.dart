import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import 'iron_notice.dart';
import 'iron_notify.dart';
import 'notice_styles.dart';

/// Puente con el panel nativo de macOS que sale del notch
/// (`macos/Runner/NotchPanel.swift`). El temporizador y la cola siguen en
/// [IronNotify]; el panel avisa de acciones, cierres y del puntero encima.
class NotchBridge {
  NotchBridge(this._notify, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('ironlink/notch');

  final IronNotify _notify;
  final MethodChannel _channel;

  /// Falso si el panel nativo no existe (p. ej. en pruebas): entonces se
  /// dibuja la versión Flutter.
  bool active = true;

  void attach() => _channel.setMethodCallHandler(_onCall);

  void detach() => _channel.setMethodCallHandler(null);

  Future<void> present(IronNotice? notice) async {
    try {
      if (notice == null) {
        await _channel.invokeMethod<void>('hide');
      } else {
        await _channel.invokeMethod<void>('show', _encode(notice));
      }
    } on MissingPluginException {
      active = false;
    } on PlatformException {
      active = false;
    }
  }

  Map<String, Object?> _encode(IronNotice n) {
    final primary = n.actions.indexWhere((a) => a.primary);
    return {
      'id': n.id,
      'title': n.title,
      'subtitle': n.subtitle,
      'context': n.context?.toUpperCase(),
      'initials': n.initials,
      // Nombre de SF Symbol equivalente al icono del tipo de aviso.
      'symbol': _symbols[n.kind],
      'accent': noticeTint(n.kind).toARGB32(),
      'alert': n.isAlert,
      'actions': [
        for (var i = 0; i < n.actions.length; i++)
          {
            'label': n.actions[i].label,
            'primary': primary < 0 ? i == 0 : i == primary,
          },
      ],
      'avatarBackground': AppColors.palette.accentTint.toARGB32(),
    };
  }

  Future<Object?> _onCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    final id = args['id'] as String?;
    switch (call.method) {
      case 'action':
        if (id != null) _notify.runAction(id, args['index'] as int? ?? -1);
      case 'dismiss':
        if (id != null) _notify.remove(id);
      case 'hover':
        (args['inside'] == true) ? _notify.pause() : _notify.resume();
    }
    return null;
  }

  static const _symbols = {
    NoticeKind.info: 'info.circle',
    NoticeKind.success: 'checkmark.circle',
    NoticeKind.error: 'exclamationmark.circle',
    NoticeKind.warning: 'exclamationmark.triangle',
    NoticeKind.message: 'bubble.left',
    NoticeKind.meeting: 'video',
    NoticeKind.friendRequest: 'person.badge.plus',
    NoticeKind.reminder: 'calendar',
  };
}
