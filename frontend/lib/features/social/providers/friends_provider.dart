import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../iam/providers/auth_provider.dart';
import '../data/friends_repository.dart';

/// Cuenta activa: todos los providers sociales se reinician al cambiarla.
final friendsOwnIdProvider = Provider<String?>(
  (ref) => ref.watch(authProvider.select((s) => s.userId)),
);

final friendsRepositoryProvider = Provider<FriendsRepository>((ref) {
  ref.watch(friendsOwnIdProvider);
  return FriendsRepository();
});

final friendsListProvider = FutureProvider<List<Friend>>((ref) async {
  if (ref.watch(friendsOwnIdProvider) == null) return const [];
  return ref.watch(friendsRepositoryProvider).friends();
});

final friendRequestsProvider = FutureProvider<FriendRequests>((ref) async {
  if (ref.watch(friendsOwnIdProvider) == null) return const FriendRequests();
  return ref.watch(friendsRepositoryProvider).requests();
});

final blockedUsersProvider = FutureProvider<List<BlockedUser>>((ref) async {
  if (ref.watch(friendsOwnIdProvider) == null) return const [];
  return ref.watch(friendsRepositoryProvider).blocked();
});

final requestPrivacyProvider = FutureProvider<RequestPrivacy>((ref) async {
  if (ref.watch(friendsOwnIdProvider) == null) return RequestPrivacy.everyone;
  return ref.watch(friendsRepositoryProvider).privacy();
});

/// Vuelve a pedir amigos, solicitudes y bloqueados tras una acción o un
/// aviso en vivo.
void refreshFriends(WidgetRef ref) {
  ref.invalidate(friendsListProvider);
  ref.invalidate(friendRequestsProvider);
  ref.invalidate(blockedUsersProvider);
}
