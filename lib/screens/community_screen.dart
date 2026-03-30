/// community_screen.dart — Community & Rankings page.
///
/// Sections (in order):
///  1. RANK           — star rating for the app; shows aggregate avg
///  2. YOUR COMMENT   — editable public comment the current user posted
///  3. COMMUNITY FEED — expandable list of all public comments (everyone sees)
///  4. PRIVATE NOTES  — personal private feedback, never shown to others
library;

import 'dart:convert';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Palette (matches about_screen) ───────────────────────────────────────────
const _bg = Color(0xFF0A0E1A);
const _surface = Color(0xFF111827);
const _card = Color(0xFF1E293B);
const _border = Color(0xFF374151);
const _cyan = Color(0xFF22D3EE);
const _text = Color(0xFFE2E8F0);
const _muted = Color(0xFF6B7280);
const _green = Color(0xFF4ADE80);
const _yellow = Color(0xFFFDE047);

// ── SharedPreferences keys ────────────────────────────────────────────────────
const _keyRating = 'about_user_rating';
const _keyPublicComments = 'about_comments_json'; // list of all public comments
const _keyMyComment = 'about_my_comment'; // this user's own comment text
const _keyPrivateNote =
    'about_private_note'; // private, never displayed publicly
// Map<device, {count:int, sum:int}>  — tracks aggregate ratings per device
const _keyDeviceRatings = 'about_device_ratings_v2';

// ── Suggestion chips ──────────────────────────────────────────────────────────
const _suggestions = [
  '🗺 Real-time 3D rack viewer',
  '🎙 Voice command integration',
  '🔥 Robot congestion heatmap',
  '📄 Export pick/pack reports',
  '🔗 WMS API bridge (SAP/Oracle)',
  '📈 Demand forecasting alerts',
  '🏭 Multi-warehouse cross-dock',
  '📷 AR warehouse mapping mode',
  '🛎 Push alerts for stuck robots',
  '🧊 Cold-chain temp monitoring',
];

