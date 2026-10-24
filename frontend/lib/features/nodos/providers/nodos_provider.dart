import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/nodos_repository.dart';
import '../../iam/providers/auth_provider.dart';
import 'chat_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Estado del módulo Nodos
// ─────────────────────────────────────────────────────────────────────────────

enum NodosStatus { initial, loading, loaded, error }

class NodosState {
  final NodosStatus status;
  final List<Nodo> nodos;
  final String? errorMessage;
  final String? successMessage;

  const NodosState({
    this.status = NodosStatus.initial,
    this.nodos = const [],
    this.errorMessage,
    this.successMessage,
  });

  NodosState copyWith({
    NodosStatus? status,
    List<Nodo>? nodos,
    String? errorMessage,
    String? successMessage,
  }) {
    return NodosState(
      status: status ?? this.status,
      nodos: nodos ?? this.nodos,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }

  /// Nodo activo más reciente (si existe)
  Nodo? get nodoActivo {
    final activos = nodos.where((n) => n.isActive).toList();
    if (activos.isEmpty) return null;
    activos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return activos.first;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notifier
// ─────────────────────────────────────────────────────────────────────────────

class NodosNotifier extends StateNotifier<NodosState> {
  final NodosRepository _repository;
  final Ref _ref;
  Timer? _pollingTimer;

  NodosNotifier(this._repository, this._ref) : super(const NodosState()) {
    startPolling();
  }

  /// Carga los nodos del usuario y actualiza sus mensajes no leídos.
  bool _refreshing = false;

  Future<void> loadNodos({bool silent = false}) async {
    _refreshing = true;
    if (!silent) {
      state = state.copyWith(status: NodosStatus.loading);
    }
    try {
      final nodos = await _repository.fetchNodos();
      // El sondeo puede terminar después de cerrar sesión o salir del panel.
      if (!mounted) return;
      state = state.copyWith(status: NodosStatus.loaded, nodos: nodos);
      await fetchUnreadCounts();
    } catch (e) {
      if (!silent && mounted) {
        state = state.copyWith(
          status: NodosStatus.error,
          errorMessage: e.toString().replaceAll('Exception: ', ''),
        );
      }
    } finally {
      _refreshing = false;
    }
  }

  /// Consulta los mensajes no leídos para cada nodo (IRL-WKS-US-03)
  Future<void> fetchUnreadCounts() async {
    // En paralelo en lugar de una petición tras otra. Si un nodo falla se
    // conserva su último valor en vez de mostrarlo como leído.
    final previous = _ref.read(unreadCountsProvider);
    final nodos = state.nodos;
    final results = await Future.wait([
      for (final nodo in nodos)
        _repository
            .getUnreadCount(nodo.id)
            .then<int?>((c) => c)
            .catchError((Object _) => previous[nodo.id]),
    ]);
    if (!mounted) return;
    final counts = <String, int>{
      for (var i = 0; i < nodos.length; i++)
        if (results[i] != null) nodos[i].id: results[i]!,
    };
    if (!mapEquals(counts, previous)) {
      _ref.read(unreadCountsProvider.notifier).state = counts;
    }
  }

  /// Limpia el badge de no leídos de un nodo al abrirlo (IRL-WKS-US-03).
  ///
  /// Solo en el cliente: `GET /mensajes` ya marca como leído hasta el último
  /// mensaje mostrado. Antes también se llamaba a `POST /read` en cada sondeo,
  /// que marcaba hasta el último mensaje existente, incluidos los que llegaron
  /// después de la consulta y la persona aún no había visto.
  void clearUnreadCount(String nodoId) {
    final current = Map<String, int>.from(_ref.read(unreadCountsProvider));
    if ((current[nodoId] ?? 0) > 0) {
      current[nodoId] = 0;
      _ref.read(unreadCountsProvider.notifier).state = current;
    }
  }

  /// Inicia el bucle de actualización periódica.
  void startPolling() {
    _pollingTimer?.cancel();
    // Cada 8 s basta para la lista y los no leídos: las reuniones en curso y
    // los avisos llegan por el canal en vivo. Antes eran 2 s con una petición
    // por nodo, unas 5 peticiones por segundo por usuario con 10 nodos.
    _pollingTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      if (!_refreshing) loadNodos(silent: true);
    });
  }

  /// Detiene el bucle de actualización.
  void stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }

  /// Crea un nodo nuevo y lo agrega a la lista local.
  Future<bool> createNodo({required String nombre, String? descripcion}) async {
    state = state.copyWith(status: NodosStatus.loading);
    try {
      final nodo = await _repository.createNodo(
        nombre: nombre,
        descripcion: descripcion,
      );
      state = state.copyWith(
        status: NodosStatus.loaded,
        nodos: [nodo, ...state.nodos],
        successMessage: 'Nodo "$nombre" creado exitosamente',
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        status: NodosStatus.loaded,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  /// Se une a un nodo mediante token de acceso.
  Future<bool> joinNodo(String token) async {
    state = state.copyWith(status: NodosStatus.loading);
    try {
      final nodo = await _repository.joinNodo(token);
      // Evitar duplicados
      final exists = state.nodos.any((n) => n.id == nodo.id);
      final updatedNodos = exists ? state.nodos : [nodo, ...state.nodos];
      state = state.copyWith(
        status: NodosStatus.loaded,
        nodos: updatedNodos,
        successMessage: 'Te has unido al nodo "${nodo.nombre}"',
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        status: NodosStatus.loaded,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  /// Elimina un nodo por su ID.
  Future<bool> deleteNodo(String id) async {
    state = state.copyWith(status: NodosStatus.loading);
    try {
      final matching = state.nodos.where((n) => n.id == id).toList();
      final nombre = matching.isNotEmpty ? matching.first.nombre : 'Nodo';

      await _repository.deleteNodo(id);

      final updatedNodos = state.nodos.where((n) => n.id != id).toList();
      state = state.copyWith(
        status: NodosStatus.loaded,
        nodos: updatedNodos,
        successMessage: 'Nodo "$nombre" eliminado exitosamente',
      );

      if (_ref.read(selectedNodoProvider)?.id == id) {
        _ref.read(selectedNodoProvider.notifier).state = null;
        _ref.read(selectedSubgrupoProvider.notifier).state = null;
      }
      return true;
    } catch (e) {
      state = state.copyWith(
        status: NodosStatus.loaded,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  /// Sale de un nodo por su ID.
  Future<bool> leaveNodo(String id) async {
    state = state.copyWith(status: NodosStatus.loading);
    try {
      // Buscar el nodo en el estado local para obtener su nombre
      final nodo = state.nodos.firstWhere((n) => n.id == id);
      final nombre = nodo.nombre;

      await _repository.leaveNodo(id);

      final updatedNodos = state.nodos.where((n) => n.id != id).toList();
      state = state.copyWith(
        status: NodosStatus.loaded,
        nodos: updatedNodos,
        successMessage: 'Has salido del nodo "$nombre" exitosamente',
      );
      // Igual que al eliminar: no seguir mostrando (ni sondeando) un nodo
      // al que ya no se pertenece.
      if (_ref.read(selectedNodoProvider)?.id == id) {
        _ref.read(selectedNodoProvider.notifier).state = null;
        _ref.read(selectedSubgrupoProvider.notifier).state = null;
      }
      return true;
    } catch (e) {
      state = state.copyWith(
        status: NodosStatus.loaded,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers de Riverpod
// ─────────────────────────────────────────────────────────────────────────────

/// Provider reactivo para almacenar mapa de conteos no leídos por ID de nodo (IRL-WKS-US-03)
final unreadCountsProvider = StateProvider<Map<String, int>>((ref) {
  ref.watch(authProvider.select((s) => s.userId));
  return {};
});

final nodosRepositoryProvider = Provider.autoDispose<NodosRepository>(
  (ref) => NodosRepository(),
);

final nodosProvider =
    StateNotifierProvider.autoDispose<NodosNotifier, NodosState>((ref) {
      final repo = ref.watch(nodosRepositoryProvider);
      return NodosNotifier(repo, ref);
    });

/// Provider para el rol del usuario (leído de authProvider).
final userRoleProvider = Provider<String>((ref) {
  final authState = ref.watch(authProvider);
  return authState.role ?? 'MEMBER';
});

/// Provider para el email del usuario (leído de authProvider).
final userEmailProvider = Provider<String>((ref) {
  final authState = ref.watch(authProvider);
  return authState.email ?? '';
});

/// Provider para el nodo seleccionado en el dashboard (área de chat)
final selectedNodoProvider = StateProvider.autoDispose<Nodo?>((ref) => null);
