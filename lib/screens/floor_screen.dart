/// floor_screen.dart — Live warehouse floor view with realistic CustomPainter.
/// AMRs rendered as rounded-rect bots; AGVs as fork-lift silhouettes.
/// Optionally overlays a WarehouseConfig for zone/aisle colouring.
///
/// Operations / fog-of-war:
///   • Before "Start Operations": screen is blank (pitch black).
///   • After start: cells are revealed as robots explore them (fog of war).
///   • Blinking border on any cell with an unresolved active event.
library;

import 'dart:async';
import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../core/auth/auth_provider.dart';
import '../application/event_bus.dart';
import '../application/manual_robot_controller.dart';
import '../application/providers.dart';
import '../application/robot_scout_simulation.dart';
import '../core/sim_ws.dart';
import '../models/sim_frame.dart';
import '../models/warehouse_config.dart';

const int _kRows = 20;
const int _kCols = 30;

class FloorScreen extends ConsumerStatefulWidget {
  const FloorScreen({super.key});

  @override
  ConsumerState<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends ConsumerState<FloorScreen>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  // GestureDetector state
  double _baseScale = 1.0;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;

  // Hover / click state
  Offset? _hoverLocal;
  Size _canvasSize = Size.zero;
  Robot? _selectedRobot;

  // Keyboard focus
  final FocusNode _focusNode = FocusNode();

  // Blink animation
  late final AnimationController _blinkCtrl;
  late final Animation<double> _blinkAnim;

  // ── Presence / edit-lock heartbeat ───────────────────────────────────────
  Timer? _heartbeatTimer;
  String? _heartbeatWarehouseId; // tracks which warehouse the timer is for

  @override
  void initState() {
    super.initState();
    _blinkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _blinkAnim = CurvedAnimation(parent: _blinkCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _stopHeartbeat();
    _blinkCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Heartbeat helpers ─────────────────────────────────────────────────────

  /// Call after Start Operations. Sends the first heartbeat immediately to
  /// claim (or be denied) the edit lock, then repeats every 45 s.
  /// The backend LOCK_TTL_SECS = 60 s — 45 s keeps us comfortably inside it.
  Future<void> _startHeartbeat(WarehouseConfig config) async {
    _stopHeartbeat(); // cancel any previous timer (e.g. after re-publish)
    _heartbeatWarehouseId = config.id;
    await _sendHeartbeat(config.id);
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _sendHeartbeat(config.id),
    );
  }

  Future<void> _sendHeartbeat(String warehouseId) async {
    if (!mounted) return;
    final auth = ref.read(authProvider);
    final userId = auth is AuthLoggedIn ? auth.session.user.id : 'local';
    final userName = auth is AuthLoggedIn ? auth.session.user.name : 'local';
    final sessionId = auth is AuthLoggedIn
        ? auth.session.effectiveSessionId
        : 'local-session';
    try {
      final result = await ApiClient.instance.heartbeat(
        warehouseId: warehouseId,
        sessionId: sessionId,
        userId: userId,
        userName: userName,
      );
      if (!mounted) return;
      final access = result['edit_access'] as String? ?? 'VIEWER';
      final holderName = result['lock_held_by_name'] as String? ?? '?';
      ref.read(editAccessProvider.notifier).state = access;
      ref.read(lockHolderNameProvider.notifier).state = holderName;

      // If we just became EDITOR (previous session expired), start the sim.
      if (access == 'EDITOR' &&
          ref.read(scoutSimulationProvider) == null &&
          ref.read(operationsStartedProvider)) {
        final config = ref.read(warehouseConfigProvider);
        if (config != null) _launchSimulation(config);
      }
    } catch (_) {
      // Network hiccup — keep current access level; sim continues.
    }
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_heartbeatWarehouseId != null) {
      final auth = ref.read(authProvider);
      final sessionId = auth is AuthLoggedIn
          ? auth.session.effectiveSessionId
          : 'local-session';
      ApiClient.instance.releaseHeartbeat(
        warehouseId: _heartbeatWarehouseId!,
        sessionId: sessionId,
      );
      _heartbeatWarehouseId = null;
    }
  }

  /// Actually starts bots and the scout simulation. Separated so it can be
  /// called both from Start Operations (EDITOR path) and from a heartbeat
  /// that discovers the previous editor left.
  void _launchSimulation(WarehouseConfig config) {
    final prevSim = ref.read(scoutSimulationProvider);
    prevSim?.dispose();
    final scout = RobotScoutSimulation(
      config: config,
      ref: ref,
      isSaboteur: false,
    );
    ref.read(scoutSimulationProvider.notifier).state = scout;
    // Manual mode: never create the step timer — robots only move via STEP.
    if (ref.read(simulationModeProvider) == 'manual') {
      scout.startManual();
    } else {
      scout.start();
    }
  }

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
    final editAccess = ref.watch(editAccessProvider);
    final lockHolderName = ref.watch(lockHolderNameProvider);
    final isViewer = opsStarted && editAccess == 'VIEWER';

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

    final floorRows = config?.rows ?? _kRows;
    final floorCols = config?.cols ?? _kCols;

