/// about_screen.dart — "About Me" tab: profile + project overview.
/// Rank, comments, and feedback live in community_screen.dart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../application/providers.dart';
import '../widgets/my_apps_section.dart';
import 'community_screen.dart';

// ── Brand palette ─────────────────────────────────────────────────────────────
const _bg = Color(0xFF0A0E1A);
const _card = Color(0xFF1E293B);
const _border = Color(0xFF374151);
const _cyan = Color(0xFF22D3EE);
const _text = Color(0xFFE2E8F0);
const _muted = Color(0xFF6B7280);
const _green = Color(0xFF4ADE80);

// ── Constants ─────────────────────────────────────────────────────────────────
const _linkedInUrl = 'https://www.linkedin.com/in/krishnavijayaram/';

/// Primary: local asset (bundle it as assets/images/profile.jpg for instant load).
/// Fallback: unavatar.io proxies LinkedIn photos with proper CORS, no expiry.
const _profileAsset = 'assets/images/profile.jpg';
const _profileFallback = 'https://unavatar.io/linkedin/krishnavijayaram';

// ═════════════════════════════════════════════════════════════════════════════
// ABOUT SCREEN
// ═════════════════════════════════════════════════════════════════════════════

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  Future<void> _openLinkedIn() async {
    final uri = Uri.parse(_linkedInUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: _bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _profileCard(context),
                const SizedBox(height: 20),
                _projectCard(),
                const SizedBox(height: 20),
                _Card(child: const MyAppsSection()),
                const SizedBox(height: 20),
                _communityCtaCard(context),
                const SizedBox(height: 16),
                _floorMapCtaCard(context, ref),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Profile card ────────────────────────────────────────────────────────────
  Widget _profileCard(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Stack(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Color(0xFF0077B5), Color(0xFF00A0DC)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Color(0x550077B5),
                        blurRadius: 16,
                        offset: Offset(0, 4)),
                  ],
                ),
                child: const ClipOval(child: _ProfileAvatar(size: 88)),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: GestureDetector(
                  onTap: _openLinkedIn,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                        color: const Color(0xFF0077B5),
                        shape: BoxShape.circle,
                        border: Border.all(color: _bg, width: 2)),
                    child: const Center(
                      child: Text('in',
                          style: TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                              fontWeight: FontWeight.w900)),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 18),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Krishna Vijayaram',
                    style: TextStyle(
                        fontSize: 18,
                        color: _text,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3)),
                const SizedBox(height: 3),
                const Text('M.Tech · AI & Warehouse Automation',
                    style: TextStyle(fontSize: 12, color: _muted)),
                const SizedBox(height: 10),
                const Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Tag('Flutter', Color(0xFF54C5F8)),
                    _Tag('AI Agents', _cyan),
                    _Tag('Robotics', _green),
                    _Tag('FastAPI', Color(0xFF009688)),
                    _Tag('LLM', Color(0xFFA855F7)),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _openLinkedIn,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0077B5),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x550077B5),
                            blurRadius: 8,
                            offset: Offset(0, 2)),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('in',
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.white,
                                fontWeight: FontWeight.w900)),
                        SizedBox(width: 7),
                        Text('View LinkedIn Profile',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        SizedBox(width: 6),
                        Icon(Icons.open_in_new,
                            size: 12, color: Colors.white70),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Project description card ─────────────────────────────────────────────────
  Widget _projectCard() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 16, color: _cyan),
              const SizedBox(width: 8),
              const Text('ABOUT THIS PROJECT',
                  style: TextStyle(
                      fontSize: 11,
                      color: _cyan,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _cyan.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: _cyan.withAlpha(80)),
                ),
                child: const Text('Final Year M.Tech Project',
                    style: TextStyle(
                        fontSize: 9, color: _cyan, letterSpacing: 0.5)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text('WIOS — Warehouse Intelligence & Operations System',
              style: TextStyle(
                  fontSize: 16,
                  color: _text,
                  fontWeight: FontWeight.w800,
                  height: 1.3)),
          const SizedBox(height: 8),
          const Text(
            'An AI-enabled, real-time agentic simulation platform that demonstrates '
            'autonomous warehouse operations at scale. Built as a full-stack system '
            'with production-grade architecture — evolving toward real deployment.',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
          ),
          const SizedBox(height: 16),
          const _FeatureRow(
              Icons.precision_manufacturing_outlined,
              'Multi-robot fleet management',
              'AMR & AGV agents with A* pathfinding, collision avoidance & live telemetry'),
          const _FeatureRow(
              Icons.chat_bubble_outline,
              'LLM-powered chatbot personas',
              'Multiple AI personalities for ops decisions, escalation & re-routing'),
          const _FeatureRow(Icons.waves, 'Order wave processing & self-healing',
              'Real-time wave triggers, automatic failure recovery & proposal engine'),
          const _FeatureRow(Icons.bug_report_outlined, 'Sabotage simulation',
              'Fault injection to test warehouse resilience — blocked paths, dead robots'),
          const _FeatureRow(
              Icons.analytics_outlined,
              'Full observability stack',
              'Cost tracking, sync monitors, event bus & structured logging pipeline'),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _cyan.withAlpha(12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _cyan.withAlpha(60)),
            ),
            child: const Row(
              children: [
                Icon(Icons.rocket_launch_outlined, size: 15, color: _cyan),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Actively evolving — new capabilities added continuously. '
                    'The roadmap includes real WMS integration, AR mapping, '
                    'and production fleet deployment.',
                    style: TextStyle(fontSize: 11, color: _cyan, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Floor Map CTA card ──────────────────────────────────────────────────────
  Widget _floorMapCtaCard(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(navigateToTabProvider.notifier).state = 1,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF22D3EE).withAlpha(30),
              const Color(0xFF54C5F8).withAlpha(20)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _cyan.withAlpha(120)),
          boxShadow: const [
            BoxShadow(
                color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _cyan.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child:
                  const Icon(Icons.grid_view_rounded, color: _cyan, size: 24),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Warehouse Floor Map',
                      style: TextStyle(
                          fontSize: 15,
                          color: _text,
                          fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text('Live robot positions · Dock status · Aisle heatmap',
                      style:
                          TextStyle(fontSize: 11, color: _muted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: _cyan),
          ],
        ),
      ),
    );
  }

  // ── Community CTA card ───────────────────────────────────────────────────────
  Widget _communityCtaCard(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => const CommunityScreen())),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_green.withAlpha(30), _cyan.withAlpha(20)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _green.withAlpha(120)),
          boxShadow: const [
            BoxShadow(
                color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _green.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.people_alt_outlined,
                  color: _green, size: 24),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Community & Rankings',
                      style: TextStyle(
                          fontSize: 15,
                          color: _text,
                          fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text(
                      'Rate the app · Leave a comment · Read community feedback',
                      style:
                          TextStyle(fontSize: 11, color: _muted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.arrow_forward_ios_rounded,
                size: 16, color: _green),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SHARED SUPPORTING WIDGETS  (also imported by CommunityScreen)
// ═════════════════════════════════════════════════════════════════════════════

class AbCard extends StatelessWidget {
  const AbCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
          boxShadow: const [
            BoxShadow(
                color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))
          ],
        ),
        child: child,
      );
}

// Private alias for use within this file only
class _Card extends AbCard {
  const _Card({required super.child});
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withAlpha(28),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withAlpha(100)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 9,
                color: color,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
      );
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _cyan.withAlpha(20),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 14, color: _cyan),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 12,
                          color: _text,
                          fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 10, color: _muted, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      );
}

// ── Profile avatar: asset → unavatar.io proxy → initials ─────────────────────
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      _profileAsset,
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Image.network(
        _profileFallback,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Center(
          child: Text('KV',
              style: TextStyle(
                  fontSize: size * 0.28,
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5)),
        ),
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return Center(
            child: SizedBox(
              width: size * 0.32,
              height: size * 0.32,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white54,
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded /
                        progress.expectedTotalBytes!
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }
}
