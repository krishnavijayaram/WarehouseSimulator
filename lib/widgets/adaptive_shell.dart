/// adaptive_shell.dart — Full SyntWare feature-parity shell.
///
/// Desktop (≥900px): NavRail | [Ticker + Floor + DataTabs + SyncBars] | [Persona Chat]
/// with draggable column splitter.
/// Mobile landscape: Full floor + slide-in panel.
/// Mobile portrait: Bottom nav switching views.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_provider.dart';
import '../core/sim_ws.dart';
import '../models/user.dart';
import '../models/sim_frame.dart';
import '../models/warehouse_config.dart';
import '../screens/about_screen.dart';
import '../screens/community_screen.dart';
import '../screens/floor_screen.dart';
import '../screens/game_screen.dart';
import '../screens/warehouse_creator_screen.dart';
import '../application/providers.dart';
import '../widgets/robot_card.dart';
import '../widgets/connection_banner.dart';
import '../widgets/tutorial_overlay.dart';
import '../core/api_client.dart';
import '../application/event_bus.dart';
import '../application/robot_scout_simulation.dart';
import '../application/manual_robot_controller.dart';
import '../widgets/wms_dashboard_panel.dart';

// ── Breakpoints ───────────────────────────────────────────────────────────────

bool _isDesktop(BuildContext ctx) => MediaQuery.sizeOf(ctx).width >= 900;
bool _isLandscape(BuildContext ctx) =>
    MediaQuery.orientationOf(ctx) == Orientation.landscape;

// ── Colours ───────────────────────────────────────────────────────────────────

const _bg = Color(0xFF0D1117);
const _surface = Color(0xFF161B22);
const _border = Color(0xFF21262D);
const _cyan = Color(0xFF00D4FF);
const _green = Color(0xFF00FF88);
const _yellow = Color(0xFFFFCC00);
const _red = Color(0xFFFF4444);
const _muted = Color(0xFF8B949E);
const _text = Color(0xFFE6EDF3);

// ── Personas ──────────────────────────────────────────────────────────────────

const _personas = ['Manager', 'Supervisor', 'Examiner', 'Demo'];

const _personaQuestions = {
  'Manager': [
    'What is the current wave efficiency?',
    'How many orders are pending?',
    'Show me today\'s throughput summary.',
    'Are there any critical alerts?',
    'What is the ROI of self-healing events?',
  ],
  'Supervisor': [
    'Which robots have the most conflicts?',
    'Show me unresolved aisle congestion.',
    'What is the current pick rate per robot?',
    'Which wave has the highest priority orders?',
    'Are there any stalled routes?',
  ],
  'Examiner': [
    'Explain the self-healing algorithm.',
    'What is the detection latency for anomalies?',
    'How does the wave planner optimise routes?',
    'Compare AMR vs AGV performance.',
    'Describe the sabotage detection mechanism.',
  ],
  'Demo': [
    'Give me a quick system overview.',
    'What features does WOIS have?',
    'Show me an interesting anomaly.',
    'How does the AI assistant work?',
    'What does the sync status mean?',
  ],
};

const _sabotageTypes = [
  'RANDOM',
  'W1',
  'W2',
  'W3',
  'O1',
  'O2',
  'O3',
  'O4',
  'D1_sab',
  'D2',
  'D3',
  'Y1',
  'Y2',
  'Y3',
  'S1',
  'S2',
];

// ──────────────────────────────────────────────────────────────────────────────
// ROOT SHELL
// ──────────────────────────────────────────────────────────────────────────────

class AdaptiveShell extends ConsumerStatefulWidget {
  const AdaptiveShell({super.key});

