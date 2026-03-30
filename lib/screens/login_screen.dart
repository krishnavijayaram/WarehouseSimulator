/// login_screen.dart — WOIS sign-in screen.
/// Mirrors the warehouse_sim.html auth overlay (Google OAuth + Dev Mode).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/auth/auth_provider.dart';
import '../core/api_client.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  Map<String, bool> _providers = {};
  bool _loadingProviders = true;

  @override
  void initState() {
    super.initState();
    _fetchProviders();
  }

  Future<void> _fetchProviders() async {
    try {
      final data = await ApiClient.instance.getProviders();
      setState(() {
        _providers = {
          for (final e in data.entries)
            e.key: (e.value as Map?)?['configured'] == true,
        };
        _loadingProviders = false;
      });
    } catch (_) {
      setState(() => _loadingProviders = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Header ──────────────────────────────────────────────────
                const Text(
                  '⬡ WOIS',
                  style: TextStyle(
                    fontSize: 40,
                    color: Color(0xFF00D4FF),
                    fontFamily: 'ShareTechMono',
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Warehouse AI Simulator',
                  style: TextStyle(fontSize: 13, color: Color(0xFF8B949E)),
                ),
                const SizedBox(height: 8),
                const Text(
                  'WAAS v4 · MTech Research Platform',
                  style: TextStyle(fontSize: 10, color: Color(0xFF484F58)),
                ),
                const SizedBox(height: 36),

                // ── Error banner ─────────────────────────────────────────────
                if (auth is AuthError) _ErrorBanner(auth.message),

                // ── OAuth buttons ─────────────────────────────────────────────
                if (_loadingProviders)
                  const CircularProgressIndicator(color: Color(0xFF00D4FF))
                else ...[
                  if (_providers['google'] == true)
                    _OAuthButton(
                      label: 'Continue with Google',
                      icon: _googleLogo(),
                      onTap: () =>
                          ref.read(authProvider.notifier).startOAuth('google'),
                    ),
                  if (_providers['microsoft'] == true)
                    _OAuthButton(
                      label: 'Continue with Microsoft',
                      icon: const Icon(Icons.window, size: 20),
                      onTap: () => ref
                          .read(authProvider.notifier)
                          .startOAuth('microsoft'),
                    ),
                  if (_providers['github'] == true)
                    _OAuthButton(
                      label: 'Continue with GitHub',
                      icon: const Icon(Icons.code, size: 20),
                      onTap: () =>
                          ref.read(authProvider.notifier).startOAuth('github'),
                    ),
                  if (_providers.values.every((v) => !v))
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'No OAuth providers configured.\nUse Dev Mode below.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
                      ),
                    ),
                ],

                const SizedBox(height: 16),
                const Divider(color: Color(0xFF30363D)),
                const SizedBox(height: 16),

                // ── Dev mode bypass ────────────────────────────────────────────
                auth is AuthLoading
                    ? const CircularProgressIndicator(color: Color(0xFF00D4FF))
                    : OutlinedButton.icon(
                        icon: const Text('⚡', style: TextStyle(fontSize: 16)),
                        label:
                            const Text('Dev Mode — Skip Auth (localhost only)'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00D4FF),
                          side: const BorderSide(color: Color(0xFF30363D)),
                          minimumSize: const Size(double.infinity, 48),
                          textStyle: const TextStyle(
                              fontFamily: 'ShareTechMono', fontSize: 12),
                        ),
                        onPressed: () =>
                            ref.read(authProvider.notifier).devLogin(),
                      ),

                const SizedBox(height: 20),
                const Text(
                  'Sign in is required to persist chat history & activity logs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: Color(0xFF484F58)),
                ),
                const SizedBox(height: 8),
                const Text(
                  'ISO 28000 · OSHA-aligned · SOC 2 Ready',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 9,
                      color: Color(0xFF363C45),
                      letterSpacing: 0.8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _googleLogo() => SizedBox(
        width: 20,
        height: 20,
        child: CustomPaint(painter: _GoogleLogoPainter()),
      );
}

// ── OAuth button ──────────────────────────────────────────────────────────────

class _OAuthButton extends StatelessWidget {
  const _OAuthButton(
      {required this.label, required this.icon, required this.onTap});
  final String label;
  final Widget icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF30363D)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                icon,
                const SizedBox(width: 12),
                Text(label,
                    style: const TextStyle(fontSize: 13, color: Colors.white)),
              ],
            ),
          ),
        ),
      );
}

// ── Error banner ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF3D1515),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFFF4444).withAlpha(120)),
        ),
        child: Text(
          message,
          style: const TextStyle(fontSize: 11, color: Color(0xFFFF8888)),
        ),
      );
}

// ── Mini Google logo painter ──────────────────────────────────────────────────

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final cx = s.width / 2, cy = s.height / 2, r = s.width / 2;
    final rects = [
      (const Color(0xFF4285F4), 0.0, 3.14),
      (const Color(0xFF34A853), 3.14, 4.71),
      (const Color(0xFFFBBC05), 4.71, 5.50),
      (const Color(0xFFEA4335), 5.50, 6.28),
    ];
    for (final (col, start, end) in rects) {
      c.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r), start,
          end - start, true, Paint()..color = col);
    }
    c.drawCircle(
        Offset(cx, cy), r * 0.55, Paint()..color = const Color(0xFF0D1117));
  }

  @override
  bool shouldRepaint(_) => false;
}
