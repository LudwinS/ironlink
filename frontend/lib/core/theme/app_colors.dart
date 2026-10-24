import 'package:flutter/material.dart';

/// Temas de IronLink derivados del sistema de diseño Nocturne.
enum IronTheme {
  dark('Oscuro'),
  amoled('AMOLED'),
  light('Claro');

  const IronTheme(this.label);
  final String label;

  static IronTheme fromName(String? name) => IronTheme.values.firstWhere(
    (t) => t.name == name,
    orElse: () => IronTheme.dark,
  );
}

/// Valores de un tema. Nocturne es monocromático: un único acento morado
/// usado como línea y brillo, nunca como relleno de grandes áreas.
class IronPalette {
  const IronPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.line,
    required this.control,
    required this.text,
    required this.textMuted,
    required this.textSubtle,
    required this.accent,
    required this.accentText,
    required this.accentDeep,
    required this.accentTint,
    required this.onAccent,
    required this.bubble,
    required this.bubbleMine,
    required this.error,
    required this.errorText,
    required this.warning,
    required this.success,
    required this.contrast,
  });

  final Brightness brightness;
  final Color bg, surface, surface2, surface3, line, control;
  final Color text, textMuted, textSubtle;

  /// [accent] para líneas, iconos y bordes; [accentText] para texto en el
  /// acento (contraste suficiente para texto de párrafo); [accentDeep] para
  /// bordes de acento atenuados; [accentTint] para fondos seleccionados.
  final Color accent, accentText, accentDeep, accentTint, onAccent;
  final Color bubble, bubbleMine;
  final Color error, errorText, warning, success;

  /// Contraste medido para el selector de tema (texto · secundario · acento).
  final String contrast;

  static const dark = IronPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF161826),
    surface: Color(0xFF1D1F2C),
    surface2: Color(0xFF232532),
    surface3: Color(0xFF292B31),
    line: Color(0xFF3F424D),
    control: Color(0xFF75798C),
    text: Color(0xFFE9E9ED),
    textMuted: Color(0xFFB2B6CA),
    textSubtle: Color(0xFF9397AB),
    accent: Color(0xFF9184D9),
    accentText: Color(0xFFD2CEFD),
    accentDeep: Color(0xFF5D5294),
    accentTint: Color(0xFF2B2741),
    onAccent: Color(0xFF161826),
    bubble: Color(0xFF232532),
    bubbleMine: Color(0xFF2B2741),
    error: Color(0xFFEF4444),
    errorText: Color(0xFFFCA5A5),
    warning: Color(0xFFFCD34D),
    success: Color(0xFF10B981),
    contrast: 'Texto 13.5:1 · Secundario 8.1:1 · Acento 10.9:1',
  );

  static const amoled = IronPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF0C0D14),
    surface: Color(0xFF12131D),
    surface2: Color(0xFF161826),
    surface3: Color(0xFF1D1F2C),
    line: Color(0xFF292B31),
    control: Color(0xFF75798C),
    text: Color(0xFFE9E9ED),
    textMuted: Color(0xFFB2B6CA),
    textSubtle: Color(0xFF9397AB),
    accent: Color(0xFF9184D9),
    accentText: Color(0xFFD2CEFD),
    accentDeep: Color(0xFF5D5294),
    accentTint: Color(0xFF2B2741),
    onAccent: Color(0xFF0C0D14),
    bubble: Color(0xFF161826),
    bubbleMine: Color(0xFF2B2741),
    error: Color(0xFFEF4444),
    errorText: Color(0xFFFCA5A5),
    warning: Color(0xFFFCD34D),
    success: Color(0xFF10B981),
    contrast: 'Texto 15.3:1 · Secundario 9.2:1 · Acento 12.3:1',
  );

  static const light = IronPalette(
    brightness: Brightness.light,
    bg: Color(0xFFE4E7F5),
    surface: Color(0xFFF3F5FE),
    surface2: Color(0xFFE4E7F5),
    surface3: Color(0xFFCFD3E5),
    line: Color(0xFFCFD3E5),
    control: Color(0xFF75798C),
    text: Color(0xFF161826),
    textMuted: Color(0xFF595D6C),
    textSubtle: Color(0xFF75798C),
    accent: Color(0xFF5D5294),
    accentText: Color(0xFF5D5294),
    accentDeep: Color(0xFF796CBF),
    accentTint: Color(0xFFE7E5FE),
    onAccent: Color(0xFFF3F5FE),
    bubble: Color(0xFFF3F5FE),
    bubbleMine: Color(0xFFE7E5FE),
    error: Color(0xFFDC2626),
    errorText: Color(0xFFB91C1C),
    warning: Color(0xFF92400E),
    success: Color(0xFF047857),
    contrast: 'Texto 16.2:1 · Secundario 6.0:1 · Acento 6.2:1',
  );

  static IronPalette of(IronTheme theme) => switch (theme) {
    IronTheme.dark => dark,
    IronTheme.amoled => amoled,
    IronTheme.light => light,
  };
}

