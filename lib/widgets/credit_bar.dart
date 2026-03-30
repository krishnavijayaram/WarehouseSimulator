/// credit_bar.dart — Horizontal saboteur-credit progress bar (0–100).
library;

import 'package:flutter/material.dart';

class CreditBar extends StatelessWidget {
  const CreditBar({super.key, required this.credits, this.max = 100});
  final int credits, max;

  static const _kGradient = LinearGradient(
    colors: [Color(0xFFFF0040), Color(0xFFFF4444), Color(0xFFFF8C00)],
  );

  @override
  Widget build(BuildContext context) {
    final fraction = (credits / max).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (_, constraints) {
        final w = constraints.maxWidth;
        return Stack(children: [
          // Background track
          Container(
            height: 18,
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          // Filled portion
          Container(
            height: 18,
            width: w * fraction,
            decoration: BoxDecoration(
              gradient: _kGradient,
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF4444).withAlpha(60),
                  blurRadius: 6,
                )
              ],
            ),
          ),
          // Tick marks every 25%
          for (double tick = 0.25; tick < 1.0; tick += 0.25)
            Positioned(
              left: w * tick - 0.5,
              child: Container(width: 1, height: 18, color: const Color(0xFF0D1117).withAlpha(120)),
            ),
        ]);
      },
    );
  }
}
