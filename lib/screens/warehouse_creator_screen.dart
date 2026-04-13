/// warehouse_creator_screen.dart — Interactive warehouse layout designer.
///
/// Features:
///  • Tap / drag to paint cells onto the grid
///  • Palette of all CellType options with colour swatches
///  • Template gallery (bottom sheet)
///  • Eraser tool
///  • Save to Riverpod provider (live floor reflects design)
///  • Share — copies base64 code to clipboard + shows shareable URL
library;

import 'dart:async';
import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../application/providers.dart';
import '../models/warehouse_config.dart';
import '../application/robot_scout_simulation.dart';
import '../warehouse_engine/services/warehouse_template_factory.dart';
import '../core/auth/auth_provider.dart';
import '../core/api_client.dart';

/// The one account that can write/overwrite standard (shared-with-all) templates.
const _kSuperUserEmail = 'krishnavijayaram@gmail.com';

// ── Palette (curated; crossAisle/legacy types omitted) ────────────────────────

const _kPaletteTypes = [
  CellType.rackLoose,
  CellType.aisle,
  CellType.packStation,
  CellType.palletStaging,
  CellType.outbound,
  CellType.inbound,
  CellType.chargingFast,
  CellType.chargingSlow,
  CellType.dock,
  CellType.obstacle,
  CellType.tree,
  CellType.dump,
  CellType.conveyorE,
  CellType.conveyorW,
  CellType.conveyorN,
  CellType.conveyorS,
  CellType.roadH,
  CellType.roadV,
  CellType.roadCornerNE,
  CellType.roadCornerNW,
  CellType.roadCornerSE,
  CellType.roadCornerSW,
  CellType.robotPath,
];

// ── Screen ────────────────────────────────────────────────────────────────────

class WarehouseCreatorScreen extends ConsumerStatefulWidget {
  const WarehouseCreatorScreen({super.key});

  @override
  ConsumerState<WarehouseCreatorScreen> createState() =>
      _WarehouseCreatorScreenState();
}

