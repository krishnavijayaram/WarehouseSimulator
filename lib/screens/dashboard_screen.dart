/// dashboard_screen.dart â€” Main hub screen showing KPIs, robot list, and nav.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/api_client.dart';
import '../core/auth/auth_provider.dart';
import '../core/sim_ws.dart';
import '../models/sim_frame.dart';
import '../widgets/kpi_card.dart';
import '../widgets/robot_card.dart';
import '../widgets/connection_banner.dart';
import '../widgets/wms_dashboard_panel.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final frame = ref.watch(simFrameProvider);


    final user = auth is AuthLoggedIn ? auth.user : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('â¬¡ WAREHOUSE AI SIM'),
        actions: [
          // Status badge
          Center(child: _StatusBadge(frame.simStatus)),
          const SizedBox(width: 8),
          // Wave badge
          Center(child: _WaveBadge(frame.waveNumber)),
          const SizedBox(width: 8),
          // User avatar
          if (user != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: GestureDetector(
                onTap: () => _showUserMenu(context, ref),
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: const Color(0xFF00D4FF).withAlpha(40),
                  child: Text(
                    (user.name.isNotEmpty ? user.name[0] : '?').toUpperCase(),
                    style:
                        const TextStyle(color: Color(0xFF00D4FF), fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Connection banner
          const ConnectionBanner(),

          Expanded(
            child: RefreshIndicator(
              color: const Color(0xFF00D4FF),
              onRefresh: () async {/* WS auto-updates â€” nothing to pull */},
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // â”€â”€ KPIs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    const _SectionHeader('KPIs'),
                    _KpiGrid(frame.kpi),
                    const SizedBox(height: 16),

                    // â”€â”€ Sim controls â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    const _SectionHeader('Simulation'),
                    _SimControls(frame.simStatus),
                    const SizedBox(height: 16),

                    // â”€â”€ Self-healing events (D4) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    if (frame.selfHealingEvents.isNotEmpty) ...[
                      const _SectionHeader('Self-Healing Events'),
                      ...frame.selfHealingEvents.take(3).map(
                            (e) => _SelfHealTile(e),
                          ),
                      const SizedBox(height: 16),
                    ],

                    // â”€â”€ Layout proposals (D5) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    if (user != null && user.canAdmin)
                      _PendingProposals(frame.layoutProposals),
                    // â”€â”€ Scouting progress + WMS inventory â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    const WmsDashboardPanel(),
                    // â”€â”€ Robots â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                    _SectionHeader('Fleet (${frame.robots.length} robots)'),
                    ...frame.robots.map((r) => RobotCard(robot: r)),
                    const SizedBox(height: 80), // nav bar padding
                  ],
                ),
              ),
            ),
          ),
        ],
      ),

      // â”€â”€ Bottom navigation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
      bottomNavigationBar: _BottomNav(user: user),
    );
  }

  void _showUserMenu(BuildContext ctx, WidgetRef ref) {
    final auth = ref.read(authProvider);
    final user = auth is AuthLoggedIn ? auth.user : null;
    showModalBottomSheet(
      context: ctx,
      backgroundColor: const Color(0xFF161B22),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user?.name ?? '',
                style: const TextStyle(fontSize: 16, color: Colors.white)),
            Text(user?.email ?? '',
                style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E))),
            Text('Role: ${user?.role ?? '-'} (L${user?.level ?? 1})',
                style: const TextStyle(fontSize: 11, color: Color(0xFF00D4FF))),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFFFF4444)),
              title: const Text('Sign out',
                  style: TextStyle(color: Color(0xFFFF4444))),
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

// â”€â”€ KPI grid â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _KpiGrid extends StatelessWidget {
  const _KpiGrid(this.kpi);
  final KpiSnapshot kpi;

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 2.2,
        children: [
          KpiCard(
              label: 'Orders Done',
              value: '${kpi.ordersDone}',
              accent: const Color(0xFF00FF88)),
          KpiCard(
              label: 'Active Bots',
              value: '${kpi.activeBots}',
              accent: const Color(0xFF00D4FF)),
          KpiCard(
              label: 'Conflicts',
              value: '${kpi.conflicts}',
              accent: const Color(0xFFFF4444)),
          KpiCard(
              label: 'Efficiency',
              value: kpi.efficiencyLabel,
              accent: const Color(0xFFFFCC00)),
          KpiCard(
            label: 'Detection Latency',
            value: kpi.detectionLatencyMs != null
                ? '${kpi.detectionLatencyMs!.toStringAsFixed(0)} ms'
                : 'â€”',
            accent: const Color(0xFFAA88FF),
            fullWidth: true,
          ),
        ],
      );
}

// â”€â”€ Sim controls â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _SimControls extends StatelessWidget {
  const _SimControls(this.status);
  final String status;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          _CtrlBtn('â–¶ NEW WAVE', const Color(0xFF00D4FF),
              () => ApiClient.instance.triggerWave()),
          const SizedBox(width: 8),
          _CtrlBtn(
            status == 'RUNNING' ? 'â¸ PAUSE' : 'â–¶ RESUME',
            const Color(0xFFFFCC00),
            () => status == 'RUNNING'
                ? ApiClient.instance.pauseSim()
                : ApiClient.instance.resumeSim(),
          ),
        ],
      );
}

