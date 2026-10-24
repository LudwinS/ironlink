import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/iam_repository.dart';
import '../data/profile_models.dart';
import 'auth_provider.dart';

class ProfileState {
  final UserProfile? profile;
  final bool isLoading;
  final String? errorMessage;
  final String? successMessage;

  const ProfileState({
    this.profile,
    this.isLoading = false,
    this.errorMessage,
    this.successMessage,
  });

  ProfileState copyWith({
    UserProfile? profile,
    bool? isLoading,
    String? errorMessage,
    String? successMessage,
    bool clearErrors = false,
    bool clearSuccess = false,
  }) {
    return ProfileState(
      profile: profile ?? this.profile,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearErrors ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearSuccess ? null : (successMessage ?? this.successMessage),
    );
  }
}

class ProfileNotifier extends StateNotifier<ProfileState> {
  final IamRepository _repository;
  final Ref _ref;

  ProfileNotifier(this._repository, this._ref) : super(const ProfileState()) {
    loadProfile();
  }

  Future<void> loadProfile() async {
    state = state.copyWith(isLoading: true, clearErrors: true);
    try {
      final json = await _repository.fetchProfile();
      if (!mounted) return;
      final userProfile = UserProfile.fromJson(json);
      state = state.copyWith(
        profile: userProfile,
        isLoading: false,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  Future<bool> updateProfile({
    String? name,
    String? telefono,
    String? bio,
    String? avatarColor,
    String? statusText,
    String? avatarUrl,
  }) async {
    state = state.copyWith(isLoading: true, clearErrors: true, clearSuccess: true);
    try {
      final json = await _repository.updateProfile(
        name: name,
        telefono: telefono,
        bio: bio,
        avatarColor: avatarColor,
        statusText: statusText,
        avatarUrl: avatarUrl,
      );
      if (!mounted) return false;
      final userProfile = UserProfile.fromJson(json);
      state = state.copyWith(
        profile: userProfile,
        isLoading: false,
        successMessage: 'Perfil actualizado correctamente.',
      );
      // Actualizar también en el estado de auth
      if (name != null && name.isNotEmpty) {
        _ref.read(authProvider.notifier).state = _ref.read(authProvider).copyWith(
          username: name,
        );
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  Future<bool> uploadAvatar({
    required String avatarData,
    String contentType = 'image/jpeg',
  }) async {
    state = state.copyWith(isLoading: true, clearErrors: true, clearSuccess: true);
    try {
      final finalUrl = await _repository.uploadAvatar(
        avatarData: avatarData,
        contentType: contentType,
      );
      if (!mounted) return false;
      if (state.profile != null) {
        final updated = state.profile!.copyWith(avatarUrl: finalUrl);
        state = state.copyWith(
          profile: updated,
          isLoading: false,
          successMessage: 'Foto de perfil actualizada exitosamente.',
        );
      } else {
        await loadProfile();
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }

  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    state = state.copyWith(isLoading: true, clearErrors: true, clearSuccess: true);
    try {
      final msg = await _repository.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      if (!mounted) return true;
      state = state.copyWith(
        isLoading: false,
        successMessage: msg,
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      state = state.copyWith(
        isLoading: false,
        errorMessage: e.toString().replaceAll('Exception: ', ''),
      );
      return false;
    }
  }
}

/// Se recrea al cambiar de cuenta: antes conservaba el perfil de la sesión
/// anterior y la siguiente persona veía (y podía guardar) los datos ajenos.
final profileProvider = StateNotifierProvider<ProfileNotifier, ProfileState>((ref) {
  ref.watch(authProvider.select((s) => s.userId));
  final repo = ref.watch(iamRepositoryProvider);
  return ProfileNotifier(repo, ref);
});