class _WarehouseCreatorScreenState
    extends ConsumerState<WarehouseCreatorScreen> {
  static const _bg = Color(0xFF0D1117);
  static const _surface = Color(0xFF161B22);
  static const _border = Color(0xFF30363D);
  static const _cyan = Color(0xFF00D4FF);
  static const _text = Color(0xFFE6EDF3);

  // Grid config
  int _rows = 16;
  int _cols = 24;

  // Canvas transform
  double _scale = 1.0;
  double _baseScale = 1.0;
  Offset _offset = Offset.zero;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;

  // Editing state
  CellType _selectedType = CellType.rackLoose;
  bool _eraser = false;
  PickZoneType? _paintingZone; // null = cell-paint; non-null = zone-paint
  List<WarehouseCell> _cells = [];
  List<RobotSpawn> _spawns = [];
  List<PickZoneDef> _zones = [];
  int? _zoneDragStartRow;
  int? _zoneDragStartCol;
  int? _zoneDragCurrentRow;
  int? _zoneDragCurrentCol;
  String _name = 'My Warehouse';
  // Stable warehouse ID — generated once per session and reused on every
  // Save / Publish so the backend always gets the same ID for the same design.
  late String _stableId;
  final _nameCtrl = TextEditingController(text: 'My Warehouse');

  // Hover state (for cell info tooltip)
  Offset? _hoverLocal;
  int? _hoverRow, _hoverCol;

  // Tracked template: null = scratch / autosave; set on template load
  WarehouseTemplate? _loadedTemplate;
  // User-created templates (loaded from SharedPreferences)
  List<_UserTemplate> _userTemplates = [];
  // Templates shared with the current user by others
  List<_UserTemplate> _sharedTemplates = [];
  // Super-user standard templates (persisted, visible to all)
  List<_UserTemplate> _stdUserTemplates = [];
  // Super-user overrides for hardcoded standard templates
  List<_UserTemplate> _stdOverrides = [];

  // Undo / redo — snapshots capture (cells, zones) on each gesture start
  static const _kMaxHistory = 50;
  final _history = <({List<WarehouseCell> cells, List<PickZoneDef> zones})>[];
  final _redoStack = <({List<WarehouseCell> cells, List<PickZoneDef> zones})>[];
  bool _historyPushedThisGesture = false;
  Timer? _autosaveTimer;

  @override
  void initState() {
    super.initState();
    _stableId = 'wh-${DateTime.now().millisecondsSinceEpoch}';
    _loadFromProviderOrPrefs();
    _loadUserTemplates();
    // Autosave every 30 s while the designer is open
    _autosaveTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _autosave(),
    );
  }

  void _loadFromProviderOrPrefs() {
    final existing = ref.read(warehouseConfigProvider);
    if (existing != null) {
      final baseCells = List<WarehouseCell>.from(existing.cells);
      final hasInventory =
          baseCells.any((c) => c.type.isRack && c.quantity > 0);
      setState(() {
        _rows = existing.rows;
        _cols = existing.cols;
        _cells = hasInventory ? baseCells : assignTemplateInventory(baseCells);
        _spawns = List.from(existing.robotSpawns);
        _zones = List.from(existing.zones);
        _name = existing.name;
        _nameCtrl.text = existing.name;
        // Reuse the existing warehouse ID so the DB record stays stable.
        _stableId = existing.id;
      });
    } else {
      // On browser refresh the Riverpod provider is wiped.
      // Priorities:
      //   1. 'warehouse_config'  — written by both _save() and _publish()
      //   2. 'warehouse_autosave' — written by the 30 s autosave timer
      SharedPreferences.getInstance().then((prefs) {
        if (!mounted) return;
        final code = prefs.getString('warehouse_config') ??
            prefs.getString('warehouse_autosave');
        if (code == null) return;
        final cfg = WarehouseConfig.fromShareCode(code);
        if (cfg == null) return;
        final baseCells = List<WarehouseCell>.from(cfg.cells);
        final hasInventory =
            baseCells.any((c) => c.type.isRack && c.quantity > 0);
        setState(() {
          _rows = cfg.rows;
          _cols = cfg.cols;
          _cells =
              hasInventory ? baseCells : assignTemplateInventory(baseCells);
          _spawns = List.from(cfg.robotSpawns);
          _zones = List.from(cfg.zones);
          _name = cfg.name;
          _nameCtrl.text = cfg.name;
          // Reuse ID from saved config.
          _stableId = cfg.id;
        });
      });
    }
  }

  // ── Cell operations ──────────────────────────────────────────────────────

  // ── Placement validation helpers ─────────────────────────────────────────

  /// Returns the effective CellType at (r,c), checking painted cells first.
  CellType _typeAt(int r, int c) {
    for (var i = _cells.length - 1; i >= 0; i--) {
      final cell = _cells[i];
      if (cell.row == r && cell.col == c) return cell.type;
    }
    return CellType.empty;
  }

  /// True if (r,c) has at least one orthogonal neighbour that is a path cell
  /// (aisle, crossAisle, robotPath, or any road type).
  bool _hasAdjacentPath(int r, int c) {
    for (final d in [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nr = r + d.$1, nc = c + d.$2;
      if (nr < 0 || nr >= _rows || nc < 0 || nc >= _cols) continue;
      final t = _typeAt(nr, nc);
      if (t.isWalkable) return true;
    }
    return false;
  }

  /// True if (r,c) is a valid charger position.
  ///
  /// Rule 3: EVERY orthogonal neighbour that exists within the grid must be
  /// walkable (aisle/road/path) or empty.  Grid boundary counts as a free
  /// side — a charger may sit at the edge or corner of the warehouse.
  /// At least one orthogonal neighbour must be an actual walkable path cell.
  bool _canPlaceCharger(int r, int c) {
    var hasPath = false;
    for (final d in [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nr = r + d.$1, nc = c + d.$2;
      if (nr < 0 || nr >= _rows || nc < 0 || nc >= _cols) {
        continue; // boundary = free
      }
      final t = _typeAt(nr, nc);
      if (!t.isWalkable && t != CellType.empty) {
        return false; // blocked side → invalid
      }
      if (t.isWalkable) hasPath = true;
    }
    return hasPath; // must have ≥1 actual path neighbour
  }

  /// True if (r,c) has an adjacent outbound dock cell or any walkable cell.
  bool _hasAdjacentOutboundOrPath(int r, int c) {
    for (final d in [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
      final nr = r + d.$1, nc = c + d.$2;
      if (nr < 0 || nr >= _rows || nc < 0 || nc >= _cols) continue;
      final t = _typeAt(nr, nc);
      if (t == CellType.outbound || t.isWalkable) return true;
    }
    return false;
  }

  /// Validate placement, show a snack if blocked, return false to abort.
  bool _validatePlacement(int row, int col, CellType type) {
    if (_eraser) return true; // erasure always allowed

    // ── Rule 1: Rack and Aisle are mutually exclusive at the same cell ──────
    // Painting a rack over an aisle (or aisle over a rack) implicitly erases
    // the existing cell — the new type simply replaces it.  A cell can never
    // be BOTH types simultaneously; the old one is removed first.
    final existing = _typeAt(row, col);
    if (type.isRack &&
        (existing == CellType.aisle || existing == CellType.crossAisle)) {
      _cells.removeWhere((c) => c.row == row && c.col == col);
    }
    if ((type == CellType.aisle || type == CellType.crossAisle) &&
        existing.isRack) {
      _cells.removeWhere((c) => c.row == row && c.col == col);
    }

    if (type.isCharger) {
      if (!_canPlaceCharger(row, col)) {
        _showPlacementError(
            'Charger: all adjacent cells must be open paths (boundary is OK).');
        return false;
      }
    }
    if (type.isRack ||
        type == CellType.aisle ||
        type == CellType.packStation ||
        type == CellType.palletStaging ||
        type == CellType.looseStaging ||
        type == CellType.caseStaging ||
        type == CellType.dump) {
      if (!_hasAdjacentPath(row, col)) {
        _showPlacementError('This cell must be adjacent to a path cell.');
        return false;
      }
    }
    if (type == CellType.outbound) {
      if (!_hasAdjacentOutboundOrPath(row, col)) {
        _showPlacementError(
            'Outbound dock must be adjacent to another outbound dock or a path cell.');
        return false;
      }
    }
    return true;
  }

  void _showPlacementError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF7F1D1D),
        duration: const Duration(seconds: 2),
      ));
  }

  void _paintCell(Offset localPos, Size canvasSize) {
    final cw = (canvasSize.width / _cols) * _scale;
    final ch = (canvasSize.height / _rows) * _scale;
    final col = ((localPos.dx - _offset.dx) / cw).floor();
    final row = ((localPos.dy - _offset.dy) / ch).floor();
    if (row < 0 || row >= _rows || col < 0 || col >= _cols) return;
    if (!_validatePlacement(row, col, _selectedType)) return;
    if (!_historyPushedThisGesture) {
      _pushHistory();
      _historyPushedThisGesture = true;
    }
    setState(() {
      _cells.removeWhere((c) => c.row == row && c.col == col);
      if (!_eraser) {
        _cells.add(WarehouseCell(row: row, col: col, type: _selectedType));
      }
    });
    _scheduleAutosave();
  }
  // ── Zone operations ──────────────────────────────────────────────────────────

  ({int row, int col})? _posToCell(Offset localPos, Size canvasSize) {
    final cw = (canvasSize.width / _cols) * _scale;
    final ch = (canvasSize.height / _rows) * _scale;
    final col = ((localPos.dx - _offset.dx) / cw).floor();
    final row = ((localPos.dy - _offset.dy) / ch).floor();
    if (col < 0 || col >= _cols || row < 0 || row >= _rows) return null;
    return (row: row, col: col);
  }

  void _applyZone() {
    if (_paintingZone == null ||
        _zoneDragStartCol == null ||
        _zoneDragStartRow == null) {
      return;
    }
    final c1 = _zoneDragStartCol!, c2 = _zoneDragCurrentCol ?? c1;
    final r1 = _zoneDragStartRow!, r2 = _zoneDragCurrentRow ?? r1;
    final colStart = c1 < c2 ? c1 : c2, colEnd = c1 < c2 ? c2 : c1;
    final rowStart = r1 < r2 ? r1 : r2, rowEnd = r1 < r2 ? r2 : r1;
    final zone = PickZoneDef(
      type: _paintingZone!,
      rowStart: rowStart,
      rowEnd: rowEnd,
      colStart: colStart,
      colEnd: colEnd,
    );
    bool overlaps(PickZoneDef z) =>
        z.rowStart <= rowEnd &&
        z.rowEnd >= rowStart &&
        z.colStart <= colEnd &&
        z.colEnd >= colStart;
    _pushHistory();
    setState(() {
      _zones = [..._zones.where((z) => !overlaps(z)), zone];
      _zoneDragStartRow = null;
      _zoneDragStartCol = null;
      _zoneDragCurrentRow = null;
      _zoneDragCurrentCol = null;
    });
    _scheduleAutosave();
  }
  // ── History: Undo / Redo ──────────────────────────────────────────────────────

  void _pushHistory() {
    _history.add((cells: List.from(_cells), zones: List.from(_zones)));
    if (_history.length > _kMaxHistory) _history.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_history.isEmpty) return;
    _redoStack.add((cells: List.from(_cells), zones: List.from(_zones)));
    final snap = _history.removeLast();
    setState(() {
      _cells = snap.cells;
      _zones = snap.zones;
    });
    _scheduleAutosave();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _history.add((cells: List.from(_cells), zones: List.from(_zones)));
    final snap = _redoStack.removeLast();
    setState(() {
      _cells = snap.cells;
      _zones = snap.zones;
    });
    _scheduleAutosave();
  }

  // ── Auto-save ───────────────────────────────────────────────────────────────────

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 15), _autosave);
  }

  Future<void> _autosave() async {
    if (!mounted) return;
    final cfg = _buildConfig();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('warehouse_autosave', cfg.toShareCode());
    // Also persist the draft to the backend if we have a real warehouse ID.
    // Fire-and-forget — UI is never blocked.
    final id = cfg.id;
    if (!id.startsWith('local') && id.isNotEmpty) {
      final auth = ref.read(authProvider);
      final userId = auth is AuthLoggedIn ? auth.user.id : 'local';
      ApiClient.instance
          .patchWarehouseDraft(
              warehouseId: id, configJson: cfg.toShareCode(), ownerId: userId)
          .catchError((_) {});
    }
  }

  // ── Publish ────────────────────────────────────────────────────────────────────

  Future<void> _publish() async {
    // Ensure rack cells have inventory before publishing.  If the user drew
    // a layout manually (not from a template) or cleared inventory, the racks
    // will have no SKU assignments.  Without inventory in Reality DB, robots
    // have nothing to discover and the WMS dashboard stays empty.
    final hasInv = _cells.any((c) => c.type.isRack && c.quantity > 0);
    if (!hasInv) {
      _cells = assignTemplateInventory(_cells);
    }

    final cfg = _buildConfig();
    ref.read(warehouseConfigProvider.notifier).state = cfg;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('warehouse_config', cfg.toShareCode());
    await prefs.setString('warehouse_published', cfg.toShareCode());
    await prefs.setString(
        'warehouse_autosave', cfg.toShareCode()); // keep in sync
    if (!mounted) return;

    // Persist warehouse to backend DB so robot observations, WMS dashboard,
    // and FLEET tabs all have a warehouse record to associate with.
    final auth = ref.read(authProvider);
    final userId = auth is AuthLoggedIn ? auth.user.id : 'local';
    try {
      final result = await ApiClient.instance.publishWarehouse(
        warehouseId: cfg.id,
        name: cfg.name,
        configJson: cfg.toShareCode(),
        ownerId: userId,
      );
      debugPrint(
        '✅ Warehouse persisted to DB: id=${cfg.id} '
        'cells=${result['cells_seeded']} robots=${result['robots_seeded']} '
        'trucks=${result['trucks_seeded'] ?? 0}',
      );
    } catch (e) {
      debugPrint('⚠️  Backend warehouse publish failed (offline mode): $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
              'Backend offline — exploring in local mode.\nInventory will sync when the backend is available.'),
          backgroundColor: const Color(0xFF1C3A4F),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'OK',
            textColor: Colors.white,
            onPressed: () {},
          ),
        ));
        // Fall through — allow ops to start using local state even if backend
        // is unreachable.  Discoveries will sync on the next successful flush.
      }
    }
    if (!mounted) return;
    // Reset all ops state so the floor goes dark again.
    ref.read(operationsStartedProvider.notifier).state = false;
    ref.read(exploredCellsProvider.notifier).reset();
    ref.read(activeEventsProvider.notifier).resolveAll();
    final prevSim = ref.read(scoutSimulationProvider);
    prevSim?.dispose();
    ref.read(scoutSimulationProvider.notifier).state = null;

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Published \u2014 choose a mode to start operations'),
      backgroundColor: Color(0xFF1C3A4F),
      duration: Duration(seconds: 2),
    ));

    // Show start-operations dialog (non-dismissible until user picks a mode)
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StartOpsDialog(config: cfg),
    );
  }
  // ── Save / share ─────────────────────────────────────────────────────────

  WarehouseConfig _buildConfig() {
    final auth = ref.read(authProvider);
    final userId = auth is AuthLoggedIn ? auth.user.id : 'local';
    return WarehouseConfig(
      id: _stableId,
      name: _name,
      description: '$_rows × $_cols custom warehouse',
      rows: _rows,
      cols: _cols,
      cells: List.from(_cells),
      robotSpawns: List.from(_spawns),
      zones: List.from(_zones),
      ownerId: userId,
    );
  }

  Future<void> _save() async {
    // System templates are read-only — redirect to "Save as new user template".
    if (_loadedTemplate?.isSystem == true) {
      _showSaveTemplateDialog(prefillName: '${_loadedTemplate!.name} (copy)');
      return;
    }
    final cfg = _buildConfig();
    ref.read(warehouseConfigProvider.notifier).state = cfg;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('warehouse_config', cfg.toShareCode());
    await prefs.setString('warehouse_autosave', cfg.toShareCode());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Draft saved ✅'),
      backgroundColor: Color(0xFF1C3A1C),
      duration: Duration(seconds: 2),
    ));
  }

  Future<void> _share() async {
    final cfg = _buildConfig();
    final code = cfg.toShareCode();
    final url = 'http://localhost:9090?wh=$code';
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => _ShareDialog(code: code, url: url),
    );
  }

  void _loadTemplate(WarehouseTemplate tpl) {
    final cfg = tpl.builder();
    // Assign fresh random inventory every time a template is loaded.
    final inventoriedCells = assignTemplateInventory(cfg.cells);
    // Sanitize: remove spawns that land on rack cells
    final sanitized = _sanitizeSpawns(cfg.robotSpawns, inventoriedCells);
    final removed = cfg.robotSpawns.length - sanitized.length;
    setState(() {
      _loadedTemplate = tpl;
      _rows = cfg.rows;
      _cols = cfg.cols;
      _cells = List.from(inventoriedCells);
      _spawns = sanitized;
      _zones = List.from(cfg.zones);
      _name = cfg.name;
      _nameCtrl.text = cfg.name;
      _offset = Offset.zero;
      _scale = 1.0;
    });
    Navigator.pop(context);
    final msg = removed > 0
        ? 'Template "${tpl.name}" loaded ($removed spawn(s) removed — were on rack cells)'
        : 'Template "${tpl.name}" loaded';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFF1C3A1C),
      duration: const Duration(seconds: 3),
    ));
  }

  /// Remove any robot spawns whose cell position is a rack cell.
  List<RobotSpawn> _sanitizeSpawns(
      List<RobotSpawn> spawns, List<WarehouseCell> cells) {
    return spawns.where((s) {
      final cellType = cells
          .lastWhere(
            (c) => c.row == s.row && c.col == s.col,
            orElse: () =>
                WarehouseCell(row: s.row, col: s.col, type: CellType.empty),
          )
          .type;
      return !cellType.isRack;
    }).toList();
  }

  void _showTemplates() {
    // Merge hardcoded standard templates with super-user-added ones.
    // Also apply any super-user overrides to hardcoded templates.
    final overrideMap = {for (final o in _stdOverrides) o.name: o};
    final overriddenNames = overrideMap.keys.toSet();

    final stdUserAsWarehouseTemplates = _stdUserTemplates
        .map((ut) {
          final cfg = WarehouseConfig.fromShareCode(ut.code);
          if (cfg == null) return null;
          return WarehouseTemplate(
            name: ut.name,
            description: '${cfg.rows}×${cfg.cols} — Standard (admin)',
            rows: cfg.rows, cols: cfg.cols,
            tags: const ['standard', 'custom'],
            builder: () => cfg,
            isSystem: false, // super user can edit these
          );
        })
        .whereType<WarehouseTemplate>()
        .toList();

    final patchedSystemTemplates = kWarehouseTemplates.map((t) {
      final override = overrideMap[t.name];
      if (override == null) return t;
      final cfg = WarehouseConfig.fromShareCode(override.code);
      if (cfg == null) return t;
      return WarehouseTemplate(
        name: t.name,
        description: '${cfg.rows}×${cfg.cols} — ${t.description} ✏️',
        rows: cfg.rows,
        cols: cfg.cols,
        tags: [...t.tags, 'overridden'],
        builder: () => cfg,
        isSystem: true,
      );
    }).toList();

    final allSystemTemplates = [
      ...patchedSystemTemplates,
      ...stdUserAsWarehouseTemplates
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: _surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, sc) => _TemplateGallery(
          scrollController: sc,
          systemTemplates: allSystemTemplates,
          userTemplates: _userTemplates,
          sharedTemplates: _sharedTemplates,
          isSuperUser: _isSuperUser,
          stdOverrideNames: overriddenNames,
          onSelect: _loadTemplate,
          onLoadUser: (ut) {
            final cfg = WarehouseConfig.fromShareCode(ut.code);
            if (cfg == null) return;
            final tpl = WarehouseTemplate(
              name: ut.name,
              description: '${cfg.rows}×${cfg.cols} custom',
              rows: cfg.rows,
              cols: cfg.cols,
              tags: const ['custom'],
              builder: () => cfg,
              isSystem: false,
            );
            _loadTemplate(tpl);
          },
          onDeleteUser: (ut) {
            Navigator.pop(context);
            _deleteUserTemplate(ut.name);
          },
          onDeleteStd: (ut) {
            Navigator.pop(context);
            _deleteStdUserTemplate(ut.name);
          },
          onShareTemplate: (ut) {
            Navigator.pop(context);
            _showShareWithDialog(ut);
          },
          onOverwriteSystem: (templateName) {
            Navigator.pop(context);
            _confirmOverwriteSystemTemplate(templateName);
          },
          onResetSystem: (templateName) {
            Navigator.pop(context);
            _resetSystemTemplate(templateName);
          },
        ),
      ),
    );
  }

  void _showShareWithDialog(_UserTemplate ut) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Share Template', style: TextStyle(color: _text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Share "${ut.name}" with another user.',
                style: const TextStyle(fontSize: 11, color: Color(0xFF8B949E))),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: _text, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Recipient e-mail…',
                hintStyle: const TextStyle(color: Color(0xFF8B949E)),
                filled: true,
                fillColor: const Color(0xFF0D1117),
                prefixIcon: const Icon(Icons.email_outlined,
                    size: 16, color: Color(0xFF8B949E)),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: _border)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _cyan),
            onPressed: () {
              Navigator.pop(context);
              final email = ctrl.text.trim();
              if (email.isNotEmpty) {
                _shareTemplateWithUser(ut.name, email);
              }
            },
            child: const Text('Share', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  void _showGridSizeDialog() {
    int newR = _rows, newC = _cols;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Grid Size', style: TextStyle(color: _text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NumberField('Rows (5–40)', _rows, (v) => newR = v, 5, 40),
            const SizedBox(height: 12),
            _NumberField('Cols (5–60)', _cols, (v) => newC = v, 5, 60),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _cyan),
            onPressed: () {
              setState(() {
                _rows = newR;
                _cols = newC;
              });
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      child: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              children: [
                _buildPalette(),
                Expanded(child: _buildCanvas()),
              ],
            ),
          ),
          _buildStatusBar(),
        ],
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() => Container(
        height: 48,
        color: _surface,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.warehouse, color: _cyan, size: 18),
            const SizedBox(width: 8),
            // Name field
            SizedBox(
              width: 180,
              child: TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: _text, fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Warehouse name…',
                  hintStyle: TextStyle(color: Color(0xFF8B949E)),
                ),
                onChanged: (v) => _name = v,
              ),
            ),
            const Spacer(),
            _ToolBtn(Icons.undo, 'Undo', _undo),
            _ToolBtn(Icons.redo, 'Redo', _redo),
            const SizedBox(width: 4),
            _ToolBtn(Icons.grid_4x4, 'Grid size', _showGridSizeDialog),
            _ToolBtn(Icons.style, 'Templates', _showTemplates),
            _ToolBtn(Icons.save_alt, 'Save draft', _save),
            _ToolBtn(Icons.bookmark_add, 'Save as Template',
                () => _showSaveTemplateDialog()),
            _ToolBtn(Icons.publish, 'Publish → Live', _publish),
            _ToolBtn(Icons.share, 'Share', _share),
            _ToolBtn(
                Icons.inventory_2, 'Manage Inventory', _showInventoryPanel),
            _ToolBtn(
                Icons.fit_screen,
                'Reset view',
                () => setState(() {
                      _scale = 1.0;
                      _offset = Offset.zero;
                    })),
          ],
        ),
      );

  // ── Left palette ──────────────────────────────────────────────────────────

  Widget _buildPalette() => Container(
        width: 130,
        color: _surface,
        child: Column(
          children: [
            // Eraser
            _PaletteEntry(
              color: const Color(0xFF4B5563),
              label: 'Eraser',
              selected: _eraser,
              onTap: () => setState(() {
                _eraser = true;
              }),
            ),
            const Divider(height: 1, color: _border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  ..._kPaletteTypes.map((t) => _PaletteEntry(
                        color: t.color,
                        label: t.label,
                        selected: !_eraser &&
                            _paintingZone == null &&
                            _selectedType == t,
                        onTap: () => setState(() {
                          _eraser = false;
                          _paintingZone = null;
                          _selectedType = t;
                        }),
                      )),
                  const Divider(height: 1, color: _border),
                  const Padding(
                    padding: EdgeInsets.only(left: 8, top: 6, bottom: 2),
                    child: Text('PICK ZONES',
                        style: TextStyle(
                            fontSize: 9,
                            color: Color(0xFF8B949E),
                            letterSpacing: 1.2)),
                  ),
                  ...PickZoneType.values.map((z) => _PaletteEntry(
                        color: z.color,
                        label: '${z.icon} ${z.label}',
                        selected: _paintingZone == z,
                        onTap: () => setState(() {
                          _paintingZone = (_paintingZone == z) ? null : z;
                          if (_paintingZone != null) _eraser = false;
                        }),
                      )),
                  if (_zones.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(() => _zones.clear()),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Text('✕ Clear all zones',
                            style: TextStyle(
                                fontSize: 10, color: Color(0xFFEF4444))),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );

  // ── Canvas ────────────────────────────────────────────────────────────────

  void _updateHover(Offset local, Size sz) {
    final cell = _posToCell(local, sz);
    if (cell?.row != _hoverRow || cell?.col != _hoverCol) {
      setState(() {
        _hoverLocal = local;
        _hoverRow = cell?.row;
        _hoverCol = cell?.col;
      });
    }
  }

  Widget _buildCanvas() => LayoutBuilder(builder: (_, constraints) {
        final sz = Size(constraints.maxWidth, constraints.maxHeight);
        return MouseRegion(
          onHover: (e) => _updateHover(e.localPosition, sz),
          onExit: (_) => setState(() {
            _hoverLocal = null;
            _hoverRow = null;
            _hoverCol = null;
          }),
          child: Stack(
            children: [
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    setState(() {
                      final zoomFactor =
                          event.scrollDelta.dy < 0 ? 1.1 : (1 / 1.1);
                      final newScale = (_scale * zoomFactor).clamp(0.3, 10.0);
                      final focal = event.localPosition;
                      _offset = focal - (focal - _offset) * (newScale / _scale);
                      _scale = newScale;
                    });
                  }
                },
                child: GestureDetector(
                  onSecondaryTapUp: (d) =>
                      _showCellContextMenu(d.localPosition, sz, context),
                  onScaleStart: (d) {
                    _baseScale = _scale;
                    _startFocal = d.focalPoint;
                    _startOffset = _offset;
                    if (_paintingZone != null) {
                      final cell = _posToCell(d.localFocalPoint, sz);
                      if (cell != null) {
                        setState(() {
                          _zoneDragStartRow = cell.row;
                          _zoneDragStartCol = cell.col;
                          _zoneDragCurrentRow = cell.row;
                          _zoneDragCurrentCol = cell.col;
                        });
                      }
                    }
                  },
                  onScaleUpdate: (d) {
                    setState(() {
                      _scale = (_baseScale * d.scale).clamp(0.3, 10.0);
                      _offset = _startOffset + (d.focalPoint - _startFocal);
                    });
                    if (d.pointerCount == 1 && d.scale == 1.0) {
                      if (_paintingZone != null) {
                        final cell = _posToCell(d.localFocalPoint, sz);
                        if (cell != null) {
                          setState(() {
                            _zoneDragCurrentRow = cell.row;
                            _zoneDragCurrentCol = cell.col;
                          });
                        }
                      } else {
                        _paintCell(d.localFocalPoint, sz);
                      }
                    }
                  },
                  onScaleEnd: (_) {
                    _historyPushedThisGesture = false;
                    if (_paintingZone != null && _zoneDragStartCol != null) {
                      _applyZone();
                    }
                  },
                  onTapDown: (d) {
                    _historyPushedThisGesture = false;
                    if (_paintingZone != null) {
                      final cell = _posToCell(d.localPosition, sz);
                      if (cell != null) {
                        setState(() {
                          _zoneDragStartRow = cell.row;
                          _zoneDragStartCol = cell.col;
                          _zoneDragCurrentRow = cell.row;
                          _zoneDragCurrentCol = cell.col;
                        });
                        _applyZone();
                      }
                    } else {
                      _paintCell(d.localPosition, sz);
                    }
                  },
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _CreatorPainter(
                        cells: _cells,
                        spawns: _spawns,
                        rows: _rows,
                        cols: _cols,
                        scale: _scale,
                        offset: _offset,
                        zones: _zones,
                        activeDragZone: _paintingZone,
                        dragRowStart: _zoneDragStartRow,
                        dragColStart: _zoneDragStartCol,
                        dragRowEnd: _zoneDragCurrentRow,
                        dragColEnd: _zoneDragCurrentCol,
                        hoverRow: _hoverRow,
                        hoverCol: _hoverCol,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ), // GestureDetector
              ), // Listener
              // ── Column ruler (top) — always visible ──────────────────────────
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 20,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RulerPainter(
                      offset: _offset,
                      scale: _scale,
                      rows: _rows,
                      cols: _cols,
                      canvasW: sz.width,
                      canvasH: sz.height,
                      isRow: false,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // ── Row ruler (left) — always visible ────────────────────────────
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 28,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RulerPainter(
                      offset: _offset,
                      scale: _scale,
                      rows: _rows,
                      cols: _cols,
                      canvasW: sz.width,
                      canvasH: sz.height,
                      isRow: true,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // ── Corner square covering ruler intersection ─────────────────────
              const Positioned(
                left: 0,
                top: 0,
                width: 28,
                height: 20,
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0xFF161B22)),
                ),
              ),
              // ── Hover info tooltip ───────────────────────────────────────────
              if (_hoverRow != null && _hoverLocal != null)
                _buildHoverTooltip(sz),
            ],
          ),
        );
      });

  // ── Hover tooltip overlay ─────────────────────────────────────────────────

  Widget _buildHoverTooltip(Size sz) {
    final r = _hoverRow!, c = _hoverCol!;
    final cw = (sz.width / _cols) * _scale;
    final ch = (sz.height / _rows) * _scale;

    // Cell info
    final cell = _cells.lastWhere((x) => x.row == r && x.col == c,
        orElse: () => WarehouseCell(row: r, col: c, type: CellType.empty));
    final zone = _zones
        .cast<PickZoneDef?>()
        .firstWhere((z) => z!.containsCell(r, c), orElse: () => null);
    final spawn = _spawns
        .cast<RobotSpawn?>()
        .firstWhere((s) => s!.row == r && s.col == c, orElse: () => null);

    const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final colLbl = c < 26 ? abc[c] : '${abc[(c ~/ 26) - 1]}${abc[c % 26]}';

    // Robot domain info
    String robotDomain = '';
    if (cell.type.isPickRobotDomain &&
        !cell.type.isInboundRobotDomain &&
        !cell.type.isOutboundRobotDomain) {
      robotDomain = '🤖 Pick robot';
    } else if (cell.type.isInboundRobotDomain &&
        !cell.type.isOutboundRobotDomain)
      robotDomain = '📦 Inbound robot';
    else if (cell.type.isOutboundRobotDomain && !cell.type.isInboundRobotDomain)
      robotDomain = '🚚 Outbound robot';
    else if (cell.type.isInboundRobotDomain && cell.type.isOutboundRobotDomain)
      robotDomain = '🔀 Any robot (path/charger)';

    // Rack unit label
    final unitLabel = switch (cell.type) {
      CellType.rackPallet => 'Pallets',
      CellType.rackCase => 'Cases',
      CellType.rackLoose => 'Units',
      _ => 'Stock',
    };

    const hdrStyle =
        TextStyle(fontSize: 11, color: _cyan, fontWeight: FontWeight.bold);
    const mutedStyle = TextStyle(fontSize: 11, color: Color(0xFF8B949E));
    const cyanStyle = TextStyle(
        fontSize: 11, color: Color(0xFF00D4FF), fontWeight: FontWeight.w600);
    const greenStyle = TextStyle(fontSize: 11, color: Color(0xFF4ADE80));
    const yellowStyle = TextStyle(fontSize: 11, color: Color(0xFFF97316));

    final tipLines = <Widget>[
      Text('$colLbl${r + 1}  ${cell.type.label}', style: hdrStyle),
      if (cell.label != null) Text('Label: ${cell.label}', style: mutedStyle),
      if (zone != null) Text('Zone: ${zone.type.label}', style: mutedStyle),
      if (cell.type.isRack && cell.skuId != null)
        Text('SKU: ${cell.skuId}', style: cyanStyle),
      if (cell.type.isRack && cell.skuId == null)
        const Text('SKU: — empty —', style: mutedStyle),
      if (cell.type.isRack)
        () {
          final pct = (cell.fillFraction * 100).round();
          return Text(
            '$unitLabel: ${cell.quantity} / ${cell.maxQuantity}  ($pct%)',
            style: pct < 50 ? yellowStyle : greenStyle,
          );
        }(),
      if (spawn != null)
        Text('🤖 ${spawn.name ?? spawn.robotType}', style: mutedStyle),
      if (robotDomain.isNotEmpty) Text(robotDomain, style: mutedStyle),
      if (cell.type == CellType.empty) const Text('(empty)', style: mutedStyle),
    ];

    // Position tooltip above the hovered cell, clamped inside canvas
    const pw = 210.0, ph = 16.0 + 14.0 * 4;
    var tx = _offset.dx + c * cw + cw / 2 - pw / 2;
    var ty = _offset.dy + r * ch - ph - 6;
    if (tx < 4) tx = 4;
    if (tx + pw > sz.width - 4) tx = sz.width - pw - 4;
    if (ty < 4) ty = _offset.dy + r * ch + ch + 6;

    return Positioned(
      left: tx,
      top: ty,
      child: IgnorePointer(
        child: Container(
          width: pw,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1C2128),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF30363D)),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: tipLines,
          ),
        ),
      ),
    );
  }

  // ── Cell right-click context menu ─────────────────────────────────────────

  Future<void> _showCellContextMenu(
      Offset local, Size sz, BuildContext ctx) async {
    final hitCell = _posToCell(local, sz);
    final r = hitCell?.row;
    final c = hitCell?.col;
    if (r == null || c == null) return;

    final hasCell = _cells.any((x) => x.row == r && x.col == c);
    final spawn = _spawns
        .cast<RobotSpawn?>()
        .firstWhere((s) => s!.row == r && s.col == c, orElse: () => null);

    final rel = RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      sz.width - local.dx,
      sz.height - local.dy,
    );

    // Pre-fetch the rack cell so we can show inventory inline.
    final WarehouseCell? rackCell = () {
      if (!hasCell) return null;
      final cell = _cells.lastWhere((x) => x.row == r && x.col == c);
      return cell.type.isRack ? cell : null;
    }();
    final locId = '${_colLabel(c)}${r + 1}';

    final action = await showMenu<String>(
      context: ctx,
      position: rel,
      color: const Color(0xFF1C2128),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        _menuHeader(
            '$locId  ${hasCell ? _cells.lastWhere((x) => x.row == r && x.col == c).type.label : 'Empty'}'),
        // ── Rack inventory info block ─────────────────────────────────────
        if (rackCell != null) ...[
          _menuDivider(),
          PopupMenuItem<String>(
            enabled: false,
            height: 26,
            child: Row(children: [
              const Icon(Icons.qr_code_rounded,
                  color: Color(0xFF8B949E), size: 13),
              const SizedBox(width: 6),
              Text(
                'SKU: ${rackCell.skuId ?? "— empty —"}',
                style: TextStyle(
                  color: rackCell.skuId != null
                      ? const Color(0xFFE6EDF3)
                      : const Color(0xFF484F58),
                  fontSize: 11,
                ),
              ),
            ]),
          ),
          PopupMenuItem<String>(
            enabled: false,
            height: 26,
            child: Row(children: [
              const Icon(Icons.location_on_outlined,
                  color: Color(0xFF8B949E), size: 13),
              const SizedBox(width: 6),
              Text('Bin ID: $locId',
                  style:
                      const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
            ]),
          ),
          PopupMenuItem<String>(
            enabled: false,
            height: 26,
            child: Row(children: [
              Icon(
                rackCell.quantity == 0
                    ? Icons.inventory_2_outlined
                    : rackCell.needsReplenishment
                        ? Icons.warning_amber_rounded
                        : Icons.inventory_2_rounded,
                color: rackCell.quantity == 0
                    ? const Color(0xFF484F58)
                    : rackCell.needsReplenishment
                        ? const Color(0xFFF97316)
                        : const Color(0xFF4ADE80),
                size: 13,
              ),
              const SizedBox(width: 6),
              Text(
                '${_rackUnitLabel(rackCell.type)}: '
                '${rackCell.quantity} / ${rackCell.maxQuantity}',
                style: TextStyle(
                  color: rackCell.quantity == 0
                      ? const Color(0xFF484F58)
                      : rackCell.needsReplenishment
                          ? const Color(0xFFF97316)
                          : const Color(0xFF4ADE80),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ]),
          ),
          _menuDivider(),
          if (rackCell.quantity < rackCell.maxQuantity)
            _menuItem(
                'increase_qty', '➕ Add 1 ${_rackUnitLabel(rackCell.type)}'),
          if (rackCell.quantity > 0)
            _menuItem(
                'decrease_qty', '➖ Remove 1 ${_rackUnitLabel(rackCell.type)}'),
          _menuItem('set_inventory', '📦 Edit Inventory…'),
          _menuDivider(),
        ],
        if (hasCell) ...[
          _menuItem('move_up', '↑ Move Cell Up'),
          _menuItem('move_down', '↓ Move Cell Down'),
          _menuItem('move_left', '← Move Cell Left'),
          _menuItem('move_right', '→ Move Cell Right'),
          _menuDivider(),
          _menuItem('delete', '🗑 Delete Cell', color: const Color(0xFFEF4444)),
        ],
        if (spawn != null) ...[
          _menuDivider(),
          _menuHeader('🤖 ${spawn.name ?? spawn.robotType}'),
          _menuItem('move_robot_up', '↑ Move Robot Up'),
          _menuItem('move_robot_down', '↓ Move Robot Down'),
          _menuItem('move_robot_left', '← Move Robot Left'),
          _menuItem('move_robot_right', '→ Move Robot Right'),
          _menuDivider(),
          _menuItem('del_spawn', '❌ Remove Robot',
              color: const Color(0xFFEF4444)),
        ],
        _menuDivider(),
        _menuItem('save_tpl', '💾 Save as Template'),
      ],
    );

    if (!mounted) return;
    switch (action) {
      case 'move_up':
        _moveCell(r, c, r - 1, c);
        break;
      case 'move_down':
        _moveCell(r, c, r + 1, c);
        break;
      case 'move_left':
        _moveCell(r, c, r, c - 1);
        break;
      case 'move_right':
        _moveCell(r, c, r, c + 1);
        break;
      case 'move_robot_up':
        _moveSpawn(r, c, r - 1, c);
        break;
      case 'move_robot_down':
        _moveSpawn(r, c, r + 1, c);
        break;
      case 'move_robot_left':
        _moveSpawn(r, c, r, c - 1);
        break;
      case 'move_robot_right':
        _moveSpawn(r, c, r, c + 1);
        break;
      case 'delete':
        _pushHistory();
        setState(() => _cells.removeWhere((x) => x.row == r && x.col == c));
        _scheduleAutosave();
      case 'increase_qty':
        _pushHistory();
        setState(() {
          _cells = _cells.map((x) {
            if (x.row == r && x.col == c) {
              return x.copyWith(
                  quantity: (x.quantity + 1).clamp(0, x.maxQuantity));
            }
            return x;
          }).toList();
        });
        _scheduleAutosave();
      case 'decrease_qty':
        _pushHistory();
        setState(() {
          _cells = _cells.map((x) {
            if (x.row == r && x.col == c) {
              return x.copyWith(
                  quantity: (x.quantity - 1).clamp(0, x.maxQuantity));
            }
            return x;
          }).toList();
        });
        _scheduleAutosave();
      case 'set_inventory':
        _showInventoryDialog(r, c);
      case 'del_spawn':
        _pushHistory();
        setState(() => _spawns.removeWhere((s) => s.row == r && s.col == c));
        _scheduleAutosave();
      case 'save_tpl':
        _showSaveTemplateDialog();
    }
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

  PopupMenuItem<String> _menuHeader(String text) => PopupMenuItem<String>(
        enabled: false,
        height: 28,
        child: Text(text,
            style: const TextStyle(
                fontSize: 10, color: Color(0xFF8B949E), letterSpacing: 0.5)),
      );

  PopupMenuItem<String> _menuItem(String value, String label, {Color? color}) =>
      PopupMenuItem<String>(
        value: value,
        height: 36,
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: color ?? const Color(0xFFE6EDF3))),
      );

  PopupMenuDivider _menuDivider() => const PopupMenuDivider(height: 1);

  // ── Inventory panel — full inventory management sheet ─────────────────────

  void _showInventoryPanel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2128),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _InventoryPanel(
        cells: _cells,
        colLabel: _colLabel,
        onRandomize: () {
          Navigator.pop(context);
          _pushHistory();
          setState(() {
            _cells = assignTemplateInventory(_cells);
          });
          _scheduleAutosave();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Inventory randomized across rack cells'),
            backgroundColor: Color(0xFF1C3A1C),
            duration: Duration(seconds: 2),
          ));
        },
        onClear: () {
          Navigator.pop(context);
          _pushHistory();
          setState(() {
            _cells = _cells
                .map((c) =>
                    c.type.isRack ? c.copyWith(clearSku: true, quantity: 0) : c)
                .toList();
          });
          _scheduleAutosave();
        },
        onCellEdit: (int row, int col) {
          Navigator.pop(context);
          _showInventoryDialog(row, col);
        },
      ),
    );
  }

  // ── Inventory dialog for rack cells ───────────────────────────────────────

  Future<void> _showInventoryDialog(int row, int col) async {
    final cell = _cells.lastWhere(
      (x) => x.row == row && x.col == col,
      orElse: () =>
          WarehouseCell(row: row, col: col, type: CellType.rackPallet),
    );

    // Preselected SKU — match against loaded list; fall back to free-text if
    // the list hasn't loaded yet or this sku_id isn't in the snapshot.
    String? selectedSkuId = cell.skuId;
    int currentQty = cell.quantity;
    final maxQty = cell.maxQuantity;

    // The dialog uses _SkuDropdownField which manages its own async load.
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C2128),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Text(
            '📦 Inventory — ${_colLabel(col)}${row + 1}  (${cell.type.label})',
            style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 14),
          ),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SKU',
                    style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                const SizedBox(height: 4),
                _SkuDropdownField(
                  warehouseId: _stableId,
                  initialValue: selectedSkuId,
                  onChanged: (v) => setDialogState(() => selectedSkuId = v),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Quantity',
                        style:
                            TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                    Text(
                      '$currentQty / $maxQty',
                      style: TextStyle(
                        color: currentQty == 0
                            ? const Color(0xFF8B949E)
                            : currentQty < maxQty * 0.5
                                ? const Color(0xFFF97316)
                                : const Color(0xFF4ADE80),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: currentQty.toDouble(),
                  min: 0,
                  max: maxQty.toDouble(),
                  divisions: maxQty,
                  activeColor: currentQty < maxQty * 0.5
                      ? const Color(0xFFF97316)
                      : const Color(0xFF00D4FF),
                  inactiveColor: const Color(0xFF30363D),
                  onChanged: (v) =>
                      setDialogState(() => currentQty = v.round()),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('0',
                        style:
                            TextStyle(color: Color(0xFF484F58), fontSize: 10)),
                    Text('Capacity: $maxQty',
                        style: const TextStyle(
                            color: Color(0xFF484F58), fontSize: 10)),
                  ],
                ),
                if (currentQty < maxQty * 0.5 && currentQty > 0) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF97316).withAlpha(25),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: const Color(0xFFF97316).withAlpha(80)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: Color(0xFFF97316), size: 14),
                        SizedBox(width: 6),
                        Text('Replenishment event will be raised',
                            style: TextStyle(
                                color: Color(0xFFF97316), fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFF8B949E))),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00D4FF),
                  foregroundColor: Colors.black),
              onPressed: () {
                _pushHistory();
                setState(() {
                  _cells = _cells
                      .map((x) => (x.row == row && x.col == col)
                          ? x.copyWith(
                              skuId: selectedSkuId,
                              clearSku: selectedSkuId == null,
                              quantity: currentQty,
                            )
                          : x)
                      .toList();
                });
                _scheduleAutosave();
                Navigator.pop(ctx);
              },
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
  }

  void _moveCell(int fr, int fc, int tr, int tc) {
    if (tr < 0 || tr >= _rows || tc < 0 || tc >= _cols) return;
    // Target must be a path/aisle cell (or empty adjacent to a path).
    final targetType = _typeAt(tr, tc);
    if (!targetType.isWalkable && targetType != CellType.empty) {
      _showPlacementError('Can only move to a path or empty cell.');
      return;
    }
    // After conceptually removing the source, check destination adjacency for
    // rack/aisle cells — it must still have an adjacent path once placed there.
    final movingCells =
        _cells.where((x) => x.row == fr && x.col == fc).toList();
    final needsPath = movingCells.any((x) =>
        x.type.isRack ||
        x.type == CellType.aisle ||
        x.type == CellType.packStation ||
        x.type == CellType.palletStaging);
    if (needsPath) {
      // Temporarily remove from source to test destination
      final saved = List<WarehouseCell>.from(_cells);
      _cells.removeWhere((x) => x.row == fr && x.col == fc);
      final ok = _hasAdjacentPath(tr, tc);
      _cells = saved;
      if (!ok) {
        _showPlacementError('Destination has no adjacent path cell.');
        return;
      }
    }
    _pushHistory();
    setState(() {
      // Collect cells currently at destination before overwriting
      final displaced =
          _cells.where((x) => x.row == tr && x.col == tc).toList();
      _cells.removeWhere((x) => x.row == fr && x.col == fc);
      _cells.removeWhere((x) => x.row == tr && x.col == tc);
      // Place moved cell(s) at destination, preserving all inventory fields
      for (final cell in movingCells) {
        _cells.add(WarehouseCell(
            row: tr,
            col: tc,
            type: cell.type,
            label: cell.label,
            levels: cell.levels,
            destId: cell.destId,
            skuId: cell.skuId,
            quantity: cell.quantity,
            maxQuantity: cell.maxQuantity));
      }
      // Swap displaced cell(s) back to source, preserving their inventory too
      for (final cell in displaced) {
        _cells.add(WarehouseCell(
            row: fr,
            col: fc,
            type: cell.type,
            label: cell.label,
            levels: cell.levels,
            destId: cell.destId,
            skuId: cell.skuId,
            quantity: cell.quantity,
            maxQuantity: cell.maxQuantity));
      }
    });
    _scheduleAutosave();
  }

  void _moveSpawn(int fr, int fc, int tr, int tc) {
    if (tr < 0 || tr >= _rows || tc < 0 || tc >= _cols) return;
    final targetType = _typeAt(tr, tc);
    if (targetType.isRack) {
      _showPlacementError('Robots cannot be placed on rack cells.');
      return;
    }
    if (!targetType.isWalkable &&
        !targetType.isCharger &&
        targetType != CellType.empty) {
      _showPlacementError(
          'Robot can only move to an aisle, path, or charger cell.');
      return;
    }
    _pushHistory();
    setState(() {
      final fromIdx = _spawns.indexWhere((s) => s.row == fr && s.col == fc);
      final toIdx = _spawns.indexWhere((s) => s.row == tr && s.col == tc);
      if (fromIdx < 0) return;
      final moving = _spawns[fromIdx];
      if (toIdx >= 0) {
        // Swap: put the displaced robot back at the source cell
        final displaced = _spawns[toIdx];
        _spawns[toIdx] = RobotSpawn(
            row: tr, col: tc, robotType: moving.robotType, name: moving.name);
        _spawns[fromIdx] = RobotSpawn(
            row: fr,
            col: fc,
            robotType: displaced.robotType,
            name: displaced.name);
      } else {
        _spawns[fromIdx] = RobotSpawn(
            row: tr, col: tc, robotType: moving.robotType, name: moving.name);
      }
    });
    _scheduleAutosave();
  }

  // ── User templates ────────────────────────────────────────────────────────

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _currentEmail {
    final s = ref.read(authProvider);
    return s is AuthLoggedIn ? s.user.email : 'guest';
  }

  bool get _isSuperUser => _currentEmail == _kSuperUserEmail;

  String get _myTemplateKey =>
      'warehouse_user_templates_${_currentEmail.replaceAll('@', '_at_')}';

  String get _sharedTemplateKey =>
      'warehouse_shared_templates_${_currentEmail.replaceAll('@', '_at_')}';

  static const _kStdUserTemplateKey = 'warehouse_std_user_templates';
  static const _kStdOverrideKey = 'warehouse_std_overrides';

  // ── Load / save user templates ────────────────────────────────────────────

  Future<void> _loadUserTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    final myList = prefs.getStringList(_myTemplateKey) ?? [];
    final sharedList = prefs.getStringList(_sharedTemplateKey) ?? [];
    final stdList = prefs.getStringList(_kStdUserTemplateKey) ?? [];
    final overrideList = prefs.getStringList(_kStdOverrideKey) ?? [];

    _UserTemplate? parse(String item,
        {String? sharedBy, bool isStdAddition = false}) {
      try {
        final parts = item.split('\x00');
        if (parts.length < 2) return null;
        return _UserTemplate(
            name: parts[0],
            code: parts[1],
            sharedBy: sharedBy,
            isStdAddition: isStdAddition);
      } catch (_) {
        return null;
      }
    }

    final mine =
        myList.map((e) => parse(e)).whereType<_UserTemplate>().toList();
    final shared = sharedList
        .map((e) {
          final parts = e.split('\x00');
          final from = parts.length >= 3 ? parts[2] : null;
          return parse(e, sharedBy: from);
        })
        .whereType<_UserTemplate>()
        .toList();
    final stdExtra = stdList
        .map((e) => parse(e, isStdAddition: true))
        .whereType<_UserTemplate>()
        .toList();
    final overrides =
        overrideList.map((e) => parse(e)).whereType<_UserTemplate>().toList();

    if (mounted) {
      setState(() {
        _userTemplates = mine;
        _sharedTemplates = shared;
        _stdUserTemplates = stdExtra;
        _stdOverrides = overrides;
      });
    }
  }

  Future<void> _saveUserTemplate(String name) async {
    final cfg = _buildConfig().copyWith(name: name);
    final code = cfg.toShareCode();
    final entry = '$name\x00$code';

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_myTemplateKey) ?? [];
    await prefs.setStringList(_myTemplateKey,
        [...existing.where((e) => !e.startsWith('$name\x00')), entry]);
    if (!mounted) return;
    await _loadUserTemplates();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Template "$name" saved to My Templates ✅'),
      backgroundColor: const Color(0xFF1C3A1C),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _saveAsStandardTemplate(String name) async {
    if (!_isSuperUser) return;
    final cfg = _buildConfig().copyWith(name: name);
    final code = cfg.toShareCode();
    final entry = '$name\x00$code';

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_kStdUserTemplateKey) ?? [];
    await prefs.setStringList(_kStdUserTemplateKey,
        [...existing.where((e) => !e.startsWith('$name\x00')), entry]);
    if (!mounted) return;
    await _loadUserTemplates();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Standard template "$name" saved ✅'),
      backgroundColor: const Color(0xFF1C3A4F),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _shareTemplateWithUser(
      String name, String recipientEmail) async {
    final cfg = _buildConfig().copyWith(name: name);
    final code = cfg.toShareCode();
    final sanitizedEmail =
        recipientEmail.trim().toLowerCase().replaceAll('@', '_at_');
    final entry = '$name\x00$code\x00$_currentEmail';
    final key = 'warehouse_shared_templates_$sanitizedEmail';

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(key) ?? [];
    await prefs.setStringList(
        key, [...existing.where((e) => !e.startsWith('$name\x00')), entry]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Template "$name" shared with $recipientEmail ✅'),
      backgroundColor: const Color(0xFF1C3A1C),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _deleteUserTemplate(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_myTemplateKey) ?? [];
    await prefs.setStringList(_myTemplateKey,
        existing.where((e) => !e.startsWith('$name\x00')).toList());
    await _loadUserTemplates();
  }

  Future<void> _deleteStdUserTemplate(String name) async {
    if (!_isSuperUser) return;
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_kStdUserTemplateKey) ?? [];
    await prefs.setStringList(_kStdUserTemplateKey,
        existing.where((e) => !e.startsWith('$name\x00')).toList());
    await _loadUserTemplates();
  }

  /// Super user: replace a hardcoded template's layout with the current canvas.
  Future<void> _overwriteSystemTemplate(String name) async {
    if (!_isSuperUser) return;
    final cfg = _buildConfig().copyWith(name: name);
    final code = cfg.toShareCode();
    final entry = '$name\x00$code';
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_kStdOverrideKey) ?? [];
    await prefs.setStringList(_kStdOverrideKey,
        [...existing.where((e) => !e.startsWith('$name\x00')), entry]);
    if (!mounted) return;
    await _loadUserTemplates();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Standard template "$name" replaced ✅'),
      backgroundColor: const Color(0xFF4F3A1C),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Super user: remove override and restore original hardcoded template.
  Future<void> _resetSystemTemplate(String name) async {
    if (!_isSuperUser) return;
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_kStdOverrideKey) ?? [];
    await prefs.setStringList(_kStdOverrideKey,
        existing.where((e) => !e.startsWith('$name\x00')).toList());
    if (!mounted) return;
    await _loadUserTemplates();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Standard template "$name" restored to default ✅'),
      backgroundColor: const Color(0xFF1C3A1C),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Show a confirmation dialog before overwriting a hardcoded standard template.
  void _confirmOverwriteSystemTemplate(String name) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Replace Standard Template',
            style: TextStyle(color: _text)),
        content: Text(
          'Replace the layout of "$name" with the current canvas?\n\n'
          'All users will see the new layout.',
          style: const TextStyle(color: _text, fontSize: 12),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD97706)),
            onPressed: () {
              Navigator.pop(context);
              _overwriteSystemTemplate(name);
            },
            child: const Text('Replace', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showSaveTemplateDialog({String? prefillName}) {
    final ctrl = TextEditingController(
        text: prefillName ??
            (_loadedTemplate?.name != null
                ? '${_loadedTemplate!.name} (copy)'
                : _name));
    var saveAsStandard = false;
    var overrideExisting = false;
    final isSuperUser = _isSuperUser;
    // Names of all hardcoded + admin-added standard templates
    final stdNames = {
      ...kWarehouseTemplates.map((t) => t.name),
      ..._stdUserTemplates.map((t) => t.name),
    };
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setSt) {
        final typedName = ctrl.text.trim();
        final canOverride = isSuperUser && stdNames.contains(typedName);
        return AlertDialog(
          backgroundColor: _surface,
          title: const Text('Save as Template', style: TextStyle(color: _text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(color: _text, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Template name…',
                  hintStyle: const TextStyle(color: Color(0xFF8B949E)),
                  filled: true,
                  fillColor: const Color(0xFF0D1117),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: _border)),
                ),
                onChanged: (_) => setSt(() {
                  // refresh canOverride when name changes
                  if (!stdNames.contains(ctrl.text.trim())) {
                    overrideExisting = false;
                  }
                }),
                onSubmitted: (_) {
                  Navigator.pop(context);
                  _handleSaveTemplate(
                      ctrl.text.trim(), saveAsStandard, overrideExisting);
                },
              ),
              if (isSuperUser) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Checkbox(
                    value: saveAsStandard,
                    activeColor: _cyan,
                    onChanged: (v) => setSt(() {
                      saveAsStandard = v ?? false;
                      if (!saveAsStandard) overrideExisting = false;
                    }),
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                      child: Text(
                    'Save as Standard Template\n(visible to all users)',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
                  )),
                ]),
                // Show override checkbox only when name matches an existing std template
                if (canOverride) ...[
                  Row(children: [
                    Checkbox(
                      value: overrideExisting,
                      activeColor: const Color(0xFFD97706),
                      onChanged: (v) => setSt(() {
                        overrideExisting = v ?? false;
                        if (overrideExisting) saveAsStandard = false;
                      }),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                        child: Text(
                      'Override existing standard template\n(replaces layout for all users)',
                      style: TextStyle(fontSize: 11, color: Color(0xFFD97706)),
                    )),
                  ]),
                ],
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor:
                      overrideExisting ? const Color(0xFFD97706) : _cyan),
              onPressed: () {
                Navigator.pop(context);
                _handleSaveTemplate(
                    ctrl.text.trim(), saveAsStandard, overrideExisting);
              },
              child: Text(
                overrideExisting ? 'Override' : 'Save',
                style: const TextStyle(color: Colors.black),
              ),
            ),
          ],
        );
      }),
    );
  }

  void _handleSaveTemplate(
      String name, bool saveAsStandard, bool overrideExisting) {
    if (name.isEmpty) return;
    if (overrideExisting) {
      _overwriteSystemTemplate(name);
    } else if (saveAsStandard) {
      _saveAsStandardTemplate(name);
    } else {
      _saveUserTemplate(name);
    }
  }

  // ── Status bar ────────────────────────────────────────────────────────────

  Widget _buildStatusBar() {
    final racks = _cells.where((c) => c.type.isRack).length;
    final aisles = _cells.where((c) => c.type.isWalkable).length;
    final charging = _cells.where((c) => c.type.isCharger).length;
    return Container(
      height: 28,
      color: _surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _statChip('Grid', '$_rows × $_cols'),
          _statChip('Racks', '$racks'),
          _statChip('Aisles', '$aisles'),
          _statChip('Charging', '$charging'),
          _statChip('Spawns', '${_spawns.length}'),
          const Spacer(),
          Text(
            'Zoom: ${(_scale * 100).round()}%  ${_eraser ? '✕ ERASER' : '● ${_selectedType.label}'}',
            style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value) => Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Text(
          '$label: $value',
          style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
        ),
      );

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _nameCtrl.dispose();
    super.dispose();
  }
}

