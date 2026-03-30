/// User / session model matching the WIOS auth_users + auth_sessions tables.
library;

import 'package:flutter/foundation.dart';

// ── Role levels (mirrors WIOS/warehouse_core/models/chat_auth.py ROLE_LEVELS) ─

const Map<String, int> kRoleLevels = {
  'Viewer':     1,
  'Operator':   2,
  'Supervisor': 3,
  'Admin':      4,
  'Saboteur':   5,
  'AIObserver': 6,
};

extension RoleExtension on String {
  int get level => kRoleLevels[this] ?? 1;
  bool get canAdmin     => level >= 4;
  bool get canSabotage  => level == 5;
  bool get canAiObs     => level >= 6;
}

// ── User ─────────────────────────────────────────────────────────────────────

@immutable
class WoisUser {
  const WoisUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    this.avatarUrl,
    this.provider = 'dev',
    this.isActive = true,
  });

  final String  id;
  final String  email;
  final String  name;
  final String  role;
  final String? avatarUrl;
  final String  provider;
  final bool    isActive;

  int  get level      => role.level;
  bool get canAdmin   => role.canAdmin;
  bool get canSabotage => role.canSabotage;
  bool get canAiObs   => role.canAiObs;

  factory WoisUser.fromJson(Map<String, dynamic> j) => WoisUser(
    id:        j['id']         as String? ?? '',
    email:     j['email']      as String? ?? '',
    name:      j['name']       as String? ?? 'User',
    role:      j['role']       as String? ?? 'Operator',
    avatarUrl: j['avatar_url'] as String?,
    provider:  j['provider']   as String? ?? 'dev',
    isActive:  j['is_active']  as bool? ?? true,
  );

  WoisUser copyWith({String? role}) => WoisUser(
    id: id, email: email, name: name,
    role:      role      ?? this.role,
    avatarUrl: avatarUrl,
    provider:  provider,
    isActive:  isActive,
  );
}

// ── Auth session (stored in SharedPreferences) ────────────────────────────────

@immutable
class WoisSession {
  const WoisSession({
    required this.token,
    required this.user,
    required this.expiresAt,
    this.sessionId = '',
  });

  final String    token;
  final WoisUser  user;
  final DateTime  expiresAt;
  /// The auth_sessions.id UUID (game credits, saboteur actions are keyed by this).
  /// Falls back to token when not provided.
  final String    sessionId;

  String get effectiveSessionId => sessionId.isNotEmpty ? sessionId : token;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  factory WoisSession.fromValidateJson(Map<String, dynamic> j) {
    final u = WoisUser.fromJson(j['user'] as Map<String, dynamic>);
    final exp = j['expires_at'] as String?;
    return WoisSession(
      token:     j['token']      as String? ?? '',
      sessionId: j['session_id'] as String? ?? '',
      user:      u,
      expiresAt: exp != null ? DateTime.parse(exp) : DateTime.now().add(const Duration(days: 7)),
    );
  }
}
