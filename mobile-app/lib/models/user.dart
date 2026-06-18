class User {
  final String id;
  final String email;
  final String? name;
  final bool isEmailVerified;
  final DateTime createdAt;
  final DateTime? lastLoginAt;
  final bool isBlocked;
  final String? avatarUrl;

  User({
    required this.id,
    required this.email,
    this.name,
    required this.isEmailVerified,
    required this.createdAt,
    this.lastLoginAt,
    required this.isBlocked,
    this.avatarUrl,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      email: json['email'],
      name: json['name'],
      isEmailVerified: json['is_email_verified'] ?? false,
      createdAt: DateTime.parse(json['created_at']),
      lastLoginAt: json['last_login_at'] != null 
          ? DateTime.parse(json['last_login_at']) 
          : null,
      isBlocked: json['is_blocked'] ?? false,
      avatarUrl: json['avatar_url'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'is_email_verified': isEmailVerified,
      'created_at': createdAt.toIso8601String(),
      'last_login_at': lastLoginAt?.toIso8601String(),
      'is_blocked': isBlocked,
      'avatar_url': avatarUrl,
    };
  }

  User copyWith({
    String? id,
    String? email,
    String? name,
    bool? isEmailVerified,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    bool? isBlocked,
    String? avatarUrl,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      name: name ?? this.name,
      isEmailVerified: isEmailVerified ?? this.isEmailVerified,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      isBlocked: isBlocked ?? this.isBlocked,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}
