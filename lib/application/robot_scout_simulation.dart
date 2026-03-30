/// robot_scout_simulation.dart
///
/// Local Flutter simulation of robot scouting / fog-of-war reveal.
///
/// Rules:
///  • Movement priority: Down → Left → Right → Up (towards unexplored cells).
///  • Vision:  Robot sees its current cell + 8 orthogonal/diagonal neighbours
///             (3×3 block).  All 9 cells are marked as explored on arrival.
///  • Frontier: from the 8 neighbours check their outer adjacent cells; if any
///              of those have unexplored cells the robot moves in that direction
///              using priority order.
///  • Truck bays (CellType.dock): treated as stationary scout robots that
///             instantly reveal themselves + their 8 neighbours.
///  • Replenishment: when a rack cell is explored with qty < 50% capacity,
///             an active event is raised.
///  • Cache flush: fire-and-forget every 15 s (or when cache hits 75 entries).
///             Robots NEVER pause for a flush. Web uses sendBeacon (survives
///             tab close); native uses an unawaited HTTP POST.
///             Slight data loss (<15 s) on hard refresh is acceptable.
///  • Saboteur: WMS update is skipped; only the reality discovery is recorded.
library;

import 'dart:async';
import 'dart:convert';
// dart:js gives direct access to the browser's window object for the
// sendBeacon registration helper defined in web/index.html.
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../env.dart';
import '../models/warehouse_config.dart';
import '../core/auth/auth_provider.dart';
import 'providers.dart';

// ── Movement priority: Down / Left / Right / Up ───────────────────────────────
const List<({int dr, int dc, String name})> kPriority = [
  (dr: 1, dc: 0, name: 'down'),
  (dr: 0, dc: -1, name: 'left'),
  (dr: 0, dc: 1, name: 'right'),
  (dr: -1, dc: 0, name: 'up'),
];

// ── Single robot scouting agent ───────────────────────────────────────────────

class ScoutBot {
  ScoutBot({
    required this.id,
    required this.row,
    required this.col,
    required this.isTruck,
  });

  final String id;
  int row;
  int col;
  final bool isTruck;

  // History kept to avoid immediately back-tracking
  final List<({int row, int col})> _history = [];
  static const int _historyDepth = 6;

  void _recordPosition() {
    _history.add((row: row, col: col));
    if (_history.length > _historyDepth) _history.removeAt(0);
  }

  bool _recentlyVisited(int r, int c) =>
      _history.any((h) => h.row == r && h.col == c);

  /// Move one step towards unexplored territory.
  /// Returns the cells newly explored this step (as "row,col" strings).
  Set<String> step(WarehouseConfig config, Set<String> explored) {
    if (isTruck) return {}; // trucks are stationary

    _recordPosition();
    final rows = config.rows;
    final cols = config.cols;

    // ── 1. Determine the set of walkable neighbours ──────────────────────────
    //  We try directions in priority order.  A direction is "desirable" if it
    //  leads towards unexplored cells (i.e. from the target cell at least one of
    //  its 8 neighbours is unexplored).
    ({int dr, int dc, String name})? bestMove;

    for (final dir in kPriority) {
      final nr = row + dir.dr;
      final nc = col + dir.dc;
      if (nr < 0 || nr >= rows || nc < 0 || nc >= cols) continue;

      // Must be walkable OR empty (unexplored floor we can traverse)
      final cell = _cellAt(config, nr, nc);
      final t = cell?.type ?? CellType.empty;
      // Robots walk on path tiles + empty tiles (blank = possible path)
      if (t.isRack ||
          t == CellType.obstacle ||
          t == CellType.tree ||
          t == CellType.packStation) {
        continue;
      }

      // Avoid immediate backtrack unless no other option
      if (_recentlyVisited(nr, nc) && kPriority.length > 1) continue;

      // Check if this direction leads towards darkness
      if (_leadsToDark(nr, nc, config, explored)) {
        bestMove = dir;
        break; // take first (highest priority) dark direction
      }
    }

    // If no dark direction found, pick any walkable non-recent direction
    if (bestMove == null) {
      for (final dir in kPriority) {
        final nr = row + dir.dr;
        final nc = col + dir.dc;
        if (nr < 0 || nr >= rows || nc < 0 || nc >= cols) continue;
        final t = _cellAt(config, nr, nc)?.type ?? CellType.empty;
        if (t.isRack ||
            t == CellType.obstacle ||
            t == CellType.tree ||
            t == CellType.packStation) {
          continue;
        }
        if (_recentlyVisited(nr, nc)) continue;
        bestMove = dir;
        break;
      }
    }

    // If still null → all neighbours blocked or visited; reset history
    if (bestMove == null) {
      _history.clear();
      return _revealAround(row, col, config, explored);
    }

    row += bestMove.dr;
    col += bestMove.dc;
    return _revealAround(row, col, config, explored);
  }