    // Grab keyboard focus whenever this tab is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      // Auto-resume heartbeat when ops state was restored from backend on refresh
      // (operationsStarted = true but simulation is not running yet).
      if (opsStarted &&
          sim == null &&
          config != null &&
          _heartbeatTimer == null) {
        _startHeartbeat(config);
      }
    });

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('FLOOR VIEW'),
          actions: [
            // ── Manual step controls in AppBar (don't overlay the canvas) ──
            if (opsStarted && simMode == 'manual' && sim != null) ...[
              Tooltip(
                message: 'Advance all robots one step',
                child: TextButton.icon(
                  onPressed: () => sim.step(),
                  icon: const Icon(Icons.skip_next_rounded, size: 16),
                  label: const Text('STEP',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF00D4FF),
                  ),
                ),
              ),
              Tooltip(
                message: 'Switch to Automated mode',
                child: IconButton(
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  onPressed: () {
                    ref.read(simulationModeProvider.notifier).state =
                        'automated';
                    sim.start();
                  },
                ),
              ),
              const VerticalDivider(width: 1),
            ],
            IconButton(
              icon: const Icon(Icons.fit_screen),
              tooltip: 'Reset zoom',
              onPressed: () => setState(() {
                _scale = 1.0;
                _offset = Offset.zero;
              }),
            ),
          ],
        ),
        body: Stack(
          children: [
            // ── Floor canvas ────────────────────────────────────────────────
            LayoutBuilder(builder: (ctx, constraints) {
              _canvasSize = constraints.biggest;
              return MouseRegion(
                onHover: (e) => setState(() => _hoverLocal = e.localPosition),
                onExit: (_) => setState(() => _hoverLocal = null),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      setState(() {
                        final zoomFactor =
                            event.scrollDelta.dy < 0 ? 1.1 : (1 / 1.1);
                        final newScale = (_scale * zoomFactor).clamp(0.4, 8.0);
                        final focal = event.localPosition;
                        _offset =
                            focal - (focal - _offset) * (newScale / _scale);
                        _scale = newScale;
                      });
                    }
                  },
                  child: GestureDetector(
                    onScaleStart: (d) {
                      _baseScale = _scale;
                      _startFocal = d.focalPoint;
                      _startOffset = _offset;
                    },
                    onScaleUpdate: (d) {
                      setState(() {
                        _scale = (_baseScale * d.scale).clamp(0.4, 8.0);
                        _offset = _startOffset + (d.focalPoint - _startFocal);
                      });
                    },
                    onTapUp: (d) {
                      final hit = _robotAtLocal(d.localPosition, displayRobots);
                      if (hit != null) {
                        setState(() => _selectedRobot = hit);
                        ref.read(selectedRobotIdProvider.notifier).state =
                            hit.id;
                      } else if (!(opsStarted && simMode == 'manual')) {
                        setState(() => _selectedRobot = null);
                        ref.read(selectedRobotIdProvider.notifier).state = null;
                      }
                    },
                    onSecondaryTapUp: (d) =>
                        _showFloorCellContextMenu(d.localPosition, context),
                    child: ClipRect(
                      child: AnimatedBuilder(
                        animation: _blinkAnim,
                        builder: (_, __) => CustomPaint(
                          painter: FloorPainter(
                            robots: opsStarted ? displayRobots : const [],
                            orders: frame.orders,
                            rows: floorRows,
                            cols: floorCols,
                            scale: _scale,
                            offset: _offset,
                            warehouseConfig: opsStarted ? config : null,
                            exploredCells:
                                opsStarted ? exploredCells : const {},
                            activeEvents: activeEvents,
                            blinkPhase: _blinkAnim.value,
                            selectedRobotId: selectedRobotId,
                            blockedCells: opsStarted ? blockedCells : const {},
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ), // GestureDetector
                ), // Listener
              );
            }),

            // ── Pre-operations blank overlay + Start button ───────────────────
            if (!opsStarted && config != null) _buildStartOpsOverlay(config),

            // ── View-mode banner (another session holds the edit lock) ─────
            if (isViewer)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: const Color(0xFFF97316).withAlpha(220),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.visibility_outlined,
                            color: Colors.black, size: 16),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'VIEW MODE — $lockHolderName is editing this warehouse. '
                            'Robot writes are paused for you.',
                            style: const TextStyle(
                                color: Colors.black,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── End of floor overlay stack ────────────────────────────────

            // ── D-pad: manual robot control ────────────────────────────────────
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

            // ── Scout progress badge ──────────────────────────────────────────
            if (opsStarted && exploredCells.isNotEmpty && config != null)
              Positioned(
                top: 12,
                left: 12,
                child: ScoutProgressBadge(
                  explored: exploredCells.length,
                  total: config.rows * config.cols,
                  simMode: simMode,
                ),
              ),

            // ── Hover tooltip ────────────────────────────────────────────────
            if (_hoverLocal != null)
              _buildHoverTooltip(frame, config, displayRobots),

            // ── Robot info panel ─────────────────────────────────────────────
            if (opsStarted && _selectedRobot != null)
              _buildRobotPanel(_selectedRobot!, frame),

            // ── Speech bubbles ───────────────────────────────────────────────
            if (opsStarted)
              ..._buildSpeechBubbles(ref.watch(speechBubbleProvider), config),

            // ── Legend ──────────────────────────────────────────────────────
            if (opsStarted)
              Positioned(
                bottom: 16,
                left: 16,
                child: _Legend(),
              ),

            // ── Robot count badge ────────────────────────────────────────────
            if (opsStarted)
              Positioned(
                top: 12,
                right: 12,
                child: _InfoBadge(
                  '${displayRobots.length} robots · wave ${frame.waveNumber}${frame.robots.isEmpty && displayRobots.isNotEmpty ? ' (parked)' : ''}',
                ),
              ),
          ],
        ),
      ), // close Scaffold
    ); // close Focus
  }

  // ── Start Operations overlay ─────────────────────────────────────────────

  Widget _buildStartOpsOverlay(WarehouseConfig config) {
    return Positioned.fill(
      child: Container(
        color: const Color(0xFF060A0F),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warehouse_outlined,
                  size: 64, color: Color(0xFF1E3A5F)),
              const SizedBox(height: 24),
              Text(
                config.name,
                style: const TextStyle(
                  fontSize: 20,
                  color: Color(0xFF8B949E),
                  fontFamily: 'ShareTechMono',
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${config.rows} × ${config.cols}  ·  '
                '${config.cells.where((c) => c.type.isRack).length} racks  ·  '
                '${config.robotSpawns.length} robots',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF444C56),
                  fontFamily: 'ShareTechMono',
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                'FLOOR VIEW IS DARK',
                style: TextStyle(
                  fontSize: 11,
                  color: Color(0xFF374151),
                  letterSpacing: 2,
                  fontFamily: 'ShareTechMono',
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Robots will scout the warehouse and reveal the layout',
                style: TextStyle(fontSize: 11, color: Color(0xFF4B5563)),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00D4FF),
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
                  textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.play_circle_outline, size: 22),
                label: const Text('START OPERATIONS'),
                onPressed: () async {
                  ref.read(simulationModeProvider.notifier).state = 'manual';
                  ref.read(exploredCellsProvider.notifier).reset();
                  ref.read(activeEventsProvider.notifier).resolveAll();
                  ref.read(operationsStartedProvider.notifier).state = true;
                  ref
                      .read(manualRobotControllerProvider.notifier)
                      .initialize(config);
                  // Claim the edit lock via heartbeat first.
                  // EDITOR → launch bots immediately.
                  // VIEWER → show view-mode banner; bots start when the editor
                  //           leaves (next heartbeat upgrades access to EDITOR).
                  await _startHeartbeat(config);
                  final access = ref.read(editAccessProvider);
                  if (access != 'VIEWER') {
                    _launchSimulation(config);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({int row, int col})? _posToCell(Offset local) {
    if (_canvasSize == Size.zero) return null;
    final config = ref.read(warehouseConfigProvider);
    final rows = config?.rows ?? _kRows;
    final cols = config?.cols ?? _kCols;
    final cw = (_canvasSize.width / cols) * _scale;
    final ch = (_canvasSize.height / rows) * _scale;
    final col = ((local.dx - _offset.dx) / cw).floor();
    final row = ((local.dy - _offset.dy) / ch).floor();
    if (col < 0 || col >= cols || row < 0 || row >= rows) return null;
    return (row: row, col: col);
  }

  String _colLabel(int c) {
    const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    return c < 26 ? abc[c] : '${abc[(c ~/ 26) - 1]}${abc[c % 26]}';
  }

  String _rackUnitLabel(CellType type) => switch (type) {
        CellType.rackPallet => 'Pallets',
        CellType.rackCase => 'Cases',
        CellType.rackLoose => 'Units',
        _ => 'Stock',
      };

  // ── Floor right-click: rack inventory popup (read-only) ─────────────────

  Future<void> _showFloorCellContextMenu(Offset local, BuildContext ctx) async {
    final hitCell = _posToCell(local);
    if (hitCell == null) return;
    final config = ref.read(warehouseConfigProvider);
    if (config == null) return;

    final r = hitCell.row, c = hitCell.col;

    // Find the rack cell at this position (explored or not).
    final wCell =
        config.cells.where((x) => x.row == r && x.col == c).lastOrNull;

    // Only show the popup for rack cells — other cells have the hover tooltip.
    if (wCell == null || !wCell.type.isRack) return;

    final locId = '${_colLabel(c)}${r + 1}';
    final unitLabel = _rackUnitLabel(wCell.type);
    final fillPct = (wCell.fillFraction * 100).round();

    final rel = RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      _canvasSize.width - local.dx,
      _canvasSize.height - local.dy,
    );

    await showMenu<void>(
      context: ctx,
      position: rel,
      color: const Color(0xFF1C2128),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        // Header: location + rack type
        PopupMenuItem<void>(
          enabled: false,
          height: 30,
          child: Text(
            '$locId  ·  ${wCell.type.label}',
            style: const TextStyle(
              color: Color(0xFFE6EDF3),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const PopupMenuDivider(height: 1),
        // Bin ID
        PopupMenuItem<void>(
          enabled: false,
          height: 26,
          child: Row(children: [
            const Icon(Icons.location_on_outlined,
                color: Color(0xFF8B949E), size: 13),
            const SizedBox(width: 6),
            Text('Bin ID: $locId',
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
          ]),
        ),
        // SKU
        PopupMenuItem<void>(
          enabled: false,
          height: 26,
          child: Row(children: [
            const Icon(Icons.qr_code_rounded,
                color: Color(0xFF8B949E), size: 13),
            const SizedBox(width: 6),
            Text(
              'SKU: ${wCell.skuId ?? "— empty —"}',
              style: TextStyle(
                color: wCell.skuId != null
                    ? const Color(0xFFE6EDF3)
                    : const Color(0xFF484F58),
                fontSize: 11,
              ),
            ),
          ]),
        ),
        // Stock count
        PopupMenuItem<void>(
          enabled: false,
          height: 26,
          child: Row(children: [
            Icon(
              wCell.quantity == 0
                  ? Icons.inventory_2_outlined
                  : wCell.needsReplenishment
                      ? Icons.warning_amber_rounded
                      : Icons.inventory_2_rounded,
              color: wCell.quantity == 0
                  ? const Color(0xFF484F58)
                  : wCell.needsReplenishment
                      ? const Color(0xFFF97316)
                      : const Color(0xFF4ADE80),
              size: 13,
            ),
            const SizedBox(width: 6),
            Text(
              '$unitLabel: ${wCell.quantity} / ${wCell.maxQuantity}'
              '${wCell.quantity > 0 ? "  ($fillPct%)" : ""}',
              style: TextStyle(
                color: wCell.quantity == 0
                    ? const Color(0xFF484F58)
                    : wCell.needsReplenishment
                        ? const Color(0xFFF97316)
                        : const Color(0xFF4ADE80),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ]),
        ),
        // Replenishment warning
        if (wCell.needsReplenishment && wCell.quantity > 0)
          const PopupMenuItem<void>(
            enabled: false,
            height: 24,
            child: Row(children: [
              Icon(Icons.sync_rounded, color: Color(0xFFF97316), size: 12),
              SizedBox(width: 6),
              Text('Replenishment required',
                  style: TextStyle(
                      color: Color(0xFFF97316),
                      fontSize: 10,
                      fontStyle: FontStyle.italic)),
            ]),
          ),
        if (wCell.isEmpty)
          const PopupMenuItem<void>(
            enabled: false,
            height: 24,
            child: Row(children: [
              Icon(Icons.remove_shopping_cart_outlined,
                  color: Color(0xFF484F58), size: 12),
              SizedBox(width: 6),
              Text('Rack empty — no stock',
                  style: TextStyle(
                      color: Color(0xFF484F58),
                      fontSize: 10,
                      fontStyle: FontStyle.italic)),
            ]),
          ),
      ],
    );
  }

  Robot? _robotAtLocal(Offset local, List<Robot> robots) {
    if (_canvasSize == Size.zero) return null;
    final config = ref.read(warehouseConfigProvider);
    final rows = config?.rows ?? _kRows;
    final cols = config?.cols ?? _kCols;
    final cw = (_canvasSize.width / cols) * _scale;
    final ch = (_canvasSize.height / rows) * _scale;
    final threshold = (cw + ch) / 4;
    for (final r in robots) {
      final cx = _offset.dx + (r.x + 0.5) * cw;
      final cy = _offset.dy + (r.y + 0.5) * ch;
      if ((local - Offset(cx, cy)).distance < threshold) return r;
    }
    return null;
  }

  // ── Hover tooltip ────────────────────────────────────────────────────────

  Widget _buildHoverTooltip(
      SimFrame frame, WarehouseConfig? config, List<Robot> displayRobots) {
    final cell = _posToCell(_hoverLocal!);
    if (cell == null) return const SizedBox.shrink();
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
    if (wCell?.destId != null) {
      lines.add(Text('Dest: ${wCell!.destId}', style: mutedStyle));
    }
    // Rack inventory — always shown for rack cells
    if (wCell != null && wCell.type.isRack) {
      final unitLabel = _rackUnitLabel(wCell.type);
      if (wCell.skuId != null) {
        final pct = (wCell.fillFraction * 100).round();
        lines.add(Text('SKU: ${wCell.skuId}', style: cyanStyle));
        final qtyColor = pct < 50 ? yellowStyle : greenStyle;
        lines.add(Text(
            '$unitLabel: ${wCell.quantity}/${wCell.maxQuantity}  ($pct%)',
            style: qtyColor));
      } else {
        lines.add(const Text('SKU: — empty —', style: mutedStyle));
        lines
            .add(Text('$unitLabel: 0/${wCell.maxQuantity}', style: mutedStyle));
      }
      if (wCell.levels > 1) {
        lines.add(Text('Levels: ${wCell.levels}', style: mutedStyle));
      }
    }
    // Robots present at this cell
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

  // ── Robot info panel ─────────────────────────────────────────────────────

  Widget _buildRobotPanel(Robot robot, SimFrame frame) {
    final bat = robot.battery.clamp(0.0, 1.0);
    final batColor = bat < 0.1
        ? const Color(0xFFEF4444)
        : bat < 0.3
            ? const Color(0xFFF97316)
            : const Color(0xFF4ADE80);
    final orders = frame.orders.where((o) => o.robotId == robot.id).toList();

    // Find the active order to show carry info
    final activeOrder = orders
            .where((o) => o.status == 'IN_PROGRESS')
            .firstOrNull ??
        (robot.currentOrder != null
            ? frame.orders.where((o) => o.id == robot.currentOrder).firstOrNull
            : null);
    String? carryDesc;
    if (activeOrder != null) {
      carryDesc = switch (activeOrder.type.toUpperCase()) {
        'LOOSE_PICK' || 'LOOSE' => '📦 Loose pick',
        'CASE_PICK' || 'CASE' => '📫 Case pick',
        'PALLET' => '🏗 Pallet',
        'REPLENISHMENT' => '🔄 Replenishing',
        _ => activeOrder.type,
      };
    }
    return Positioned(
      top: 60,
      right: 16,
      child: GestureDetector(
        onTap: () => setState(() => _selectedRobot = null),
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1117).withAlpha(245),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF8B949E),
                fontFamily: 'ShareTechMono'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Row(children: [
                  Expanded(
                    child: Text(robot.name,
                        style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFE6EDF3),
                            fontWeight: FontWeight.bold)),
                  ),
                  const Text('✕', style: TextStyle(color: Color(0xFF8B949E))),
                ]),
                const SizedBox(height: 6),
                _rpRow('Type', robot.type),
                _rpRow('State', robot.state),
                _rpRow('Pos',
                    '(${robot.x.toStringAsFixed(1)}, ${robot.y.toStringAsFixed(1)})'),
                _rpRow('Picks', '${robot.picks}'),
                if (robot.currentOrder != null)
                  _rpRow('Order', robot.currentOrder!),
                if (carryDesc != null) ...[
                  _rpRow('Carrying', carryDesc),
                  if (activeOrder != null && activeOrder.progress > 0)
                    _rpRow('Progress', '${activeOrder.progress}%'),
                ],
                const SizedBox(height: 6),
                // Battery bar
                Row(children: [
                  const Text('Battery: '),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: bat,
                        minHeight: 6,
                        backgroundColor: const Color(0xFF21262D),
                        valueColor: AlwaysStoppedAnimation(batColor),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('${(bat * 100).toStringAsFixed(0)}%'),
                ]),
                if (bat < 0.1)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('⚠ LOW BATTERY',
                        style: TextStyle(color: Color(0xFFEF4444))),
                  ),
                if (orders.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Orders:',
                      style: TextStyle(color: Color(0xFFE6EDF3))),
                  ...orders.take(3).map((o) => Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(children: [
                          Expanded(
                              child:
                                  Text(o.id, overflow: TextOverflow.ellipsis)),
                          Text(' ${o.type} ${o.progress}%'),
                        ]),
                      )),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rpRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          SizedBox(width: 52, child: Text('$label:')),
          Expanded(
              child: Text(value,
                  style: const TextStyle(color: Color(0xFFE6EDF3)),
                  overflow: TextOverflow.ellipsis)),
        ]),
      );

  // ── Speech bubble overlay ─────────────────────────────────────────────────

  List<Widget> _buildSpeechBubbles(
      List<SpeechBubble> bubbles, WarehouseConfig? config) {
    if (_canvasSize == Size.zero) return const [];
    final rows = config?.rows ?? _kRows;
    final cols = config?.cols ?? _kCols;
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
}

// ── Legend ─────────────────────────────────────────────────────────────────

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117).withAlpha(200),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LegendRow(Color(0xFF00D4FF), 'AMR / IDLE'),
            _LegendRow(Color(0xFF00FF88), 'PICKING'),
            _LegendRow(Color(0xFFFFCC00), 'CHARGING'),
            _LegendRow(Color(0xFFFF4444), 'ERROR'),
            _LegendRow(Color(0xFF8B949E), 'AGV'),
          ],
        ),
      );
}

