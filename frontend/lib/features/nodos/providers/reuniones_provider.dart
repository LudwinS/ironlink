import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/reuniones_repository.dart';
import '../../iam/providers/auth_provider.dart';

class ReunionesState {
  final List<Reunion> reuniones;
  final bool isLoading;
  final String? errorMessage;

  const ReunionesState({
    this.reuniones = const [],
    this.isLoading = false,
    this.errorMessage,
  });

  ReunionesState copyWith({
    List<Reunion>? reuniones,
    bool? isLoading,
    String? errorMessage,
    bool clearErrors = false,
  }) {
    return ReunionesState(
      reuniones: reuniones ?? this.reuniones,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearErrors ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class ReunionesNotifier extends StateNotifier<ReunionesState> {
  final ReunionesRepository _repository;
  final String? _nodoId;

  ReunionesNotifier(this._repository, this._nodoId)
    : super(const ReunionesState()) {
    if (_nodoId != null && _nodoId.isNotEmpty) {
      loadReuniones();
    }
  }

  Future<void> loadReuniones() async {
    if (_nodoId == null) return;
    state = state.copyWith(isLoading: true, clearErrors: true);
    try {
      final list = await _repository.fetchReuniones(_nodoId);
      if (!mounted) return;
      state = state.copyWith(reuniones: list, isLoading: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  /// Cancela una reunión o, con [serie], las programadas de su serie.
  Future<bool> deleteReunion(String reunionId, {bool serie = false}) async {
    if (_nodoId == null) return false;
    try {
      await _repository.deleteReunion(
        nodoId: _nodoId,
        reunionId: reunionId,
        serie: serie,
      );
      if (!mounted) return true;
      await loadReuniones();
      return true;
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          errorMessage: e.toString().replaceAll('Exception: ', ''),
        );
      }
      return false;
    }
  }
}

final reunionesProvider =
    StateNotifierProvider.family<ReunionesNotifier, ReunionesState, String>((
      ref,
      nodoId,
    ) {
      // Las reuniones de un nodo no se comparten entre cuentas de la misma sesión.
      ref.watch(authProvider.select((s) => s.userId));
      final repo = ref.watch(reunionesRepositoryProvider);
      return ReunionesNotifier(repo, nodoId);
    });