  /// Mark the 3×3 area around (r,c) as explored.
  Set<String> _revealAround(
      int r, int c, WarehouseConfig config, Set<String> existing) {
    final revealed = <String>{};
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final nr = r + dr;
        final nc = c + dc;
        if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols)
          continue;
        final key = '$nr,$nc';
        if (!existing.contains(key)) revealed.add(key);
      }
    }
    return revealed;
  }

  /// Does moving to (tr,tc) put the robot in a position where ≥1 neighbour
  /// of (tr,tc) is unexplored?
  bool _leadsToDark(
      int tr, int tc, WarehouseConfig config, Set<String> explored) {
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final nr = tr + dr;
        final nc = tc + dc;
        if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols)
          continue;
        if (!explored.contains('$nr,$nc')) return true;
      }
    }
    return false;
  }

  static WarehouseCell? _cellAt(WarehouseConfig cfg, int r, int c) {
    try {
      return cfg.cells.lastWhere((x) => x.row == r && x.col == c);
    } catch (_) {
      return null;
    }
  }

  /// Cells that are revealed by this bot at its current position (initial seed).
  Set<String> initialReveal(WarehouseConfig config) =>
      _revealAround(row, col, config, const {});
}

// ── Discovery cache entry ─────────────────────────────────────────────────────

class _CacheEntry {
  _CacheEntry({
    required this.row,
    required this.col,
    required this.cellType,
    this.skuId,
    required this.quantity,
    required this.maxQuantity,
    required this.discoveredBy,
  });
  final int row, col;
  final String cellType;
  final String? skuId;
  final int quantity, maxQuantity;
  final String discoveredBy;

  Map<String, dynamic> toJson() => {
        'row': row,
        'col': col,
        'cell_type': cellType,
        if (skuId != null) 'sku_id': skuId,
        'quantity': quantity,
        'max_quantity': maxQuantity,
        'discovered_by': discoveredBy,
      };
}

// ── Main simulation class ─────────────────────────────────────────────────────

/// Manages all scouting bots, the discovery cache, and the 30-second WMS flush.
///
/// Usage:
/// ```dart
/// final sim = RobotScoutSimulation(config: cfg, ref: ref, isSaboteur: false);
/// sim.start(); // automated
/// // or
/// sim.step();  // manual
/// sim.dispose();
/// ```
class RobotScoutSimulation {
  RobotScoutSimulation({
    required this.config,
    required this.ref,
    required this.isSaboteur,
    this.stepIntervalMs = 400,
    String? backendBase,
  }) : backendBase = backendBase ?? gatewayBaseUrl {
    _buildBots();
    _seedInitialReveal();
  }

  final WarehouseConfig config;
  final WidgetRef ref;
  final bool isSaboteur;
  final int stepIntervalMs;
  final String backendBase;

  final List<ScoutBot> _bots = [];
  final List<_CacheEntry> _cache = [];
  final Set<String> _cacheKeys = {}; // O(1) dedup index by 'row,col'
  Timer? _stepTimer;
  Timer? _flushTimer;
  bool _running = false;

  // Cache cap: flush early when this many entries accumulate so individual
  // beacons stay well under the sendBeacon 64 KB limit.
  static const int _cacheCap = 75;

  // ── Initialise bots from robot spawn points + truck dock cells ───────────

  void _buildBots() {
    // One bot per robot spawn
    for (final spawn in config.robotSpawns) {
      _bots.add(ScoutBot(
        id: spawn.name ?? '${spawn.robotType}-${spawn.row}-${spawn.col}',
        row: spawn.row,
        col: spawn.col,
        isTruck: false,
      ));
    }
    // One stationary "truck" bot per dock cell
    for (final cell in config.cells) {
      if (cell.type == CellType.dock) {
        _bots.add(ScoutBot(
          id: 'truck-${cell.row}-${cell.col}',
          row: cell.row,
          col: cell.col,
          isTruck: true,
        ));
      }
    }
    // If no robots spawned, add a default bot at (0,0)
    if (_bots.every((b) => b.isTruck)) {
      final first = config.cells.firstWhere(
        (c) => c.type.isWalkable,
        orElse: () => WarehouseCell(row: 0, col: 0, type: CellType.empty),
      );
      _bots.add(ScoutBot(
          id: 'default-bot', row: first.row, col: first.col, isTruck: false));
    }
  }

