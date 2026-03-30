/// game_screen.dart — WAAS v4 game-mode panel.
/// Visible only to Admin/Saboteur/AIObserver (level ≥ 4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/auth/auth_provider.dart';
import '../core/api_client.dart';
import '../core/sim_ws.dart';
import '../models/sim_frame.dart';
import '../widgets/credit_bar.dart';
import '../widgets/connection_banner.dart';

// ── Game mode constants ───────────────────────────────────────────────────────

const _kModes = [
  ('OPTION_1',  'Normal Ops',   Color(0xFF8B949E)),
  ('OPTION_2',  'High-Stress',  Color(0xFFFFCC00)),
  ('OPTION_3',  'MCI Surge',    Color(0xFFFF8C00)),
  ('COOP',      'Co-op',        Color(0xFF00FF88)),
  ('1V1',       'Competitive',  Color(0xFFFF4444)),
  ('TUTORIAL',  'Tutorial',     Color(0xFF00D4FF)),
];

// ── Saboteur actions ──────────────────────────────────────────────────────────

const _kSaboteurActions = [
  ('BLOCK_CHARGER',     'Block Charger',     Icons.power_off,         Color(0xFFFF4444)),
  ('MOVE_SHELF',        'Move Shelf',        Icons.move_to_inbox,     Color(0xFFFF8C00)),
  ('PLACE_OBSTACLE',    'Place Obstacle',    Icons.dangerous,         Color(0xFFFF4444)),
  ('SCRAMBLE_PATH',     'Scramble Path',     Icons.route,             Color(0xFFFFCC00)),
  ('CORRUPT_MAP',       'Corrupt Map',       Icons.map,               Color(0xFFAA44FF)),
  ('DISABLE_SENSOR',    'Disable Sensor',    Icons.sensors_off,       Color(0xFFFF8C00)),
  ('FLOOD_ORDERS',      'Flood Orders',      Icons.list_alt,          Color(0xFFFFCC00)),
  ('SHUTDOWN_ROBOT',    'Shutdown Robot',    Icons.stop_circle,       Color(0xFFFF4444)),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key});

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  String _activeMode = 'OPTION_1';
  int    _credits    = 0;
  bool   _loading    = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabCount(), vsync: this);
    _fetchCredits();
    _fetchMode();
  }

  int _tabCount() {
    final auth = ref.read(authProvider);
    final level = auth is AuthLoggedIn ? auth.user.level : 1;
    return level >= 5 ? 3 : 2; // Saboteur gets extra tab
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _fetchCredits() async {
    final auth = ref.read(authProvider);
    if (auth is! AuthLoggedIn) return;
    try {
      final c = await ApiClient.instance.getCreditCount(auth.session.effectiveSessionId);
      if (mounted) setState(() => _credits = c);
    } catch (_) {}
  }

  Future<void> _fetchMode() async {
    try {
      final mode = await ApiClient.instance.getGameMode();
      if (mounted) setState(() => _activeMode = mode);
    } catch (_) {}
  }

  Future<void> _setMode(String mode) async {
    setState(() => _loading = true);
    try {
      await ApiClient.instance.setGameMode(mode);
      setState(() { _activeMode = mode; _loading = false; });
    } catch (e) {
      setState(() { _loading = false; });
      if (mounted) _showSnack('Failed: $e', error: true);
    }
  }

  Future<void> _doAction(String actionType) async {
    final auth = ref.read(authProvider);
    if (auth is! AuthLoggedIn) return;
    if (_credits < 10) {
      _showSnack('Not enough credits (need 10)', error: true);
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await ApiClient.instance.performSaboteurAction(
        sessionId: auth.session.effectiveSessionId,
        actionType: actionType,
      );
      await _fetchCredits();
      setState(() {
        _loading     = false;
        _lastResult  = result;
      });
      _showSnack(result);
    } catch (e) {
      setState(() => _loading = false);
      _showSnack('Action failed: $e', error: true);
    }
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'ShareTechMono')),
        backgroundColor: error ? const Color(0xFF4A1515) : const Color(0xFF1A4A1A),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth  = ref.watch(authProvider);
    final frame = ref.watch(simFrameProvider);
    final level = auth is AuthLoggedIn ? auth.user.level : 1;

    final tabLabels = ['MODES', 'PROPOSALS'];
    if (level >= 5) tabLabels.add('SABOTEUR');

    return Scaffold(
      appBar: AppBar(
        title: const Text('GAME CENTER'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: const Color(0xFF00D4FF),
          labelStyle: const TextStyle(fontFamily: 'ShareTechMono', fontSize: 10),
          tabs: tabLabels.map((l) => Tab(text: l)).toList(),
        ),
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _ModesTab(activeMode: _activeMode, loading: _loading, onSelect: _setMode),
                _ProposalsTab(proposals: frame.layoutProposals, userLevel: level),
                if (level >= 5) _SaboteurTab(
                  credits:    _credits,
                  loading:    _loading,
                  lastResult: _lastResult,
                  onAction:   _doAction,
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: Color(0xFF00D4FF)),
        ],
      ),
    );
  }
}

// ── Modes Tab ─────────────────────────────────────────────────────────────────