class _LegendRow extends StatelessWidget {
  const _LegendRow(this.color, this.label);
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 10,
                height: 10,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 9,
                    color: Color(0xFF8B949E),
                    fontFamily: 'ShareTechMono')),
          ],
        ),
      );
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 9,
                color: Color(0xFF00D4FF),
                fontFamily: 'ShareTechMono')),
      );
}

// ── Scout progress badge ─────────────────────────────────────────────────────

class ScoutProgressBadge extends StatelessWidget {
  const ScoutProgressBadge({
    super.key,
    required this.explored,
    required this.total,
    required this.simMode,
  });
  final int explored, total;
  final String simMode;

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? (explored / total * 100).round() : 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117).withAlpha(220),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.radar, color: Color(0xFF00D4FF), size: 13),
              const SizedBox(width: 5),
              Text(
                'SCOUTING  $pct%  ($explored/$total cells)',
                style: const TextStyle(
                    color: Color(0xFF00D4FF),
                    fontSize: 10,
                    fontFamily: 'ShareTechMono'),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: simMode == 'automated'
                      ? const Color(0xFF00D4FF).withAlpha(30)
                      : const Color(0xFFF97316).withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  simMode.toUpperCase(),
                  style: TextStyle(
                      color: simMode == 'automated'
                          ? const Color(0xFF00D4FF)
                          : const Color(0xFFF97316),
                      fontSize: 9,
                      fontFamily: 'ShareTechMono'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 200,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: total > 0 ? explored / total : 0,
                minHeight: 3,
                backgroundColor: const Color(0xFF1C2128),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF00D4FF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Speech bubble widget ────────────────────────────────────────────────────

class SpeechBubbleWidget extends StatelessWidget {
  const SpeechBubbleWidget({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            constraints: const BoxConstraints(maxWidth: 150),
            decoration: BoxDecoration(
              color: const Color(0xFF1C2333),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: const Color(0xFFFF8C00).withAlpha(180), width: 1.2),
              boxShadow: [
                BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 6)
              ],
            ),
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 9,
                  color: Color(0xFFE6EDF3),
                  fontFamily: 'ShareTechMono'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          CustomPaint(
            size: const Size(12, 7),
            painter: _BubbleTailPainter(),
          ),
        ],
      );
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF1C2333));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFF8C00).withAlpha(180)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ── CustomPainter ───────────────────────────────────────────────────────────

