/// auth_provider.dart — Riverpod auth state for WIOS sessions.
///
/// Flow:
///   1. App starts → tries to restore token from SharedPreferences.
///   2. If token found → validate with gateway → restore session.
///   3. If not found / expired → show LoginScreen.
///   4. OAuth: open browser with url_launcher, gateway redirects to
///      wois://auth-callback?wois_token=...&wois_user=...
///      uni_links_plus intercepts the deep link and calls [handleOAuthCallback].
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/user.dart';
import '../api_client.dart';
import '../../env.dart';

const _kTokenKey = 'wois_token';
const _kUserKey = 'wois_user';
const _kSessionKey = 'wois_session_id';

// ── State ─────────────────────────────────────────────────────────────────────

sealed class AuthState {}

class AuthLoading extends AuthState {}

class AuthLoggedOut extends AuthState {}

class AuthLoggedIn extends AuthState {
  AuthLoggedIn(this.session);
  final WoisSession session;
  WoisUser get user => session.user;
  String get token => session.token;
}

class AuthError extends AuthState {
  AuthError(this.message);
  final String message;
}

// ── Provider ──────────────────────────────────────────────────────────────────

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ApiClient.instance),
);

// ── Notifier ──────────────────────────────────────────────────────────────────

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._api) : super(AuthLoading()) {
    _restore();
  }

  final ApiClient _api;

  // ── Restore from SharedPreferences ────────────────────────────────────────

  Future<void> _restore() async {
    // On web: if the URL carries a wois_token (success) or auth_error (failure),
    // leave state as AuthLoading and let handleOAuthCallback (via microtask in
    // main.dart) set the correct state. Guards against _restore() overriding it.
    if (kIsWeb &&
        (Uri.base.queryParameters.containsKey('wois_token') ||
            Uri.base.queryParameters.containsKey('auth_error'))) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_kTokenKey);
    if (token == null) {
      // handleOAuthCallback may have already logged us in — don't override it.
      if (state is! AuthLoggedIn) state = AuthLoggedOut();
      return;
    }
    try {
      final data = await _api.validateToken(token);
      if (data['valid'] != true) throw Exception('invalid');
      final session = WoisSession.fromValidateJson({...data, 'token': token});
      if (session.isExpired) throw Exception('expired');
      // Don't override a session already established by handleOAuthCallback.
      if (state is! AuthLoggedIn) _applySession(session);
    } catch (_) {
      // Guard: if handleOAuthCallback already wrote a fresh token to prefs and
      // set AuthLoggedIn, don't wipe that token or kick the user back to login.
      if (state is AuthLoggedIn) return;
      await _clearPrefs();
      state = AuthLoggedOut();
    }
  }

  // ── OAuth (Google / GitHub / Microsoft) ───────────────────────────────────

  /// Opens the OAuth consent screen in the device browser.
  /// The gateway will redirect back to wois://auth-callback → [handleOAuthCallback].
  /// On web: navigates the current tab (webOnlyWindowName: '_self') so the OAuth
  /// redirect lands back in the same tab; the app reads the token from URL params.
  Future<void> startOAuth(String provider) async {
    final url = Uri.parse('$gatewayBaseUrl/auth/$provider');
    if (kIsWeb) {
      // '_self' = navigate current tab, not a new window/tab.
      await launchUrl(url, webOnlyWindowName: '_self');
    } else {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        state = AuthError('Could not open browser. Is the gateway running?');
      }
    }
  }

  /// Called by the deep-link handler (main.dart) when OAuth redirects back.
  /// Handles both:
  ///   Native: wois://auth-callback?wois_token=XXX&wois_user=<base64-json>
  ///   Web:    http://localhost:9090?wois_token=XXX&wois_user=<base64-json>
  Future<void> handleOAuthCallback(Uri uri) async {
    final token = uri.queryParameters['wois_token'];
    final userRaw = uri.queryParameters['wois_user'];
    if (token == null || userRaw == null) {
      final err = uri.queryParameters['auth_error'] ?? 'unknown_error';
      state = AuthError('OAuth failed: $err');
      return;
    }
    try {
      final userJson =
          utf8.decode(base64Url.decode(base64Url.normalize(userRaw)));
      final userMap = jsonDecode(userJson) as Map<String, dynamic>;
      final user = WoisUser.fromJson(userMap);
      final expiresAt = DateTime.now().add(const Duration(days: 7));
      final session =
          WoisSession(token: token, user: user, expiresAt: expiresAt);
      await _persist(session);
      _applySession(session);
    } catch (e) {
      state = AuthError('Could not parse OAuth callback: $e');
    }
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  Future<void> logout() async {
    final s = state;
    if (s is AuthLoggedIn) {
      try {
        await _api.invalidateSession(s.token);
      } catch (_) {}
    }
    await _clearPrefs();
    _api.clearToken();
    state = AuthLoggedOut();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _applySession(WoisSession session) {
    _api.setToken(session.token);
    state = AuthLoggedIn(session);
  }

  Future<void> _persist(WoisSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTokenKey, session.token);
    await prefs.setString(_kSessionKey, session.token); // same for now
    await prefs.setString(
        _kUserKey,
        jsonEncode({
          'id': session.user.id,
          'email': session.user.email,
          'name': session.user.name,
          'role': session.user.role,
          'avatar_url': session.user.avatarUrl,
          'provider': session.user.provider,
        }));
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTokenKey);
    await prefs.remove(_kUserKey);
    await prefs.remove(_kSessionKey);
  }
}
