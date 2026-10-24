import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../security/storage_facade.dart';
import 'app_colors.dart';

/// Tema elegido en este dispositivo. Se guarda fuera de la cuenta para que
/// también se aplique en las pantallas de acceso, antes de iniciar sesión.
final themeProvider = StateNotifierProvider<ThemeNotifier, IronTheme>(
  (ref) => ThemeNotifier(VaultStorage.create()),
);

class ThemeNotifier extends StateNotifier<IronTheme> {
  ThemeNotifier(this._storage) : super(IronTheme.dark) {
    _load();
  }

  static const _key = 'ironlink_theme';
  final VaultStorage _storage;
  bool _edited = false;

  Future<void> _load() async {
    try {
      final saved = await _storage.read(key: _key);
      if (mounted && !_edited && saved != null) {
        state = IronTheme.fromName(saved);
      }
    } catch (_) {
      /* Sin almacenamiento se mantiene el tema oscuro. */
    }
  }

  /// Aplica el tema; devuelve false si no se pudo guardar en el dispositivo.
  Future<bool> select(IronTheme theme) async {
    _edited = true;
    state = theme;
    try {
      await _storage.write(key: _key, value: theme.name);
      return true;
    } catch (_) {
      return false;
    }
  }
}