class FloorPainter extends CustomPainter {
  const FloorPainter({
    required this.robots,
    required this.orders,
    required this.rows,
    required this.cols,
    required this.scale,
    required this.offset,
    this.warehouseConfig,
    this.exploredCells = const {},
    this.activeEvents = const {},
    this.blinkPhase = 0.0,
    this.selectedRobotId,
    this.blockedCells = const {},
  });

  final List<Robot> robots;
  final List<WaveOrder> orders;
  final int rows, cols;
  final double scale;
  final Offset offset;
  final WarehouseConfig? warehouseConfig;

  /// Set of "row,col" keys for cells revealed by robot scouting.
  /// Empty set = all cells are in fog (operations not started or no scouting yet).
  final Set<String> exploredCells;

  /// Map from "row,col" → event descriptor for cells that should blink.
  final Map<String, String> activeEvents;

  /// 0.0–1.0 animation phase for blinking (driven by AnimationController outside).
  final double blinkPhase;

  /// The robot ID currently selected for D-pad control (highlighted on canvas).
  final String? selectedRobotId;

  /// Set of "row,col" strings for physically blocked cells (RealityCell.is_blocked).
  /// Rendered as a red/orange X overlay so the operator sees actual obstructions.
  final Set<String> blockedCells;

  bool _isExplored(int row, int col) =>
      exploredCells.isEmpty || exploredCells.contains('$row,$col');

  Color? _eventColor(int row, int col) {
    final ev = activeEvents['$row,$col'];
    if (ev == null) return null;
    final hex = ActiveEventsNotifier.colorOf(ev).replaceFirst('#', 'FF');
    try {
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return const Color(0xFFF97316);
    }
  }

  bool _eventIsFast(int row, int col) {
    final ev = activeEvents['$row,$col'];
    return ev != null && ActiveEventsNotifier.isFast(ev);
  }

  // ── Coordinate helpers ────────────────────────────────────────────────────

  double _cw(Size s) => (s.width / cols) * scale;
  double _ch(Size s) => (s.height / rows) * scale;

  Offset _cellCenter(Size s, double col, double row) =>
      offset + Offset((col + 0.5) * _cw(s), (row + 0.5) * _ch(s));