  @override
  ConsumerState<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends ConsumerState<AdaptiveShell> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      TutorialController.showIfFirstRun(ref);
    });
  }

  List<NavigationDestination> _destinations(int level) => [
        const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard'),
        const NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view),
            label: 'Floor'),
        const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat'),
        const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'About'),
        const NavigationDestination(
            icon: Icon(Icons.star_outline_rounded),
            selectedIcon: Icon(Icons.star_rounded),
            label: 'Rate'),
        if (level >= 4)
          const NavigationDestination(
              icon: Icon(Icons.sports_esports_outlined),
              selectedIcon: Icon(Icons.sports_esports),
              label: 'Game'),
      ];

  void _onNavTap(int i) => setState(() => _selectedIndex = i);

  @override
  Widget build(BuildContext context) {
    // Listen for programmatic tab navigation (e.g. Start Operations)
    ref.listen<int?>(navigateToTabProvider, (_, next) {
      if (next != null) {
        setState(() => _selectedIndex = next);
        ref.read(navigateToTabProvider.notifier).state = null;
      }
    });

    final auth = ref.watch(authProvider);
    final frame = ref.watch(simFrameProvider);
    final user = auth is AuthLoggedIn ? auth.user : null;
    final level = user?.level ?? 1;

    return TutorialOverlay(
      child: _isDesktop(context)
          ? _DesktopLayout(frame: frame, user: user, level: level)
          : _isLandscape(context)
              ? _MobileLandscapeLayout(
                  frame: frame,
                  user: user,
                  level: level,
                  selectedIndex: _selectedIndex,
                  destinations: _destinations(level),
                  onNavTap: _onNavTap,
                  onTutorial: () => TutorialController.show(ref),
                )
              : _MobilePortraitLayout(
                  frame: frame,
                  user: user,
                  level: level,
                  selectedIndex: _selectedIndex,
                  destinations: _destinations(level),
                  onNavTap: _onNavTap,
                  onTutorial: () => TutorialController.show(ref),
                ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// DESKTOP — NavRail | Left(Ticker+Floor+Tabs+Sync) | Draggable | Right(Chat)
// ══════════════════════════════════════════════════════════════════════════════

class _DesktopLayout extends ConsumerStatefulWidget {
  const _DesktopLayout(
      {required this.frame, required this.user, required this.level});
  final SimFrame frame;
  final WoisUser? user;
  final int level;

  @override
  ConsumerState<_DesktopLayout> createState() => _DesktopLayoutState();
}

class _DesktopLayoutState extends ConsumerState<_DesktopLayout> {
  double _rightWidth = 360;
  static const _minRight = 260.0;
  static const _maxRight = 560.0;
  int _navIndex = 0;

  List<NavigationRailDestination> get _railDests => [
        const NavigationRailDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: Text('DASH')),
        const NavigationRailDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view),
            label: Text('FLOOR')),
        const NavigationRailDestination(
            icon: Icon(Icons.warehouse_outlined),
            selectedIcon: Icon(Icons.warehouse),
            label: Text('CRAFT')),
        const NavigationRailDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: Text('ABOUT')),
        const NavigationRailDestination(
            icon: Icon(Icons.star_outline_rounded),
            selectedIcon: Icon(Icons.star_rounded),
            label: Text('RATE')),
        if (widget.level >= 4)
          const NavigationRailDestination(
              icon: Icon(Icons.sports_esports_outlined),
              selectedIcon: Icon(Icons.sports_esports),
              label: Text('GAME')),
      ];

  @override
  Widget build(BuildContext context) {
    ref.listen<SimFrame>(simFrameProvider, (_, frame) {
      ref.read(manualModeProvider.notifier).ingestFromFrame(frame);
    });
    // Listen for programmatic tab navigation (e.g. Start Operations → Floor)
    ref.listen<int?>(navigateToTabProvider, (_, next) {
      if (next != null) {
        setState(() => _navIndex = next);
        ref.read(navigateToTabProvider.notifier).state = null;
      }
    });
    final manualState = ref.watch(manualModeProvider);
    return Scaffold(
      backgroundColor: _bg,
      body: Row(
        children: [
          _NavRail(
            selectedIndex: _navIndex.clamp(0, _railDests.length - 1),
            destinations: _railDests,
            onTap: (i) => setState(() => _navIndex = i),
            user: widget.user,
            onTutorial: () => TutorialController.show(ref),
          ),
          const VerticalDivider(width: 1, color: _border),

          // ── Left column ────────────────────────────────────────────────────
          Expanded(
            child: Column(
              children: [
                const ConnectionBanner(),
                _ManualModeBar(manualState: manualState),
                _TickerStrip(
                    frame: widget.frame, isManual: manualState.isManual),
                const Divider(height: 1, color: _border),
                Expanded(child: _leftContent()),
              ],
            ),
          ),

          // ── Draggable splitter ─────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              setState(() {
                _rightWidth =
                    (_rightWidth - d.delta.dx).clamp(_minRight, _maxRight);
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                width: 6,
                color: _border,
                child: const Center(
                  child: Icon(Icons.drag_indicator, size: 14, color: _muted),
                ),
              ),
            ),
          ),

          // ── Right panel ─────────────────────────────────────────────────────
          SizedBox(
            width: _rightWidth,
            child: _RightChatPanel(user: widget.user),
          ),
        ],
      ),
    );
  }

  Widget _leftContent() {
    return switch (_navIndex) {
      1 => const FloorCanvas(),
      2 => const WarehouseCreatorScreen(),
      3 => const AboutScreen(),
      4 => const CommunityScreen(),
      5 => const GameScreen(),
      _ => Column(
          children: [
            Expanded(
              child: _VerticalSplit(
                top: const FloorCanvas(),
                bottom: _DataTabs(frame: widget.frame, user: widget.user),
              ),
            ),
            const Divider(height: 1, color: _border),
            _SyncBarsStrip(frame: widget.frame),
          ],
        ),
    };
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MANUAL MODE BAR — shown above ticker when manual mode is active
// ══════════════════════════════════════════════════════════════════════════════

class _ManualModeBar extends ConsumerWidget {
  const _ManualModeBar({required this.manualState});
  final ManualModeState manualState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = manualState.pendingEvents.length;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: manualState.isManual ? 36 : 0,
      color: _red.withAlpha(25),
      child: manualState.isManual
          ? Row(
              children: [
                const SizedBox(width: 12),
                const Text('⏸', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'MANUAL MODE — $pending event${pending == 1 ? '' : 's'} awaiting approval',
                    style: const TextStyle(
                      fontSize: 10,
                      color: _red,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(manualModeProvider.notifier).toggleManual(),
                  child: const Text('RESUME AUTO',
                      style: TextStyle(fontSize: 9, color: _green)),
                ),
                const SizedBox(width: 8),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TICKER STRIP
// ══════════════════════════════════════════════════════════════════════════════

class _TickerStrip extends StatefulWidget {
  const _TickerStrip({required this.frame, this.isManual = false});
  final SimFrame frame;
  final bool isManual;

  @override
  State<_TickerStrip> createState() => _TickerStripState();
}

class _TickerStripState extends State<_TickerStrip>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<double> _pos;

  @override
  void initState() {
    super.initState();
    _anim =
        AnimationController(vsync: this, duration: const Duration(seconds: 20))
          ..repeat();
    _pos = Tween(begin: 0.0, end: 1.0).animate(_anim);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kpi = widget.frame.kpi;
    final effPct = (kpi.efficiency * 100).round();
    final items = [
      'WMS 98%',
      'OMS 95%',
      'DMS 99%',
      'YMS 97%',
      'SMS 96%',
      'ALERTS: ${kpi.conflicts}',
      'EFF: $effPct%',
      'BOTS: ${kpi.activeBots}',
      'WAVE #${widget.frame.waveNumber}',
      'STATUS: ${widget.frame.simStatus}',
    ];
    final text = items.join('    ◈    ');

    return Container(
      height: 26,
      color: const Color(0xFF0A0F16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: _cyan.withAlpha(30),
            child: const Text('LIVE',
                style: TextStyle(
                    fontSize: 8,
                    color: _cyan,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
          ),
          if (widget.isManual)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: _red.withAlpha(40),
              child: const Text('⏸ MANUAL',
                  style: TextStyle(
                      fontSize: 8,
                      color: _red,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold)),
            ),
          Expanded(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _pos,
                builder: (ctx, _) => FractionalTranslation(
                  translation: Offset(-_pos.value, 0),
                  child: OverflowBox(
                    maxWidth: double.infinity,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '$text    $text',
                      style: const TextStyle(
                          fontSize: 9,
                          color: _muted,
                          letterSpacing: 1.2,
                          fontFamily: 'monospace'),
                      softWrap: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// VERTICAL SPLIT (Floor on top, Tabs below) with draggable divider
// ══════════════════════════════════════════════════════════════════════════════

class _VerticalSplit extends StatefulWidget {
  const _VerticalSplit({required this.top, required this.bottom});
  final Widget top, bottom;

  @override
  State<_VerticalSplit> createState() => _VerticalSplitState();
}

class _VerticalSplitState extends State<_VerticalSplit> {
  double _topFraction = 0.52;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final totalH = constraints.maxHeight - 6;
      final topH = (totalH * _topFraction).clamp(80.0, totalH - 80);
      final botH = totalH - topH;
      return Column(
        children: [
          SizedBox(height: topH, child: widget.top),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              setState(() {
                _topFraction = ((_topFraction * totalH + d.delta.dy) / totalH)
                    .clamp(0.2, 0.8);
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: Container(
                height: 6,
                color: _border,
                child: const Center(
                    child: Icon(Icons.drag_handle, size: 14, color: _muted)),
              ),
            ),
          ),
          SizedBox(height: botH, child: widget.bottom),
        ],
      );
    });
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// DATA TABS (10 tabs)
// ══════════════════════════════════════════════════════════════════════════════

class _DataTabs extends ConsumerWidget {
  const _DataTabs({required this.frame, required this.user});
  final SimFrame frame;
  final WoisUser? user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Live robots from DB (polls every 3 s); falls back to empty list.
    final robots = ref.watch(liveRobotsProvider).valueOrNull ?? const [];

    return DefaultTabController(
      length: 11,
      child: Column(
        children: [
          Container(
            color: _surface,
            child: const TabBar(
              isScrollable: true,
              labelColor: _cyan,
              unselectedLabelColor: _muted,
              tabs: [
                Tab(text: '🤖 FLEET'),
                Tab(text: '📍 WMS'),
                Tab(text: '📦 ORDERS'),
                Tab(text: '🌊 WAVES'),
                Tab(text: '⚠️ ALERTS'),
                Tab(text: '⛓ EVENTS'),
                Tab(text: '📊 KPIs'),
                Tab(text: '⚡ SELF-HEAL'),
                Tab(text: '🗺 PROPOSALS'),
                Tab(text: '🎮 SIM CTRL'),
                Tab(text: '🔬 AISLE DL'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _FleetTab(robots: robots),
                const WmsDashboardPanel(),
                _OrdersTab(frame: frame),
                _WavesTab(frame: frame),
                _AlertsTab(frame: frame),
                const _EventsTab(),
                _KpiTab(kpi: frame.kpi),
                _SelfHealTab(events: frame.selfHealingEvents),
                _ProposalsTab(proposals: frame.layoutProposals, user: user),
                _SimCtrlTab(frame: frame),
                _AisleDrillTab(robots: robots),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Fleet Tab ─────────────────────────────────────────────────────────────────

class _FleetTab extends StatelessWidget {
  const _FleetTab({required this.robots});
  final List<Robot> robots;

  @override
  Widget build(BuildContext context) {
    if (robots.isEmpty) {
      return const _EmptyTab(
          'No robots online yet.\nStart Operations and move a robot.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: robots.length,
      itemBuilder: (_, i) => RobotCard(robot: robots[i]),
    );
  }
}

// ── Orders Tab ────────────────────────────────────────────────────────────────

class _OrdersTab extends StatelessWidget {
  const _OrdersTab({required this.frame});
  final SimFrame frame;

  @override
  Widget build(BuildContext context) {
    if (frame.orders.isEmpty) {
      return const _EmptyTab('No orders in current wave');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: frame.orders.length,
      itemBuilder: (_, i) {
        final o = frame.orders[i];
        final statusColor = switch (o.status) {
          'DONE' => _green,
          'IN_PROGRESS' => _yellow,
          _ => _muted,
        };
        return _RowTile(
          leading: Text(
            o.type.isNotEmpty ? o.type.substring(0, 1) : '?',
            style: const TextStyle(color: _cyan, fontSize: 12),
          ),
          title:
              o.id.length > 12 ? '…${o.id.substring(o.id.length - 12)}' : o.id,
          subtitle: o.type,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withAlpha(30),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: statusColor.withAlpha(80)),
            ),
            child: Text(o.status,
                style: TextStyle(fontSize: 8, color: statusColor)),
          ),
        );
      },
    );
  }
}

// ── Waves Tab ─────────────────────────────────────────────────────────────────

class _WavesTab extends StatelessWidget {
  const _WavesTab({required this.frame});
  final SimFrame frame;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('CURRENT WAVE',
                style: TextStyle(fontSize: 8, color: _muted, letterSpacing: 2)),
            const SizedBox(height: 8),
            Text('# ${frame.waveNumber}',
                style: const TextStyle(
                    fontSize: 48, color: _cyan, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _StatusBadge(frame.simStatus),
            const SizedBox(height: 16),
            Text('${frame.orders.length} orders in wave',
                style: const TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 4),
            Text(
              '${frame.robots.where((r) => r.state == 'MOVING').length} robots active',
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Alerts Tab ────────────────────────────────────────────────────────────────

class _AlertsTab extends StatelessWidget {
  const _AlertsTab({required this.frame});
  final SimFrame frame;

  @override
  Widget build(BuildContext context) {
    final alerts = frame.selfHealingEvents;
    if (alerts.isEmpty) return const _EmptyTab('No active alerts');
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: alerts.length,
      itemBuilder: (_, i) {
        final e = alerts[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _border),
          ),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            leading: const Text('⚠', style: TextStyle(fontSize: 16)),
            title: Text(e.type,
                style: const TextStyle(fontSize: 11, color: _yellow)),
            subtitle: Text(
              '${e.ts.hour.toString().padLeft(2, '0')}:${e.ts.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 9, color: _muted),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(e.description,
                      style: const TextStyle(fontSize: 11, color: _text)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Event Chain Tab ───────────────────────────────────────────────────────────

class _EventsTab extends ConsumerWidget {
  const _EventsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(manualModeProvider);
    final allEvt = [...state.pendingEvents, ...state.eventHistory];

    if (allEvt.isEmpty) {
      return const _EmptyTab(
          'No events yet.\nEvents from the live simulation appear here.');
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: allEvt.length,
      itemBuilder: (_, i) {
        final e = allEvt[i];
        final isPending = e.isPending;

        return Padding(
          padding: EdgeInsets.only(
            left: e.parentId != null ? 20.0 : 0,
            bottom: 6,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Causal connector line
              if (e.parentId != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4, top: 4),
                  child: Column(
                    children: [
                      Container(width: 1, height: 12, color: _border),
                      const Icon(Icons.subdirectory_arrow_right,
                          size: 12, color: _muted),
                    ],
                  ),
                ),
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isPending
                        ? _yellow.withAlpha(15)
                        : e.isApproved
                            ? _green.withAlpha(10)
                            : e.isSkipped
                                ? _red.withAlpha(10)
                                : _surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isPending
                          ? _yellow.withAlpha(80)
                          : e.isApproved
                              ? _green.withAlpha(40)
                              : e.isSkipped
                                  ? _red.withAlpha(40)
                                  : _border,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(e.type.icon,
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(e.title,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: isPending ? _yellow : _text,
                                    fontWeight: FontWeight.w600)),
                          ),
                          Text(
                            '${e.ts.hour.toString().padLeft(2, '0')}:${e.ts.minute.toString().padLeft(2, '0')}:${e.ts.second.toString().padLeft(2, '0')}',
                            style: const TextStyle(fontSize: 8, color: _muted),
                          ),
                        ],
                      ),
                      if (e.description.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(e.description,
                            style: const TextStyle(fontSize: 9, color: _muted)),
                      ],
                      if (isPending) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            _CtrlButton(
                                e.type == WoisEventType.inboundOrder
                                    ? '📥 APPROVE ORDER'
                                    : '✅ EXECUTE',
                                _green,
                                () => ref
                                    .read(manualModeProvider.notifier)
                                    .approveEvent(e.id)),
                            const SizedBox(width: 6),
                            _CtrlButton(
                                '⏭ SKIP',
                                _muted,
                                () => ref
                                    .read(manualModeProvider.notifier)
                                    .skipEvent(e.id)),
                          ],
                        ),
                      ] else ...[
                        const SizedBox(height: 3),
                        Text(
                          e.isApproved
                              ? '✓ Executed'
                              : e.isSkipped
                                  ? '⏭ Skipped'
                                  : '',
                          style: TextStyle(
                              fontSize: 8,
                              color: e.isApproved ? _green : _muted),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Sim Control Tab ───────────────────────────────────────────────────────────

class _SimCtrlTab extends ConsumerWidget {
  const _SimCtrlTab({required this.frame});
  final SimFrame frame;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRunning = frame.simStatus == 'RUNNING';
    final manualState = ref.watch(manualModeProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusBadge(frame.simStatus),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CtrlButton('▶ NEW WAVE', _cyan,
                    () => ApiClient.instance.triggerWave()),
                const SizedBox(width: 12),
                _CtrlButton(
                  isRunning ? '⏸ PAUSE' : '▶ RESUME',
                  _yellow,
                  () => isRunning
                      ? ApiClient.instance.pauseSim()
                      : ApiClient.instance.resumeSim(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Manual mode toggle
            GestureDetector(
              onTap: () => ref.read(manualModeProvider.notifier).toggleManual(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: manualState.isManual ? _red.withAlpha(30) : _surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: manualState.isManual ? _red.withAlpha(120) : _border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      manualState.isManual
                          ? Icons.pause_circle
                          : Icons.play_circle_outline,
                      color: manualState.isManual ? _red : _muted,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      manualState.isManual
                          ? 'MANUAL MODE — ON (click to resume auto)'
                          : 'Enable Manual Mode',
                      style: TextStyle(
                        fontSize: 10,
                        color: manualState.isManual ? _red : _muted,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Wave #${frame.waveNumber}',
                style: const TextStyle(fontSize: 12, color: _muted)),
            if (manualState.isManual)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${manualState.pendingEvents.length} events pending — see ⛓ EVENTS tab',
                  style: const TextStyle(fontSize: 10, color: _yellow),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── KPI Tab ───────────────────────────────────────────────────────────────────

class _KpiTab extends StatelessWidget {
  const _KpiTab({required this.kpi});
  final KpiSnapshot kpi;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('ORDERS DONE', '${kpi.ordersDone}', _cyan),
      ('ACTIVE BOTS', '${kpi.activeBots}', _green),
      ('CONFLICTS', '${kpi.conflicts}', _red),
      ('EFFICIENCY', kpi.efficiencyLabel, _yellow),
      (
        'DETECT LATENCY',
        kpi.detectionLatencyMs != null
            ? '${kpi.detectionLatencyMs!.toStringAsFixed(0)} ms'
            : 'N/A',
        _muted
      ),
    ];
    return GridView.count(
      crossAxisCount: 2,
      padding: const EdgeInsets.all(12),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 2.2,
      children: [
        for (final (label, value, color) in items)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withAlpha(15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withAlpha(60)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 22,
                        color: color,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(label,
                    style: const TextStyle(
                        fontSize: 8, color: _muted, letterSpacing: 1)),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Self-Heal Tab ─────────────────────────────────────────────────────────────

class _SelfHealTab extends StatelessWidget {
  const _SelfHealTab({required this.events});
  final List<SelfHealEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const _EmptyTab('No self-healing events');
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: events.length,
      itemBuilder: (_, i) {
        final e = events[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              const Text('⚡', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.type,
                        style: const TextStyle(
                            fontSize: 11,
                            color: _cyan,
                            fontWeight: FontWeight.w600)),
                    Text(e.description,
                        style: const TextStyle(fontSize: 9, color: _muted)),
                  ],
                ),
              ),
              Text(
                '${e.ts.hour.toString().padLeft(2, '0')}:${e.ts.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 8, color: _muted),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Proposals Tab ─────────────────────────────────────────────────────────────

class _ProposalsTab extends ConsumerWidget {
  const _ProposalsTab({required this.proposals, required this.user});
  final List<LayoutProposal> proposals;
  final WoisUser? user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (proposals.isEmpty) return const _EmptyTab('No layout proposals');
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: proposals.length,
      itemBuilder: (_, i) {
        final p = proposals[i];
        final statusColor = switch (p.status) {
          'APPROVED' => _green,
          'REJECTED' => _red,
          _ => _yellow,
        };
        return _RowTile(
          leading: const Text('🗺', style: TextStyle(fontSize: 16)),
          title: p.description,
          subtitle:
              '+${p.gainPercent.toStringAsFixed(1)}% efficiency · ${p.status}',
          trailing: p.isPending && user != null && user!.canAdmin
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => ApiClient.instance.approveProposal(p.id),
                      child: const Icon(Icons.check_circle_outline,
                          color: _green, size: 18),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () => ApiClient.instance.rejectProposal(p.id),
                      child: const Icon(Icons.cancel_outlined,
                          color: _red, size: 18),
                    ),
                  ],
                )
              : Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(p.status,
                      style: TextStyle(fontSize: 8, color: statusColor)),
                ),
        );
      },
    );
  }
}

// ── Aisle Drill Tab ───────────────────────────────────────────────────────────

class _AisleDrillTab extends StatelessWidget {
  const _AisleDrillTab({required this.robots});
  final List<Robot> robots;

  static String _group(Robot r) {
    switch (r.state.toUpperCase()) {
      case 'IDLE':
        return '\u{1F50B} IDLE';
      case 'CHARGING':
        return '\u26A1 CHARGING';
      case 'ERROR':
        return '\u{1F6A8} ERROR';
      case 'PICKING':
        return '\u{1F4E6} PICKING';
      default:
        // Group by column — each unique column is one aisle lane.
        return 'AISLE col-${r.x.toInt()}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final byAisle = <String, List<Robot>>{};
    for (final r in robots) {
      byAisle.putIfAbsent(_group(r), () => []).add(r);
    }
    if (byAisle.isEmpty) {
      return const _EmptyTab(
          'No robots online yet.\nRobots appear here once operations start.');
    }
    // Sort: IDLE last, named aisles first
    final keys = byAisle.keys.toList()
      ..sort((a, b) {
        if (a.startsWith('AISLE') && !b.startsWith('AISLE')) return -1;
        if (!a.startsWith('AISLE') && b.startsWith('AISLE')) return 1;
        return a.compareTo(b);
      });
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final key in keys)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _border),
            ),
            child: ExpansionTile(
              initiallyExpanded: key.startsWith('AISLE'),
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              title:
                  Text(key, style: const TextStyle(fontSize: 11, color: _cyan)),
              subtitle: Text('${byAisle[key]!.length} robot(s)',
                  style: const TextStyle(fontSize: 9, color: _muted)),
              children: [
                for (final r in byAisle[key]!)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: RobotCard(robot: r),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SYNC BARS STRIP
// ══════════════════════════════════════════════════════════════════════════════

class _SyncBarsStrip extends StatelessWidget {
  const _SyncBarsStrip({required this.frame});
  final SimFrame frame;

  static const _systems = [
    ('WMS', 98.0),
    ('OMS', 95.0),
    ('DMS', 99.0),
    ('YMS', 97.0),
    ('SMS', 96.0),
  ];

  Color _barColor(double pct) {
    if (pct >= 98) return _green;
    if (pct >= 90) return _yellow;
    return _red;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: const Color(0xFF0A0F16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          for (final (name, pct) in _systems) ...[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 7, color: _muted, letterSpacing: 1)),
                      Text('${pct.toInt()}%',
                          style: TextStyle(fontSize: 7, color: _barColor(pct))),
                    ],
                  ),
                  const SizedBox(height: 2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: pct / 100,
                      backgroundColor: _border,
                      color: _barColor(pct),
                      minHeight: 4,
                    ),
                  ),
                ],
              ),
            ),
            if (name != 'SMS') const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// RIGHT CHAT PANEL — Persona + Suggestions + Chat + Sabotage
// ══════════════════════════════════════════════════════════════════════════════

class _RightChatPanel extends ConsumerStatefulWidget {
  const _RightChatPanel({required this.user});
  final WoisUser? user;

  @override
  ConsumerState<_RightChatPanel> createState() => _RightChatPanelState();
}

class _RightChatPanelState extends ConsumerState<_RightChatPanel> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  String? _sessionId;
  bool _sending = false;
  String _persona = 'Manager';
  bool _sabotageExpanded = false;

  @override
  void initState() {
    super.initState();
    _ensureSession();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ensureSession() async {
    if (_sessionId != null) return;
    final auth = ref.read(authProvider);
    if (auth is! AuthLoggedIn) return;
    try {
      final id = await ApiClient.instance.createChatSession(auth.token);
      if (mounted) setState(() => _sessionId = id);
    } catch (_) {}
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _sending || _sessionId == null) return;
    _ctrl.clear();
    setState(() {
      _msgs.add(_Msg('user', t, DateTime.now()));
      _sending = true;
    });
    _scrollToBottom();
    try {
      final reply = await ApiClient.instance
          .sendChatMessage(sessionId: _sessionId!, message: t);
      if (mounted) {
        setState(() => _msgs.add(_Msg('assistant', reply, DateTime.now())));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _msgs.add(_Msg('assistant', '⚠ $e', DateTime.now())));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _triggerSabotage(String type) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Trigger Sabotage: $type',
            style: const TextStyle(color: _red, fontSize: 14)),
        content: Text(
            'This will inject a "$type" sabotage event into the simulation. Continue?',
            style: const TextStyle(color: _text, fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('TRIGGER',
                style: TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final auth = ref.read(authProvider);
      final sessionId =
          auth is AuthLoggedIn ? auth.session.effectiveSessionId : 'default';
      final result = await ApiClient.instance
          .performSaboteurAction(sessionId: sessionId, actionType: type);
      if (mounted) {
        setState(() => _msgs.add(
            _Msg('assistant', '💥 Sabotage [$type]: $result', DateTime.now())));
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _msgs
            .add(_Msg('assistant', '⚠ Sabotage failed: $e', DateTime.now())));
        _scrollToBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final questions = _personaQuestions[_persona] ?? [];
    return Container(
      color: _bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: _surface,
            child: Row(
              children: [
                const Text('⬡', style: TextStyle(fontSize: 18, color: _cyan)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI ASSISTANT',
                          style: TextStyle(
                              fontSize: 11,
                              color: _cyan,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.bold)),
                      Text('Warehouse Intelligence',
                          style: TextStyle(fontSize: 8, color: _muted)),
                    ],
                  ),
                ),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _sessionId != null ? _green : _red,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _border),

          // ── Persona selector ─────────────────────────────────────────────────
          Container(
            height: 36,
            color: const Color(0xFF0A0F16),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              children: [
                for (final p in _personas) ...[
                  GestureDetector(
                    onTap: () => setState(() => _persona = p),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: _persona == p
                            ? _cyan.withAlpha(40)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _persona == p ? _cyan : _border,
                        ),
                      ),
                      child: Text(
                        p,
                        style: TextStyle(
                          fontSize: 9,
                          color: _persona == p ? _cyan : _muted,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: _border),

          // ── Chat messages ────────────────────────────────────────────────────
          Expanded(
            child: _msgs.isEmpty
                ? _ChatEmptyState(
                    persona: _persona,
                    questions: questions,
                    onTap: _send,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    itemCount: _msgs.length + (_sending ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == _msgs.length) {
                        return const Padding(
                          padding: EdgeInsets.only(left: 8, top: 4),
                          child: Row(children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5, color: _cyan),
                            ),
                            SizedBox(width: 8),
                            Text('Thinking…',
                                style: TextStyle(color: _muted, fontSize: 11)),
                          ]),
                        );
                      }
                      return _BubbleTile(_msgs[i]);
                    },
                  ),
          ),

          // ── Suggestion chips (shown when msgs exist) ─────────────────────────
          if (_msgs.isNotEmpty) ...[
            const Divider(height: 1, color: _border),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                children: [
                  for (final q in questions) ...[
                    GestureDetector(
                      onTap: () => _send(q),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _border),
                        ),
                        child: Text(q,
                            style: const TextStyle(fontSize: 8, color: _muted),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ],

          const Divider(height: 1, color: _border),

          // ── Sabotage accordion ───────────────────────────────────────────────
          if (widget.user != null && widget.user!.canSabotage) ...[
            GestureDetector(
              onTap: () =>
                  setState(() => _sabotageExpanded = !_sabotageExpanded),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: _red.withAlpha(15),
                child: Row(
                  children: [
                    const Text('💥', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 6),
                    const Text('SABOTAGE CONTROLS',
                        style: TextStyle(
                            fontSize: 9,
                            color: _red,
                            letterSpacing: 1,
                            fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Icon(
                      _sabotageExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: _red,
                    ),
                  ],
                ),
              ),
            ),
            if (_sabotageExpanded) ...[
              Container(
                color: _red.withAlpha(8),
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final s in _sabotageTypes)
                      GestureDetector(
                        onTap: () => _triggerSabotage(s),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _surface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _red.withAlpha(80)),
                          ),
                          child: Text(s,
                              style: const TextStyle(fontSize: 9, color: _red)),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),
            ],
          ],

          // ── Input bar ─────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: _surface,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    style: const TextStyle(fontSize: 12, color: _text),
                    decoration: InputDecoration(
                      hintText: 'Ask $_persona anything…',
                      hintStyle: const TextStyle(fontSize: 11, color: _muted),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      filled: true,
                      fillColor: _bg,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _cyan),
                      ),
                    ),
                    onSubmitted: _send,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.send, color: _cyan, size: 18),
                  tooltip: 'Send',
                  onPressed: () => _send(_ctrl.text),
                ),
                IconButton(
                  icon:
                      const Icon(Icons.delete_outline, color: _muted, size: 16),
                  tooltip: 'Clear chat',
                  onPressed: () => setState(() => _msgs.clear()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty chat state — persona icon + suggested question tiles ─────────────────

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({
    required this.persona,
    required this.questions,
    required this.onTap,
  });
  final String persona;
  final List<String> questions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (persona) {
      'Manager' => '🏭',
      'Supervisor' => '⚡',
      'Examiner' => '🎓',
      'Demo' => '🎯',
      _ => '🤖',
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(icon, style: const TextStyle(fontSize: 36)),
          const SizedBox(height: 8),
          Text('$persona Mode',
              style: const TextStyle(
                  fontSize: 13, color: _cyan, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Suggested questions:',
              style: TextStyle(fontSize: 9, color: _muted)),
          const SizedBox(height: 12),
          for (final q in questions) ...[
            GestureDetector(
              onTap: () => onTap(q),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border),
                ),
                child:
                    Text(q, style: const TextStyle(fontSize: 11, color: _text)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Chat bubble tile ──────────────────────────────────────────────────────────

class _BubbleTile extends StatelessWidget {
  const _BubbleTile(this.msg);
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _cyan.withAlpha(30),
                shape: BoxShape.circle,
                border: Border.all(color: _cyan.withAlpha(60)),
              ),
              child: const Center(
                  child: Text('⬡', style: TextStyle(fontSize: 10))),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  constraints: const BoxConstraints(maxWidth: 280),
                  decoration: BoxDecoration(
                    color: isUser ? _cyan.withAlpha(30) : _surface,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(12),
                      topRight: const Radius.circular(12),
                      bottomLeft: Radius.circular(isUser ? 12 : 2),
                      bottomRight: Radius.circular(isUser ? 2 : 12),
                    ),
                    border: Border.all(
                      color: isUser ? _cyan.withAlpha(60) : _border,
                    ),
                  ),
                  child: Text(msg.content,
                      style: TextStyle(
                          fontSize: 11, color: isUser ? _cyan : _text)),
                ),
                const SizedBox(height: 2),
                Text(
                  '${msg.ts.hour.toString().padLeft(2, '0')}:${msg.ts.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 8, color: _muted),
                ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 6),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// FLOOR CANVAS — pinch-zoom + right-click context menu
// ══════════════════════════════════════════════════════════════════════════════

class FloorCanvas extends ConsumerStatefulWidget {
  const FloorCanvas({super.key});

  @override
  ConsumerState<FloorCanvas> createState() => _FloorCanvasState();
}

class _FloorCanvasState extends ConsumerState<FloorCanvas>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  double _baseScale = 1.0;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;
  Offset? _hoverLocal;
  Size _canvasSize = Size.zero;

  // Blink animation for active events
  late final AnimationController _blinkCtrl;
  late final Animation<double> _blinkAnim;

  // Keyboard focus for arrow-key robot control
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _blinkAnim = CurvedAnimation(parent: _blinkCtrl, curve: Curves.easeInOut);
    // Re-launch the simulation if FloorCanvas mounts while ops are already
    // running but there is no active sim (e.g. user navigated away and back).
    // Only creates a new sim when one doesn't exist — avoids disposing a
    // running simulation on every rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final config = ref.read(warehouseConfigProvider);
      if (ref.read(operationsStartedProvider) &&
          ref.read(scoutSimulationProvider) == null &&
          config != null) {
        _launchSimulation(config);
      }
    });
  }

  @override
  void dispose() {
    _blinkCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Create and start a fresh [RobotScoutSimulation] for [config].
  /// Disposes any previous instance first so timers don't leak.
  /// In manual mode the step timer is immediately paused — bots only move
  /// when the user presses STEP.  The 30-second flush timer still runs so
  /// discoveries recorded via the STEP button reach the backend.
  void _launchSimulation(WarehouseConfig config) {
    final prevSim = ref.read(scoutSimulationProvider);
    prevSim?.dispose();
    final scout = RobotScoutSimulation(
      config: config,
      ref: ref,
      isSaboteur: false,
    );
    ref.read(scoutSimulationProvider.notifier).state = scout;
    // In manual mode never create the step timer — robots only move via STEP.
    // In auto mode start() creates both the step timer and the flush timer.
    if (ref.read(simulationModeProvider) == 'manual') {
      scout.startManual();
    } else {
      scout.start();
    }
  }

  /// Handle keyboard arrow keys → move selected robot one step.
  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ctrl = ref.read(manualRobotControllerProvider);
    if (ctrl == null) return KeyEventResult.ignored;
    final RobotMoveDirection? dir = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => RobotMoveDirection.up,
      LogicalKeyboardKey.arrowDown => RobotMoveDirection.down,
      LogicalKeyboardKey.arrowLeft => RobotMoveDirection.left,
      LogicalKeyboardKey.arrowRight => RobotMoveDirection.right,
      _ => null,
    };
    if (dir == null) return KeyEventResult.ignored;
    ctrl.moveSelected(dir);
    return KeyEventResult.handled;
  }

  // ── Hit-test: which grid cell is under the pointer ─────────────────────────
  ({int row, int col}) _cellAt(Offset localPos, Size canvasSize) {
    final config = ref.read(warehouseConfigProvider);
    final rows = config?.rows ?? 20;
    final cols = config?.cols ?? 30;
    final cw = (canvasSize.width / cols) * _scale;
    final ch = (canvasSize.height / rows) * _scale;
    final col = ((localPos.dx - _offset.dx) / cw).floor().clamp(0, cols - 1);
    final row = ((localPos.dy - _offset.dy) / ch).floor().clamp(0, rows - 1);
    return (row: row, col: col);
  }

  // ── Hit-test: which robot (if any) is under the tap ───────────────────────
  Robot? _robotAtLocal(Offset localPos, List<Robot> robots) {
    if (_canvasSize == Size.zero) return null;
    final config = ref.read(warehouseConfigProvider);
    final rows = config?.rows ?? 20;
    final cols = config?.cols ?? 30;
    final cw = (_canvasSize.width / cols) * _scale;
    final ch = (_canvasSize.height / rows) * _scale;
    final radius = (cw < ch ? cw : ch) * 0.5;
    for (final r in robots) {
      final cx = _offset.dx + (r.x + 0.5) * cw;
      final cy = _offset.dy + (r.y + 0.5) * ch;
      if ((localPos - Offset(cx, cy)).distance < radius) return r;
    }
    return null;
  }

  // ── Build smart context menu based on what is under the cursor ─────────────
  void _showContextMenu(BuildContext ctx, Offset globalPos, Offset localPos) {
    final RenderBox renderBox = ctx.findRenderObject() as RenderBox;
    final canvasSize = renderBox.size;
    final hit = _cellAt(localPos, canvasSize);

    final config = ref.read(warehouseConfigProvider);
    final frame = ref.read(simFrameProvider);
    final cell = config?.cellAt(hit.row, hit.col);
    final cellType = cell?.type ?? CellType.empty;

    // Robot at this cell?
    final robot = frame.robots
        .where(
          (r) => r.x.round() == hit.col && r.y.round() == hit.row,
        )
        .firstOrNull;

    final RenderBox overlay =
        Overlay.of(ctx).context.findRenderObject() as RenderBox;

    // ── Build menu items ──────────────────────────────────────────────────────
    final items = <PopupMenuEntry<String>>[];

    // ─── Section: what's here ──────────────────────────────────────────────
    final cellLabel =
        cellType == CellType.empty ? 'Empty Cell' : cellType.label;
    items.add(PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(
        '┌ ${robot != null ? robot.id : cellLabel} [${hit.col},${hit.row}]',
        style: const TextStyle(fontSize: 10, color: _muted),
      ),
    ));

    // ─── Robot actions ──────────────────────────────────────────────────────
    if (robot != null) {
      items.addAll([
        PopupMenuItem(
            value: 'robot_detail',
            child: _MenuItem(Icons.precision_manufacturing,
                'Inspect Robot: ${robot.id}', _cyan)),
        const PopupMenuItem(
            value: 'robot_charge',
            child: _MenuItem(
                Icons.battery_charging_full, 'Send to Charge', _yellow)),
        const PopupMenuItem(
            value: 'robot_pause',
            child: _MenuItem(Icons.pause_circle_outline, 'Pause Robot', _red)),
        const PopupMenuDivider(),
      ]);
    }

    // ─── Component-specific inspect actions ────────────────────────────────
    switch (cellType) {
      case CellType.rackLoose || CellType.rackCase || CellType.rackPallet:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_rack',
              child: _MenuItem(
                  Icons.view_agenda_outlined, 'View Rack / Bins', _cyan)),
          const PopupMenuItem(
              value: 'inspect_aisle',
              child: _MenuItem(Icons.grid_view, 'View Aisle', _text)),
          const PopupMenuItem(
              value: 'place_obstacle',
              child: _MenuItem(Icons.block, 'Place Obstacle', _red)),
        ]);
      case CellType.dock:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_dock',
              child: _MenuItem(
                  Icons.local_shipping_outlined, 'View Dock / Truck', _cyan)),
          const PopupMenuItem(
              value: 'inspect_packing',
              child: _MenuItem(
                  Icons.inventory_2_outlined, 'View Packing Progress', _text)),
        ]);
      case CellType.inbound:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_inbound',
              child: _MenuItem(Icons.input, 'View Inbound Queue', _cyan)),
          const PopupMenuItem(
              value: 'trigger_receiving',
              child: _MenuItem(
                  Icons.move_to_inbox, 'Trigger Receiving Task', _yellow)),
        ]);
      case CellType.outbound:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_outbound',
              child: _MenuItem(Icons.output, 'View Outbound Queue', _cyan)),
          const PopupMenuItem(
              value: 'trigger_dispatch',
              child:
                  _MenuItem(Icons.local_shipping, 'Trigger Dispatch', _yellow)),
        ]);
      case CellType.charging:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_charging',
              child: _MenuItem(Icons.bolt, 'View Charging Station', _yellow)),
          const PopupMenuItem(
              value: 'block_charger',
              child:
                  _MenuItem(Icons.power_off, 'Sabotage: Block Charger', _red)),
        ]);
      case CellType.packStation || CellType.labelStation:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_pack',
              child: _MenuItem(Icons.inventory, 'View Pack Station', _cyan)),
        ]);
      case CellType.looseStaging ||
            CellType.caseStaging ||
            CellType.palletStaging:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_staging',
              child: _MenuItem(Icons.storage, 'View Staging Area', _cyan)),
          const PopupMenuItem(
              value: 'trigger_wave',
              child: _MenuItem(Icons.waves, 'Trigger New Wave', _yellow)),
        ]);
      case CellType.aisle || CellType.crossAisle:
        items.addAll([
          const PopupMenuItem(
              value: 'inspect_aisle',
              child:
                  _MenuItem(Icons.view_column_outlined, 'View Aisle', _cyan)),
          const PopupMenuItem(
              value: 'place_obstacle',
              child: _MenuItem(Icons.block, 'Place Obstacle', _red)),
          const PopupMenuItem(
              value: 'scramble_path',
              child: _MenuItem(Icons.route, 'Scramble Path (Sabotage)', _red)),
        ]);
      case CellType.empty:
        // Add component sub-menu items
        items.add(const PopupMenuItem<String>(
          enabled: false,
          height: 24,
          child: Text('─── Place Component ───',
              style: TextStyle(fontSize: 9, color: _muted)),
        ));
        items.addAll([
          const PopupMenuItem(
              value: 'add_rackLoose',
              child: _MenuItem(Icons.view_agenda, 'Add Loose Rack', _text)),
          const PopupMenuItem(
              value: 'add_rackCase',
              child: _MenuItem(
                  Icons.view_agenda, 'Add Case Rack', Color(0xFF4ECDC4))),
          const PopupMenuItem(
              value: 'add_rackPallet',
              child: _MenuItem(
                  Icons.view_agenda, 'Add Pallet Rack', Color(0xFF45B7D1))),
          const PopupMenuItem(
              value: 'add_aisle',
              child: _MenuItem(Icons.horizontal_rule, 'Add Aisle', _muted)),
          const PopupMenuItem(
              value: 'add_dock',
              child: _MenuItem(
                  Icons.local_shipping, 'Add Truck Bay', Color(0xFF92400E))),
          const PopupMenuItem(
              value: 'add_charging',
              child: _MenuItem(Icons.bolt, 'Add Charging Station', _yellow)),
          const PopupMenuItem(
              value: 'add_packStation',
              child: _MenuItem(
                  Icons.inventory, 'Add Pack Station', Color(0xFFF97316))),
          const PopupMenuItem(
              value: 'add_inbound',
              child: _MenuItem(Icons.input, 'Add Inbound Zone', _green)),
          const PopupMenuItem(
              value: 'add_outbound',
              child: _MenuItem(
                  Icons.output, 'Add Outbound Zone', Color(0xFFFB923C))),
          const PopupMenuItem(
              value: 'add_obstacle',
              child: _MenuItem(Icons.block, 'Add Obstacle', _red)),
        ]);
      default:
        break;
    }

    // ─── Always-available view controls ────────────────────────────────────
    items.addAll([
      if (items.isNotEmpty) const PopupMenuDivider(),
      const PopupMenuItem(
          value: 'zoom_in', child: _MenuItem(Icons.zoom_in, 'Zoom In', _muted)),
      const PopupMenuItem(
          value: 'zoom_out',
          child: _MenuItem(Icons.zoom_out, 'Zoom Out', _muted)),
      const PopupMenuItem(
          value: 'reset',
          child: _MenuItem(Icons.fit_screen, 'Reset View', _muted)),
      const PopupMenuItem(
          value: 'wave', child: _MenuItem(Icons.waves, 'Trigger Wave', _cyan)),
    ]);

    showMenu<String>(
      context: ctx,
      color: _surface,
      position: RelativeRect.fromRect(
        globalPos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    ).then((val) => _handleMenuAction(val, hit.row, hit.col, ctx));
  }

  void _handleMenuAction(String? val, int row, int col, BuildContext ctx) {
    if (val == null) return;
    switch (val) {
      // View controls
      case 'zoom_in':
        setState(() => _scale = (_scale * 1.3).clamp(0.4, 8.0));
      case 'zoom_out':
        setState(() => _scale = (_scale / 1.3).clamp(0.4, 8.0));
      case 'reset':
        setState(() {
          _scale = 1.0;
          _offset = Offset.zero;
        });
      case 'wave' || 'trigger_wave':
        ApiClient.instance.triggerWave();

      // Place component on empty cell
      case String s when s.startsWith('add_'):
        final typeName = s.substring(4);
        final type = CellType.values.firstWhere((t) => t.name == typeName,
            orElse: () => CellType.empty);
        if (type != CellType.empty) {
          final current = ref.read(warehouseConfigProvider);
          if (current != null) {
            ref.read(warehouseConfigProvider.notifier).state =
                current.setCell(WarehouseCell(row: row, col: col, type: type));
          }
        }

      // Sabotage / manual actions
      case 'trigger_receiving' || 'trigger_dispatch':
        ApiClient.instance.triggerWave();
      case 'scramble_path':
        _showSnack(ctx, 'Scramble path queued — robots rerouting');
        ref.read(manualModeProvider.notifier).addCustomEvent(
              'Scramble Path',
              'Aisle blocked at [$col,$row] — robots rerouting around obstacle',
            );
      case 'block_charger':
        _showSnack(ctx, 'Charger sabotage queued');
        ref.read(manualModeProvider.notifier).addCustomEvent(
              'Block Charger',
              'Charging station at [$col,$row] is offline — robots redirected',
            );
      case 'place_obstacle':
        final current = ref.read(warehouseConfigProvider);
        if (current != null) {
          // Update local config so the cell renders immediately as an obstacle.
          ref.read(warehouseConfigProvider.notifier).state = current.setCell(
              WarehouseCell(row: row, col: col, type: CellType.obstacle));
          // Persist the obstruction to the Reality DB so the simulation engine
          // and all other connected clients see it.
          final warehouseId = current.id;
          ApiClient.instance
              .placeObstacle(
            warehouseId: warehouseId,
            row: row,
            col: col,
            blockerType: 'TEMPORARY',
            obstacleLabel: 'Saboteur block @ R${row}C$col',
            durationSeconds: 300,
          )
              .then((_) {
            // Refresh the blocked-cells set so FloorPainter shows the overlay.
            ref.read(blockedCellsProvider.notifier).addLocal(row, col);
          }).catchError((_) {
            // Best-effort — local visual is already placed.
          });
        }

      // Inspect drill-in — show bottom sheet with detail
      case String s when s.startsWith('inspect_') || s == 'robot_detail':
        _showInspectSheet(ctx, val, row, col);
    }
  }

  void _showInspectSheet(BuildContext ctx, String action, int row, int col) {
    final frame = ref.read(simFrameProvider);
    final config = ref.read(warehouseConfigProvider);
    final cell = config?.cellAt(row, col);
    final robot = frame.robots
        .where((r) => r.x.round() == col && r.y.round() == row)
        .firstOrNull;

    showModalBottomSheet(
      context: ctx,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => _CellInspectSheet(
          row: row, col: col, cell: cell, robot: robot, frame: frame),
    );
  }

  void _showSnack(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 11)),
      backgroundColor: _surface,
      duration: const Duration(seconds: 2),
    ));
  }

  // ── Hover tooltip ─────────────────────────────────────────

  Widget _buildHoverTooltip(
      WarehouseConfig? config, List<Robot> displayRobots) {
    final cell = _cellAt(_hoverLocal!, _canvasSize);
    final wCell = config?.cells
        .where((c) => c.row == cell.row && c.col == cell.col)
        .firstOrNull;
    final zone = config?.zoneForCell(cell.row, cell.col);
    final colLetter =
        cell.col < 26 ? String.fromCharCode(65 + cell.col) : '${cell.col}';
    final typeName = wCell != null
        ? wCell.type.label
        : (zone != null ? zone.label : 'Empty');

    const hdrStyle = TextStyle(
        fontSize: 11,
        color: Color(0xFFE6EDF3),
        fontWeight: FontWeight.bold,
        fontFamily: 'ShareTechMono');
    const mutedStyle = TextStyle(
        fontSize: 10, color: Color(0xFF8B949E), fontFamily: 'ShareTechMono');
    const cyanStyle = TextStyle(
        fontSize: 10,
        color: Color(0xFF00D4FF),
        fontFamily: 'ShareTechMono',
        fontWeight: FontWeight.w600);
    const greenStyle = TextStyle(
        fontSize: 10, color: Color(0xFF4ADE80), fontFamily: 'ShareTechMono');
    const yellowStyle = TextStyle(
        fontSize: 10, color: Color(0xFFF97316), fontFamily: 'ShareTechMono');

    final lines = <Widget>[
      Text('[$colLetter${cell.row + 1}]  $typeName', style: hdrStyle),
    ];
    if (zone != null) {
      lines.add(Text('Zone: ${zone.label}', style: mutedStyle));
    }
    if (wCell != null && wCell.type.isRack) {
      final unitLabel = switch (wCell.type) {
        CellType.rackPallet => 'Pallets',
        CellType.rackCase => 'Cases',
        CellType.rackLoose => 'Units',
        _ => 'Stock',
      };
      if (wCell.skuId != null) {
        final pct = (wCell.fillFraction * 100).round();
        lines.add(Text('SKU: ${wCell.skuId}', style: cyanStyle));
        final qtyStyle = pct < 50 ? yellowStyle : greenStyle;
        lines.add(Text(
            '$unitLabel: ${wCell.quantity}/${wCell.maxQuantity}  ($pct%)',
            style: qtyStyle));
      } else {
        lines.add(const Text('SKU: — empty —', style: mutedStyle));
        lines
            .add(Text('$unitLabel: 0/${wCell.maxQuantity}', style: mutedStyle));
      }
      if (wCell.levels > 1) {
        lines.add(Text('Levels: ${wCell.levels}', style: mutedStyle));
      }
    } else if (wCell != null) {
      if (wCell.destId != null) {
        lines.add(Text('Dest: ${wCell.destId}', style: mutedStyle));
      }
    }
    final robotsHere = displayRobots
        .where((r) => r.x.round() == cell.col && r.y.round() == cell.row)
        .toList();
    if (robotsHere.isNotEmpty) {
      lines.add(Text('🤖 ${robotsHere.map((r) => r.name).join(', ')}',
          style: mutedStyle));
    }
    if (wCell == null || wCell.type == CellType.empty) {
      lines.add(const Text('(empty)', style: mutedStyle));
    }
    final tipX = _hoverLocal!.dx + 12;
    final tipY = _hoverLocal!.dy - 8;
    return Positioned(
      left: tipX.clamp(0, _canvasSize.width - 200),
      top: tipY.clamp(0, _canvasSize.height - 100),
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22).withAlpha(240),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: lines,
          ),
        ),
      ),
    );
  }

  // ── Speech bubble overlay ──────────────────────────────────────

  List<Widget> _buildSpeechBubbles(
      List<SpeechBubble> bubbles, WarehouseConfig? config) {
    if (_canvasSize == Size.zero) return const [];
    final rows = config?.rows ?? 20;
    final cols = config?.cols ?? 30;
    final cw = (_canvasSize.width / cols) * _scale;
    final ch = (_canvasSize.height / rows) * _scale;
    return bubbles.map((b) {
      final px = _offset.dx + (b.col + 0.5) * cw;
      final py = _offset.dy + b.row * ch - 4;
      return Positioned(
        left: (px - 70).clamp(0, _canvasSize.width - 148),
        top: (py - 46).clamp(0, _canvasSize.height - 52),
        child: IgnorePointer(
          child: SpeechBubbleWidget(text: b.text),
        ),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final frame = ref.watch(simFrameProvider);
    final config = ref.watch(warehouseConfigProvider);
    final opsStarted = ref.watch(operationsStartedProvider);
    final exploredCells = ref.watch(exploredCellsProvider);
    final activeEvents = ref.watch(activeEventsProvider);
    final blockedCells = ref.watch(blockedCellsProvider);
    final simMode = ref.watch(simulationModeProvider);
    final sim = ref.watch(scoutSimulationProvider);
    final manualPositions = ref.watch(manualRobotPositionsProvider);
    final selectedRobotId = ref.watch(selectedRobotIdProvider);
    final manualCtrl = ref.watch(manualRobotControllerProvider);

    // In manual mode use locally-tracked positions; otherwise WS frame / spawns.
    final List<Robot> displayRobots;
    if (opsStarted && simMode == 'manual' && manualPositions.isNotEmpty) {
      displayRobots = manualPositions.entries
          .map((e) => Robot(
                id: e.key,
                name: e.key,
                type: e.key.toLowerCase().contains('agv') ? 'AGV' : 'AMR',
                x: e.value.col.toDouble(),
                y: e.value.row.toDouble(),
                state: selectedRobotId == e.key ? 'SELECTED' : 'IDLE',
                battery: 1.0,
              ))
          .toList();
    } else {
      displayRobots = frame.robots.isNotEmpty
          ? frame.robots
          : (config?.robotSpawns
                  .map((s) => Robot(
                        id: s.name ?? s.robotType,
                        name: s.name ?? s.robotType,
                        type: s.robotType,
                        x: s.col.toDouble(),
                        y: s.row.toDouble(),
                        state: 'IDLE',
                        battery: 1.0,
                      ))
                  .toList() ??
              []);
    }

    // Request keyboard focus so arrow keys work immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      autofocus: true,
      child: Column(
        children: [
          // ── Step toolbar — above the canvas, never overlays the floor ──
          if (opsStarted && simMode == 'manual' && sim != null)
            Container(
              height: 36,
              color: _surface,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Tooltip(
                    message: 'Advance all robots one step',
                    child: TextButton.icon(
                      onPressed: () => sim.step(),
                      icon: const Icon(Icons.skip_next_rounded, size: 16),
                      label: const Text('STEP',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                      style: TextButton.styleFrom(foregroundColor: _cyan),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Switch to Automated — robots run continuously',
                    child: TextButton.icon(
                      onPressed: () {
                        ref.read(simulationModeProvider.notifier).state =
                            'automated';
                        sim.start();
                      },
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      label: const Text('AUTO', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(foregroundColor: _muted),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'MANUAL STEP MODE',
                    style: TextStyle(
                        fontSize: 9,
                        color: _cyan.withAlpha(150),
                        letterSpacing: 1.5),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(builder: (_, constraints) {
              _canvasSize = constraints.biggest;
              return MouseRegion(
                onHover: (e) => setState(() => _hoverLocal = e.localPosition),
                onExit: (_) => setState(() => _hoverLocal = null),
                // Stack sits OUTSIDE the GestureDetector so D-pad and overlay buttons
                // receive clean pointer events without competing with the scale recognizer.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // ── Floor canvas: all zoom/pan/tap gestures scoped to canvas only ──
                    Positioned.fill(
                      child: GestureDetector(
                        onScaleStart: (d) {
                          _baseScale = _scale;
                          _startFocal = d.focalPoint;
                          _startOffset = _offset;
                        },
                        onScaleUpdate: (d) {
                          setState(() {
                            _scale = (_baseScale * d.scale).clamp(0.4, 8.0);
                            _offset =
                                _startOffset + (d.focalPoint - _startFocal);
                          });
                        },
                        onSecondaryTapUp: (d) {
                          final box = context.findRenderObject() as RenderBox;
                          final localPos = box.globalToLocal(d.globalPosition);
                          _showContextMenu(context, d.globalPosition, localPos);
                        },
                        onTapUp: (d) {
                          // Tap a robot to select it for D-pad control.
                          final hit =
                              _robotAtLocal(d.localPosition, displayRobots);
                          if (hit != null) {
                            ref.read(selectedRobotIdProvider.notifier).state =
                                hit.id;
                            manualCtrl?.selectRobot(hit.id);
                          } else if (!(opsStarted && simMode == 'manual')) {
                            ref.read(selectedRobotIdProvider.notifier).state =
                                null;
                          }
                        },
                        child: ClipRect(
                          child: AnimatedBuilder(
                            animation: _blinkAnim,
                            builder: (_, __) => CustomPaint(
                              painter: FloorPainter(
                                robots: opsStarted ? displayRobots : const [],
                                orders: frame.orders,
                                rows: config?.rows ?? 20,
                                cols: config?.cols ?? 30,
                                scale: _scale,
                                offset: _offset,
                                warehouseConfig:
                                    config, // always draw layout as preview
                                exploredCells:
                                    opsStarted ? exploredCells : const {},
                                activeEvents: activeEvents,
                                blinkPhase: _blinkAnim.value,
                                selectedRobotId: selectedRobotId,
                                blockedCells:
                                    opsStarted ? blockedCells : const {},
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Pre-ops overlay: shown until user starts operations ─────
                    if (!opsStarted && config != null)
                      _buildStartOpsOverlay(config),

                    // ── D-pad: manual robot control ───────────────────────────
                    if (opsStarted && simMode == 'manual' && manualCtrl != null)
                      Positioned(
                        bottom: 24,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: DPadControls(
                            controller: manualCtrl,
                            selectedRobotId: selectedRobotId,
                          ),
                        ),
                      ),

                    // ── Scout progress badge ─────────────────────────────────
                    if (opsStarted &&
                        exploredCells.isNotEmpty &&
                        config != null)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: ScoutProgressBadge(
                          explored: exploredCells.length,
                          total: config.rows * config.cols,
                          simMode: simMode,
                        ),
                      ),

                    if (_hoverLocal != null)
                      _buildHoverTooltip(config, displayRobots),
                    ..._buildSpeechBubbles(
                        ref.watch(speechBubbleProvider), config),
                  ],
                ), // Stack
              ); // MouseRegion
            }), // LayoutBuilder
          ), // Expanded
        ],
      ), // Column
    ); // Focus
  }

  // ── Start-ops overlay shown before the user starts operations ─────────────
  Widget _buildStartOpsOverlay(WarehouseConfig config) {
    return Positioned.fill(
      child: Container(
        color: const Color(0xFF0A0F14),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warehouse_outlined,
                  size: 52, color: Color(0xFF00D4FF)),
              const SizedBox(height: 20),
              const Text(
                'WAREHOUSE READY',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE6EDF3),
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Robots are standing by. Start operations to begin scouting.',
                style: TextStyle(fontSize: 12, color: Color(0xFF8B949E)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00D4FF),
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('START OPERATIONS',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                onPressed: () {
                  ref.read(simulationModeProvider.notifier).state = 'manual';
                  ref.read(exploredCellsProvider.notifier).reset();
                  ref.read(activeEventsProvider.notifier).resolveAll();
                  ref.read(blockedCellsProvider.notifier).reset();
                  ref.read(operationsStartedProvider.notifier).state = true;
                  ref
                      .read(manualRobotControllerProvider.notifier)
                      .initialize(config);
                  // Seed the blocked-cells overlay from the backend.
                  ref.read(blockedCellsProvider.notifier).refresh(config.id);
                  // Create the simulation (needed for the STEP button and
                  // the 30-second backend flush) but keep it paused so bots
                  // only move when the user presses STEP.
                  _launchSimulation(config);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable menu item row ────────────────────────────────────────────────────

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.icon, this.label, this.color);
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 12, color: color)),
        ],
      );
}

// ── Cell inspect bottom sheet ─────────────────────────────────────────────────

class _CellInspectSheet extends StatelessWidget {
  const _CellInspectSheet({
    required this.row,
    required this.col,
    required this.cell,
    required this.robot,
    required this.frame,
  });
  final int row, col;
  final WarehouseCell? cell;
  final Robot? robot;
  final SimFrame frame;

  @override
  Widget build(BuildContext context) {
    final cellType = cell?.type ?? CellType.empty;
    final label = cell?.label ?? '';

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            Container(
              width: 16,
              height: 16,
              decoration:
                  BoxDecoration(color: cellType.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(cellType.label,
                style: const TextStyle(
                    fontSize: 15, color: _cyan, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('[$col, $row]',
                style: const TextStyle(fontSize: 10, color: _muted)),
          ]),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: _muted)),
          ],
          const Divider(color: _border, height: 20),

          // Robot info
          if (robot != null) ...[
            _SheetRow('Robot', robot!.id, _cyan),
            _SheetRow('State', robot!.state, _yellow),
            _SheetRow(
                'Battery', '${robot!.battery.toStringAsFixed(0)}%', _green),
            _SheetRow('Type', robot!.type, _muted),
            const Divider(color: _border, height: 20),
          ],

          // Cell-type specifics
          if (cellType.isRack) ...[
            _SheetRow('Zone', cell?.label ?? 'Unassigned', _muted),
            _SheetRow('Levels', '${cell?.levels ?? 1}', _text),
            _SheetRow(
              'SKU',
              cell?.skuId ?? '— empty —',
              cell?.skuId != null ? _cyan : _muted,
            ),
            if (cell != null) ...[
              _SheetRow(
                'Stock',
                cell!.quantity == 0
                    ? 'Empty'
                    : '${cell!.quantity} / ${cell!.maxQuantity}'
                        '  (${(cell!.fillFraction * 100).round()}%)',
                cell!.quantity == 0
                    ? _muted
                    : cell!.needsReplenishment
                        ? _yellow
                        : _green,
              ),
              if (cell!.needsReplenishment && cell!.quantity > 0)
                const _SheetRow(
                    '⚠ Replenishment', 'below 50% capacity', Color(0xFFF97316)),
              if (cell!.isEmpty)
                const _SheetRow('', 'No stock on hand', _muted),
            ],
            const SizedBox(height: 8),
            const Text('→ Use Craft tab to adjust rack height / type',
                style: TextStyle(
                    fontSize: 10, color: _muted, fontStyle: FontStyle.italic)),
          ],
          if (cellType == CellType.dock) ...[
            _SheetRow('Bay', '#$col', _muted),
            // In a real integration: fetch truck at dock from API
            const _SheetRow('Status', 'Live data via API', _muted),
          ],
          if (cellType == CellType.charging) ...[
            const _SheetRow('Capacity', '1 robot at a time', _muted),
            _SheetRow('Robots near by', () {
              final nearby = frame.robots
                  .where((r) => (r.x - col).abs() + (r.y - row).abs() < 3)
                  .map((r) => r.id)
                  .join(', ');
              return nearby.isEmpty ? 'none' : nearby;
            }(), _yellow),
          ],
          if (cellType == CellType.inbound ||
              cellType == CellType.outbound) ...[
            _SheetRow(
                'Orders pending',
                '${frame.orders.where((o) => o.status == 'PENDING').length}',
                _cyan),
          ],

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow(this.key_, this.value, this.color);
  final String key_, value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
                width: 110,
                child: Text(key_,
                    style: const TextStyle(fontSize: 11, color: _muted))),
            Expanded(
                child:
                    Text(value, style: TextStyle(fontSize: 11, color: color))),
          ],
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// MOBILE LANDSCAPE
// ══════════════════════════════════════════════════════════════════════════════

class _MobileLandscapeLayout extends StatefulWidget {
  const _MobileLandscapeLayout({
    required this.frame,
    required this.user,
    required this.level,
    required this.selectedIndex,
    required this.destinations,
    required this.onNavTap,
    required this.onTutorial,
  });
  final SimFrame frame;
  final WoisUser? user;
  final int level, selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onNavTap;
  final VoidCallback onTutorial;

  @override
  State<_MobileLandscapeLayout> createState() => _MobileLandscapeLayoutState();
}

class _MobileLandscapeLayoutState extends State<_MobileLandscapeLayout> {
  bool _panelOpen = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          const Positioned.fill(child: FloorCanvas()),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _LandscapeAppBar(
              frame: widget.frame,
              user: widget.user,
              onMenu: () => setState(() => _panelOpen = !_panelOpen),
              panelOpen: _panelOpen,
              onTutorial: widget.onTutorial,
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInOut,
            top: 0,
            bottom: 0,
            right: _panelOpen ? 0 : -320,
            width: 320,
            child: Container(
              color: _bg,
              child: SafeArea(
                child: _RightChatPanel(user: widget.user),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _MobileBottomBar(
              selectedIndex: widget.selectedIndex,
              destinations: widget.destinations,
              onTap: widget.onNavTap,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MOBILE PORTRAIT
// ══════════════════════════════════════════════════════════════════════════════

class _MobilePortraitLayout extends ConsumerWidget {
  const _MobilePortraitLayout({
    required this.frame,
    required this.user,
    required this.level,
    required this.selectedIndex,
    required this.destinations,
    required this.onNavTap,
    required this.onTutorial,
  });
  final SimFrame frame;
  final WoisUser? user;
  final int level, selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onNavTap;
  final VoidCallback onTutorial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget body = switch (selectedIndex) {
      1 => const FloorCanvas(),
      2 => _RightChatPanel(user: user),
      3 => const AboutScreen(),
      4 => const CommunityScreen(),
      5 => const GameScreen(),
      _ => Column(
          children: [
            _TickerStrip(frame: frame),
            Expanded(child: _DataTabs(frame: frame, user: user)),
            _SyncBarsStrip(frame: frame),
          ],
        ),
    };
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        title: _AppBarTitle(frame: frame),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, size: 18),
            tooltip: 'Tutorial',
            onPressed: onTutorial,
          ),
          if (user != null) _UserAvatar(user: user!),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: _MobileBottomBar(
        selectedIndex: selectedIndex,
        destinations: destinations,
        onTap: onNavTap,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SHARED NAVIGATION COMPONENTS
// ══════════════════════════════════════════════════════════════════════════════

class _NavRail extends ConsumerWidget {
  const _NavRail({
    required this.selectedIndex,
    required this.destinations,
    required this.onTap,
    required this.user,
    required this.onTutorial,
  });
  final int selectedIndex;
  final List<NavigationRailDestination> destinations;
  final ValueChanged<int> onTap;
  final WoisUser? user;
  final VoidCallback onTutorial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: _bg,
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: selectedIndex.clamp(0, destinations.length - 1),
        onDestinationSelected: onTap,
        labelType: NavigationRailLabelType.all,
        selectedLabelTextStyle:
            const TextStyle(color: _cyan, fontSize: 9, letterSpacing: 1),
        unselectedLabelTextStyle: const TextStyle(color: _muted, fontSize: 9),
        selectedIconTheme: const IconThemeData(color: _cyan, size: 20),
        unselectedIconTheme: const IconThemeData(color: _muted, size: 20),
        leading: Column(
          children: [
            const SizedBox(height: 8),
            GestureDetector(
              onTap: onTutorial,
              child:
                  const Text('⬡', style: TextStyle(fontSize: 22, color: _cyan)),
            ),
            const SizedBox(height: 4),
          ],
        ),
        trailing: Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (user != null) ...[
                    _SimStatusDot(),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => _showUserMenu(context, ref),
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: _cyan.withAlpha(40),
                        child: Text(
                          (user!.name.isNotEmpty ? user!.name[0] : '?')
                              .toUpperCase(),
                          style: const TextStyle(color: _cyan, fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        destinations: destinations,
      ),
    );
  }

  void _showUserMenu(BuildContext ctx, WidgetRef ref) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: _surface,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user?.name ?? '',
                style: const TextStyle(fontSize: 16, color: Colors.white)),
            Text(user?.email ?? '',
                style: const TextStyle(fontSize: 11, color: _muted)),
            Text('Role: ${user?.role ?? '-'} (L${user?.level ?? 1})',
                style: const TextStyle(fontSize: 11, color: _cyan)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.help_outline, color: _cyan),
              title: const Text('Replay tour', style: TextStyle(color: _cyan)),
              onTap: () {
                Navigator.pop(ctx);
                TutorialController.show(ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: _red),
              title: const Text('Sign out', style: TextStyle(color: _red)),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(authProvider.notifier).logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileBottomBar extends StatelessWidget {
  const _MobileBottomBar({
    required this.selectedIndex,
    required this.destinations,
    required this.onTap,
  });
  final int selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => NavigationBar(
        backgroundColor: _surface,
        indicatorColor: _cyan.withAlpha(40),
        selectedIndex: selectedIndex.clamp(0, destinations.length - 1),
        onDestinationSelected: onTap,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: destinations,
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// SMALL SHARED WIDGETS
// ══════════════════════════════════════════════════════════════════════════════

class _CtrlButton extends StatelessWidget {
  const _CtrlButton(this.label, this.color, this.onPressed);
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 32,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: color.withAlpha(100)),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(fontSize: 9, letterSpacing: 0.5),
          ),
          child: Text(label),
        ),
      );
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'RUNNING' => _green,
      'PAUSED' => _yellow,
      _ => _red,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(status,
              style: TextStyle(fontSize: 9, color: color, letterSpacing: 1)),
        ],
      ),
    );
  }
}

class _SimStatusDot extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frame = ref.watch(simFrameProvider);
    final color = switch (frame.simStatus) {
      'RUNNING' => _green,
      'PAUSED' => _yellow,
      _ => _red,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            style: const TextStyle(color: _muted, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
      );
}

class _RowTile extends StatelessWidget {
  const _RowTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });
  final Widget leading, trailing;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 11, color: _text),
                      overflow: TextOverflow.ellipsis),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 9, color: _muted)),
                ],
              ),
            ),
            trailing,
          ],
        ),
      );
}

