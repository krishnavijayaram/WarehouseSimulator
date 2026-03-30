/// robot_card.dart — Compact card displaying one robot's live state.
library;

import 'package:flutter/material.dart';
import '../models/sim_frame.dart';

class RobotCard extends StatelessWidget {
  const RobotCard({super.key, required this.robot});
  final Robot robot;

  Color get _stateColor => switch (robot.state) {
    'PICKING'  => const Color(0xFF00FF88),
    'MOVING'   => const Color(0xFF00D4FF),
    'CHARGING' => const Color(0xFFFFCC00),
    'ERROR'    => const Color(0xFFFF4444),
    _          => const Color(0xFF8B949E),
  };

  IconData get _stateIcon => switch (robot.state) {
    'PICKING'  => Icons.shopping_basket,
    'MOVING'   => Icons.directions_run,
    'CHARGING' => Icons.battery_charging_full,
    'ERROR'    => Icons.error_outline,
    _          => Icons.pause_circle_outline,
  };

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        // ── Avatar ────────────────────────────────────────────────────────
        CircleAvatar(
          radius: 18,
          backgroundColor: _stateColor.withAlpha(30),
          child: Icon(_stateIcon, color: _stateColor, size: 18),
        ),
        const SizedBox(width: 12),

        // ── Name + type ───────────────────────────────────────────────────
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(robot.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                _TypeBadge(robot.type),
              ]),
              const SizedBox(height: 4),
              // Battery bar
              _BatteryBar(robot.battery),
              const SizedBox(height: 2),
              Row(children: [
                Text(
                  '${(robot.battery * 100).round()}%',
                  style: const TextStyle(fontSize: 9, color: Color(0xFF8B949E)),
                ),
                const SizedBox(width: 8),
                Text(
                  'pos (${robot.x},${robot.y})',
                  style: const TextStyle(fontSize: 9, color: Color(0xFF484F58), fontFamily: 'ShareTechMono'),
                ),
              ]),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // ── Picks + state chip ────────────────────────────────────────────
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _StateChip(robot.state, _stateColor),
            const SizedBox(height: 4),
            Text(
              '${robot.picks} picks',
              style: const TextStyle(fontSize: 9, color: Color(0xFF8B949E)),
            ),
          ],
        ),
      ]),
    ),
  );
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge(this.type);
  final String type;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: const Color(0xFF21262D),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      type,
      style: const TextStyle(fontSize: 8, color: Color(0xFF8B949E), fontFamily: 'ShareTechMono'),
    ),
  );
}

class _StateChip extends StatelessWidget {
  const _StateChip(this.state, this.color);
  final String state;
  final Color  color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withAlpha(25),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withAlpha(80)),
    ),
    child: Text(
      state,
      style: TextStyle(fontSize: 8, color: color, fontFamily: 'ShareTechMono', letterSpacing: 0.5),
    ),
  );
}

class _BatteryBar extends StatelessWidget {
  const _BatteryBar(this.pct);
  final double pct;

  Color get _color {
    if (pct < 20) return const Color(0xFFFF4444);
    if (pct < 50) return const Color(0xFFFFCC00);
    return const Color(0xFF00FF88);
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: LinearProgressIndicator(
      value: pct / 100.0,
      minHeight: 3,
      backgroundColor: const Color(0xFF21262D),
      valueColor: AlwaysStoppedAnimation<Color>(_color),
    ),
  );
}
