/// kpi_card.dart — Dark metric tile with an optional accent colour and trend icon.
library;

import 'package:flutter/material.dart';

class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.accent       = const Color(0xFF00D4FF),
    this.icon,
    this.trend,       // positive / negative / null
    this.fullWidth    = false,
  });

  final String  label, value;
  final Color   accent;
  final IconData? icon;
  final bool?   trend;     // true = up (good), false = down (bad)
  final bool    fullWidth;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF161B22),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: accent.withAlpha(50)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: accent.withAlpha(180)),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 7,
                letterSpacing: 1.2,
                color: accent.withAlpha(160),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trend != null)
            Icon(
              trend! ? Icons.arrow_upward : Icons.arrow_downward,
              size: 11,
              color: trend! ? const Color(0xFF00FF88) : const Color(0xFFFF4444),
            ),
        ]),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: accent,
            fontFamily: 'ShareTechMono',
          ),
        ),
      ],
    ),
  );
}
