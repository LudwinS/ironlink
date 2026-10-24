import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/iron_logo.dart';
import '../../../../core/widgets/no_scrollbar_behavior.dart';

/// Ancho a partir del cual se muestra el panel de marca a la izquierda.
const double kAuthWideBreakpoint = 900;

/// Estructura común de las pantallas de acceso (diseño «IronLink Acceso»):
/// panel de marca a la izquierda en escritorio y una columna de 400 px con
/// título, aviso y formulario.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.viewKey,
    required this.title,
    required this.subtitle,
    required this.child,
    this.banner,
    this.onBack,
  });

  /// Identifica la vista para animar su entrada al cambiar de paso.
  final Object viewKey;
  final String title, subtitle;
  final Widget child;
  final AuthBanner? banner;

  /// Muestra «Volver a iniciar sesión» cuando no es nulo.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.4,
            colors: [AppColors.accentTint, AppColors.bg],
            stops: const [0, .6],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= kAuthWideBreakpoint;
            final column = _MainColumn(
              wide: wide,
              viewKey: viewKey,
              reduceMotion: reduceMotion,
              title: title,
              subtitle: subtitle,
              banner: banner,
              onBack: onBack,
              child: child,
            );
            if (!wide) return SafeArea(child: column);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: (constraints.maxWidth / 2).clamp(0, 560).toDouble(),
                  child: const _BrandPanel(),
                ),
                Expanded(child: column),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(48),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.surface3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Transform.translate(
            offset: const Offset(-24, 0),
            child: const IronLogo.full(
              semanticLabel: 'IronLink · Conecta, comunica, colabora',
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mensajes directos y nodos de trabajo en un mismo lugar.',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 32,
                    fontWeight: FontWeight.w500,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Tus conversaciones, subgrupos y reuniones siguen donde las dejaste, en cualquier dispositivo.',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 15,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 16,
                color: AppColors.accent,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Autenticación segura · IronLink',
                  style: TextStyle(color: AppColors.textSubtle, fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MainColumn extends StatelessWidget {
  const _MainColumn({
    required this.wide,
    required this.viewKey,
    required this.reduceMotion,
    required this.title,
    required this.subtitle,
    required this.child,
    this.banner,
    this.onBack,
  });

  final bool wide, reduceMotion;
  final Object viewKey;
  final String title, subtitle;
  final Widget child;
  final AuthBanner? banner;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      key: ValueKey(viewKey),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!wide) ...[
          Row(
            children: [
              const IronLogo.mark(),
              const SizedBox(width: 10),
              Text(
                'IronLink',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        if (onBack != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Transform.translate(
              offset: const Offset(-8, 0),
              child: TextButton.icon(
                onPressed: onBack,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textMuted,
                ),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Volver a iniciar sesión'),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Semantics(
          header: true,
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 26,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        if (banner != null) ...[banner!, const SizedBox(height: 20)],
        child,
      ],
    );

    return Center(
      child: ScrollConfiguration(
        behavior: const NoScrollbarBehavior(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: AnimatedSwitcher(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOut,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, .02),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) =>
                  current ?? const SizedBox.shrink(),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

enum AuthBannerKind { error, warning, success }

/// Aviso con icono y acción opcional, anunciado a lectores de pantalla.
class AuthBanner extends StatelessWidget {
  const AuthBanner({
    super.key,
    required this.kind,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final AuthBannerKind kind;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final (icon, fg, border, fill) = switch (kind) {
      AuthBannerKind.error => (
        Icons.error_outline,
        AppColors.errorText,
        AppColors.error.withValues(alpha: .5),
        AppColors.error.withValues(alpha: .10),
      ),
      AuthBannerKind.warning => (
        Icons.mark_email_unread_outlined,
        AppColors.warning,
        AppColors.warning.withValues(alpha: .45),
        AppColors.warning.withValues(alpha: .08),
      ),
      AuthBannerKind.success => (
        Icons.check_circle_outline,
        AppColors.accentText,
        AppColors.accentDeep,
        AppColors.accentTint,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 18, color: fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 30,
                      child: OutlinedButton(
                        onPressed: onAction,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          textStyle: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(fontSize: 13),
                        ),
                        child: Text(actionLabel!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Campo con etiqueta visible encima y error debajo.
class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.label,
    required this.controller,
    this.trailingLabel,
    this.hint,
    this.errorText,
    this.helper,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.obscure = false,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.inputFormatters,
  });

  final String label;
  final Widget? trailingLabel;
  final TextEditingController controller;
  final String? hint, errorText;
  final Widget? helper;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool obscure, autofocus;
  final Widget? suffix;
  final ValueChanged<String>? onChanged, onSubmitted;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _FieldLabel(label)),
            ?trailingLabel,
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          autofocus: autofocus,
          obscureText: obscure,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          autofillHints: autofillHints,
          inputFormatters: inputFormatters,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: TextStyle(color: AppColors.text, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 13,
            ),
            suffixIcon: suffix,
            errorText: errorText,
            errorMaxLines: 3,
          ),
        ),
        if (helper != null && errorText == null) ...[
          const SizedBox(height: 6),
          helper!,
        ],
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: AppColors.textMuted,
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// Botón para mostrar u ocultar la contraseña.
class PasswordToggle extends StatelessWidget {
  const PasswordToggle({
    super.key,
    required this.visible,
    required this.onToggle,
  });

  final bool visible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: visible ? 'Ocultar contraseña' : 'Mostrar contraseña',
    onPressed: onToggle,
    icon: Icon(
      visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      color: AppColors.textMuted,
      size: 20,
    ),
  );
}

/// Reglas de contraseña que exige el backend (auth/service.rs).
class PasswordRules {
  static final _special = RegExp(r'''[!@#$%^&*()_+\-=\[\]{}|;:'",.<>?/\\`~]''');

  static List<String> missing(String p) => [
    if (p.length < 8) 'al menos 8 caracteres',
    if (!p.contains(RegExp(r'[A-Z]'))) 'una mayúscula',
    if (!p.contains(RegExp(r'[a-z]'))) 'una minúscula',
    if (!p.contains(RegExp(r'[0-9]'))) 'un número',
    if (!p.contains(_special)) 'un símbolo',
  ];

  static bool isValid(String p) => missing(p).isEmpty;

  /// Nivel 0–4: longitud, mayúsculas y minúsculas, número, símbolo.
  static int strength(String p) {
    if (p.isEmpty) return 0;
    var n = 0;
    if (p.length >= 8) n++;
    if (p.contains(RegExp(r'[A-Z]')) && p.contains(RegExp(r'[a-z]'))) n++;
    if (p.contains(RegExp(r'[0-9]'))) n++;
    if (p.contains(_special)) n++;
    return n < 1 ? 1 : n;
  }

  static String? validate(String p) {
    if (p.isEmpty) return 'Escribe una contraseña.';
    final m = missing(p);
    return m.isEmpty ? null : 'Añade ${_join(m)}.';
  }

  static String _join(List<String> items) => items.length == 1
      ? items.first
      : '${items.sublist(0, items.length - 1).join(', ')} y ${items.last}';
}

/// Barra de seguridad de cuatro segmentos con el texto de lo que falta.
class PasswordStrengthBar extends StatelessWidget {
  const PasswordStrengthBar({super.key, required this.password});
  final String password;

  @override
  Widget build(BuildContext context) {
    final level = PasswordRules.strength(password);
    final colors = [
      AppColors.error,
      AppColors.warning,
      AppColors.accent,
      AppColors.accentText,
    ];
    final missing = PasswordRules.missing(password);
    final text = password.isEmpty
        ? 'Mínimo 8 caracteres con mayúscula, minúscula, número y símbolo.'
        : missing.isNotEmpty
        ? 'Falta ${PasswordRules._join(missing)}.'
        : const [
            '',
            'Seguridad baja',
            'Seguridad media',
            'Seguridad buena',
            'Seguridad alta',
          ][level];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: i < level ? colors[level - 1] : AppColors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          text,
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
        ),
      ],
    );
  }
}

/// Código de 6 dígitos: un dígito por casilla, pegar el código completo
/// lo reparte y Retroceso en una casilla vacía vuelve a la anterior.
class CodeInput extends StatefulWidget {
  const CodeInput({
    super.key,
    required this.onChanged,
    this.errorText,
    this.onCompleted,
    this.autofocus = true,
  });

  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onCompleted;
  final String? errorText;
  final bool autofocus;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  late final List<FocusNode> _nodes = List.generate(
    6,
    (i) => FocusNode(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.backspace &&
            _controllers[i].text.isEmpty &&
            i > 0) {
          _controllers[i - 1].clear();
          _nodes[i - 1].requestFocus();
          _emit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
    ),
  );

  String get _code => _controllers.map((c) => c.text).join();

  void _emit() {
    widget.onChanged(_code);
    if (_code.length == 6) widget.onCompleted?.call(_code);
  }

  void _onChanged(int i, String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 1) {
      final chars = digits.substring(0, (6 - i).clamp(0, digits.length));
      for (var k = 0; k < chars.length; k++) {
        _controllers[i + k].text = chars[k];
      }
      final next = (i + chars.length).clamp(0, 5);
      _nodes[next].requestFocus();
    } else {
      _controllers[i].text = digits;
      if (digits.isNotEmpty && i < 5) _nodes[i + 1].requestFocus();
    }
    setState(() {});
    _emit();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel('Código de 6 dígitos'),
        const SizedBox(height: 8),
        Semantics(
          label: 'Código de verificación',
          child: AutofillGroup(
            child: Row(
              children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controllers[i],
                      focusNode: _nodes[i],
                      autofocus: widget.autofocus && i == 0,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      autofillHints: i == 0
                          ? const [AutofillHints.oneTimeCode]
                          : null,
                      // Se admite más de un carácter para poder pegar el código.
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      onChanged: (v) => _onChanged(i, v),
                      style: TextStyle(color: AppColors.text, fontSize: 20),
                      decoration: InputDecoration(
                        semanticCounterText: 'Dígito ${i + 1} de 6',
                        counterText: '',
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 14,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: hasError
                                ? AppColors.error
                                : _controllers[i].text.isNotEmpty
                                ? AppColors.accentDeep
                                : AppColors.line,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(
            widget.errorText!,
            style: TextStyle(color: AppColors.errorText, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// «¿No te llegó? Reenviar código» con espera entre envíos.
class ResendCode extends StatefulWidget {
  const ResendCode({
    super.key,
    required this.onResend,
    this.waitSeconds = 30,
    this.startWaiting = true,
  });

  /// Devuelve true si el envío se realizó, para reiniciar la espera.
  final Future<bool> Function() onResend;
  final int waitSeconds;
  final bool startWaiting;

  @override
  State<ResendCode> createState() => _ResendCodeState();
}

class _ResendCodeState extends State<ResendCode> {
  Timer? _timer;
  int _wait = 0;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (widget.startWaiting) _start();
  }

  void _start() {
    _timer?.cancel();
    setState(() => _wait = widget.waitSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait = (_wait - 1).clamp(0, widget.waitSeconds));
      if (_wait == 0) t.cancel();
    });
  }

  Future<void> _resend() async {
    setState(() => _sending = true);
    final ok = await widget.onResend();
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _wait > 0 || _sending;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          _wait > 0 ? 'Puedes pedir otro en $_wait s' : '¿No te llegó?',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.5),
        ),
        AuthLink(
          label: _sending ? 'Enviando…' : 'Reenviar código',
          onTap: disabled ? null : _resend,
        ),
      ],
    );
  }
}

/// Enlace de texto en el acento, con área táctil suficiente.
class AuthLink extends StatelessWidget {
  const AuthLink({super.key, required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: AppColors.accentText,
      disabledForegroundColor: AppColors.control,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 14),
    ),
    child: Text(label),
  );
}

/// Acción principal: contorno de acento a todo el ancho, con estado de carga.
class AuthPrimaryButton extends StatelessWidget {
  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.loadingLabel,
    required this.icon,
    required this.loading,
    required this.onPressed,
  });

  final String label, loadingLabel;
  final IconData icon;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: OutlinedButton(
        onPressed: loading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accentText,
          disabledForegroundColor: AppColors.accentText.withValues(alpha: .6),
          side: BorderSide(color: AppColors.accent),
          overlayColor: AppColors.accent,
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accentText,
                ),
              )
            else
              Icon(icon, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(loading ? loadingLabel : label)),
          ],
        ),
      ),
    );
  }
}

/// Casilla con texto que también se puede pulsar.
class AuthCheckbox extends StatelessWidget {
  const AuthCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: AppColors.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  label,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Texto secundario seguido de un enlace («¿No tienes cuenta? Crear cuenta»).
class AuthPrompt extends StatelessWidget {
  const AuthPrompt({super.key, required this.text, required this.link});
  final String text;
  final Widget link;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 6,
    children: [
      Text(text, style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
      link,
    ],
  );
}

/// Mensaje de error suelto, con el mismo estilo que el de los campos.
class AuthErrorText extends StatelessWidget {
  const AuthErrorText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: AppColors.errorText, fontSize: 12.5));
}

/// Validación de formato de correo usada en todas las pantallas de acceso.
String? validateEmail(String value) {
  final v = value.trim();
  if (v.isEmpty) return 'Escribe tu correo.';
  if (!RegExp(r'^\S+@\S+\.\S+$').hasMatch(v)) {
    return 'Revisa el formato: nombre@dominio.com';
  }
  return null;
}