class _ModesTab extends StatelessWidget {
  const _ModesTab({
    required this.activeMode,
    required this.loading,
    required this.onSelect,
  });
  final String   activeMode;
  final bool     loading;
  final void Function(String) onSelect;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const _SectionHead('SELECT GAME MODE'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _kModes.map((m) {
          final (id, label, color) = m;
          final active = id == activeMode;
          return _ModeChip(
            id: id, label: label, color: color,
            active: active, enabled: !loading,
            onTap: () => onSelect(id),
          );
        }).toList(),
      ),
    ],
  );
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.id, required this.label, required this.color,
    required this.active, required this.enabled, required this.onTap,
  });
  final String id, label;
  final Color  color;
  final bool   active, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: active ? color.withAlpha(40) : const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: active ? color : color.withAlpha(60), width: active ? 2 : 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: color, fontFamily: 'ShareTechMono', fontSize: 11, fontWeight: FontWeight.bold)),
          Text(id,    style: TextStyle(color: color.withAlpha(150), fontFamily: 'ShareTechMono', fontSize: 8)),
        ],
      ),
    ),
  );
}

// ── Proposals Tab ─────────────────────────────────────────────────────────────

class _ProposalsTab extends StatelessWidget {
  const _ProposalsTab({required this.proposals, required this.userLevel});
  final List<LayoutProposal> proposals;
  final int userLevel;

  @override
  Widget build(BuildContext context) {
    if (proposals.isEmpty) return const _Empty('No layout proposals');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: proposals.map((p) => _ProposalCard(p, userLevel)).toList(),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard(this.p, this.level);
  final LayoutProposal p;
  final int level;

  Color get _statusColor => switch (p.status) {
    'APPROVED' => const Color(0xFF00FF88),
    'REJECTED' => const Color(0xFFFF4444),
    _          => const Color(0xFFFFCC00),
  };

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _statusColor.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _statusColor.withAlpha(100)),
              ),
              child: Text(p.status, style: TextStyle(fontSize: 8, color: _statusColor, fontFamily: 'ShareTechMono')),
            ),
            const Spacer(),
            Text(
              '+${p.gainPercent.toStringAsFixed(1)}% efficiency',
              style: const TextStyle(fontSize: 10, color: Color(0xFF00FF88)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(p.description, style: const TextStyle(fontSize: 12)),
          if (level >= 4 && p.isPending)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(children: [
                _ActionBtn('APPROVE', const Color(0xFF00FF88), () => ApiClient.instance.approveProposal(p.id)),
                const SizedBox(width: 8),
                _ActionBtn('REJECT',  const Color(0xFFFF4444), () => ApiClient.instance.rejectProposal(p.id)),
              ]),
            ),
        ],
      ),
    ),
  );
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn(this.label, this.color, this.onTap);
  final String label;
  final Color  color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      foregroundColor: color,
      side: BorderSide(color: color.withAlpha(120)),
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontFamily: 'ShareTechMono', fontSize: 10),
    ),
    child: Text(label),
  );
}

// ── Saboteur Tab ──────────────────────────────────────────────────────────────

class _SaboteurTab extends StatelessWidget {
  const _SaboteurTab({
    required this.credits,
    required this.loading,
    required this.lastResult,
    required this.onAction,
  });
  final int    credits;
  final bool   loading;
  final String? lastResult;
  final void Function(String) onAction;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const _SectionHead('SABOTEUR CREDITS'),
      CreditBar(credits: credits),
      const SizedBox(height: 4),
      Text('$credits / 100 credits', style: const TextStyle(fontSize: 9, color: Color(0xFF8B949E), fontFamily: 'ShareTechMono')),
      const SizedBox(height: 16),
      const _SectionHead('ACTIONS (10 credits each)'),
      GridView.count(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.4,
        children: _kSaboteurActions.map((a) {
          final (id, label, icon, color) = a;
          return _ActionCard(
            id: id, label: label, icon: icon, color: color,
            enabled: !loading && credits >= 10,
            onTap: () => onAction(id),
          );
        }).toList(),
      ),
      if (lastResult != null) ...[
        const SizedBox(height: 16),
        const _SectionHead('LAST RESULT'),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: Text(lastResult!, style: const TextStyle(fontSize: 11, color: Color(0xFFFF8C00))),
        ),
      ],
    ],
  );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.id, required this.label, required this.icon,
    required this.color, required this.enabled, required this.onTap,
  });
  final String   id, label;
  final IconData icon;
  final Color    color;
  final bool     enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: enabled ? onTap : null,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: enabled ? color.withAlpha(20) : const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: enabled ? color.withAlpha(100) : const Color(0xFF21262D),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: enabled ? color : const Color(0xFF484F58), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: enabled ? color : const Color(0xFF484F58),
                fontFamily: 'ShareTechMono',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

// ── Shared ─────────────────────────────────────────────────────────────────────

class _SectionHead extends StatelessWidget {
  const _SectionHead(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 9, letterSpacing: 1.5, color: Color(0xFF8B949E)),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      message,
      style: const TextStyle(color: Color(0xFF484F58), fontFamily: 'ShareTechMono'),
    ),
  );
}