class _AppBarTitle extends StatelessWidget {
  const _AppBarTitle({required this.frame});
  final SimFrame frame;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⬡ WOIS',
              style: TextStyle(color: _cyan, letterSpacing: 1)),
          const SizedBox(width: 8),
          _StatusBadge(frame.simStatus),
        ],
      );
}

class _UserAvatar extends ConsumerWidget {
  const _UserAvatar({required this.user});
  final WoisUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GestureDetector(
        onTap: () => showModalBottomSheet(
          context: context,
          backgroundColor: _surface,
          builder: (_) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.name,
                    style: const TextStyle(fontSize: 16, color: Colors.white)),
                Text(user.email,
                    style: const TextStyle(fontSize: 11, color: _muted)),
                Text('Role: ${user.role} (L${user.level})',
                    style: const TextStyle(fontSize: 11, color: _cyan)),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.logout, color: _red),
                  title: const Text('Sign out', style: TextStyle(color: _red)),
                  onTap: () {
                    Navigator.pop(context);
                    ref.read(authProvider.notifier).logout();
                  },
                ),
              ],
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: CircleAvatar(
            radius: 15,
            backgroundColor: _cyan.withAlpha(40),
            child: Text(
              (user.name.isNotEmpty ? user.name[0] : '?').toUpperCase(),
              style: const TextStyle(color: _cyan, fontSize: 12),
            ),
          ),
        ),
      );
}