  // ── Seed initial reveal for all bot starting positions ───────────────────
  // Only reveals fog-of-war around spawn points — does NOT record inventory
  // discoveries.  WMS is populated exclusively when robots physically move
  // and scan rack locations (via _tick → _recordDiscoveriesAt).

  void _seedInitialReveal() {
    final exploredN = ref.read(exploredCellsProvider.notifier);
    for (final bot in _bots) {
      final revealed = bot.initialReveal(config);
      for (final key in revealed) {
        final parts = key.split(',');
        exploredN.markExplored(int.parse(parts[0]), int.parse(parts[1]));
      }
      // NOTE: no _recordDiscoveriesAt here — robots must physically move to
      // a cell before it is reported to the WMS backend.
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Start auto-scouting: creates both the 400 ms step timer and the 15 s
  /// flush timer.  Call [startManual] instead when in manual mode so that
  /// the step timer is never created and robots cannot move on their own.
  void start() {
    if (_running) return;
    _running = true;
    _stepTimer =
        Timer.periodic(Duration(milliseconds: stepIntervalMs), (_) => _tick());
    _flushTimer ??=
        Timer.periodic(const Duration(seconds: 15), (_) => _flush());
  }

  /// Start manual mode: creates ONLY the 15 s flush timer so that
  /// STEP-driven discoveries still reach the backend.
  /// The step timer is never created, so robots cannot auto-move.
  void startManual() {
    // _running stays false — no step timer is ever created.
    _flushTimer ??=
        Timer.periodic(const Duration(seconds: 15), (_) => _flush());
  }

  /// Advance all bots one step (used by the STEP button in manual mode).
  /// Also persists explored cells locally so a refresh restores them.
  void step() {
    _tick();
    _saveExploredCellsLocally();
  }

  void pause() {
    _running = false;
    _stepTimer?.cancel();
    _stepTimer = null;
  }

  void resume() {
    if (_running) return;
    _running = true;
    _stepTimer =
        Timer.periodic(Duration(milliseconds: stepIntervalMs), (_) => _tick());
  }

  void dispose() {
    _stepTimer?.cancel();
    _flushTimer?.cancel();
    _running = false;
  }

  // ── Internal tick ─────────────────────────────────────────────────────────

  void _tick() {
    // Robots never pause — flush happens in the background.
    final exploredN = ref.read(exploredCellsProvider.notifier);
    final current = ref.read(exploredCellsProvider);

    for (final bot in _bots) {
      if (bot.isTruck) continue; // trucks are stationary
      final newly = bot.step(config, current);
      for (final key in newly) {
        final parts = key.split(',');
        exploredN.markExplored(int.parse(parts[0]), int.parse(parts[1]));
      }
      _recordDiscoveriesAt(bot.row, bot.col, bot.id);
    }
    // Early flush: if the cache is full, send now without waiting for the timer.
    if (_cache.length >= _cacheCap) _flush();
  }

  // ── Record what the robot sees at its current position ───────────────────

  void _recordDiscoveriesAt(int r, int c, String botId) {
    final eventsN = ref.read(activeEventsProvider.notifier);
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final nr = r + dr;
        final nc = c + dc;
        if (nr < 0 || nr >= config.rows || nc < 0 || nc >= config.cols)
          continue;
        final cell = _cellAt(nr, nc);
        if (cell == null) continue;

        // Only log meaningful cells to cache
        if (cell.type == CellType.empty || cell.type.isWalkable) {
          if (dr == 0 && dc == 0) {
            // at least log immediate position
            _addToCache(cell, botId);
          }
        } else {
          _addToCache(cell, botId);
        }

        // Raise replenishment event for rack cells that need it
        if (cell.type.isRack && cell.needsReplenishment && cell.quantity > 0) {
          eventsN.raise(nr, nc, 'REPLENISHMENT_NEEDED',
              color: '#F97316', speed: 'slow');
        }
        // Raise low-stock event for empty racks that had a SKU assigned
        if (cell.type.isRack && cell.isEmpty && cell.skuId != null) {
          eventsN.raise(nr, nc, 'OUT_OF_STOCK',
              color: '#EF4444', speed: 'fast');
        }

        // Map SKU staging + outbound/pack station inventory to orders (fire event)
        if ((cell.type == CellType.palletStaging ||
                cell.type == CellType.outbound ||
                cell.type == CellType.packStation) &&
            cell.skuId != null) {
          eventsN.raise(nr, nc, 'STAGING_MAPPED',
              color: '#00D4FF', speed: 'slow');
        }
      }
    }
  }