/// Acceso global a la paleta activa. La app vuelve a montar su árbol al
/// cambiar de tema (ver `main.dart`), de modo que los widgets que leen estos
/// valores en `build` reciben siempre los del tema seleccionado.
class AppColors {
  AppColors._();

  static IronPalette _p = IronPalette.dark;
  static IronPalette get palette => _p;
  static void use(IronTheme theme) => _p = IronPalette.of(theme);

  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surface2 => _p.surface2;
  static Color get surface3 => _p.surface3;
  static Color get line => _p.line;
  static Color get control => _p.control;
  static Color get text => _p.text;
  static Color get textMuted => _p.textMuted;
  static Color get textSubtle => _p.textSubtle;
  static Color get accent => _p.accent;
  static Color get accentText => _p.accentText;
  static Color get accentDeep => _p.accentDeep;
  static Color get accentTint => _p.accentTint;
  static Color get onAccent => _p.onAccent;
  static Color get bubble => _p.bubble;
  static Color get bubbleMine => _p.bubbleMine;
  static Color get error => _p.error;
  static Color get errorText => _p.errorText;
  static Color get warning => _p.warning;
  static Color get success => _p.success;

  /// Tema de Material construido a partir de la paleta activa.
  static ThemeData theme() {
    final p = _p;
    final scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      secondary: p.accent,
      onSecondary: p.onAccent,
      error: p.error,
      onError: p.onAccent,
      surface: p.surface,
      onSurface: p.text,
      onSurfaceVariant: p.textMuted,
      surfaceContainerLowest: p.bg,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surface2,
      surfaceContainerHigh: p.surface2,
      surfaceContainerHighest: p.surface3,
      outline: p.control,
      outlineVariant: p.line,
      primaryContainer: p.accentTint,
      onPrimaryContainer: p.accentText,
      inverseSurface: p.text,
      onInverseSurface: p.bg,
    );
    final radius = BorderRadius.circular(8);
    return ThemeData(
      brightness: p.brightness,
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      dividerColor: p.line,
      fontFamily: 'Inter',
      textTheme: TextTheme(
        titleLarge: TextStyle(color: p.text, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: p.text),
        bodyMedium: TextStyle(color: p.textMuted),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withValues(alpha: .3),
      ),
      // Nocturne: la acción principal es un contorno de acento, no un relleno.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: p.accentText,
          side: BorderSide(color: p.accent),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          side: BorderSide(color: p.line),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.accentText),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        hintStyle: TextStyle(color: p.textSubtle),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: p.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: p.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: p.error, width: 1.5),
        ),
        errorStyle: TextStyle(color: p.errorText),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.line),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surface3,
        contentTextStyle: TextStyle(color: p.text),
        behavior: SnackBarBehavior.floating,
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: p.control),
        checkColor: WidgetStatePropertyAll(p.onAccent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accent,
        thumbColor: p.accent,
        inactiveTrackColor: p.line,
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(p.line),
      ),
    );
  }
}