// ── Painter ───────────────────────────────────────────────────────────────────

class _CreatorPainter extends CustomPainter {
  const _CreatorPainter({
    required this.cells,
    required this.spawns,
    required this.rows,
    required this.cols,
    required this.scale,
    required this.offset,
    this.zones = const [],
    this.activeDragZone,
    this.dragRowStart,
    this.dragColStart,
    this.dragRowEnd,
    this.dragColEnd,
    this.hoverRow,
    this.hoverCol,
  });

  final List<WarehouseCell> cells;
  final List<RobotSpawn> spawns;
  final List<PickZoneDef> zones;
  final PickZoneType? activeDragZone;
  final int? dragRowStart;
  final int? dragColStart;
  final int? dragRowEnd;
  final int? dragColEnd;
  final int? hoverRow;
  final int? hoverCol;
  final int rows, cols;
  final double scale;
  final Offset offset;

  double _cw(Size s) => (s.width / cols) * scale;
  double _ch(Size s) => (s.height / rows) * scale;

  @override
  void paint(Canvas canvas, Size size) {
    final cw = _cw(size);
    final ch = _ch(size);
    final gridW = cols * cw;
    final gridH = rows * ch;

    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0D1117),
    );

    // ── Warehouse path: tiny saffron dot on every grid cell ─
    if (scale > 0.3) {
      final dotR = min(cw, ch) * 0.06; // smaller dot
      final dotPaint = Paint()..color = const Color(0xFFFF8C00).withAlpha(40);
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

    // ── Zone rectangles (committed zones) ─────────────────────────────────────────
    for (final zone in zones) {
      final left = offset.dx + zone.colStart * cw;
      final top = offset.dy + zone.rowStart * ch;
      final bandW = (zone.colEnd - zone.colStart + 1) * cw;
      final bandH = (zone.rowEnd - zone.rowStart + 1) * ch;
      final rect = Rect.fromLTWH(left, top, bandW, bandH);
      canvas.drawRect(rect, Paint()..color = zone.type.color.withAlpha(40));
      canvas.drawRect(
          rect,
          Paint()
            ..color = zone.type.color.withAlpha(100)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0);
      if (scale > 0.5) {
        _text(canvas, zone.type.label, rect.center, 7 * scale.clamp(0.6, 1.4),
            color: zone.type.color.withAlpha(200));
      }
    }

    // ── Drag-preview rectangle ────────────────────────────────────────────────
    if (activeDragZone != null &&
        dragColStart != null &&
        dragRowStart != null) {
      final c1 = dragColStart!, c2 = dragColEnd ?? c1;
      final r1 = dragRowStart!, r2 = dragRowEnd ?? r1;
      final cMin = c1 < c2 ? c1 : c2, cMax = c1 < c2 ? c2 : c1;
      final rMin = r1 < r2 ? r1 : r2, rMax = r1 < r2 ? r2 : r1;
      final left = offset.dx + cMin * cw;
      final top = offset.dy + rMin * ch;
      final bandW = (cMax - cMin + 1) * cw;
      final bandH = (rMax - rMin + 1) * ch;
      final rect = Rect.fromLTWH(left, top, bandW, bandH);
      canvas.drawRect(
          rect, Paint()..color = activeDragZone!.color.withAlpha(60));
      canvas.drawRect(
          rect,
          Paint()
            ..color = activeDragZone!.color.withAlpha(160)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }

    // ── Cell fills ──────────────────────────────────────────────────────────
    for (final cell in cells) {
      final rect = Rect.fromLTWH(
        offset.dx + cell.col * cw,
        offset.dy + cell.row * ch,
        cw,
        ch,
      );

      // Road cells — draw asphalt + saffron road markings
      if (cell.type.isRoad) {
        _drawRoadCell(canvas, rect, cell.type);
        continue;
      }

      // Aisle / cross-aisle / robot-path — rendered identically (one Aisle type)
      if (cell.type == CellType.aisle ||
          cell.type == CellType.crossAisle ||
          cell.type == CellType.robotPath) {
        canvas.drawRect(rect, Paint()..color = CellType.aisle.color);
        if (scale > 0.5) {
          final dotR = min(cw, ch) * 0.07;
          canvas.drawCircle(rect.center, dotR,
              Paint()..color = const Color(0xFFFF8C00).withAlpha(180));
        }
        continue;
      }

      // Conveyor cells — directional belt
      if (cell.type.isConveyor) {
        _drawConveyorCell(canvas, rect, cell.type);
        continue;
      }

      // Dock — skeleton wireframe (truck is the occupant, not the cell)
      if (cell.type == CellType.dock) {
        _drawDockCell(canvas, rect);
        continue;
      }

      canvas.drawRect(rect, Paint()..color = cell.type.color);

      // Rack shelf lines + fill-level icon
      if (cell.type.isRack) {
        // Inventory tint — visible at ALL zoom levels:
        // green overlay when stocked, amber when below 50%, transparent when empty
        if (!cell.isEmpty) {
          final tintColor = cell.isFull
              ? const Color(0xFF4ADE80).withAlpha(55) // green — full
              : cell.needsReplenishment
                  ? const Color(0xFFF97316).withAlpha(50) // amber — low
                  : const Color(0xFF22C55E).withAlpha(40); // green — partial
          canvas.drawRect(rect, Paint()..color = tintColor);
        }
        if (scale > 0.6) {
          final lp = Paint()
            ..color = Colors.white.withAlpha(50)
            ..strokeWidth = max(0.4, rect.shortestSide * 0.03);
          for (var i = 1; i < 4; i++) {
            final y = rect.top + rect.height * i / 4;
            canvas.drawLine(
                Offset(rect.left + 1, y), Offset(rect.right - 1, y), lp);
          }
        }
        if (scale > 0.8) {
          // Fill-level icon driven by inventory fields
          final String rackIcon;
          final Color rackColor;
          if (cell.isEmpty) {
            rackIcon = '▢';
            rackColor = Colors.white.withAlpha(160);
          } else if (cell.isFull) {
            rackIcon = '▉';
            rackColor = const Color(0xFF4ADE80).withAlpha(220); // green-full
          } else {
            rackIcon = '▦';
            rackColor = cell.needsReplenishment
                ? const Color(0xFFF97316).withAlpha(220) // amber warning <50%
                : Colors.white.withAlpha(200);
          }
          _text(canvas, rackIcon, rect.center, min(cw, ch) * 0.38,
              color: rackColor);
          // SKU label below icon
          if (cell.skuId != null && scale > 1.0) {
            _text(
              canvas,
              cell.skuId!.length > 7
                  ? cell.skuId!.substring(0, 7)
                  : cell.skuId!,
              rect.center.translate(0, min(cw, ch) * 0.26),
              min(cw, ch) * 0.22,
              color: const Color(0xFFB3C5D4),
            );
          }
        }
      }

      // Icon labels for special cells
      if (scale > 0.8) {
        String? icon;
        if (cell.type == CellType.chargingSlow) icon = '⚡';
        if (cell.type == CellType.chargingFast) icon = '⚡⚡';
        if (cell.type == CellType.charging) icon = '⚡';
        if (cell.type == CellType.packStation) icon = 'PKG';
        if (cell.type == CellType.dump) icon = '🗑';
        if (cell.type == CellType.tree) icon = '🌲';
        if (cell.type == CellType.inbound) icon = '↓IN';
        if (cell.type == CellType.outbound) icon = 'OUT↗';
        if (cell.type == CellType.palletStaging) icon = 'SKU';
        if (icon != null) {
          _text(canvas, icon, rect.center, min(cw, ch) * 0.38);
        }
      }
    }

    // ── Hover cell highlight ───────────────────────────────────────────────
    if (hoverRow != null && hoverCol != null) {
      final hr = Rect.fromLTWH(
          offset.dx + hoverCol! * cw, offset.dy + hoverRow! * ch, cw, ch);
      canvas.drawRect(
          hr,
          Paint()
            ..color = Colors.white.withAlpha(22)
            ..style = PaintingStyle.fill);
      canvas.drawRect(
          hr,
          Paint()
            ..color = const Color(0xFF00D4FF).withAlpha(180)
            ..style = PaintingStyle.stroke
            ..strokeWidth = max(1.0, min(cw, ch) * 0.05));
    }

    // ── Robot spawn markers ──────────────────────────────────────────────────
    for (final spawn in spawns) {
      final cx = offset.dx + (spawn.col + 0.5) * cw;
      final cy = offset.dy + (spawn.row + 0.5) * ch;
      final r = min(cw, ch) * 0.35;
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = spawn.robotType == 'AMR'
              ? const Color(0xFF00D4FF)
              : const Color(0xFF8B949E),
      );
      if (scale > 1.0) {
        _text(canvas, spawn.robotType == 'AMR' ? 'A' : 'G',
            Offset(cx, cy - r * 0.4), r * 0.85,
            color: Colors.black);
      }
    }

    // ── Grid ─────────────────────────────────────────────────────────────────
    final gp = Paint()
      ..color = const Color(0xFF21262D)
      ..strokeWidth = 0.5;
    for (int r = 0; r <= rows; r++) {
      final y = offset.dy + r * ch;
      canvas.drawLine(Offset(offset.dx, y), Offset(offset.dx + gridW, y), gp);
    }
    for (int c = 0; c <= cols; c++) {
      final x = offset.dx + c * cw;
      canvas.drawLine(Offset(x, offset.dy), Offset(x, offset.dy + gridH), gp);
    }

    // ── Column labels & row numbers — always visible ──────────────────────────
    {
      const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      for (var c = 0; c < cols && c < 26; c++) {
        _text(
            canvas,
            abc[c],
            Offset(offset.dx + (c + 0.5) * cw, offset.dy - 10),
            (8 * scale).clamp(6.0, 18.0),
            color: const Color(0xFF8B949E));
      }
      for (var r = 0; r < rows; r++) {
        _text(
            canvas,
            '${r + 1}',
            Offset(offset.dx - 12, offset.dy + (r + 0.5) * ch),
            (7 * scale).clamp(5.5, 16.0),
            color: const Color(0xFF8B949E));
      }
    }
  }

  // ── Road cell renderer ───────────────────────────────────────────────────
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

  // ── Conveyor cell renderer ─────────────────────────────────────────────────
  void _drawConveyorCell(Canvas canvas, Rect rect, CellType type) {
    canvas.drawRect(rect, Paint()..color = type.color.withAlpha(210));
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

  // ── Dock cell renderer (skeleton wireframe — truck is the occupant) ────────
  void _drawDockCell(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = const Color(0xFF0D1117));
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = const Color(0xFFD97706).withAlpha(200)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.2, rect.shortestSide * 0.07),
    );
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
      _text(canvas, 'BAY', rect.center, rect.shortestSide * 0.22,
          color: const Color(0xFFD97706).withAlpha(160));
    }
  }

  void _text(Canvas canvas, String t, Offset pos, double size,
      {Color color = Colors.white}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_CreatorPainter old) =>
      old.cells != cells ||
      old.scale != scale ||
      old.offset != offset ||
      old.rows != rows ||
      old.cols != cols ||
      old.zones != zones ||
      old.activeDragZone != activeDragZone ||
      old.dragRowStart != dragRowStart ||
      old.dragColStart != dragColStart ||
      old.dragRowEnd != dragRowEnd ||
      old.dragColEnd != dragColEnd ||
      old.hoverRow != hoverRow ||
      old.hoverCol != hoverCol;
}

