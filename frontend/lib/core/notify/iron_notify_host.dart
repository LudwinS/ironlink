import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'iron_notice.dart';
import 'iron_notify.dart';
import 'notch_bridge.dart';
import 'notice_styles.dart';

/// Estilo según la plataforma; en la web, según el ancho.
NoticeStyle noticeStyleFor(
  TargetPlatform platform, {
  bool web = kIsWeb,
  double width = 1280,
}) {
  if (web) return width < 600 ? NoticeStyle.headsUp : NoticeStyle.toast;
  return switch (platform) {
    TargetPlatform.macOS => NoticeStyle.notch,
    TargetPlatform.iOS => NoticeStyle.island,
    TargetPlatform.android || TargetPlatform.fuchsia => NoticeStyle.headsUp,
    TargetPlatform.windows || TargetPlatform.linux => NoticeStyle.toast,
  };
}

/// Dibuja sobre la app el aviso visible de [IronNotify]. En macOS lo entrega
/// al panel nativo del notch y solo dibuja si ese panel no está disponible.
class IronNotifyHost extends StatefulWidget {
  const IronNotifyHost({
    super.key,
    required this.child,
    this.style,
    this.controller,
    this.bridge,
  });

  final Widget child;

  /// Fija el estilo (pruebas); sin él, se elige por plataforma.
  final NoticeStyle? style;
  final IronNotify? controller;
  final NotchBridge? bridge;

  @override
  State<IronNotifyHost> createState() => _IronNotifyHostState();
}

class _IronNotifyHostState extends State<IronNotifyHost>
    with SingleTickerProviderStateMixin {
  late final IronNotify _notify = widget.controller ?? IronNotify.instance;
  late final AnimationController _anim;
  NotchBridge? _bridge;
  IronNotice? _shown;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    // Se crea aquí y no al primer uso: con el panel nativo podría no usarse
    // nunca y crearse en dispose().
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _notify.addListener(_sync);
    final macOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    if (widget.style == null && macOS || widget.bridge != null) {
      _bridge = (widget.bridge ?? NotchBridge(_notify))..attach();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _notify.removeListener(_sync);
    _bridge?.detach();
    _anim.dispose();
    super.dispose();
  }

  /// Sigue al aviso actual: si cambia, el anterior sale antes de que entre el
  /// nuevo. Con cambios seguidos solo se anima hacia el último.
  Future<void> _sync() async {
    if (_switching || !mounted) return;
    _switching = true;
    try {
      while (mounted && _notify.current?.id != _shown?.id) {
        final target = _notify.current;
        if (_bridge?.active ?? false) {
          // El panel nativo anima por su cuenta.
          setState(() => _shown = target);
          await _bridge!.present(target);
          // Sin panel nativo, se vuelve a mostrar con la versión Flutter.
          if (!_bridge!.active && mounted) setState(() => _shown = null);
          continue;
        }
        if (_shown != null) await _anim.reverse().orCancel.catchError((_) {});
        if (!mounted) return;
        setState(() => _shown = _notify.current);
        if (_shown != null) {
          unawaited(_anim.forward(from: 0).orCancel.catchError((_) {}));
        }
      }
    } finally {
      _switching = false;
    }
  }

  NoticeStyle _style(BuildContext context) =>
      widget.style ??
      noticeStyleFor(
        defaultTargetPlatform,
        width: MediaQuery.sizeOf(context).width,
      );

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final native = _bridge?.active ?? false;
    return Stack(
      children: [
        widget.child,
        if (shown != null && !native)
          Positioned.fill(
            child: SafeArea(
              top: false,
              bottom: false,
              child: Material(
                type: MaterialType.transparency,
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) {
                    final frame = NoticeFrame(
                      notice: shown,
                      t: _anim.value,
                      reduceMotion: MediaQuery.disableAnimationsOf(context),
                      onAction: (i) => _notify.runAction(shown.id, i),
                      onDismiss: () => _notify.remove(shown.id),
                    );
                    return switch (_style(context)) {
                      NoticeStyle.notch => NotchNotice(frame),
                      NoticeStyle.island => IslandNotice(frame),
                      NoticeStyle.toast => ToastNotice(
                        frame,
                        key: ValueKey(shown.id),
                      ),
                      NoticeStyle.headsUp => HeadsUpNotice(frame),
                    };
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}