class _LandscapeAppBar extends StatelessWidget {
  const _LandscapeAppBar({
    required this.frame,
    required this.user,
    required this.onMenu,
    required this.panelOpen,
    required this.onTutorial,
  });
  final SimFrame frame;
  final WoisUser? user;
  final VoidCallback onMenu, onTutorial;
  final bool panelOpen;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        color: _bg.withAlpha(220),
        child: SafeArea(
          child: Row(
            children: [
              const Text('⬡ WOIS',
                  style:
                      TextStyle(color: _cyan, fontSize: 14, letterSpacing: 2)),
              const SizedBox(width: 10),
              _StatusBadge(frame.simStatus),
              const SizedBox(width: 6),
              Text('WAVE ${frame.waveNumber}',
                  style: const TextStyle(
                      fontSize: 9, color: _muted, letterSpacing: 1)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.help_outline, size: 16, color: _muted),
                onPressed: onTutorial,
              ),
              IconButton(
                icon: Icon(
                  panelOpen ? Icons.close : Icons.chat_bubble_outline,
                  size: 16,
                  color: _cyan,
                ),
                onPressed: onMenu,
              ),
            ],
          ),
        ),
      );
}

// ── Message model ─────────────────────────────────────────────────────────────

@immutable
class _Msg {
  const _Msg(this.role, this.content, this.ts);
  final String role, content;
  final DateTime ts;
}