// ── Row / column ruler overlay ────────────────────────────────────────────────

class _RulerPainter extends CustomPainter {
  const _RulerPainter({
    required this.offset,
    required this.scale,
    required this.rows,
    required this.cols,
    required this.canvasW,
    required this.canvasH,
    required this.isRow,
  });

  final Offset offset;
  final double scale, canvasW, canvasH;
  final int rows, cols;
  final bool
      isRow; // true = left row-number strip; false = top col-letter strip

  static const _abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static String _colLabel(int c) =>
      c < 26 ? _abc[c] : '${_abc[(c ~/ 26) - 1]}${_abc[c % 26]}';

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF161B22));
    // Border on inner edge
    canvas.drawLine(
      isRow ? Offset(size.width, 0) : Offset(0, size.height),
      isRow ? Offset(size.width, size.height) : Offset(size.width, size.height),
      Paint()
        ..color = const Color(0xFF30363D)
        ..strokeWidth = 1,
    );

    if (isRow) {
      final ch = (canvasH / rows) * scale;
      if (ch < 4) return;
      final fs = (ch * 0.55).clamp(7.0, 11.0);
      for (int r = 0; r < rows; r++) {
        final cy = offset.dy + (r + 0.5) * ch;
        if (cy < -ch || cy > size.height + ch) continue;
        _label(canvas, '${r + 1}', Offset(size.width / 2, cy), fs);
      }
    } else {
      final cw = (canvasW / cols) * scale;
      if (cw < 4) return;
      final fs = (cw * 0.55).clamp(7.0, 11.0);
      for (int c = 0; c < cols; c++) {
        final cx = offset.dx + (c + 0.5) * cw;
        if (cx < -cw || cx > size.width + cw) continue;
        _label(canvas, _colLabel(c), Offset(cx, size.height / 2), fs);
      }
    }
  }

  void _label(Canvas canvas, String t, Offset pos, double fs) {
    final tp = TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(fontSize: fs, color: const Color(0xFF8B949E))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.offset != offset ||
      old.scale != scale ||
      old.rows != rows ||
      old.cols != cols ||
      old.canvasW != canvasW ||
      old.canvasH != canvasH;
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _ToolBtn extends StatelessWidget {
  const _ToolBtn(this.icon, this.tip, this.onTap);
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 18, color: const Color(0xFF8B949E)),
          splashRadius: 20,
        ),
      );
}

