class UserProfile {
  final String id;
  final String name;
  final String email;
  final String telefono;
  final String rol;
  final String estado;
  final String bio;
  final String avatarColor;
  final String statusText;
  final String? avatarUrl;
  final DateTime createdAt;

  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.telefono,
    required this.rol,
    required this.estado,
    required this.bio,
    required this.avatarColor,
    required this.statusText,
    this.avatarUrl,
    required this.createdAt,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      telefono: json['telefono'] as String? ?? '',
      rol: json['rol'] as String? ?? 'MEMBER',
      estado: json['estado'] as String? ?? 'ACTIVE',
      bio: json['bio'] as String? ?? '',
      avatarColor: json['avatar_color'] as String? ?? '#00E5FF',
      statusText: json['status_text'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  UserProfile copyWith({
    String? name,
    String? telefono,
    String? bio,
    String? avatarColor,
    String? statusText,
    String? avatarUrl,
  }) {
    return UserProfile(
      id: id,
      name: name ?? this.name,
      email: email,
      telefono: telefono ?? this.telefono,
      rol: rol,
      estado: estado,
      bio: bio ?? this.bio,
      avatarColor: avatarColor ?? this.avatarColor,
      statusText: statusText ?? this.statusText,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      createdAt: createdAt,
    );
  }
}
