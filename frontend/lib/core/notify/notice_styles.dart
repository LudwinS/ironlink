import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../widgets/iron_logo.dart';
import 'iron_notice.dart';
import 'iron_notify.dart';

/// Cómo se presenta un aviso en cada plataforma (Claude Design, «IronLink —
/// Correos y notificaciones»).
enum NoticeStyle {
  /// macOS: panel negro que sale del notch (o píldora sin notch).
  notch,

  /// iPhone: se expande desde la Dynamic Island (o baja desde arriba).
  island,

  /// Windows, Linux y web de escritorio: abajo a la derecha.
  toast,

  /// Android y web móvil: tarjeta que baja desde arriba.
  headsUp,
}

/// Curva de resorte del diseño (cubic-bezier(.32,.72,0,1)).
const springCurve = Cubic(0.32, 0.72, 0, 1);

/// Curva de deslizamiento del diseño (cubic-bezier(.2,.9,.1,1)).
const slideCurve = Cubic(0.2, 0.9, 0.1, 1);

/// Colores fijos de las superficies negras que imitan el hardware.
const _hwText = Color(0xFFFFFFFF);
const _hwMuted = Color(0xFF9397AB);
const _hwSoft = Color(0xFFB2B6CA);
const _hwButton = Color(0xFF292B31);
const _hwInk = Color(0xFF0C0D14);

Color noticeTint(NoticeKind kind) => switch (kind) {
  NoticeKind.error => AppColors.error,
  NoticeKind.warning => AppColors.warning,
  NoticeKind.success => AppColors.success,
  _ => AppColors.accent,
};

/// Propiedades comunes a todos los estilos. [t] va de 0 (oculto) a 1.
class NoticeFrame {
  const NoticeFrame({
    required this.notice,
    required this.t,
    required this.reduceMotion,
    required this.onAction,
    required this.onDismiss,
  });

  final IronNotice notice;
  final double t;
  final bool reduceMotion;
  final void Function(int index) onAction;
  final VoidCallback onDismiss;

  double curved(Curve curve, [double begin = 0, double end = 1]) {
    if (t <= begin) return 0;
    if (t >= end) return 1;
    return curve.transform((t - begin) / (end - begin));
  }

  int? get primary {
    final index = notice.actions.indexWhere((a) => a.primary);
    if (index >= 0) return index;
    return notice.actions.isEmpty ? null : 0;
  }
}

/// Envoltorio accesible: se anuncia al aparecer y pausa con el puntero.
class _Announce extends StatelessWidget {
  const _Announce({required this.notice, required this.child});

  final IronNotice notice;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    child: MouseRegion(
      onEnter: (_) => IronNotify.instance.pause(),
      onExit: (_) => IronNotify.instance.resume(),
      child: child,
    ),
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.notice,
    required this.size,
    this.ring,
    this.square = false,
    this.background,
    this.foreground,
  });

  final IronNotice notice;
  final double size;
  final Color? ring;
  final bool square;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final tint = noticeTint(notice.kind);
    final fg = foreground ?? (notice.isAlert ? tint : AppColors.accentText);
    final initials = notice.initials;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? AppColors.accentTint,
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square ? BorderRadius.circular(size * 0.32) : null,
        border: ring == null ? null : Border.all(color: ring!, width: 1.5),
      ),
      alignment: Alignment.center,
      child: initials != null
          ? Text(
              initials,
              style: TextStyle(
                fontSize: size * 0.36,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            )
          : Icon(notice.icon, size: size * 0.5, color: fg),
    );
  }
}

