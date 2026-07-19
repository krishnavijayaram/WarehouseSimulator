/// sim_ws.dart — WebSocket client for the 20 Hz simulation frame stream.
/// Connects to ws://host:8002/ws/sim  (simulation engine direct, not via gateway).
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../env.dart';
import '../models/sim_frame.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

final simFrameProvider = StateNotifierProvider<SimFrameNotifier, SimFrame>(
  (ref) => SimFrameNotifier(ref),
);

final simConnectionProvider = StateProvider<SimConnectionState>((ref) => SimConnectionState.disconnected);

enum SimConnectionState { disconnected, connecting, connected, error }

// ── Notifier ──────────────────────────────────────────────────────────────────

class SimFrameNotifier extends StateNotifier<SimFrame> {
  SimFrameNotifier(this._ref) : super(SimFrame.empty);

  final Ref _ref;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;

  void _setConn(SimConnectionState s) {
    if (_disposed) return;
    _ref.read(simConnectionProvider.notifier).state = s;
  }

  /// Connect (or reconnect) to the simulation WebSocket.
  void connect() {
    if (_disposed) return;
    _sub?.cancel();
    _channel?.sink.close();
    _reconnectTimer?.cancel();

    _setConn(SimConnectionState.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(simWsUrl));
      _sub = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone:  _onDone,
        cancelOnError: false,
      );
    } catch (e) {
      _setConn(SimConnectionState.error);
      _scheduleReconnect();
    }
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _setConn(SimConnectionState.disconnected);
  }

  void _onData(dynamic raw) {
    // Mark connected on first successful frame
    if (_ref.read(simConnectionProvider) != SimConnectionState.connected) {
      _setConn(SimConnectionState.connected);
    }
    // A real frame arrived — the endpoint works, so drop back to the fast retry
    // for any future blip. Only a genuinely dead endpoint backs off to minutes.
    _reconnectAttempt = 0;
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      state = SimFrame.fromJson(j);
    } catch (_) {
      // malformed frame — ignore
    }
  }

  void _onError(Object e) {
    _setConn(SimConnectionState.error);
    _scheduleReconnect();
  }

  void _onDone() {
    _setConn(SimConnectionState.disconnected);
    _scheduleReconnect();
  }

  // ── Reconnect backoff (Azure cost control) ────────────────────────────────
  //
  // This used to retry every 3s forever. When no sim/frame engine is deployed —
  // which is the normal state in prod, since the automation runs locally — that
  // is ~20 failed connections a minute, ~28,800 a DAY per open tab, every one of
  // them hitting the gateway/ingress and billing for it. Exponential backoff
  // with a ceiling turns that into a few dozen a day, while a session that CAN
  // connect still recovers quickly because the delay resets on the first frame.
  static const Duration _kBaseReconnect = Duration(seconds: 3);
  static const Duration _kMaxReconnect = Duration(minutes: 5);
  int _reconnectAttempt = 0;

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    // 3s, 6s, 12s, 24s … capped at 5 min.
    final shift = _reconnectAttempt.clamp(0, 8);
    final ms = _kBaseReconnect.inMilliseconds * (1 << shift);
    final delay = ms >= _kMaxReconnect.inMilliseconds
        ? _kMaxReconnect
        : Duration(milliseconds: ms);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, connect);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