class _PaletteEntry extends StatelessWidget {
  const _PaletteEntry({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? color.withAlpha(40) : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? color : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: Colors.white24, width: 0.5),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: selected ? color : const Color(0xFF8B949E),
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
}

// ── User template data ────────────────────────────────────────────────────────

class _UserTemplate {
  const _UserTemplate({
    required this.name,
    required this.code,
    this.sharedBy,
    this.isStdAddition = false,
  });
  final String name;
  final String code;

  /// Non-null when this is a template shared TO this user BY another user.
  final String? sharedBy;

  /// True when this is a standard template added by the super user.
  final bool isStdAddition;
}

// ── Template gallery ──────────────────────────────────────────────────────────

class _TemplateGallery extends StatelessWidget {
  const _TemplateGallery({
    required this.scrollController,
    required this.systemTemplates,
    required this.userTemplates,
    required this.sharedTemplates,
    required this.isSuperUser,
    required this.stdOverrideNames,
    required this.onSelect,
    required this.onLoadUser,
    required this.onDeleteUser,
    required this.onDeleteStd,
    required this.onShareTemplate,
    required this.onOverwriteSystem,
    required this.onResetSystem,
  });
  final ScrollController scrollController;
  final List<WarehouseTemplate> systemTemplates;
  final List<_UserTemplate> userTemplates;
  final List<_UserTemplate> sharedTemplates;
  final bool isSuperUser;
  final Set<String> stdOverrideNames;
  final void Function(WarehouseTemplate) onSelect;
  final void Function(_UserTemplate) onLoadUser;
  final void Function(_UserTemplate) onDeleteUser;
  final void Function(_UserTemplate) onDeleteStd;
  final void Function(_UserTemplate) onShareTemplate;
  final void Function(String) onOverwriteSystem;
  final void Function(String) onResetSystem;

