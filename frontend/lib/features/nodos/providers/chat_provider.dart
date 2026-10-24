import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/nodos_repository.dart';
import '../data/subgrupos_repository.dart';
import 'nodos_provider.dart';
import '../../iam/providers/auth_provider.dart';

final workspaceNodeVisibleProvider = StateProvider<bool>((ref) => true);

final selectedSubgrupoProvider = StateProvider<Subgrupo?>((ref) {
  ref.watch(authProvider.select((s) => s.userId));
  return null;
});

class ChatMessagesState {
  final List<Mensaje> mensajes;
  final bool loading;
  final String? error;

  const ChatMessagesState({
    this.mensajes = const [],
    this.loading = false,
    this.error,
  });

  ChatMessagesState copyWith({
    List<Mensaje>? mensajes,
    bool? loading,
    String? error,
  }) {
    return ChatMessagesState(
      mensajes: mensajes ?? this.mensajes,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

class ChatMessagesNotifier extends StateNotifier<ChatMessagesState> {
  final NodosRepository _repository;
  final Ref _ref;
  Timer? _timer;
  String? _activeNodoId;
  String? _activeSubgrupoId;

  ChatMessagesNotifier(this._repository, this._ref)
    : super(const ChatMessagesState()) {
    // Escuchar el nodo seleccionado para cargar mensajes automáticamente
    _ref.listen<Nodo?>(selectedNodoProvider, (previous, next) {
      _cursor = null;
      if (next == null) {
        _activeNodoId = null;
        _activeSubgrupoId = null;
        _timer?.cancel();
        state = const ChatMessagesState();
      } else {
        _activeNodoId = next.id;
        _activeSubgrupoId = _ref.read(selectedSubgrupoProvider)?.id;
        loadMensajes();
        _startPolling();
      }
    });

    // Escuchar el subgrupo seleccionado dentro del nodo
    _ref.listen<Subgrupo?>(selectedSubgrupoProvider, (previous, next) {
      final currentNodo = _ref.read(selectedNodoProvider);
      _cursor = null;
      if (currentNodo != null) {
        _activeNodoId = currentNodo.id;
        _activeSubgrupoId = next?.id;
        state = const ChatMessagesState(loading: true);
        loadMensajes();
        _startPolling();
      }
    });

    _ref.listen<bool>(workspaceNodeVisibleProvider, (previous, visible) {
      if (visible && _activeNodoId != null) {
        loadMensajes();
        _startPolling();
      } else {
        _timer?.cancel();
      }
    });

    // Si ya hay un nodo seleccionado al inicializar
    final initialNodo = _ref.read(selectedNodoProvider);
    if (initialNodo != null) {
      _activeNodoId = initialNodo.id;
      _activeSubgrupoId = _ref.read(selectedSubgrupoProvider)?.id;
      loadMensajes();
      _startPolling();
    }
  }

  bool _loading = false;

  /// Último mensaje recibido del servidor en el canal activo. El sondeo pide
  /// solo lo posterior; no se usa el mensaje propio recién enviado porque los
  /// de otras personas con hora anterior quedarían fuera.
  String? _cursor;
  int _polls = 0;

  /// Cada 30 sondeos (1 minuto) se recarga la lista completa para refrescar
  /// nombres y fotos de los autores.
  static const _fullReloadEvery = 30;

  Future<void> loadMensajes({bool silent = false}) async {
    if (!_ref.read(workspaceNodeVisibleProvider)) return;
    final nodoId = _activeNodoId;
    final subgrupoId = _activeSubgrupoId;
    if (nodoId == null) return;
    _loading = true;
    try {
      await _loadMensajes(nodoId, subgrupoId, silent);
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadMensajes(
    String nodoId,
    String? subgrupoId,
    bool silent,
  ) async {
    if (!silent && state.mensajes.isEmpty) {
      state = state.copyWith(loading: true);
    }
    final incremental =
        silent && _cursor != null && ++_polls % _fullReloadEvery != 0;

    try {
      final page = await _repository.fetchMensajes(
        nodoId,
        subgrupoId: subgrupoId,
        despuesDe: incremental ? _cursor : null,
      );
      // Evitar sobreescribir si ya cambiamos de nodo o subgrupo
      if (!mounted ||
          _activeNodoId != nodoId ||
          _activeSubgrupoId != subgrupoId) {
        return;
      }
      if (page.mensajes.isNotEmpty) _cursor = page.mensajes.last.id;
      if (page.incremental) {
        final known = {for (final m in state.mensajes) m.id};
        final fresh = page.mensajes.where((m) => !known.contains(m.id));
        if (fresh.isNotEmpty) {
          final merged = [...state.mensajes, ...fresh]
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          state = state.copyWith(mensajes: merged, loading: false);
        } else if (state.loading || state.error != null) {
          state = state.copyWith(loading: false);
        }
      } else {
        state = state.copyWith(
          mensajes: page.mensajes,
          loading: false,
          error: null,
        );
      }
      if (subgrupoId == null) {
        _ref.read(nodosProvider.notifier).clearUnreadCount(nodoId);
      }
    } catch (e) {
      if (mounted &&
          _activeNodoId == nodoId &&
          _activeSubgrupoId == subgrupoId &&
          !silent) {
        state = state.copyWith(
          error: e.toString().replaceAll('Exception: ', ''),
          loading: false,
        );
      }
    }
  }

  void _startPolling() {
    _timer?.cancel();
    if (!_ref.read(workspaceNodeVisibleProvider)) return;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      // Una red lenta no debe acumular peticiones superpuestas.
      if (!_loading) loadMensajes(silent: true);
    });
  }

  Future<bool> sendMensaje(String contenido) async {
    final nodoId = _activeNodoId;
    final subgrupoId = _activeSubgrupoId;
    if (nodoId == null || contenido.trim().isEmpty) return false;

    try {
      final msg = await _repository.sendMensaje(
        nodoId,
        contenido.trim(),
        subgrupoId: subgrupoId,
      );
      if (mounted &&
          _activeNodoId == nodoId &&
          _activeSubgrupoId == subgrupoId &&
          !state.mensajes.any((m) => m.id == msg.id)) {
        state = state.copyWith(mensajes: [...state.mensajes, msg]);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final chatMessagesProvider =
    StateNotifierProvider.autoDispose<ChatMessagesNotifier, ChatMessagesState>((
      ref,
    ) {
      final repo = ref.watch(nodosRepositoryProvider);
      return ChatMessagesNotifier(repo, ref);
    });