// ── Device detection ─────────────────────────────────────────────────────────
/// Returns one of: 'desktop' | 'android' | 'ios' | 'tablet'
String _detectDeviceType(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return width >= 768 ? 'tablet' : 'ios';
    case TargetPlatform.android:
      return width >= 600 ? 'tablet' : 'android';
    default:
      return 'desktop'; // macOS, Windows, Linux, Fuchsia
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// COMMUNITY SCREEN
// ═════════════════════════════════════════════════════════════════════════════

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  // ── State ────────────────────────────────────────────────────────────────────
  int _rating = 0;
  bool _ratingDone = false;

  // Public comment (this user's own)
  String _myComment = '';
  bool _editingComment = false;
  final _commentCtrl = TextEditingController();
  final Set<String> _chips = {};
  bool _savingComment = false;

  // All public comments
  List<_PubComment> _publicComments = [];

  // Private note
  String _privateNote = '';
  bool _editingPrivate = false;
  final _privateCtrl = TextEditingController();
  bool _savingPrivate = false;

  // UI
  bool _pubExpanded = true;

  // Device type & per-device aggregate ratings
  String _deviceType = 'desktop';
  // device → {count, sum}  so avg = sum/count
  Map<String, Map<String, int>> _devAgg = {};

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _deviceType = _detectDeviceType(context);
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _privateCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final rating = p.getInt(_keyRating) ?? 0;
    final myTxt = p.getString(_keyMyComment) ?? '';
    final privTxt = p.getString(_keyPrivateNote) ?? '';
    final raw = p.getString(_keyPublicComments);
    final List<_PubComment> loaded = [];
    if (raw != null) {
      try {
        for (final m in jsonDecode(raw) as List) {
          loaded.add(_PubComment.fromJson(m as Map<String, dynamic>));
        }
      } catch (_) {}
    }
    // ── Load / seed device aggregate ratings ─────────────────────────────────
    final rawDev = p.getString(_keyDeviceRatings);
    Map<String, Map<String, int>> agg = {};
    if (rawDev != null) {
      try {
        final outer = jsonDecode(rawDev) as Map<String, dynamic>;
        for (final e in outer.entries) {
          final inner = e.value as Map<String, dynamic>;
          agg[e.key] = {
            'count': (inner['count'] as num).toInt(),
            'sum': (inner['sum'] as num).toInt(),
          };
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _rating = rating;
        _ratingDone = rating > 0;
        _myComment = myTxt;
        _privateNote = privTxt;
        _publicComments = loaded;
        _commentCtrl.text = myTxt;
        _privateCtrl.text = privTxt;
        _devAgg = agg;
      });
    }
  }

  // ── Rating ───────────────────────────────────────────────────────────────────

  Future<void> _saveRating(int r) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_keyRating, r);
    // Update count+sum for this device
    final updated = Map<String, Map<String, int>>.from(
        _devAgg.map((k, v) => MapEntry(k, Map<String, int>.from(v))));
    final prev = updated[_deviceType];
    if (prev == null) {
      updated[_deviceType] = {'count': 1, 'sum': r};
    } else {
      // Replace this device's single rating (not cumulative — each device can change its vote)
      updated[_deviceType] = {
        'count': prev['count']!,
        'sum': (prev['sum']! - (prev['sum']! ~/ prev['count']!)) + r
      };
      // Simpler: just update avg in-place as one representative rating per device session
      updated[_deviceType] = {'count': 1, 'sum': r};
    }
    await p.setString(_keyDeviceRatings, jsonEncode(updated));
    setState(() {
      _rating = r;
      _ratingDone = true;
      _devAgg = updated;
    });
  }

  // ── Public comment ────────────────────────────────────────────────────────────

  Future<void> _submitComment() async {
    final parts = [
      ..._chips,
      if (_commentCtrl.text.trim().isNotEmpty) _commentCtrl.text.trim(),
    ];
    if (parts.isEmpty) return;
    final text = parts.join(' · ');
    setState(() => _savingComment = true);

    final p = await SharedPreferences.getInstance();
    await p.setString(_keyMyComment, text);

    // Add to public list (remove previous entry from this user to avoid dupes)
    final prev = p.getString(_keyMyComment) ?? '';
    final updated = [
      _PubComment(text: text, rating: _rating, ts: DateTime.now()),
      ..._publicComments.where((c) => c.text != prev),
    ];
    await p.setString(_keyPublicComments,
        jsonEncode(updated.map((c) => c.toJson()).toList()));

    if (mounted) {
      setState(() {
        _myComment = text;
        _publicComments = updated;
        _savingComment = false;
        _editingComment = false;
        _chips.clear();
      });
      _snack('Comment posted ✓', _green);
    }
  }

  // ── Private note ──────────────────────────────────────────────────────────────

  Future<void> _savePrivate() async {
    final text = _privateCtrl.text.trim();
    setState(() => _savingPrivate = true);
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyPrivateNote, text);
    if (mounted) {
      setState(() {
        _privateNote = text;
        _savingPrivate = false;
        _editingPrivate = false;
      });
      _snack('Private note saved 🔒', _cyan);
    }
  }

  void _snack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg,
          style:
              const TextStyle(color: _bg, fontSize: 12, fontWeight: FontWeight.w600)),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1320),
        foregroundColor: _text,
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.people_alt_outlined, size: 18, color: _green),
            SizedBox(width: 8),
            Text('Community & Rankings',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _text)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 1. RANK ────────────────────────────────────────────────
                _rankSection(),
                const SizedBox(height: 16),

                // ── 2. YOUR COMMENT ────────────────────────────────────────
                _selfCommentSection(),
                const SizedBox(height: 16),

                // ── 3. COMMUNITY COMMENTS ──────────────────────────────────
                _publicCommentsSection(),
                const SizedBox(height: 16),

                // ── 4. PRIVATE FEEDBACK ────────────────────────────────────
                _privFeedbackSection(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Section 1: Rank ───────────────────────────────────────────────────────────

  // helpers for aggregate model
  double _avgFor(String device) {
    final e = _devAgg[device];
    if (e == null || e['count'] == 0) return 0;
    return e['sum']! / e['count']!;
  }

  int _countFor(String device) => _devAgg[device]?['count'] ?? 0;

  double _globalAvg() {
    int totalSum = 0, totalCount = 0;
    for (final e in _devAgg.values) {
      totalSum += e['sum']!;
      totalCount += e['count']!;
    }
    return totalCount == 0 ? 0 : totalSum / totalCount;
  }

  int _globalCount() => _devAgg.values.fold(0, (s, e) => s + e['count']!);

  Widget _rankSection() {
    final globalAvg = _globalAvg();
    final globalCount = _globalCount();

    // build avg map for bar chart: device → avg rating (double)
    final Map<String, double> avgMap = {
      for (final d in ['desktop', 'android', 'ios', 'tablet']) d: _avgFor(d),
    };
    final countMap = {
      for (final d in ['desktop', 'android', 'ios', 'tablet']) d: _countFor(d),
    };

    return _SCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Row(children: [
            const Icon(Icons.star_rate_rounded, size: 16, color: _yellow),
            const SizedBox(width: 8),
            const Text('RANK THIS APP',
                style: TextStyle(
                    fontSize: 11,
                    color: _yellow,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            _DeviceBadge(_deviceType),
            if (globalCount > 0) ...[
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Row(children: [
                  const Icon(Icons.star_rounded, size: 12, color: _yellow),
                  const SizedBox(width: 3),
                  Text(globalAvg.toStringAsFixed(1),
                      style: const TextStyle(
                          fontSize: 11,
                          color: _yellow,
                          fontWeight: FontWeight.w700)),
                ]),
                Text('$globalCount ratings',
                    style: const TextStyle(fontSize: 9, color: _muted)),
              ]),
            ],
          ]),
          const SizedBox(height: 14),
          // ── Stars ────────────────────────────────────────────────────────────
          Row(
            children: List.generate(5, (i) {
              final filled = i < _rating;
              return GestureDetector(
                onTap: () => _saveRating(i + 1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      filled
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      key: ValueKey(filled),
                      size: 38,
                      color: filled ? _yellow : _border,
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 18),
          // ── Device bar chart (full width) ─────────────────────────────────
          _DeviceBarChart(
            avgs: avgMap,
            counts: countMap,
            globalAvg: globalAvg,
            globalCount: globalCount,
          ),
          if (_ratingDone) ...[
            const SizedBox(height: 10),
            Text(_ratingLabel(_rating),
                style: const TextStyle(
                    fontSize: 11, color: _muted, fontStyle: FontStyle.italic)),
          ],
        ],
      ),
    );
  }

  String _ratingLabel(int r) => switch (r) {
        1 => 'Thanks for the honest feedback — we\'ll do better.',
        2 => 'Noted. More improvements are coming soon.',
        3 => 'Decent! New features are being added continuously.',
        4 => 'Great! Almost there — stay tuned for the next release.',
        5 => '🎉 Awesome! You\'re a fan — follow on LinkedIn for updates.',
        _ => '',
      };

  // ── Section 2: Your comment ───────────────────────────────────────────────────

  Widget _selfCommentSection() {
    final hasComment = _myComment.isNotEmpty;
    return _SCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.edit_note_rounded, size: 16, color: _cyan),
            const SizedBox(width: 8),
            const Text('YOUR COMMENT',
                style: TextStyle(
                    fontSize: 11,
                    color: _cyan,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _cyan.withAlpha(25),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _cyan.withAlpha(70)),
              ),
              child: const Text('PUBLIC',
                  style:
                      TextStyle(fontSize: 8, color: _cyan, letterSpacing: 1.2)),
            ),
            const Spacer(),
            if (hasComment && !_editingComment)
              TextButton.icon(
                onPressed: () => setState(() => _editingComment = true),
                icon: const Icon(Icons.edit_rounded, size: 13),
                label: const Text('Edit', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                    foregroundColor: _cyan,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              ),
          ]),
          const SizedBox(height: 12),
          if (!_editingComment && hasComment)
            // Read-only display of posted comment
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _border),
              ),
              child: Text(_myComment,
                  style:
                      const TextStyle(fontSize: 12, color: _text, height: 1.5)),
            )
          else ...[
            // Chip quick-picks
            const Text('QUICK PICKS',
                style:
                    TextStyle(fontSize: 9, color: _muted, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggestions.map((s) {
                final sel = _chips.contains(s);
                return GestureDetector(
                  onTap: () => setState(() {
                    sel ? _chips.remove(s) : _chips.add(s);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 130),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: sel ? _green.withAlpha(30) : _surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: sel ? _green : _border, width: sel ? 1.5 : 1),
                    ),
                    child: Text(s,
                        style: TextStyle(
                            fontSize: 11, color: sel ? _green : _muted)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            const Text('OR WRITE YOUR OWN',
                style:
                    TextStyle(fontSize: 9, color: _muted, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            TextField(
              controller: _commentCtrl,
              maxLines: 3,
              style: const TextStyle(fontSize: 12, color: _text),
              decoration: InputDecoration(
                hintText: 'Write what you think — everyone can see this…',
                hintStyle: const TextStyle(fontSize: 11, color: _muted),
                filled: true,
                fillColor: _surface,
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _green, width: 1.5)),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              if (hasComment)
                TextButton(
                  onPressed: () => setState(() {
                    _editingComment = false;
                  }),
                  child: const Text('Cancel', style: TextStyle(color: _muted)),
                ),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: _bg,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: (_savingComment ||
                        (_chips.isEmpty && _commentCtrl.text.trim().isEmpty))
                    ? null
                    : _submitComment,
                icon: _savingComment
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _bg))
                    : const Icon(Icons.send_rounded, size: 15),
                label: Text(_savingComment ? 'Posting…' : 'Post Comment',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  // ── Section 3: Community comments ────────────────────────────────────────────

  Widget _publicCommentsSection() {
    return _SCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — tap to expand/collapse
          GestureDetector(
            onTap: () => setState(() => _pubExpanded = !_pubExpanded),
            behavior: HitTestBehavior.opaque,
            child: Row(children: [
              const Icon(Icons.forum_outlined, size: 16, color: _green),
              const SizedBox(width: 8),
              const Text('COMMUNITY COMMENTS',
                  style: TextStyle(
                      fontSize: 11,
                      color: _green,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: _green.withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${_publicComments.length}',
                    style: const TextStyle(
                        fontSize: 10,
                        color: _green,
                        fontWeight: FontWeight.w700)),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: _pubExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more_rounded,
                    color: _muted, size: 20),
              ),
            ]),
          ),

          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                const Text(
                    'What others are saying — publicly visible to everyone.',
                    style: TextStyle(fontSize: 11, color: _muted)),
                const SizedBox(height: 14),
                if (_publicComments.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text('No community comments yet — be the first!',
                          style: TextStyle(
                              fontSize: 12,
                              color: _muted,
                              fontStyle: FontStyle.italic)),
                    ),
                  )
                else
                  ..._publicComments.take(30).map((c) => _CommentTile(c)),
              ],
            ),
            crossFadeState: _pubExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }

  // ── Section 4: Private feedback ───────────────────────────────────────────────

  Widget _privFeedbackSection() {
    final hasNote = _privateNote.isNotEmpty;
    return _SCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.lock_outline_rounded, size: 16, color: _muted),
            const SizedBox(width: 8),
            const Text('PRIVATE FEEDBACK',
                style: TextStyle(
                    fontSize: 11,
                    color: _muted,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _muted.withAlpha(25),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _muted.withAlpha(70)),
              ),
              child: const Text('ONLY YOU',
                  style: TextStyle(
                      fontSize: 8, color: _muted, letterSpacing: 1.2)),
            ),
            const Spacer(),
            if (hasNote && !_editingPrivate)
              TextButton.icon(
                onPressed: () => setState(() => _editingPrivate = true),
                icon: const Icon(Icons.edit_rounded, size: 13),
                label: const Text('Edit', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                    foregroundColor: _muted,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              ),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Only stored on this device. Never shown to anyone. Use for personal notes or private suggestions.',
            style: TextStyle(fontSize: 10, color: _muted, height: 1.5),
          ),
          const SizedBox(height: 14),
          if (!_editingPrivate && hasNote)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _border),
              ),
              child: Text(_privateNote,
                  style:
                      const TextStyle(fontSize: 12, color: _text, height: 1.5)),
            )
          else ...[
            TextField(
              controller: _privateCtrl,
              maxLines: 4,
              style: const TextStyle(fontSize: 12, color: _text),
              decoration: InputDecoration(
                hintText: 'Your private thoughts, bugs, or ideas…',
                hintStyle: const TextStyle(fontSize: 11, color: _muted),
                filled: true,
                fillColor: _surface,
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        BorderSide(color: _muted.withAlpha(180), width: 1.5)),
                contentPadding: const EdgeInsets.all(12),
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(left: 10, right: 8, top: 12),
                  child:
                      Icon(Icons.lock_outline_rounded, size: 15, color: _muted),
                ),
                prefixIconConstraints: const BoxConstraints(),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              if (hasNote)
                TextButton(
                  onPressed: () => setState(() {
                    _editingPrivate = false;
                  }),
                  child: const Text('Cancel', style: TextStyle(color: _muted)),
                ),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF374151),
                  foregroundColor: _text,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: (_savingPrivate || _privateCtrl.text.trim().isEmpty)
                    ? null
                    : _savePrivate,
                icon: _savingPrivate
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _text))
                    : const Icon(Icons.save_outlined, size: 15),
                label: Text(_savingPrivate ? 'Saving…' : 'Save Privately',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// SUPPORTING WIDGETS & MODELS
// ═════════════════════════════════════════════════════════════════════════════

class _SCard extends StatelessWidget {
  const _SCard({required this.child});
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

class _CommentTile extends StatelessWidget {
  const _CommentTile(this.comment);
  final _PubComment comment;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Row(
                children: List.generate(
                    5,
                    (i) => Icon(
                          i < comment.rating
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 10,
                          color: i < comment.rating ? _yellow : _border,
                        ))),
            const Spacer(),
            Text(_fmt(comment.ts),
                style: const TextStyle(fontSize: 9, color: _muted)),
          ]),
          const SizedBox(height: 5),
          Text(comment.text,
              style: const TextStyle(fontSize: 11, color: _text, height: 1.4)),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ── Data model ────────────────────────────────────────────────────────────────

class _PubComment {
  const _PubComment(
      {required this.text, required this.rating, required this.ts});
  final String text;
  final int rating;
  final DateTime ts;

  factory _PubComment.fromJson(Map<String, dynamic> m) => _PubComment(
        text: m['text'] as String? ?? '',
        rating: m['rating'] as int? ?? 0,
        ts: DateTime.tryParse(m['ts'] as String? ?? '') ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'rating': rating,
        'ts': ts.toIso8601String(),
      };
}

// ── Device badge ──────────────────────────────────────────────────────────────

class _DeviceBadge extends StatelessWidget {
  final String device;
  const _DeviceBadge(this.device);

  static const _info = <String, (IconData, Color, String)>{
    'desktop': (Icons.desktop_windows_outlined, Color(0xFF818CF8), 'Desktop'),
    'android': (Icons.android_rounded, Color(0xFF4ADE80), 'Android'),
    'ios': (Icons.phone_iphone_rounded, Color(0xFFF9A8D4), 'iPhone'),
    'tablet': (Icons.tablet_mac_outlined, Color(0xFFFBBF24), 'Tablet'),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) =
        _info[device] ?? (Icons.devices_rounded, _muted, 'Device');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: 9, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ── Device bar chart ──────────────────────────────────────────────────────────

class _DeviceBarChart extends StatelessWidget {
  final Map<String, double> avgs;
  final Map<String, int> counts;
  final double globalAvg;
  final int globalCount;

  const _DeviceBarChart({
    required this.avgs,
    required this.counts,
    required this.globalAvg,
    required this.globalCount,
  });

  static const _defs = [
    ('total', 'Total', Icons.equalizer_rounded, Color(0xFF22D3EE)),
    ('desktop', 'Desktop', Icons.desktop_windows_outlined, Color(0xFF818CF8)),
    ('android', 'Android', Icons.android_rounded, Color(0xFF4ADE80)),
    ('ios', 'iPhone', Icons.phone_iphone_rounded, Color(0xFFF9A8D4)),
    ('tablet', 'Tablet', Icons.tablet_mac_outlined, Color(0xFFFBBF24)),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final (key, label, icon, color) in _defs)
            _bar(
              label: label,
              value: key == 'total' ? globalAvg : (avgs[key] ?? 0),
              count: key == 'total' ? globalCount : (counts[key] ?? 0),
              color: color,
              icon: icon,
            ),
        ],
      ),
    );
  }

  Widget _bar({
    required String label,
    required double value,
    required int count,
    required Color color,
    required IconData icon,
  }) {
    const maxBarH = 72.0;
    final hasData = value > 0;
    final barH = hasData ? (value / 5.0) * maxBarH : 4.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // avg score
        if (hasData)
          Text(
            value.toStringAsFixed(1),
            style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: FontWeight.w800,
                height: 1.2),
          )
        else
          const Text('–',
              style: TextStyle(
                  fontSize: 13,
                  color: _border,
                  fontWeight: FontWeight.w700,
                  height: 1.2)),
        const SizedBox(height: 4),
        // bar
        AnimatedContainer(
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOut,
          width: 28,
          height: barH,
          decoration: BoxDecoration(
            color: hasData ? color.withAlpha(220) : _border.withAlpha(50),
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(5), bottom: Radius.circular(2)),
          ),
        ),
        const SizedBox(height: 6),
        // icon
        Icon(icon, size: 22, color: hasData ? color : _muted),
        const SizedBox(height: 3),
        // label
        Text(
          label,
          style: TextStyle(
              fontSize: 11,
              color: hasData ? color.withAlpha(240) : _muted,
              fontWeight: FontWeight.w600,
              height: 1.3),
          textAlign: TextAlign.center,
        ),
        // count
        Text(
          hasData ? 'n\u2009=\u2009$count' : 'none',
          style: TextStyle(
              fontSize: 9, color: hasData ? _muted : _border, height: 1.3),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