  void _addToCache(WarehouseCell cell, String botId) {
    final key = '${cell.row},${cell.col}';
    if (_cacheKeys.contains(key)) return;
    _cacheKeys.add(key);
    _cache.add(_CacheEntry(
      row: cell.row,
      col: cell.col,
      cellType: cell.type.name,
      skuId: cell.skuId,
      quantity: cell.quantity,
      maxQuantity: cell.maxQuantity,
      discoveredBy: botId,
    ));
  }

  WarehouseCell? _cellAt(int r, int c) {
    try {
      return config.cells.lastWhere((x) => x.row == r && x.col == c);
    } catch (_) {
      return null;
    }
  }

  // ── Fire-and-forget WMS flush ─────────────────────────────────────────────
  //
  // Design goals:
  //   • Robots NEVER pause. Sending is fully decoupled from the sim loop.
  //   • On web: navigator.sendBeacon — queued by the browser, survives tab
  //     close, zero main-thread overhead, no response handling needed.
  //   • On native: unawaited HTTP POST — same fire-and-forget semantics.
  //   • Slight loss (<20 s of discoveries) on hard-refresh is acceptable.
  //   • Explored-cell fog-of-war IS saved to localStorage on every flush
  //     and every manual step, so the map always survives a refresh.

  void _flush() {
    // Always snapshot fog-of-war — this is the cheap, critical piece.
    _saveExploredCellsLocally();

    if (_cache.isEmpty) return;

    // Snapshot and clear immediately so the sim loop keeps accumulating
    // into a fresh list while the beacon/HTTP is in flight.
    final batch = List<_CacheEntry>.from(_cache);
    _cache.clear();
    _cacheKeys.clear();

    final auth = ref.read(authProvider);
    final sessionId = auth is AuthLoggedIn
        ? auth.session.effectiveSessionId
        : 'local-session';
    final payload = jsonEncode({
      'warehouse_id': config.id,
      'is_saboteur': isSaboteur,
      'session_id': sessionId,
      'discoveries': batch.map((e) => e.toJson()).toList(),
    });

    if (kIsWeb) {
      // sendBeacon: browser-managed, non-blocking, survives navigation.
      try {
        js.context.callMethod(
            'woisSendBeacon', ['$backendBase/api/scout-report', payload]);
        return; // done — browser handles delivery
      } catch (_) {
        // JS bridge unavailable (unit-test) — fall through to HTTP.
      }
    }
    // Native / test fallback: fire-and-forget HTTP POST.
    _postToBackend(payload).ignore();
  }

  /// Persists the fog-of-war cell list to localStorage so a refresh
  /// always restores the visual map.  Cheap: one key, run often.
  void _saveExploredCellsLocally() {
    // Run async but don't await — we don't need to block anything on this.
    Future.microtask(() async {
      try {
        final explored = ref.read(exploredCellsProvider);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'explored_cells_${config.id}', jsonEncode(explored.toList()));
        await prefs.setBool('ops_started', true);
        await prefs.setString('ops_warehouse_id', config.id);
      } catch (_) {}
    });
  }

  Future<void> _postToBackend(String jsonPayload) async {
    final url = Uri.parse('$backendBase/api/scout-report');
    await http.post(url,
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': 'wois-gateway-internal-key-2026',
        },
        body: jsonPayload);
    // Non-2xx responses are silently ignored (offline resilience).
  }

  // ── Accessors (for UI) ────────────────────────────────────────────────────

  /// Current bot positions as a list of (row, col) tuples for the painter.
  List<({String id, int row, int col, bool isTruck})> get botPositions => _bots
      .map((b) => (id: b.id, row: b.row, col: b.col, isTruck: b.isTruck))
      .toList();

  bool get isRunning => _running;
  int get cachedDiscoveries => _cache.length;
}

// ── Provider ──────────────────────────────────────────────────────────────────

/// Holds the active simulation instance, or null before ops start.
final scoutSimulationProvider =
    StateProvider<RobotScoutSimulation?>((ref) => null);
