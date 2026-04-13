/// my_apps_section.dart — shared "My Apps" hub widget.
/// Fetches the cross-app manifest from Azure Blob Storage and renders a card
/// per app.  Import this wherever you want the "MY APPS" section to appear.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// ── Manifest URL ──────────────────────────────────────────────────────────────
const kAppsManifestUrl =
    'https://sanatanaapistore.blob.core.windows.net/apps-manifest/apps.json';

// ── Brand palette (matches about_screen.dart) ─────────────────────────────────
const _bg    = Color(0xFF0A0E1A);
const _card  = Color(0xFF1E293B);
const _border = Color(0xFF374151);
const _cyan  = Color(0xFF22D3EE);
const _text  = Color(0xFFE2E8F0);
const _muted = Color(0xFF6B7280);

// ── Hex → Color ───────────────────────────────────────────────────────────────
Color parseHexColor(String hex) {
  final h = hex.replaceAll('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

// ═════════════════════════════════════════════════════════════════════════════
// PUBLIC WIDGET — drop anywhere
// ═════════════════════════════════════════════════════════════════════════════

/// Renders the "MY APPS" section.
/// Wrap in a card container to match the About screen style, e.g.:
///   Container(decoration: …, child: const MyAppsSection())
class MyAppsSection extends StatefulWidget {
  const MyAppsSection({super.key});

  @override
  State<MyAppsSection> createState() => _MyAppsSectionState();
}

class _MyAppsSectionState extends State<MyAppsSection> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchApps();
  }

  Future<List<Map<String, dynamic>>> _fetchApps() async {
    final response = await http.get(Uri.parse(kAppsManifestUrl));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['apps'] as List).cast<Map<String, dynamic>>();
    }
    throw Exception('HTTP ${response.statusCode}');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section header ───────────────────────────────────────────────────
        Row(
          children: [
            const Icon(Icons.apps_rounded, size: 16, color: _cyan),
            const SizedBox(width: 8),
            const Text(
              'MY APPS',
              style: TextStyle(
                  fontSize: 11,
                  color: _cyan,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _cyan.withAlpha(20),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _cyan.withAlpha(60)),
              ),
              child: const Text('Play Store · App Store',
                  style:
                      TextStyle(fontSize: 9, color: _cyan, letterSpacing: 0.5)),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // ── Cards ────────────────────────────────────────────────────────────
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: CircularProgressIndicator(
                      color: _cyan, strokeWidth: 2),
                ),
              );
            }
            if (snapshot.hasError) {
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withAlpha(60)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.redAccent, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('Unable to load apps — check network',
                          style: TextStyle(
                              color: Colors.redAccent, fontSize: 12)),
                    ),
                  ],
                ),
              );
            }
            final apps = snapshot.data!;
            if (apps.isEmpty) {
              return const Text('No apps published yet.',
                  style: TextStyle(color: _muted, fontSize: 12));
            }
            return Column(
              children: apps
                  .map((app) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: AppCard(app: app),
                      ))
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// APP CARD
// ═════════════════════════════════════════════════════════════════════════════

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.app});
  final Map<String, dynamic> app;

  @override
  Widget build(BuildContext context) {
    final name        = app['name']        as String? ?? '';
    final tagline     = app['tagline']     as String? ?? '';
    final description = app['description'] as String? ?? '';
    final category    = app['category']    as String? ?? '';
    final iconUrl     = app['iconUrl']     as String?;
    final bannerHex   = app['bannerColor'] as String? ?? '#22D3EE';
    final playStoreUrl = app['playStoreUrl'] as String?;
    final appStoreUrl  = app['appStoreUrl']  as String?;
    final isLive      = app['isLive']      as bool?   ?? false;
    final tags        = (app['tags'] as List?)?.cast<String>() ?? [];
    final banner      = parseHexColor(bannerHex);

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
        boxShadow: const [
          BoxShadow(
              color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Banner ────────────────────────────────────────────────────────
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [banner, banner.withAlpha(180)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                // App icon
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(30),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: iconUrl != null && iconUrl.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            iconUrl,
                            width: 52,
                            height: 52,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.apps_rounded,
                                color: Colors.white70,
                                size: 28),
                          ),
                        )
                      : const Icon(Icons.apps_rounded,
                          color: Colors.white70, size: 28),
                ),
                const SizedBox(width: 14),
                // Name + tagline
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(tagline,
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
                              height: 1.3)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Live badge + category
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isLive
                            ? const Color(0xFF4ADE80).withAlpha(220)
                            : Colors.black38,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: isLive
                                ? const Color(0xFF4ADE80)
                                : Colors.white30),
                      ),
                      child: Text(
                        isLive ? '● Live' : 'Coming Soon',
                        style: TextStyle(
                            fontSize: 9,
                            color: isLive ? Colors.white : Colors.white60,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(category,
                          style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white70,
                              letterSpacing: 0.4)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Body ──────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description,
                    style: const TextStyle(
                        fontSize: 12, color: _muted, height: 1.55)),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: tags
                        .map((t) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: banner.withAlpha(22),
                                borderRadius: BorderRadius.circular(4),
                                border:
                                    Border.all(color: banner.withAlpha(80)),
                              ),
                              child: Text(t,
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: banner,
                                      fontWeight: FontWeight.w600)),
                            ))
                        .toList(),
                  ),
                ],
                if (playStoreUrl != null || appStoreUrl != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (playStoreUrl != null)
                        AppStoreButton(
                          label: 'Google Play',
                          icon: Icons.shop_outlined,
                          url: playStoreUrl,
                          color: banner,
                          isLive: isLive,
                        ),
                      if (playStoreUrl != null && appStoreUrl != null)
                        const SizedBox(width: 10),
                      if (appStoreUrl != null)
                        AppStoreButton(
                          label: 'App Store',
                          icon: Icons.apple,
                          url: appStoreUrl,
                          color: banner,
                          isLive: isLive,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// STORE BUTTON
// ═════════════════════════════════════════════════════════════════════════════

class AppStoreButton extends StatelessWidget {
  const AppStoreButton({
    super.key,
    required this.label,
    required this.icon,
    required this.url,
    required this.color,
    required this.isLive,
  });

  final String label, url;
  final IconData icon;
  final Color color;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isLive ? color : color.withAlpha(60),
          borderRadius: BorderRadius.circular(8),
          boxShadow: isLive
              ? [
                  BoxShadow(
                      color: color.withAlpha(80),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
