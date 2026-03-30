/// connection_banner.dart — Thin status bar showing WebSocket connection state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/sim_ws.dart';

class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connState = ref.watch(simConnectionProvider);

    // Hide banner entirely when connected
    if (connState == SimConnectionState.connected) return const SizedBox.shrink();

    final (label, bg, fg) = switch (connState) {
      SimConnectionState.connecting   => ('◌ SIM CONNECTING…', const Color(0xFF1A1A0A), const Color(0xFFAA8800)),
      SimConnectionState.error        => ('⚠ SIM UNREACHABLE', const Color(0xFF1A0A0A), const Color(0xFFAA4444)),
      SimConnectionState.disconnected => ('⬡ SIM OFFLINE', const Color(0xFF111318), const Color(0xFF484F58)),
      SimConnectionState.connected    => ('', Colors.transparent, Colors.transparent),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
      color: bg,
      child: Text(
        label,
        style: TextStyle(fontSize: 9, color: fg, fontFamily: 'ShareTechMono', letterSpacing: 1),
        textAlign: TextAlign.center,
      ),
    );
  }
}