  // ── Paint ─────────────────────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0A0F14),
    );

    _drawZones(canvas, size);
    _drawGrid(canvas, size);
    _drawAisleLabels(canvas, size);
    _drawPaths(canvas, size);
    _drawRobots(canvas, size);
    _drawBlockedCells(canvas, size);
    _drawFogOfWar(canvas, size);
    _drawBlinkingEvents(canvas, size);
  }

  // ── Blocked-cell (obstruction) overlay ───────────────────────────────────
  // Draws a semi-transparent red fill + orange X on each physically blocked cell.
  // Painted before fog-of-war so the mark is still visible through fog in
  // explored cells, but hidden by fog in unexplored ones.

  void _drawBlockedCells(Canvas canvas, Size size) {
    if (blockedCells.isEmpty) return;
    final cw = _cw(size);
    final ch = _ch(size);
    final fillPaint = Paint()..color = const Color(0x55EF4444); // red 33 %
    final borderPaint = Paint()
      ..color = const Color(0xCCEF4444)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.0, min(cw, ch) * 0.06);
    final xPaint = Paint()
      ..color = const Color(0xFFF97316) // orange X
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.5, min(cw, ch) * 0.10)
      ..strokeCap = StrokeCap.round;
    final inset = min(cw, ch) * 0.20;
    for (final key in blockedCells) {
      final parts = key.split(',');
      if (parts.length != 2) continue;
      final row = int.tryParse(parts[0]);
      final col = int.tryParse(parts[1]);
      if (row == null || col == null) continue;
      final rect = Rect.fromLTWH(
        offset.dx + col * cw,
        offset.dy + row * ch,
        cw,
        ch,
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect.deflate(0.5), borderPaint);
      // Draw X
      canvas.drawLine(
        Offset(rect.left + inset, rect.top + inset),
        Offset(rect.right - inset, rect.bottom - inset),
        xPaint,
      );
      canvas.drawLine(
        Offset(rect.right - inset, rect.top + inset),
        Offset(rect.left + inset, rect.bottom - inset),
        xPaint,
      );
    }
  }

  // ── Fog-of-war overlay ────────────────────────────────────────────────────
  // Draws a black tile over every cell that has NOT been explored.
  // Skipped entirely when exploredCells is empty (pre-ops: full black is the
  // background; the Start Ops overlay covers everything at the widget layer).

  void _drawFogOfWar(Canvas canvas, Size size) {
    if (exploredCells.isEmpty) return; // no scouting started yet
    final cw = _cw(size);
    final ch = _ch(size);
    final fogPaint = Paint()..color = const Color(0xFF050A0F);
    final rows = warehouseConfig?.rows ?? this.rows;
    final cols = warehouseConfig?.cols ?? this.cols;
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        if (!_isExplored(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(
              offset.dx + c * cw,
              offset.dy + r * ch,
              cw,
              ch,
            ),
            fogPaint,
          );
        }
      }
    }
  }

  // ── Blinking event borders ────────────────────────────────────────────────

  void _drawBlinkingEvents(Canvas canvas, Size size) {
    if (activeEvents.isEmpty) return;
    final cw = _cw(size);
    final ch = _ch(size);
    for (final entry in activeEvents.entries) {
      final parts = entry.key.split(',');
      if (parts.length != 2) continue;
      final row = int.tryParse(parts[0]);
      final col = int.tryParse(parts[1]);
      if (row == null || col == null) continue;
      // Don't blink cells still in fog
      if (!_isExplored(row, col)) continue;

      final isFast = _eventIsFast(row, col);
      final speed = isFast ? 1.0 : 0.5;
      // Compute a smooth alpha oscillation from blinkPhase
      final alpha = ((blinkPhase * speed * 2 * 3.14159265).truncateToDouble() <
              speed * 3.14159265
          ? blinkPhase
          : 1.0 - blinkPhase);
      final blinkAlpha = ((alpha * 255).round()).clamp(0, 255);

      final evColor = _eventColor(row, col) ?? const Color(0xFFF97316);
      final rect = Rect.fromLTWH(
        offset.dx + col * cw,
        offset.dy + row * ch,
        cw,
        ch,
      );
      // Subtle fill pulse
      canvas.drawRect(
        rect,
        Paint()..color = evColor.withAlpha((blinkAlpha * 0.18).round()),
      );
      // Bright border
      canvas.drawRect(
        rect.deflate(0.5),
        Paint()
          ..color = evColor.withAlpha(blinkAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(1.5, min(cw, ch) * 0.08),
      );
    }
  }

  @override
  bool shouldRepaint(covariant FloorPainter old) =>
      old.robots != robots ||
      old.warehouseConfig != warehouseConfig ||
      old.exploredCells != exploredCells ||
      old.activeEvents != activeEvents ||
      old.blinkPhase != blinkPhase ||
      old.scale != scale ||
      old.offset != offset ||
      old.selectedRobotId != selectedRobotId ||
      old.blockedCells != blockedCells;

  void _drawZones(Canvas canvas, Size size) {
    final cw = _cw(size);
    final ch = _ch(size);

    if (warehouseConfig != null) {
      // ── 1. Draw pick-zone rectangles first (background layer) ──────────────
      for (final zone in warehouseConfig!.zones) {
        final left = offset.dx + zone.colStart * cw;
        final top = offset.dy + zone.rowStart * ch;
        final bandW = (zone.colEnd - zone.colStart + 1) * cw;
        final bandH = (zone.rowEnd - zone.rowStart + 1) * ch;
        final rect = Rect.fromLTWH(left, top, bandW, bandH);

        canvas.drawRect(rect, Paint()..color = zone.type.color.withAlpha(35));
        canvas.drawRect(
            rect,
            Paint()
              ..color = zone.type.color.withAlpha(90)
              ..strokeWidth = 1.2
              ..style = PaintingStyle.stroke);

        if (scale > 0.4) {
          _drawTextCentered(canvas, zone.type.label, rect.center,
              (7.5 * scale).clamp(6.0, 14.0),
              color: zone.type.color.withAlpha(200));
        }
      }

      // ── Warehouse path: tiny saffron dot on every grid cell ─
      if (scale > 0.3) {
        final dotR = min(cw, ch) * 0.06; // smaller dot
        final dotPaint = Paint()..color = const Color(0xFFFF8C00).withAlpha(38);
        for (int r = 0; r < rows; r++) {
          for (int c = 0; c < cols; c++) {
            canvas.drawCircle(
              Offset(offset.dx + (c + 0.5) * cw, offset.dy + (r + 0.5) * ch),
              dotR,
              dotPaint,
            );
          }
        }
      }

      // ── 2. Draw individual cells on top of zone bands ──────────────────────
      for (final cell in warehouseConfig!.cells) {
        if (cell.type == CellType.empty) continue;
        final rect = Rect.fromLTWH(
          offset.dx + cell.col * cw,
          offset.dy + cell.row * ch,
          cw,
          ch,
        );

        // Road cells — dark asphalt + saffron road markings
        if (cell.type.isRoad) {
          _drawRoadCell(canvas, rect, cell.type);
          continue;
        }

        // Aisle / cross-aisle / robot-path — dark bg + saffron navigation dot
        if (cell.type == CellType.aisle ||
            cell.type == CellType.crossAisle ||
            cell.type == CellType.robotPath) {
          canvas.drawRect(rect, Paint()..color = cell.type.color);
          if (scale > 0.4) {
            final dotR = min(cw, ch) * 0.14;
            canvas.drawCircle(
                rect.center, dotR, Paint()..color = const Color(0xFFFF8C00));
          }
          continue;
        }

        // Conveyor cells — directional belt + arrow
        if (cell.type.isConveyor) {
          _drawConveyorCell(canvas, rect, cell.type);
          continue;
        }

        // Dock — skeleton wireframe (bay outline only; truck is the occupant)
        if (cell.type == CellType.dock) {
          _drawDockCell(canvas, rect);
          continue;
        }

        // For rack cells inside a zone — tint with zone color for coherence
        final zoneType = warehouseConfig!.zoneForCell(cell.row, cell.col);
        final baseAlpha = cell.type.isRack && zoneType != null ? 220 : 190;
        canvas.drawRect(
            rect, Paint()..color = cell.type.color.withAlpha(baseAlpha));

        // Rack: draw shelf lines + fill-level icon
        if (cell.type.isRack) {
          if (scale > 0.7) {
            final linePaint = Paint()
              ..color = Colors.white.withAlpha(45)
              ..strokeWidth = max(0.4, rect.shortestSide * 0.03);
            for (var i = 1; i < 4; i++) {
              final y = rect.top + rect.height * i / 4;
              canvas.drawLine(Offset(rect.left + 1, y),
                  Offset(rect.right - 1, y), linePaint);
            }
          }
          // Shelf-fill bar — bottom inset fill rectangle driven by actual
          // inventory quantity vs capacity (fillFraction 0.0–1.0).
          final fill = cell.fillFraction;
          if (fill > 0) {
            final fillColor = fill >= 1.0
                ? const Color(0xFF00FF88) // full  — green
                : fill >= 0.5
                    ? const Color(0xFFFFCC00) // ≥50%  — amber
                    : const Color(0xFFFF6B35); // <50%  — orange-red
            final barH = rect.height * fill;
            canvas.drawRect(
              Rect.fromLTWH(
                rect.left + 1,
                rect.bottom - barH,
                rect.width - 2,
                barH,
              ),
              Paint()..color = fillColor.withAlpha(70),
            );
          }
          // Shelf-fill icon — driven by actual stock level
          if (scale > 1.0) {
            final icon = fill >= 1.0
                ? '▉'
                : fill > 0
                    ? '▦'
                    : '▢';
            _drawTextCentered(canvas, icon, rect.center, min(cw, ch) * 0.38,
                color: Colors.white.withAlpha(200));
          }
        }

        // Charger: distinguish fast vs slow with colors + label
        if (cell.type.isCharger && scale > 0.6) {
          final isFast = cell.type == CellType.chargingFast;
          final icon = isFast ? '⚡⚡' : '⚡';
          final label = isFast ? 'FAST' : 'SLOW';
          _drawTextCentered(
              canvas,
              icon,
              rect.center - Offset(0, rect.height * 0.1),
              max(7.0, min(cw, ch) * 0.35));
          if (scale > 1.0) {
            _drawTextCentered(
                canvas,
                label,
                rect.center + Offset(0, rect.height * 0.28),
                max(5.0, min(cw, ch) * 0.18),
                color:
                    isFast ? const Color(0xFFEAB308) : const Color(0xFFF59E0B));
          }
          // Status dot in top-right
          if (scale > 1.2) {
            canvas.drawCircle(
              Offset(rect.right - rect.width * 0.15,
                  rect.top + rect.height * 0.15),
              rect.shortestSide * 0.1,
              Paint()..color = const Color(0xFF4ADE80),
            );
          }
        }

        // Dump station
        if (cell.type == CellType.dump && scale > 0.8) {
          _drawTextCentered(
              canvas, '🗑', rect.center, 9 * scale.clamp(0.6, 2.0));
        }
      }
    } else {
      // Default: draw tiny saffron dot on every cell, then overlay special regions
      if (scale > 0.3) {
        final dotR = min(cw, ch) * 0.06;
        final dotPaint = Paint()..color = const Color(0xFFFF8C00).withAlpha(38);
        for (int r = 0; r < rows; r++) {
          for (int c = 0; c < cols; c++) {
            canvas.drawCircle(
              Offset(offset.dx + (c + 0.5) * cw, offset.dy + (r + 0.5) * ch),
              dotR,
              dotPaint,
            );
          }
        }
      }
      // Packing strip at top (rows 0-1)
      _fillRegion(canvas, size, 0, 0, 2, cols,
          const Color(0xFFF97316).withAlpha(60), 'PACK');
      // Staging at bottom
      _fillRegion(canvas, size, rows - 2, 0, 2, cols,
          const Color(0xFF4ADE80).withAlpha(50), 'STAGING');
      // Aisle columns (every 3rd) — slightly lighter to distinguish
      for (var c = 0; c < cols; c += 3) {
        _fillRegion(canvas, size, 0, c, rows, 1,
            const Color(0xFF1F2937).withAlpha(80), null);
      }
    }
  }

  // ── Road cell renderer ──────────────────────────────────────────────────
  void _drawRoadCell(Canvas canvas, Rect rect, CellType type) {
    canvas.drawRect(rect, Paint()..color = const Color(0xFF141A22));
    final cx = rect.center.dx, cy = rect.center.dy;
    // 18% gap at each end → visible break between adjacent road cell dashes
    final gap = rect.width * 0.18;
    final dashPaint = Paint()
      ..color = Colors.white.withAlpha(210)
      ..strokeWidth = max(1.0, rect.width * 0.07)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;
    switch (type) {
      case CellType.roadH:
        canvas.drawLine(Offset(rect.left + gap, cy),
            Offset(rect.right - gap, cy), dashPaint);
      case CellType.roadV:
        canvas.drawLine(Offset(cx, rect.top + gap),
            Offset(cx, rect.bottom - gap), dashPaint);
      case CellType.roadCornerNE:
        canvas.drawPath(
            Path()
              ..moveTo(cx, rect.top + gap)
              ..quadraticBezierTo(cx, cy, rect.right - gap, cy),
            dashPaint);
      case CellType.roadCornerNW:
        canvas.drawPath(
            Path()
              ..moveTo(cx, rect.top + gap)
              ..quadraticBezierTo(cx, cy, rect.left + gap, cy),
            dashPaint);
      case CellType.roadCornerSE:
        canvas.drawPath(
            Path()
              ..moveTo(cx, rect.bottom - gap)
              ..quadraticBezierTo(cx, cy, rect.right - gap, cy),
            dashPaint);
      case CellType.roadCornerSW:
        canvas.drawPath(
            Path()
              ..moveTo(cx, rect.bottom - gap)
              ..quadraticBezierTo(cx, cy, rect.left + gap, cy),
            dashPaint);
      default:
        break;
    }
  }

  // ── Conveyor cell renderer ──────────────────────────────────────────────────
  void _drawConveyorCell(Canvas canvas, Rect rect, CellType type) {
    canvas.drawRect(rect, Paint()..color = type.color.withAlpha(210));

    // Belt slats perpendicular to direction of travel
    final slatPaint = Paint()
      ..color = Colors.black.withAlpha(55)
      ..strokeWidth = max(0.5, rect.shortestSide * 0.05);
    final isH = type == CellType.conveyorE ||
        type == CellType.conveyorW ||
        type == CellType.conveyorH;
    if (scale > 0.5) {
      if (isH) {
        for (int i = 1; i <= 3; i++) {
          final x = rect.left + rect.width * i / 4;
          canvas.drawLine(
              Offset(x, rect.top + 1), Offset(x, rect.bottom - 1), slatPaint);
        }
      } else {
        for (int i = 1; i <= 3; i++) {
          final y = rect.top + rect.height * i / 4;
          canvas.drawLine(
              Offset(rect.left + 1, y), Offset(rect.right - 1, y), slatPaint);
        }
      }
    }

    // Direction arrow
    if (scale > 0.4) {
      final ap = Paint()
        ..color = Colors.white.withAlpha(230)
        ..strokeWidth = max(1.5, rect.shortestSide * 0.1)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final cx = rect.center.dx, cy = rect.center.dy;
      final s = min(rect.width, rect.height) * 0.3;
      late Offset tail, tip, barL, barR;
      if (type == CellType.conveyorE || type == CellType.conveyorH) {
        tail = Offset(cx - s, cy);
        tip = Offset(cx + s, cy);
        barL = Offset(cx + s * 0.38, cy - s * 0.44);
        barR = Offset(cx + s * 0.38, cy + s * 0.44);
      } else if (type == CellType.conveyorW) {
        tail = Offset(cx + s, cy);
        tip = Offset(cx - s, cy);
        barL = Offset(cx - s * 0.38, cy - s * 0.44);
        barR = Offset(cx - s * 0.38, cy + s * 0.44);
      } else if (type == CellType.conveyorN || type == CellType.conveyorV) {
        tail = Offset(cx, cy + s);
        tip = Offset(cx, cy - s);
        barL = Offset(cx - s * 0.44, cy - s * 0.38);
        barR = Offset(cx + s * 0.44, cy - s * 0.38);
      } else {
        tail = Offset(cx, cy - s);
        tip = Offset(cx, cy + s);
        barL = Offset(cx - s * 0.44, cy + s * 0.38);
        barR = Offset(cx + s * 0.44, cy + s * 0.38);
      }
      canvas.drawPath(
        Path()
          ..moveTo(tail.dx, tail.dy)
          ..lineTo(tip.dx, tip.dy)
          ..moveTo(barL.dx, barL.dy)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(barR.dx, barR.dy),
        ap,
      );
    }
  }

  // ── Dock cell renderer (skeleton wireframe only) ────────────────────────────
  void _drawDockCell(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = const Color(0xFF0D1117));
    // Amber wireframe border
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = const Color(0xFFD97706).withAlpha(200)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.2, rect.shortestSide * 0.07),
    );
    // Corner bumpers
    final bump = rect.shortestSide * 0.14;
    final bumpP = Paint()..color = const Color(0xFFD97706).withAlpha(160);
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawRect(
          Rect.fromCenter(center: corner, width: bump, height: bump), bumpP);
    }
    if (scale > 0.7) {
      _drawTextCentered(canvas, 'BAY', rect.center, rect.shortestSide * 0.22,
          color: const Color(0xFFD97706).withAlpha(160));
    }
  }

  void _fillRegion(Canvas canvas, Size size, int row, int col, int h, int w,
      Color color, String? label) {
    final cw = _cw(size);
    final ch = _ch(size);
    final rect = Rect.fromLTWH(
      offset.dx + col * cw,
      offset.dy + row * ch,
      w * cw,
      h * ch,
    );
    canvas.drawRect(rect, Paint()..color = color);
    if (label != null && scale > 0.6) {
      _drawTextCentered(canvas, label, rect.center, 8 * scale.clamp(0.5, 1.8),
          color: Colors.white.withAlpha(120));
    }
  }

  // ── Grid lines ────────────────────────────────────────────────────────────

  void _drawGrid(Canvas canvas, Size size) {
    final cw = _cw(size);
    final ch = _ch(size);
    final p = Paint()
      ..color = const Color(0xFF21262D).withAlpha(160)
      ..strokeWidth = 0.5;

    // Only draw grid lines when zoomed in enough
    if (scale < 0.4) return;

    for (int r = 0; r <= rows; r++) {
      final y = offset.dy + r * ch;
      canvas.drawLine(
          Offset(offset.dx, y), Offset(offset.dx + cols * cw, y), p);
    }
    for (int c = 0; c <= cols; c++) {
      final x = offset.dx + c * cw;
      canvas.drawLine(
          Offset(x, offset.dy), Offset(x, offset.dy + rows * ch), p);
    }
  }

  // ── Aisle column labels + row numbers — always visible ────────────────────

  void _drawAisleLabels(Canvas canvas, Size size) {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final cw = _cw(size);
    final ch = _ch(size);
    for (var c = 0; c < cols && c < 26; c++) {
      final x = offset.dx + (c + 0.5) * cw;
      final y = offset.dy - 12;
      _drawTextCentered(
          canvas, letters[c], Offset(x, y), (8 * scale).clamp(6.0, 18.0),
          color: const Color(0xFF8B949E));
    }
    for (var r = 0; r < rows; r++) {
      final x = offset.dx - 12;
      final y = offset.dy + (r + 0.5) * ch;
      _drawTextCentered(
          canvas, '${r + 1}', Offset(x, y), (7 * scale).clamp(5.5, 16.0),
          color: const Color(0xFF8B949E));
    }
  }

  // ── Robot paths with arrows ───────────────────────────────────────────────

  void _drawPaths(Canvas canvas, Size size) {
    for (final robot in robots) {
      if (robot.pathX.isEmpty || robot.pathX.length != robot.pathY.length) {
        continue;
      }

      final color = _robotColor(robot).withAlpha(100);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.0, _cw(size) * 0.08);

      final path = Path();
      Offset? prev;
      for (int i = 0; i < robot.pathX.length; i++) {
        final pt = _cellCenter(size, robot.pathX[i], robot.pathY[i]);
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
          // Arrow at each segment midpoint
          if (prev != null) _drawArrow(canvas, prev, pt, color);
        }
        prev = pt;
      }
      canvas.drawPath(path, paint);
    }
  }

  void _drawArrow(Canvas canvas, Offset from, Offset to, Color color) {
    final mid = (from + to) / 2;
    final dir = to - from;
    final len = dir.distance;
    if (len < 1) return;
    final norm = dir / len;
    final perp = Offset(-norm.dy, norm.dx);
    final arrowSize = min(6.0, len * 0.3);
    final tip = mid + norm * arrowSize * 0.5;
    final left = mid - norm * arrowSize * 0.5 + perp * arrowSize * 0.35;
    final right = mid - norm * arrowSize * 0.5 - perp * arrowSize * 0.35;

    final p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  // ── Robot drawing ─────────────────────────────────────────────────────────

  void _drawRobots(Canvas canvas, Size size) {
    for (final robot in robots) {
      final center = _cellCenter(size, robot.x, robot.y);
      final radius = min(_cw(size), _ch(size)) * 0.42;
      final color = _robotColor(robot);

      // Selection ring: drawn behind the robot so it doesn't obscure detail.
      if (selectedRobotId != null && robot.id == selectedRobotId) {
        final selPaint = Paint()
          ..color = const Color(0xFF00D4FF).withAlpha(50)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(center, radius * 2.0, selPaint);
        canvas.drawCircle(
          center,
          radius * 2.0,
          Paint()
            ..color = const Color(0xFF00D4FF)
            ..strokeWidth = 2.0
            ..style = PaintingStyle.stroke,
        );
      }

      if (robot.type == 'AGV') {
        _drawAGV(canvas, center, radius, color, robot);
      } else {
        _drawAMR(canvas, center, radius, color, robot);
      }
    }
  }

  /// Realistic AMR top-down view: rounded rect body, LIDAR sensor, 4 wheels,
  /// status LED, battery bar, name label.
  void _drawAMR(Canvas canvas, Offset c, double r, Color color, Robot robot) {
    final bodyW = r * 1.7;
    final bodyH = r * 2.1;

    // Shadow
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: c + const Offset(2, 2), width: bodyW, height: bodyH),
        Radius.circular(r * 0.25),
      ),
      Paint()
        ..color = Colors.black.withAlpha(80)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Glow ring
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: bodyW + 4, height: bodyH + 4),
        Radius.circular(r * 0.3),
      ),
      Paint()..color = color.withAlpha(50),
    );

    // Main body
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: bodyW, height: bodyH),
        Radius.circular(r * 0.25),
      ),
      Paint()..color = color,
    );

    // Top panel (cargo deck)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: c + Offset(0, r * 0.05),
            width: bodyW * 0.75,
            height: bodyH * 0.55),
        Radius.circular(r * 0.1),
      ),
      Paint()..color = color.withAlpha(160),
    );

    // Deck grid lines
    if (r > 8) {
      final gp = Paint()
        ..color = Colors.white.withAlpha(40)
        ..strokeWidth = 0.5;
      for (var i = 1; i < 3; i++) {
        final y = (c.dy - bodyH * 0.275) + i * bodyH * 0.18;
        canvas.drawLine(Offset(c.dx - bodyW * 0.375, y),
            Offset(c.dx + bodyW * 0.375, y), gp);
      }
    }

    // LIDAR sensor (circular, front top)
    canvas.drawCircle(c + Offset(0, -bodyH / 2 + r * 0.18), r * 0.18,
        Paint()..color = Colors.white70);
    canvas.drawCircle(c + Offset(0, -bodyH / 2 + r * 0.18), r * 0.10,
        Paint()..color = const Color(0xFF0A0F14));

    // 4 Drive wheels
    final wheelW = r * 0.32;
    final wheelH = r * 0.48;
    final wheelR = Radius.circular(r * 0.08);
    final wp = Paint()..color = const Color(0xFF1A2535);
    for (final (dx, dy) in [
      (-bodyW / 2 - wheelW / 3, -bodyH * 0.28),
      (bodyW / 2 - wheelW * 0.65, -bodyH * 0.28),
      (-bodyW / 2 - wheelW / 3, bodyH * 0.28),
      (bodyW / 2 - wheelW * 0.65, bodyH * 0.28),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: c + Offset(dx, dy), width: wheelW, height: wheelH),
          wheelR,
        ),
        wp,
      );
    }

    // Status LED (top-right of body)
    final ledColor = switch (robot.state) {
      'ERROR' => const Color(0xFFFF4444),
      'CHARGING' => const Color(0xFFFFCC00),
      'PICKING' => const Color(0xFF00FF88),
      'MOVING' => const Color(0xFF00D4FF),
      _ => const Color(0xFF4ADE80),
    };
    canvas.drawCircle(
      c + Offset(bodyW / 2 - r * 0.22, -bodyH / 2 + r * 0.22),
      r * 0.14,
      Paint()..color = ledColor,
    );

    _drawBatteryAndLabel(canvas, c, r, bodyW, bodyH, color, robot);
  }

  /// Realistic AGV top-down: rectangular body + fork prongs + counterweight.
  void _drawAGV(Canvas canvas, Offset c, double r, Color color, Robot robot) {
    final bodyW = r * 2.2;
    final bodyH = r * 1.6;
    final forkLen = r * 1.4;
    final forkW = r * 0.22;

    // Shadow
    canvas.drawRect(
      Rect.fromCenter(
          center: c + const Offset(2, 2), width: bodyW, height: bodyH),
      Paint()
        ..color = Colors.black.withAlpha(80)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Glow
    canvas.drawRect(
      Rect.fromCenter(center: c, width: bodyW + 4, height: bodyH + 4),
      Paint()..color = color.withAlpha(40),
    );

    // Counterweight (rear)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          c.dx - bodyW / 2 - r * 0.6,
          c.dy - bodyH / 2,
          r * 0.65,
          bodyH,
        ),
        Radius.circular(r * 0.1),
      ),
      Paint()..color = color.withAlpha(180),
    );

    // Main body
    canvas.drawRect(
      Rect.fromCenter(center: c, width: bodyW, height: bodyH),
      Paint()..color = color,
    );

    // Mast (vertical central bar)
    canvas.drawRect(
      Rect.fromCenter(
          center: c + Offset(-bodyW * 0.15, 0),
          width: r * 0.28,
          height: bodyH * 0.75),
      Paint()..color = color.withAlpha(140),
    );

    // Fork prongs (extend forward/right)
    for (final dy in [-bodyH * 0.25, bodyH * 0.25]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            c.dx + bodyW / 2,
            c.dy + dy - forkW / 2,
            forkLen,
            forkW,
          ),
          Radius.circular(r * 0.03),
        ),
        Paint()..color = const Color(0xFF2D3F55),
      );
    }

    // Wheels (4 corners of body)
    final wp = Paint()..color = const Color(0xFF1A2535);
    for (final (dx, dy) in [
      (-bodyW / 2 - r * 0.18, -bodyH / 2 - r * 0.12),
      (-bodyW / 2 - r * 0.18, bodyH / 2 - r * 0.06),
      (bodyW / 2 - r * 0.14, -bodyH / 2 - r * 0.12),
      (bodyW / 2 - r * 0.14, bodyH / 2 - r * 0.06),
    ]) {
      canvas.drawOval(
        Rect.fromCenter(
            center: c + Offset(dx, dy), width: r * 0.36, height: r * 0.22),
        wp,
      );
    }

    // Status LED
    final ledColor = switch (robot.state) {
      'ERROR' => const Color(0xFFFF4444),
      'CHARGING' => const Color(0xFFFFCC00),
      'PICKING' => const Color(0xFF00FF88),
      'MOVING' => const Color(0xFF00D4FF),
      _ => const Color(0xFF4ADE80),
    };
    canvas.drawCircle(
      c + Offset(bodyW / 2 - r * 0.3, -bodyH / 2 + r * 0.2),
      r * 0.14,
      Paint()..color = ledColor,
    );

    _drawBatteryAndLabel(canvas, c, r, bodyW, bodyH, color, robot);
  }

  /// Returns the short role abbreviation for a robot based on its name/type.
  /// IR=Inbound, OR=Outbound, PR=Pallet, CR=Case, LR=Loose
  String _robotAbbr(Robot robot) {
    final n = robot.name.toUpperCase();
    if (n.contains('INBOUND') || n.startsWith('IR')) return 'IR';
    if (n.contains('OUTBOUND') || n.startsWith('OR')) return 'OR';
    if (n.contains('PALLET') || n.startsWith('PR') || n.startsWith('PAL')) {
      return 'PR';
    }
    if (n.contains('CASE') || n.startsWith('CR') || n.startsWith('CS')) {
      return 'CR';
    }
    if (n.contains('LOOSE') || n.startsWith('LR') || n.startsWith('LS')) {
      return 'LR';
    }
    // Fallback: use robot type
    return robot.type == 'AGV' ? 'AGV' : 'BOT';
  }

  void _drawBatteryAndLabel(Canvas canvas, Offset c, double r, double bodyW,
      double bodyH, Color color, Robot robot) {
    final batW = bodyW * 0.9;
    final batH = max(r * 0.18, 3.0);
    final batY = c.dy + bodyH / 2 + r * 0.10;
    final batX = c.dx - batW / 2;
    final batPct = robot.battery.clamp(0.0, 1.0);
    final batColor = batPct > 0.3
        ? const Color(0xFF4ADE80)
        : batPct > 0.1
            ? const Color(0xFFFBBF24)
            : const Color(0xFFEF4444);

    // Battery track background
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(batX, batY, batW, batH),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.black54,
    );
    // Battery fill — always draw even at 0% (shows empty)
    if (batPct > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(batX, batY, batW * batPct, batH),
          const Radius.circular(2),
        ),
        Paint()..color = batColor,
      );
    }
    // Battery % text alongside bar (compact)
    if (scale > 0.8) {
      _drawTextCentered(
        canvas,
        '${(batPct * 100).toStringAsFixed(0)}%',
        Offset(c.dx, batY + batH * 0.5),
        max(5.0, batH * 0.85),
        color: Colors.white.withAlpha(220),
        bold: true,
      );
    }

    // Robot abbreviation label — always visible below battery
    final abbr = _robotAbbr(robot);
    final labelY = batY + batH + max(2.0, r * 0.12);
    final labelSize = max(7.0, 8 * scale.clamp(0.5, 2.0));
    _drawTextCentered(canvas, abbr, Offset(c.dx, labelY), labelSize,
        color: color, bold: true);

    // Full name when zoomed in
    if (scale > 1.4) {
      _drawTextCentered(
          canvas,
          robot.name,
          Offset(c.dx, labelY + labelSize + 1),
          max(5.5, 6 * scale.clamp(0.5, 1.3)),
          color: Colors.white54);
    }
  }

  // ── Text helpers ──────────────────────────────────────────────────────────

  void _drawTextCentered(Canvas canvas, String text, Offset pos, double size,
      {Color color = Colors.white, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy));
  }

  Color _robotColor(Robot robot) => switch (robot.state) {
        'PICKING' => const Color(0xFF00FF88),
        'CHARGING' => const Color(0xFFFFCC00),
        'ERROR' => const Color(0xFFFF4444),
        'MOVING' => const Color(0xFF00AAFF),
        _ => robot.type == 'AGV'
            ? const Color(0xFF8B949E)
            : const Color(0xFF00D4FF),
      };
}