  @override
  Widget build(BuildContext context) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // ── Standard Templates ─────────────────────────────────────────────
          Row(children: [
            const Text('Standard Templates',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE6EDF3))),
            const SizedBox(width: 6),
            if (isSuperUser)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF00D4FF).withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: const Color(0xFF00D4FF).withAlpha(80)),
                ),
                child: const Text('SUPER USER',
                    style: TextStyle(
                        fontSize: 8,
                        color: Color(0xFF00D4FF),
                        letterSpacing: 1)),
              ),
          ]),
          const SizedBox(height: 2),
          Text(
            isSuperUser
                ? 'You can save new standard templates or replace existing ones with the current canvas.'
                : 'Read-only — load and "Save as Template" to modify.',
            style: const TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: systemTemplates.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final t = systemTemplates[i];
                final isEditable = isSuperUser && !t.isSystem;
                final isOverridden =
                    t.isSystem && stdOverrideNames.contains(t.name);
                return _SystemCard(
                  t: t,
                  isEditable: isEditable,
                  isSuperUser: isSuperUser,
                  isOverridden: isOverridden,
                  onTap: () => onSelect(t),
                  onDelete: isEditable
                      ? () {
                          onDeleteStd(_UserTemplate(name: t.name, code: ''));
                        }
                      : null,
                  onOverwrite: (isSuperUser && t.isSystem)
                      ? () => onOverwriteSystem(t.name)
                      : null,
                  onReset: (isSuperUser && isOverridden)
                      ? () => onResetSystem(t.name)
                      : null,
                );
              },
            ),
          ),

          // ── My Templates ───────────────────────────────────────────────────
          if (userTemplates.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('My Templates',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE6EDF3))),
            const SizedBox(height: 8),
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: userTemplates.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _UserCard(
                  ut: userTemplates[i],
                  onLoad: () => onLoadUser(userTemplates[i]),
                  onDelete: () => onDeleteUser(userTemplates[i]),
                  onShare: () => onShareTemplate(userTemplates[i]),
                ),
              ),
            ),
          ],

          // ── Shared with me ─────────────────────────────────────────────────
          if (sharedTemplates.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Shared with Me',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE6EDF3))),
            const SizedBox(height: 8),
            SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: sharedTemplates.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => _UserCard(
                  ut: sharedTemplates[i],
                  onLoad: () => onLoadUser(sharedTemplates[i]),
                  onDelete: null, // can't delete shared templates you received
                  onShare:
                      null, // can't re-share (would need explicit permission)
                ),
              ),
            ),
          ],

          if (userTemplates.isEmpty && sharedTemplates.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                'Save a layout as a template to see it here.\n'
                'You can share your templates with colleagues by entering their email.',
                style: TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );
}

