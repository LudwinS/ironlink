import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/subgrupos_repository.dart';

class SubgruposState {
  final List<Subgrupo> subgrupos;
  final bool isLoading;
  final String? errorMessage;
  final String? selectedSubgrupoId;

  const SubgruposState({
    this.subgrupos = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedSubgrupoId,
  });

  SubgruposState copyWith({
    List<Subgrupo>? subgrupos,
    bool? isLoading,
    String? errorMessage,
    String? selectedSubgrupoId,
    bool clearErrors = false,
  }) {
    return SubgruposState(
      subgrupos: subgrupos ?? this.subgrupos,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearErrors ? null : (errorMessage ?? this.errorMessage),
      selectedSubgrupoId: selectedSubgrupoId ?? this.selectedSubgrupoId,
    );
  }
}

class SubgruposNotifier extends StateNotifier<SubgruposState> {
  final SubgruposRepository _repository;
  final String? _nodoId;
  Timer? _timer;

  SubgruposNotifier(this._repository, this._nodoId)
    : super(const SubgruposState()) {
    if (_nodoId != null && _nodoId.isNotEmpty) {
      loadSubgrupos();
      _startPolling();
    }
  }

  void _startPolling() {
    _timer?.cancel();
    // La lista de subgrupos cambia poco: 8 s y sin solapar peticiones.
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!_refreshing) loadSubgrupos(silent: true);
    });
  }

  bool _refreshing = false;

  Future<void> loadSubgrupos({bool silent = false}) async {
    if (_nodoId == null) return;
    _refreshing = true;
    if (!silent && state.subgrupos.isEmpty) {
      state = state.copyWith(isLoading: true, clearErrors: true);
    }
    try {
      final list = await _repository.fetchSubgrupos(_nodoId);
      if (!mounted) return;
      state = state.copyWith(subgrupos: list, isLoading: false);
    } catch (e) {
      if (!silent && mounted) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: e.toString().replaceAll('Exception: ', ''),
        );
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<bool> createSubgrupo({
    required String nombre,
    String? descripcion,
    bool esPrivado = false,
  }) async {
    if (_nodoId == null) return false;
    state = state.copyWith(isLoading: true, clearErrors: true);
    try {
      final newSub = await _repository.createSubgrupo(
        nodoId: _nodoId,
        nombre: nombre,
        descripcion: descripcion,
        esPrivado: esPrivado,
      );
      state = state.copyWith(
        subgrupos: [...state.subgrupos, newSub],
        isLoading: false,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  Future<bool> toggleJoin(Subgrupo subgrupo) async {
    if (_nodoId == null) return false;

    // 1. Actualización optimista inmediata en memoria
    final newIsMember = !subgrupo.isMember;
    final newCount = newIsMember
        ? subgrupo.miembrosCount + 1
        : (subgrupo.miembrosCount > 0 ? subgrupo.miembrosCount - 1 : 0);
    final updatedSub = subgrupo.copyWith(
      isMember: newIsMember,
      miembrosCount: newCount,
    );

    state = state.copyWith(
      subgrupos: state.subgrupos
          .map((s) => s.id == subgrupo.id ? updatedSub : s)
          .toList(),
      clearErrors: true,
    );

    try {
      if (subgrupo.isMember) {
        await _repository.leaveSubgrupo(
          nodoId: _nodoId,
          subgrupoId: subgrupo.id,
        );
      } else {
        await _repository.joinSubgrupo(
          nodoId: _nodoId,
          subgrupoId: subgrupo.id,
        );
      }
      await loadSubgrupos();
      return true;
    } catch (e) {
      // Revertir estado si el servidor rechaza la acción
      await loadSubgrupos();
      state = state.copyWith(
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  /// Edición de nombre y descripción en caliente sin recarga completa (IRL-WKS-US-02)
  Future<bool> updateSubgrupo({
    required String subgrupoId,
    String? nombre,
    String? descripcion,
  }) async {
    if (_nodoId == null) return false;

    // Optimistic update in place
    state = state.copyWith(
      subgrupos: state.subgrupos.map((s) {
        if (s.id == subgrupoId) {
          return s.copyWith(
            nombre: nombre ?? s.nombre,
            descripcion: descripcion ?? s.descripcion,
          );
        }
        return s;
      }).toList(),
      clearErrors: true,
    );

    try {
      final updated = await _repository.updateSubgrupo(
        nodoId: _nodoId,
        subgrupoId: subgrupoId,
        nombre: nombre,
        descripcion: descripcion,
      );
      state = state.copyWith(
        subgrupos: state.subgrupos
            .map((s) => s.id == subgrupoId ? updated : s)
            .toList(),
      );
      return true;
    } catch (e) {
      await loadSubgrupos();
      state = state.copyWith(
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  /// Asignación masiva de miembros a subgrupo (IRL-WKS-US-02)
  Future<bool> asignarMiembros({
    required String subgrupoId,
    required List<String> userIds,
  }) async {
    if (_nodoId == null || userIds.isEmpty) return false;
    try {
      final count = await _repository.asignarMiembros(
        nodoId: _nodoId,
        subgrupoId: subgrupoId,
        userIds: userIds,
      );
      // Actualizar contador en caliente
      state = state.copyWith(
        subgrupos: state.subgrupos.map((s) {
          if (s.id == subgrupoId) {
            return s.copyWith(miembrosCount: s.miembrosCount + count);
          }
          return s;
        }).toList(),
      );
      await loadSubgrupos();
      return true;
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  Future<bool> deleteSubgrupo(String subgrupoId) async {
    if (_nodoId == null) return false;
    try {
      await _repository.deleteSubgrupo(nodoId: _nodoId, subgrupoId: subgrupoId);
      state = state.copyWith(
        subgrupos: state.subgrupos.where((s) => s.id != subgrupoId).toList(),
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final subgruposProvider = StateNotifierProvider.autoDispose
    .family<SubgruposNotifier, SubgruposState, String>((ref, nodoId) {
      final repo = ref.watch(subgruposRepositoryProvider);
      return SubgruposNotifier(repo, nodoId);
    });