// ── D-pad overlay for manual robot control ─────────────────────────────────

class DPadControls extends StatelessWidget {
  const DPadControls({
    super.key,
    required this.controller,
    required this.selectedRobotId,
  });

  final ManualRobotController controller;
  final String? selectedRobotId;

  @override
  Widget build(BuildContext context) {
    const mid = Color(0xFF1E2A3A);
    const accent = Color(0xFF00D4FF);
    final noSel = selectedRobotId == null;

    Widget arrowBtn(RobotMoveDirection dir, IconData icon) {
      return DPadKey(
        icon: icon,
        enabled: !noSel,
        onPressed: noSel ? null : () => controller.moveSelected(dir),
      );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: mid.withAlpha(200),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withAlpha(80)),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 12)
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Robot label
          Text(
            noSel ? 'Select a robot' : selectedRobotId!,
            style: TextStyle(
              color: noSel ? Colors.white54 : accent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          // UP
          arrowBtn(RobotMoveDirection.up, Icons.keyboard_arrow_up),
          // LEFT / blank / RIGHT
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              arrowBtn(RobotMoveDirection.left, Icons.keyboard_arrow_left),
              const SizedBox(width: 36, height: 36),
              arrowBtn(RobotMoveDirection.right, Icons.keyboard_arrow_right),
            ],
          ),
          // DOWN
          arrowBtn(RobotMoveDirection.down, Icons.keyboard_arrow_down),
        ],
      ),
    );
  }
}

class DPadKey extends StatelessWidget {
  const DPadKey({
    super.key,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00D4FF);
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: enabled ? accent.withAlpha(30) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Icon(
            icon,
            color: enabled ? accent : Colors.white24,
            size: 22,
          ),
        ),
      ),
    );
  }
}