class _SystemCard extends StatelessWidget {
  const _SystemCard({
    required this.t,
    required this.onTap,
    this.isEditable = false,
    this.isSuperUser = false,
    this.isOverridden = false,
    this.onDelete,
    this.onOverwrite,
    this.onReset,
  });
  final WarehouseTemplate t;
  final VoidCallback onTap;
  final bool isEditable;
  final bool isSuperUser;
  final bool isOverridden;
  final VoidCallback? onDelete;
  final VoidCallback? onOverwrite;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 190,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1117),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: isOverridden
                    ? const Color(0xFFD97706).withAlpha(140)
                    : isEditable
                        ? const Color(0xFF00D4FF).withAlpha(100)
                        : const Color(0xFF30363D)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                  isOverridden
                      ? Icons.swap_horiz
                      : (isEditable ? Icons.edit : Icons.lock),
                  size: 10,
                  color: isOverridden
                      ? const Color(0xFFD97706)
                      : (isEditable
                          ? const Color(0xFF00D4FF)
                          : const Color(0xFF8B949E)),
                ),
                const SizedBox(width: 4),
                Expanded(
                    child: Text(t.name,
                        style: TextStyle(
                            color: isOverridden
                                ? const Color(0xFFD97706)
                                : const Color(0xFF00D4FF),
                            fontWeight: FontWeight.bold,
                            fontSize: 12),
                        overflow: TextOverflow.ellipsis)),
                // Replace with current canvas (super user on any system template)
                if (onOverwrite != null)
                  Tooltip(
                    message: 'Replace with current canvas',
                    child: GestureDetector(
                      onTap: onOverwrite,
                      child: const Icon(Icons.upload_rounded,
                          size: 13, color: Color(0xFFD97706)),
                    ),
                  ),
                // Restore original (only when overridden)
                if (onReset != null) ...[
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Restore original',
                    child: GestureDetector(
                      onTap: onReset,
                      child: const Icon(Icons.restore,
                          size: 13, color: Color(0xFF22C55E)),
                    ),
                  ),
                ],
                // Delete for super-user-added (non-system) templates
                if (isEditable && onDelete != null) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onDelete,
                    child: const Icon(Icons.close,
                        size: 12, color: Color(0xFFEF4444)),
                  ),
                ],
              ]),
              const SizedBox(height: 4),
              Text(t.description,
                  style: const TextStyle(fontSize: 9, color: Color(0xFF8B949E)),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis),
              const Spacer(),
              Wrap(
                  spacing: 3,
                  children: t.tags
                      .map((tag) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                                color: const Color(0xFF21262D),
                                borderRadius: BorderRadius.circular(20)),
                            child: Text(tag,
                                style: const TextStyle(
                                    fontSize: 8, color: Color(0xFF8B949E))),
                          ))
                      .toList()),
            ],
          ),
        ),
      );
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.ut,
    required this.onLoad,
    required this.onDelete,
    this.onShare,
  });
  final _UserTemplate ut;
  final VoidCallback onLoad;
  final VoidCallback? onDelete;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) => Container(
        width: 190,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: ut.sharedBy != null
                  ? const Color(0xFF9B59B6).withAlpha(120)
                  : const Color(0xFF00D4FF).withAlpha(80)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: onLoad,
                  child: Text(ut.name,
                      style: const TextStyle(
                          color: Color(0xFF00D4FF),
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                ),
              ),
              if (onShare != null)
                IconButton(
                  onPressed: onShare,
                  icon: const Icon(Icons.share, size: 14),
                  color: const Color(0xFF8B949E),
                  splashRadius: 14,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  tooltip: 'Share with another user',
                ),
              if (onDelete != null)
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 14),
                  color: const Color(0xFFEF4444),
                  splashRadius: 14,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  tooltip: 'Delete',
                ),
            ]),
            const SizedBox(height: 2),
            if (ut.sharedBy != null)
              Text('Shared by ${ut.sharedBy}',
                  style: const TextStyle(fontSize: 9, color: Color(0xFF9B59B6)),
                  overflow: TextOverflow.ellipsis)
            else
              const Text('My template',
                  style: TextStyle(fontSize: 9, color: Color(0xFF8B949E))),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: onLoad,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00D4FF).withAlpha(20),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Center(
                  child: Text('Load',
                      style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF00D4FF),
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      );
}

// ── Share dialog ──────────────────────────────────────────────────────────────

class _ShareDialog extends StatelessWidget {
  const _ShareDialog({required this.code, required this.url});
  final String code;
  final String url;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Share Warehouse',
            style: TextStyle(color: Color(0xFFE6EDF3))),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Share code (copied to clipboard):',
                style: TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1117),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  code.length > 120 ? '${code.substring(0, 120)}…' : code,
                  style: const TextStyle(
                    fontSize: 9,
                    color: Color(0xFF00D4FF),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Share URL:',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8B949E))),
              const SizedBox(height: 4),
              SelectableText(url,
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFF4ADE80))),
              const SizedBox(height: 8),
              const Text(
                'Send this URL to a friend — they can open it to import your warehouse.',
                style: TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D4FF),
              foregroundColor: Colors.black,
            ),
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy URL'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('URL copied!'),
                  duration: Duration(seconds: 1),
                ));
              }
            },
          ),
        ],
      );
}

// ── SKU dropdown field (self-contained async loader) ─────────────────────────

class _SkuDropdownField extends StatefulWidget {
  const _SkuDropdownField({
    required this.warehouseId,
    required this.initialValue,
    required this.onChanged,
  });

  final String warehouseId;
  final String? initialValue;
  final ValueChanged<String?> onChanged;

  @override
  State<_SkuDropdownField> createState() => _SkuDropdownFieldState();
}

