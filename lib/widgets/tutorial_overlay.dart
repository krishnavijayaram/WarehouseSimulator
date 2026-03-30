/// tutorial_overlay.dart — First-run interactive tutorial overlay.
///
/// Shown once after login (key stored in SharedPreferences).
/// Works on desktop, tablet, and mobile by overlaying a spotlight + tooltip
/// on the relevant area of the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Step model ────────────────────────────────────────────────────────────────

class TutorialStep {
  const TutorialStep({
    required this.title,
    required this.body,
    required this.icon,
    this.alignment = Alignment.center,
  });
  final String    title;
  final String    body;
  final IconData  icon;
  final Alignment alignment; // where the tooltip card floats
}

const _kSteps = [
  TutorialStep(
    icon: Icons.waving_hand,
    title: 'Welcome to WOIS',
    body: 'Warehouse Operations AI Simulator — a live, AI-driven warehouse floor.\n\nThis quick tour shows you around.',
    alignment: Alignment.center,
  ),
  TutorialStep(
    icon: Icons.dashboard,
    title: 'Dashboard',
    body: 'The dashboard shows live KPIs, fleet status, simulation controls and self-healing events.\n\nOn desktop it stays always visible on the left.',
    alignment: Alignment.center,
  ),
  TutorialStep(
    icon: Icons.grid_view,
    title: 'Warehouse Floor',
    body: 'A live top-down view of the warehouse grid.\n\nPinch or scroll to zoom. Coloured dots = robots moving in real-time at 20 Hz.',
    alignment: Alignment.center,
  ),
  TutorialStep(
    icon: Icons.chat_bubble_outline,
    title: 'AI Chat',
    body: 'Ask the warehouse AI anything:\n"How many bots are idle?"\n"Show me recent conflicts"\n\nThe AI reads live sensor data before answering.',
    alignment: Alignment.center,
  ),
  TutorialStep(
    icon: Icons.sports_esports,
    title: 'Game Mode',
    body: 'Unlock sabotage, layout proposals, and simulation challenges as you level up.\n\nGame tab appears when you reach Level 4.',
    alignment: Alignment.center,
  ),
  TutorialStep(
    icon: Icons.devices,
    title: 'Responsive Layout',
    body: '• Desktop / wide tablet: 3-column layout — nav · floor · panel\n• Phone landscape: full-screen floor view\n• Phone portrait: panel view (scrollable)\n\nRotate or resize anytime.',
    alignment: Alignment.center,
  ),
  TutorialStep(
    icon: Icons.check_circle_outline,
    title: "You're all set!",
    body: 'The simulation is already running. Watch the robots pick orders live!\n\nTap the ⬡ logo in the menu any time to replay this tour.',
    alignment: Alignment.center,
  ),
];

// ── Provider ──────────────────────────────────────────────────────────────────

final tutorialVisibleProvider = StateProvider<bool>((ref) => false);
final tutorialStepProvider    = StateProvider<int>((ref) => 0);

class TutorialController {
  static const _kPrefKey = 'wois_tutorial_done';

  static Future<void> showIfFirstRun(WidgetRef ref) async {
    final prefs = await SharedPreferences.getInstance();
    final done  = prefs.getBool(_kPrefKey) ?? false;
    if (!done) {
      ref.read(tutorialStepProvider.notifier).state = 0;
      ref.read(tutorialVisibleProvider.notifier).state = true;
    }
  }

  static Future<void> show(WidgetRef ref) async {
    ref.read(tutorialStepProvider.notifier).state = 0;
    ref.read(tutorialVisibleProvider.notifier).state = true;
  }

  static Future<void> dismiss(WidgetRef ref) async {
    ref.read(tutorialVisibleProvider.notifier).state = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefKey, true);
  }
}

// ── Overlay widget ────────────────────────────────────────────────────────────

class TutorialOverlay extends ConsumerWidget {
  const TutorialOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(tutorialVisibleProvider);
    final step    = ref.watch(tutorialStepProvider);

    return Stack(
      children: [
        child,
        if (visible) _TutorialCard(step: step, total: _kSteps.length),
      ],
    );
  }
}

class _TutorialCard extends ConsumerWidget {
  const _TutorialCard({required this.step, required this.total});
  final int step;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s   = _kSteps[step];
    final isLast = step == total - 1;

    return GestureDetector(
      onTap: () {}, // consume taps so they don't pass through
      child: Container(
        color: Colors.black.withAlpha(180),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _Card(key: ValueKey(step), s: s, step: step,
                    total: total, isLast: isLast, ref_: ref),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card({
    super.key,
    required this.s,
    required this.step,
    required this.total,
    required this.isLast,
    required this.ref_,
  });
  final TutorialStep s;
  final int step;
  final int total;
  final bool isLast;
  final WidgetRef ref_;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF00D4FF).withAlpha(120), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00D4FF).withAlpha(40),
            blurRadius: 32,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(total, (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == step ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == step
                    ? const Color(0xFF00D4FF)
                    : const Color(0xFF30363D),
                borderRadius: BorderRadius.circular(3),
              ),
            )),
          ),
          const SizedBox(height: 20),

          // Icon
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF00D4FF).withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: Icon(s.icon, size: 36, color: const Color(0xFF00D4FF)),
          ),
          const SizedBox(height: 16),

          // Title
          Text(
            s.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              color: Color(0xFF00D4FF),
              letterSpacing: 1,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),

          // Body
          Text(
            s.body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFFE6EDF3),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),

          // Buttons
          Row(
            children: [
              // Skip
              if (!isLast)
                TextButton(
                  onPressed: () => TutorialController.dismiss(ref),
                  child: const Text(
                    'SKIP TOUR',
                    style: TextStyle(fontSize: 10, color: Color(0xFF484F58), letterSpacing: 1),
                  ),
                ),
              const Spacer(),
              // Back
              if (step > 0)
                OutlinedButton(
                  onPressed: () => ref.read(tutorialStepProvider.notifier).state = step - 1,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF8B949E),
                    side: const BorderSide(color: Color(0xFF30363D)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    textStyle: const TextStyle(fontSize: 11),
                  ),
                  child: const Text('BACK'),
                ),
              const SizedBox(width: 8),
              // Next / Done
              FilledButton(
                onPressed: isLast
                    ? () => TutorialController.dismiss(ref)
                    : () => ref.read(tutorialStepProvider.notifier).state = step + 1,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00D4FF),
                  foregroundColor: const Color(0xFF0D1117),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
                child: Text(isLast ? "LET'S GO!" : 'NEXT'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