/// Botón con área de pulsación de al menos 44 px.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.onTap,
    required this.background,
    required this.foreground,
    this.icon,
    this.height = 36,
    this.expand = false,
    this.border,
    this.radius,
  });

  final String label;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final IconData? icon;
  final double height;
  final bool expand;
  final Color? border;

  /// Sin radio, forma de píldora.
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final side = border == null ? BorderSide.none : BorderSide(color: border!);
    final pill = Material(
      color: background,
      shape: radius == null
          ? StadiumBorder(side: side)
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius!),
              side: side,
            ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: foreground),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: math.max(44, height)),
        child: Center(widthFactor: expand ? null : 1, child: pill),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.background,
    required this.foreground,
    this.size = 36,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tooltip,
    excludeSemantics: true,
    child: SizedBox(
      width: math.max(44, size),
      height: math.max(44, size),
      child: Center(
        child: Material(
          color: background,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: size * 0.45, color: foreground),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _texts({
  required IronNotice notice,
  required Color title,
  required Color subtitle,
  Color? context,
  bool contextUpper = false,
  double titleSize = 15,
}) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    if (notice.context != null)
      Text(
        contextUpper ? notice.context!.toUpperCase() : notice.context!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: contextUpper ? 11 : 12,
          fontWeight: contextUpper ? FontWeight.w600 : FontWeight.w400,
          letterSpacing: contextUpper ? 0.6 : 0,
          color: context ?? subtitle,
        ),
      ),
    Text(
      notice.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: titleSize,
        fontWeight: FontWeight.w600,
        color: title,
        height: 1.25,
      ),
    ),
    if (notice.subtitle != null)
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          notice.subtitle!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: subtitle),
        ),
      ),
  ],
);

/// Desenfoque, escala y fundido del contenido al aparecer (como el diseño).
Widget _reveal(NoticeFrame f, Widget child, {double from = 0.94}) {
  if (f.reduceMotion) return Opacity(opacity: f.t, child: child);
  final v = f.curved(Curves.easeOut, 0.35, 1);
  final blur = (1 - v) * 5;
  return Opacity(
    opacity: v,
    child: Transform.scale(
      scale: lerpDouble(from, 1, v)!,
      child: blur < 0.05
          ? child
          : ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: child,
            ),
    ),
  );
}

// ─── macOS: desde el notch (versión Flutter, sin el panel nativo) ─────────

class NotchNotice extends StatelessWidget {
  const NotchNotice(this.f, {super.key});

  final NoticeFrame f;