class _SkuDropdownFieldState extends State<_SkuDropdownField> {
  List<Map<String, dynamic>> _skus = [];
  bool _loading = true;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialValue;
    _load();
  }

  Future<void> _load() async {
    try {
      List<Map<String, dynamic>> skus;
      try {
        skus = await ApiClient.instance.getWarehouseSkus(widget.warehouseId);
      } catch (_) {
        skus = [];
      }
      // Fall back to global master catalogue if warehouse snapshot is empty
      if (skus.isEmpty) {
        skus = await ApiClient.instance.getGlobalSkus();
      }
      // Final fallback: use the 20 standard SKUs defined locally so the
      // dropdown is never empty even when the backend is unreachable.
      if (skus.isEmpty) {
        const abcOf = {
          'E': 'A',
          'F': 'B',
          'A': 'C',
          'I': 'D',
        };
        const categoryOf = {
          'E': 'Electronics',
          'F': 'Furniture',
          'A': 'Apparel',
          'I': 'Industrial',
        };
        skus = kAllSkuIds.map((id) {
          // id format: SKU-X##  (e.g. SKU-E01)
          final prefix = id.length >= 5 ? id[4] : '?';
          return <String, dynamic>{
            'sku_id': id,
            'sku_name': id,
            'abc_class': abcOf[prefix] ?? '?',
            'category': categoryOf[prefix] ?? 'Standard',
          };
        }).toList();
      }
      if (mounted) {
        setState(() {
          _skus = skus;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        // Even after a hard failure, populate from local standard SKUs.
        const abcOf = {
          'E': 'A',
          'F': 'B',
          'A': 'C',
          'I': 'D',
        };
        const categoryOf = {
          'E': 'Electronics',
          'F': 'Furniture',
          'A': 'Apparel',
          'I': 'Industrial',
        };
        final fallback = kAllSkuIds.map((id) {
          final prefix = id.length >= 5 ? id[4] : '?';
          return <String, dynamic>{
            'sku_id': id,
            'sku_name': id,
            'abc_class': abcOf[prefix] ?? '?',
            'category': categoryOf[prefix] ?? 'Standard',
          };
        }).toList();
        setState(() {
          _skus = fallback;
          _loading = false;
        });
      }
    }
  }

  List<DropdownMenuItem<String>> _buildItems() {
    final Map<String, List<Map<String, dynamic>>> byCategory = {};
    for (final s in _skus) {
      final cat = s['category'] as String? ?? 'Other';
      byCategory.putIfAbsent(cat, () => []).add(s);
    }
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(
        value: '',
        child: Text('— No SKU —', style: TextStyle(color: Color(0xFF8B949E))),
      ),
    ];
    for (final entry in byCategory.entries) {
      items.add(DropdownMenuItem<String>(
        enabled: false,
        value: '__header_${entry.key}',
        child: Text('── ${entry.key} ──',
            style: const TextStyle(
                color: Color(0xFF00D4FF),
                fontSize: 11,
                fontWeight: FontWeight.bold)),
      ));
      for (final s in entry.value) {
        final skuId = s['sku_id'] as String;
        final skuName = s['sku_name'] as String;
        final abc = s['abc_class'] as String? ?? '';
        items.add(DropdownMenuItem<String>(
          value: skuId,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(skuName,
                  style:
                      const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
                  overflow: TextOverflow.ellipsis),
              Text('$skuId  •  ABC-$abc',
                  style:
                      const TextStyle(color: Color(0xFF8B949E), fontSize: 10)),
            ],
          ),
        ));
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 44,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFF00D4FF)),
          ),
        ),
      );
    }
    // If the cell already has a SKU that isn't in the loaded list (e.g. from
    // template inventory seeded with master SKU IDs), add it as a synthetic
    // entry so the dropdown shows the current value instead of going blank.
    final alreadyInList =
        _selected == null || _skus.any((s) => s['sku_id'] == _selected);
    if (!alreadyInList && _selected != null) {
      _skus = [
        {
          'sku_id': _selected,
          'sku_name': _selected,
          'abc_class': '?',
          'category': 'Current'
        },
        ..._skus,
      ];
    }
    final validValue =
        _skus.any((s) => s['sku_id'] == _selected) ? _selected : null;
    return DropdownButtonFormField<String>(
      initialValue: validValue,
      dropdownColor: const Color(0xFF161B22),
      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13),
      decoration: InputDecoration(
        hintText: 'Select a SKU…',
        hintStyle: const TextStyle(color: Color(0xFF484F58)),
        filled: true,
        fillColor: const Color(0xFF0D1117),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF30363D))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF00D4FF), width: 1.5)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      isExpanded: true,
      items: _buildItems(),
      onChanged: (v) {
        final val = (v == null || v.isEmpty) ? null : v;
        setState(() => _selected = val);
        widget.onChanged(val);
      },
    );
  }
}

// ── NumberField helper ────────────────────────────────────────────────────────

class _NumberField extends StatefulWidget {
  const _NumberField(
      this.label, this.initial, this.onChanged, this.min, this.max);
  final String label;
  final int initial;
  final void Function(int) onChanged;
  final int min, max;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.initial}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _ctrl,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: Color(0xFFE6EDF3)),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
          border: const OutlineInputBorder(),
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n >= widget.min && n <= widget.max) {
            widget.onChanged(n);
          }
        },
      );
}

// =============================================================================
// _StartOpsDialog — shown after every Publish click
// =============================================================================

class _StartOpsDialog extends ConsumerStatefulWidget {
  const _StartOpsDialog({required this.config});
  final WarehouseConfig config;

  @override
  ConsumerState<_StartOpsDialog> createState() => _StartOpsDialogState();
}

class _StartOpsDialogState extends ConsumerState<_StartOpsDialog> {
  void _launch() {
    // Always manual: robots are driven by D-pad, one cell at a time.
    ref.read(simulationModeProvider.notifier).state = 'manual';

    // Reset fog-of-war and events.
    ref.read(exploredCellsProvider.notifier).reset();
    ref.read(activeEventsProvider.notifier).resolveAll();

    // Mark ops started (floor goes into fog-of-war mode).
    ref.read(operationsStartedProvider.notifier).state = true;

    // Persist ops-started state so a page refresh restores it without
    // requiring the backend to be online.
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('ops_started', true);
      prefs.setString('ops_warehouse_id', widget.config.id);
      // Clear stale explored-cells cache for this warehouse so a fresh
      // run starts with an empty fog-of-war rather than old data.
      prefs.remove('explored_cells_${widget.config.id}');
    });

    // Initialize ManualRobotController via its notifier.
    // The notifier holds a stable Ref — no stale-ref issues.
    ref.read(manualRobotControllerProvider.notifier).initialize(widget.config);

    // Create the scout simulation so the STEP button and the 30-second
    // backend flush work, but keep it paused — bots only move when the
    // user presses STEP (manual mode).
    final prevSim = ref.read(scoutSimulationProvider);
    prevSim?.dispose();
    final scout = RobotScoutSimulation(
      config: widget.config,
      ref: ref,
      isSaboteur: false,
    );
    ref.read(scoutSimulationProvider.notifier).state = scout;
    // Manual mode: never create the step timer — robots only move via STEP.
    scout.startManual();

    // Navigate to Floor tab.
    ref.read(navigateToTabProvider.notifier).state = 1;

    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final robotCount = widget.config.robotSpawns.length;
    return Dialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              const Row(children: [
                Icon(Icons.gamepad_rounded, color: Color(0xFF00D4FF), size: 22),
                SizedBox(width: 10),
                Text('Start Manual Operations',
                    style: TextStyle(
                      color: Color(0xFFE6EDF3),
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    )),
              ]),
              const SizedBox(height: 6),
              Text(
                '"${widget.config.name}"  \u00b7  '
                '${widget.config.rows}\u00d7${widget.config.cols}'
                '  \u00b7  $robotCount robot(s)',
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
              ),
              const SizedBox(height: 20),

              // Info card
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF00D4FF).withAlpha(12),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: const Color(0xFF00D4FF).withAlpha(60)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.info_outline_rounded,
                          color: Color(0xFF00D4FF), size: 16),
                      SizedBox(width: 6),
                      Text('Manual D-pad control',
                          style: TextStyle(
                              color: Color(0xFF00D4FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 12)),
                    ]),
                    SizedBox(height: 8),
                    Text(
                      '\u2022 Tap a robot on the floor to select it.\n'
                      '\u2022 Use the D-pad (\u2191\u2193\u2190\u2192) to move one cell at a time.\n'
                      '\u2022 Each move scans 8 surrounding cells and sends\n'
                      '  an observation report to the WMS database.',
                      style: TextStyle(
                          color: Color(0xFF8B949E), fontSize: 11, height: 1.6),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // Start button
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00D4FF),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _launch,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text(
                  'START \u2014 Manual Control',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _InventoryPanel — Inventory management bottom sheet for the craft screen
// =============================================================================

class _InventoryPanel extends StatelessWidget {
  const _InventoryPanel({
    required this.cells,
    required this.colLabel,
    required this.onRandomize,
    required this.onClear,
    required this.onCellEdit,
  });

  final List<WarehouseCell> cells;
  final String Function(int) colLabel;
  final VoidCallback onRandomize;
  final VoidCallback onClear;
  final void Function(int row, int col) onCellEdit;

  @override
  Widget build(BuildContext context) {
    final rackCells = cells.where((c) => c.type.isRack).toList()
      ..sort((a, b) {
        final cmp = a.row.compareTo(b.row);
        return cmp != 0 ? cmp : a.col.compareTo(b.col);
      });
    final stockedCount = rackCells.where((c) => c.quantity > 0).length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.85,
      minChildSize: 0.25,
      builder: (_, scrollCtrl) => Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF484F58),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_rounded,
                    color: Color(0xFF00D4FF), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '✅ Inventory  —  $stockedCount / ${rackCells.length} cells stocked',
                    style: const TextStyle(
                        color: Color(0xFFE6EDF3),
                        fontSize: 13,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  onPressed: onRandomize,
                  icon: const Icon(Icons.shuffle_rounded, size: 14),
                  label:
                      const Text('Randomize', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF00D4FF),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                TextButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.clear_all_rounded, size: 14),
                  label:
                      const Text('Clear All', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFF97316),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF30363D)),
          // Cell list
          Expanded(
            child: rackCells.isEmpty
                ? const Center(
                    child: Text('No rack cells in warehouse',
                        style:
                            TextStyle(color: Color(0xFF8B949E), fontSize: 13)))
                : ListView.builder(
                    controller: scrollCtrl,
                    itemCount: rackCells.length,
                    itemBuilder: (_, i) {
                      final cell = rackCells[i];
                      final loc = '${colLabel(cell.col)}${cell.row + 1}';
                      final fillPct = (cell.fillFraction * 100).round();
                      final stocked = cell.quantity > 0;
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 1),
                        leading: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: cell.type.color.withAlpha(50),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: cell.type.color.withAlpha(100)),
                          ),
                          child: Center(
                            child: Text(
                              stocked ? (cell.isFull ? '▉' : '▆') : '▢',
                              style: TextStyle(
                                fontSize: 12,
                                color: !stocked
                                    ? const Color(0xFF484F58)
                                    : cell.needsReplenishment
                                        ? const Color(0xFFF97316)
                                        : const Color(0xFF4ADE80),
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          cell.skuId ?? '— empty —',
                          style: TextStyle(
                            fontSize: 12,
                            color: cell.skuId != null
                                ? const Color(0xFFE6EDF3)
                                : const Color(0xFF484F58),
                          ),
                        ),
                        subtitle: Text(
                          '$loc  ·  ${cell.type.label}',
                          style: const TextStyle(
                              fontSize: 10, color: Color(0xFF8B949E)),
                        ),
                        trailing: !stocked
                            ? const Text('empty',
                                style: TextStyle(
                                    color: Color(0xFF484F58), fontSize: 11))
                            : Text(
                                '${cell.quantity}/${cell.maxQuantity}  ($fillPct%)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: cell.needsReplenishment
                                      ? const Color(0xFFF97316)
                                      : const Color(0xFF4ADE80),
                                ),
                              ),
                        onTap: () => onCellEdit(cell.row, cell.col),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