class _CtrlBtn extends StatelessWidget {
  const _CtrlBtn(this.label, this.color, this.onPressed);
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withAlpha(100)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: const TextStyle(fontFamily: 'ShareTechMono', fontSize: 11),
        ),
        child: Text(label),
      );
}

// â”€â”€ Self-heal tile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _SelfHealTile extends StatelessWidget {
  const _SelfHealTile(this.event);
  final SelfHealEvent event;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          leading: const Text('âš¡', style: TextStyle(fontSize: 18)),
          title: Text(event.description, style: const TextStyle(fontSize: 12)),
          subtitle: Text(event.type,
              style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E))),
        ),
      );
}

// â”€â”€ Layout proposal tile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _ProposalTile extends StatelessWidget {
  const _ProposalTile(this.proposal);
  final LayoutProposal proposal;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          leading: const Text('ðŸ—º', style: TextStyle(fontSize: 18)),
          title:
              Text(proposal.description, style: const TextStyle(fontSize: 12)),
          subtitle: Text(
            '+${proposal.gainPercent.toStringAsFixed(1)}% efficiency gain',
            style: const TextStyle(fontSize: 10, color: Color(0xFF00FF88)),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon:
                    const Icon(Icons.check, color: Color(0xFF00FF88), size: 20),
                onPressed: () =>
                    ApiClient.instance.approveProposal(proposal.id),
              ),
              IconButton(
                icon:
                    const Icon(Icons.close, color: Color(0xFFFF4444), size: 20),
                onPressed: () => ApiClient.instance.rejectProposal(proposal.id),
              ),
            ],
          ),
        ),
      );
}

// â”€â”€ Pending proposals summary widget â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _PendingProposals extends StatelessWidget {
  const _PendingProposals(this.proposals);
  final List<LayoutProposal> proposals;

  @override
  Widget build(BuildContext context) {
    final pending = proposals.where((p) => p.isPending).toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Layout Proposals (${pending.length} pending)'),
        ...pending.map((p) => _ProposalTile(p)),
        const SizedBox(height: 16),
      ],
    );
  }
}

// â”€â”€ Section header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 9,
            letterSpacing: 1.5,
            color: Color(0xFF8B949E),
          ),
        ),
      );
}

// â”€â”€ Status badges â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'RUNNING' => const Color(0xFF00FF88),
      'PAUSED' => const Color(0xFFFFCC00),
      _ => const Color(0xFFFF4444),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(status,
          style: TextStyle(fontSize: 9, color: color, letterSpacing: 1)),
    );
  }
}

class _WaveBadge extends StatelessWidget {
  const _WaveBadge(this.wave);
  final int wave;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF00D4FF).withAlpha(20),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF00D4FF).withAlpha(60)),
        ),
        child: Text(
          'WAVE $wave',
          style: const TextStyle(
              fontSize: 9, color: Color(0xFF00D4FF), letterSpacing: 1),
        ),
      );
}

// â”€â”€ Bottom navigation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _BottomNav extends ConsumerWidget {
  const _BottomNav({this.user});
  final dynamic user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = [
      const BottomNavigationBarItem(
          icon: Icon(Icons.dashboard), label: 'Dashboard'),
      const BottomNavigationBarItem(
          icon: Icon(Icons.grid_view), label: 'Floor'),
      const BottomNavigationBarItem(
          icon: Icon(Icons.chat_bubble), label: 'Chat'),
    ];

    // Add Game tab for Admin/Saboteur/AIObserver
    final authUser = ref.watch(authProvider);
    final level = authUser is AuthLoggedIn ? authUser.user.level : 1;
    if (level >= 4) {
      items.add(const BottomNavigationBarItem(
          icon: Icon(Icons.sports_esports), label: 'Game'));
    }

    return BottomNavigationBar(
      backgroundColor: const Color(0xFF0D1117),
      selectedItemColor: const Color(0xFF00D4FF),
      unselectedItemColor: const Color(0xFF484F58),
      type: BottomNavigationBarType.fixed,
      selectedLabelStyle:
          const TextStyle(fontFamily: 'ShareTechMono', fontSize: 9),
      unselectedLabelStyle:
          const TextStyle(fontFamily: 'ShareTechMono', fontSize: 9),
      currentIndex: _currentIndex(context),
      onTap: (i) {
        final routes = ['/dashboard', '/floor', '/chat'];
        if (level >= 4) routes.add('/game');
        if (i < routes.length) context.go(routes[i]);
      },
      items: items,
    );
  }

  int _currentIndex(BuildContext ctx) {
    final location = GoRouterState.of(ctx).matchedLocation;
    return switch (location) {
      '/dashboard' => 0,
      '/floor' => 1,
      '/chat' => 2,
      '/game' => 3,
      _ => 0,
    };
  }
}