  @override
  Widget build(BuildContext context) {
    final n = f.notice;
    final screen = MediaQuery.sizeOf(context).width;
    final full = math.min(540.0, screen - 32);
    final e = f.reduceMotion ? 1.0 : f.curved(springCurve);
    final width = lerpDouble(200, full, e)!;
    final height = lerpDouble(32, 104, e)!;
    final radius = lerpDouble(12, 30, e)!;
    final accent = noticeTint(n.kind);
    final primary = f.primary;
    final body = SizedBox(
      width: full,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 16, 18),
        child: Row(
          children: [
            _Avatar(
              notice: n,
              size: 44,
              ring: accent,
              background: const Color(0xFF2B2741),
              foreground: n.isAlert ? accent : const Color(0xFFD2CEFD),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _texts(
                notice: n,
                title: _hwText,
                subtitle: _hwMuted,
                context: accent,
                contextUpper: true,
              ),
            ),
            _RoundButton(
              icon: Icons.close_rounded,
              tooltip: 'Cerrar',
              onTap: f.onDismiss,
              background: _hwButton,
              foreground: const Color(0xFFE9E9ED),
            ),
            if (primary != null)
              _Pill(
                label: n.actions[primary].label,
                icon: n.kind == NoticeKind.meeting
                    ? Icons.videocam_rounded
                    : null,
                onTap: () => f.onAction(primary),
                background: accent,
                foreground: _hwInk,
              ),
          ],
        ),
      ),
    );
    return _Announce(
      notice: n,
      child: Align(
        alignment: Alignment.topCenter,
        child: Opacity(
          opacity: f.reduceMotion ? f.t : math.min(1, f.t * 4),
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(radius),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.bottomCenter,
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minWidth: full,
              maxWidth: full,
              maxHeight: 104,
              child: _reveal(f, body),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── iPhone: desde la Dynamic Island ─────────────────────────────────────

class IslandNotice extends StatelessWidget {
  const IslandNotice(this.f, {super.key});

  final NoticeFrame f;

  /// Margen superior de los iPhone con Dynamic Island.
  static bool hasIsland(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).top >= 59;

  @override
  Widget build(BuildContext context) {
    final n = f.notice;
    final island = hasIsland(context);
    final full = math.min(366.0, MediaQuery.sizeOf(context).width - 24);
    final e = f.reduceMotion ? 1.0 : f.curved(springCurve);
    final primary = f.primary;
    final accent = noticeTint(n.kind);
    final content = SizedBox(
      width: full,
      height: 88,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            _Avatar(
              notice: n,
              size: 52,
              background: const Color(0xFF2B2741),
              foreground: n.isAlert ? accent : const Color(0xFFD2CEFD),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _texts(
                notice: n,
                title: _hwText,
                subtitle: _hwSoft,
                context: _hwMuted,
              ),
            ),
            if (primary != null) ...[
              const SizedBox(width: 8),
              _Pill(
                label: n.actions[primary].label,
                onTap: () => f.onAction(primary),
                background: accent,
                foreground: _hwInk,
                height: 40,
              ),
            ],
          ],
        ),
      ),
    );
    Widget shape;
    if (island) {
      // Nace con la forma y el lugar exactos de la isla.
      shape = Container(
        width: lerpDouble(126, full, e),
        height: lerpDouble(37, 88, e),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(lerpDouble(19, 44, e)!),
        ),
        clipBehavior: Clip.antiAlias,
        child: OverflowBox(
          minWidth: full,
          maxWidth: full,
          maxHeight: 88,
          child: _reveal(f, content, from: 0.92),
        ),
      );
    } else {
      shape = Transform.translate(
        offset: Offset(0, f.reduceMotion ? 0 : lerpDouble(-120, 0, e)!),
        child: Opacity(
          opacity: f.reduceMotion ? f.t : math.min(1, f.t * 2),
          child: Container(
            width: full,
            height: 88,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(32),
            ),
            child: content,
          ),
        ),
      );
    }
    return _Announce(
      notice: n,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(
            top: island ? 11 : MediaQuery.viewPaddingOf(context).top + 8,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Deslizar hacia arriba lo descarta.
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -100) f.onDismiss();
            },
            child: Opacity(
              opacity: island && !f.reduceMotion ? math.min(1, f.t * 6) : 1,
              child: shape,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Windows: abajo a la derecha ─────────────────────────────────────────

class ToastNotice extends StatefulWidget {
  const ToastNotice(this.f, {super.key});

  final NoticeFrame f;

  @override
  State<ToastNotice> createState() => _ToastNoticeState();
}

class _ToastNoticeState extends State<ToastNotice>
    with TickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.f.notice.duration,
  );
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    final total = widget.f.notice.duration.inMilliseconds;
    final left = IronNotify.instance.remaining.inMilliseconds;
    _progress.value = total == 0 ? 0 : 1 - left / total;
    if (!IronNotify.instance.paused) _progress.forward();
    // El borde de acento destella al llegar.
    if (!widget.f.reduceMotion) {
      Future.delayed(const Duration(milliseconds: 280), () {
        if (mounted) _flash.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final n = f.notice;
    final accent = noticeTint(n.kind);
    final e = f.reduceMotion ? 1.0 : f.curved(slideCurve);
    final width = math.min(380.0, MediaQuery.sizeOf(context).width - 32);
    final primary = f.primary;
    final card = Container(
      width: width,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 50,
            offset: Offset(0, 18),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const IronLogo.mark(size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'IronLink · ${n.context ?? 'ahora'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSubtle,
                            ),
                          ),
                        ),
                        _RoundButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Cerrar',
                          onTap: f.onDismiss,
                          background: Colors.transparent,
                          foreground: AppColors.textMuted,
                          size: 28,
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Row(
                        children: [
                          _Avatar(notice: n, size: 44),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _texts(
                              notice: n.context == null
                                  ? n
                                  : _withoutContext(n),
                              title: AppColors.text,
                              subtitle: AppColors.textMuted,
                              titleSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (n.actions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 12),
                        child: Row(
                          children: [
                            for (var i = 0; i < n.actions.length; i++) ...[
                              if (i > 0) const SizedBox(width: 8),
                              Expanded(
                                child: _Pill(
                                  label: n.actions[i].label,
                                  onTap: () => f.onAction(i),
                                  expand: true,
                                  radius: 8,
                                  background: i == primary
                                      ? accent
                                      : AppColors.surface,
                                  foreground: i == primary
                                      ? AppColors.onAccent
                                      : AppColors.text,
                                  border: i == primary ? null : AppColors.line,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(
                height: 3,
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: 1 - _progress.value,
                      heightFactor: 1,
                      child: ColoredBox(color: accent),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flash,
                builder: (context, _) {
                  final glow = math.sin(_flash.value * math.pi);
                  return glow <= 0
                      ? const SizedBox.shrink()
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: accent.withValues(alpha: glow),
                            ),
                          ),
                        );
                },
              ),
            ),
          ),
        ],
      ),
    );
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: _Announce(
          notice: n,
          child: MouseRegion(
            onEnter: (_) => _progress.stop(),
            onExit: (_) {
              if (!IronNotify.instance.paused) _progress.forward();
            },
            child: Opacity(
              opacity: f.reduceMotion ? f.t : math.min(1, f.t * 2),
              child: Transform.translate(
                offset: Offset(f.reduceMotion ? 0 : (1 - e) * 56, 0),
                child: Transform.scale(
                  scale: f.reduceMotion ? 1 : lerpDouble(0.98, 1, e)!,
                  child: card,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static IronNotice _withoutContext(IronNotice n) => IronNotice(
    id: n.id,
    kind: n.kind,
    title: n.title,
    subtitle: n.subtitle,
    initials: n.initials,
    icon: n.icon,
    actions: n.actions,
    duration: n.duration,
    priority: n.priority,
  );
}

// ─── Android: tarjeta que baja desde arriba ──────────────────────────────

class HeadsUpNotice extends StatelessWidget {
  const HeadsUpNotice(this.f, {super.key});

  final NoticeFrame f;

  @override
  Widget build(BuildContext context) {
    final n = f.notice;
    final accent = noticeTint(n.kind);
    final primary = f.primary;
    // Baja con un leve rebote y el icono aparece con un pequeño salto.
    final drop = f.reduceMotion ? 1.0 : f.curved(Curves.easeOutBack);
    final pop = f.reduceMotion ? 1.0 : f.curved(Curves.elasticOut, 0.3, 1);
    final card = Container(
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x80000000),
            blurRadius: 40,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Transform.scale(
                scale: lerpDouble(0.6, 1, pop)!,
                child: _Avatar(notice: n, size: 44, square: n.initials == null),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _texts(
                  notice: n,
                  title: AppColors.text,
                  subtitle: AppColors.textMuted,
                  context: AppColors.textSubtle,
                ),
              ),
            ],
          ),
          if (n.actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  for (var i = 0; i < n.actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _Pill(
                        label: n.actions[i].label,
                        onTap: () => f.onAction(i),
                        expand: true,
                        height: 44,
                        background: i == primary
                            ? accent
                            : AppColors.accentTint,
                        foreground: i == primary
                            ? AppColors.onAccent
                            : AppColors.accentText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 6),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.viewPaddingOf(context).top + 8,
          12,
          0,
        ),
        child: _Announce(
          notice: n,
          child: Dismissible(
            key: ValueKey(n.id),
            direction: DismissDirection.horizontal,
            onDismissed: (_) => f.onDismiss(),
            child: GestureDetector(
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -100) f.onDismiss();
              },
              child: Opacity(
                opacity: f.reduceMotion ? f.t : math.min(1, f.t * 2),
                child: FractionalTranslation(
                  translation: Offset(0, f.reduceMotion ? 0 : (drop - 1) * 1.2),
                  child: card,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
