/// wms_dashboard_panel.dart
/// Public widget: shows layout scouting progress + WMS inventory.
/// Polls GET /api/v1/wms/dashboard every 10 s.
/// Used by both DashboardScreen (mobile) and AdaptiveShell DataTabs (desktop).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../application/providers.dart';
import '../models/warehouse_config.dart';

// ── Public entry point ────────────────────────────────────────────────────────

/// Drop-in widget that reads warehouseConfigProvider and shows the scouting +
/// inventory panel. Shows a helper message if no warehouse is loaded yet.
class WmsDashboardPanel extends ConsumerWidget {
  const WmsDashboardPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(warehouseConfigProvider);
    if (config == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No warehouse loaded — publish a warehouse first.',
          style: TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
        ),
      );
    }
    return _ScoutingPanel(config: config);
  }
}

// ── Internal polling widget ───────────────────────────────────────────────────

class _ScoutingPanel extends ConsumerStatefulWidget {
  const _ScoutingPanel({required this.config});
  final WarehouseConfig config;

  @override
  ConsumerState<_ScoutingPanel> createState() => _ScoutingPanelState();
}

class _ScoutingPanelState extends ConsumerState<_ScoutingPanel> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _warehouseStatus;
  bool _loading = true;
  bool _whChecked = false;
  String? _fetchError;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fetchWarehouseStatus();
    _fetch();
    // Poll dashboard every 10 s; also retry status check until OPERATIONAL.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      _fetch();
      // Keep retrying until the warehouse is confirmed in the DB.
      if (_warehouseStatus == null) _fetchWarehouseStatus();
    });
  }

  @override
  void didUpdateWidget(_ScoutingPanel old) {
    super.didUpdateWidget(old);
    // Warehouse was re-published with a new ID — reset and re-check.
    if (old.config.id != widget.config.id) {
      setState(() {
        _warehouseStatus = null;
        _whChecked = false;
        _data = null;
        _loading = true;
        _fetchError = null;
      });
      _fetchWarehouseStatus();
      _fetch();
    }
  }

  Future<void> _fetchWarehouseStatus() async {
    final status =
        await ApiClient.instance.getWarehouseStatus(widget.config.id);
    if (!mounted) return;
    final wasNull = _warehouseStatus == null;
    setState(() {
      _warehouseStatus = status;
      _whChecked = true;
    });
    // If the warehouse just became visible in the DB, pull a fresh inventory snapshot
    // immediately rather than waiting for the next 10 s tick.
    if (wasNull && status != null) _fetch();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final data = await ApiClient.instance.getWmsDashboard(widget.config.id);
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
          _fetchError = null;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _fetchError = e.toString();
        });
    }
  }

  /// Compute exploration + inventory stats from local Riverpod state.
  /// Used as a fallback when the backend is unreachable.
  static Map<String, dynamic> _buildLocalSnapshot(
      WarehouseConfig config, Set<String> explored) {
    final exploredSet = <(int, int)>{};
    for (final key in explored) {
      final parts = key.split(',');
      if (parts.length == 2) {
        final r = int.tryParse(parts[0]);
        final c = int.tryParse(parts[1]);
        if (r != null && c != null) exploredSet.add((r, c));
      }
    }
    final totalCells = config.rows * config.cols;
    final exploredCount = explored.length;
    final pct = totalCells > 0 ? exploredCount / totalCells * 100.0 : 0.0;

    final breakdown = <String, int>{};
    for (final cell in config.cells) {
      if (exploredSet.contains((cell.row, cell.col))) {
        final name = cell.type.name;
        breakdown[name] = (breakdown[name] ?? 0) + 1;
      }
    }

    final racks = config.cells.where((c) => c.type.isRack).toList();
    final exploredRacks =
        racks.where((c) => exploredSet.contains((c.row, c.col))).toList();
    // Only include racks the robots have actually visited — unexplored racks
    // have no real WMS data yet and must not appear in the inventory panel.
    final inventoryItems = exploredRacks
        .where((c) => c.skuId != null)
        .take(15)
        .map((c) => {
              'row': c.row,
              'col': c.col,
              'sku_id': c.skuId!,
              'fill_pct': c.fillFraction * 100.0,
              'wms_confidence': 0.75,
            })
        .toList();
    return {
      'exploration': {
        'explored_count': exploredCount,
        'total_cells': totalCells,
        'exploration_pct': pct,
        'cell_type_breakdown': breakdown,
        'recent_discoveries': <Map<String, dynamic>>[],
      },
      'inventory': {
        'total_racks': racks.length,
        'fully_stocked': exploredRacks.where((c) => c.isFull).length,
        'low_stock': exploredRacks.where((c) => c.needsReplenishment).length,
        'out_of_stock':
            exploredRacks.where((c) => c.isEmpty && c.skuId != null).length,
        'items': inventoryItems,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final explored = ref.watch(exploredCellsProvider);
    final opsStarted = ref.watch(operationsStartedProvider);

    // ── Decide what data to display ──────────────────────────────────────────
    // When ops are running we ALWAYS derive exploration from local Riverpod
    // state — it updates every 400 ms.  The backend only knows about cells
    // that have been flushed (every 30 s), so _data will show 0 explored
    // cells almost all of the time and must NOT override local exploration.
    //
    // For inventory we prefer backend data (it has confidence scores and
    // persists across sessions) but fall back to local cell config data.
    Map<String, dynamic>? displayData;
    bool isLocalMode = false;

    if (opsStarted) {
      final local = _buildLocalSnapshot(widget.config, explored);
      if (_data == null) {
        displayData = local;
        isLocalMode = true;
      } else {
        // Merge: local exploration (live) + backend inventory (more accurate
        // when synced), falling back to local inventory between 30-s flushes.
        final backendInv =
            (_data!['inventory'] as Map?)?.cast<String, dynamic>() ?? {};
        final backendHasRacks = (backendInv['total_racks'] as int? ?? 0) > 0;
        displayData = {
          'exploration': local['exploration'],
          'inventory': backendHasRacks ? backendInv : local['inventory'],
        };
      }
    } else {
      // Ops not yet started in this session.  rack_inventory_wms may have
      // rows from a previous session, but showing them here violates the
      // "earn your WMS data through exploration" contract — robots haven't
      // confirmed anything yet.  Always show zero-exploration snapshot.
      displayData = _buildLocalSnapshot(widget.config, const {});
      isLocalMode = false;
    }

    if (displayData == null) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: Color(0xFF00D4FF),
                strokeWidth: 2,
              ),
            ),
          ),
        );
      }
      if (_fetchError != null) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 14, color: Color(0xFFFF4444)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Could not reach backend: $_fetchError',
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFFFF4444)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh,
                    size: 14, color: Color(0xFF8B949E)),
                onPressed: () {
                  _fetchWarehouseStatus();
                  _fetch();
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final exploration =
        (displayData['exploration'] as Map?)?.cast<String, dynamic>() ?? {};
    final inventory =
        (displayData['inventory'] as Map?)?.cast<String, dynamic>() ?? {};

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isLocalMode)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 11, color: Color(0xFF8B949E)),
                  SizedBox(width: 4),
                  Text(
                    'Local mode — syncs when backend is online',
                    style: TextStyle(fontSize: 9, color: Color(0xFF8B949E)),
                  ),
                ],
              ),
            ),
          if (_whChecked && !isLocalMode)
            _WarehouseStatusChip(
              warehouseId: widget.config.id,
              status: _warehouseStatus,
              onRetry: () {
                _fetchWarehouseStatus();
                _fetch();
              },
            ),
          if (_whChecked) const SizedBox(height: 12),
          const _PanelHeader('Layout Discovery'),
          WmsExplorationCard(exploration),
          const SizedBox(height: 14),
          const _PanelHeader('WMS Inventory'),
          WmsInventoryCard(inventory),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Warehouse registration status chip ────────────────────────────────────────

class _WarehouseStatusChip extends StatelessWidget {
  const _WarehouseStatusChip({
    required this.warehouseId,
    required this.status,
    required this.onRetry,
  });
  final String warehouseId;
  final Map<String, dynamic>? status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool registered = status != null;
    final color =
        registered ? const Color(0xFF00FF88) : const Color(0xFFFF4444);
    final icon =
        registered ? Icons.check_circle_outline : Icons.warning_amber_rounded;
    final label = registered
        ? 'Warehouse registered in DB  ·  ${status!['status']}'
        : 'Not in DB — click Publish in the Craft tab';
    final idStr = warehouseId.length > 22
        ? '${warehouseId.substring(0, 22)}…'
        : warehouseId;

    return GestureDetector(
      onTap: onRetry,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withAlpha(80)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 10, color: color),
                  ),
                  Text(
                    'ID: $idStr',
                    style: const TextStyle(
                      fontSize: 8.5,
                      color: Color(0xFF8B949E),
                      fontFamily: 'ShareTechMono',
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.refresh, size: 11, color: color.withAlpha(160)),
          ],
        ),
      ),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _PanelHeader extends StatelessWidget {
  const _PanelHeader(this.text);
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

// ── Exploration card ──────────────────────────────────────────────────────────

class WmsExplorationCard extends StatelessWidget {
  const WmsExplorationCard(this.data, {super.key});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final explored = data['explored_count'] as int? ?? 0;
    final total = data['total_cells'] as int? ?? 0;
    final pct = (data['exploration_pct'] as num?)?.toDouble() ?? 0.0;
    final breakdown =
        (data['cell_type_breakdown'] as Map?)?.cast<String, dynamic>() ?? {};
    final recent = (data['recent_discoveries'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [];

    return Card(
      color: const Color(0xFF161B22),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.explore_outlined,
                    size: 14, color: Color(0xFF00D4FF)),
                const SizedBox(width: 6),
                Text(
                  '$explored / $total cells scouted',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
                const Spacer(),
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF00D4FF),
                    fontFamily: 'ShareTechMono',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total > 0 ? explored / total : 0,
                minHeight: 6,
                color: const Color(0xFF00D4FF),
                backgroundColor: const Color(0xFF21262D),
              ),
            ),
            if (breakdown.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: breakdown.entries
                    .where((e) => (e.value as int? ?? 0) > 0)
                    .map((e) => _CellTypeChip(e.key, e.value as int))
                    .toList(),
              ),
            ],
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'RECENT DISCOVERIES',
                style: TextStyle(
                    fontSize: 8, letterSpacing: 1.5, color: Color(0xFF8B949E)),
              ),
              const SizedBox(height: 4),
              ...recent.take(5).map((r) => _DiscoveryRow(r)),
            ],
          ],
        ),
      ),
    );
  }
}

class _CellTypeChip extends StatelessWidget {
  const _CellTypeChip(this.type, this.count);
  final String type;
  final int count;

  static Color _color(String t) => switch (t) {
        'rackPallet' ||
        'rackCase' ||
        'rackLoose' ||
        'rack' =>
          const Color(0xFF00D4FF),
        'aisle' || 'crossAisle' || 'roadAisle' => const Color(0xFF00FF88),
        'packStation' => const Color(0xFFFFCC00),
        'obstacle' || 'tree' => const Color(0xFFFF4444),
        _ => const Color(0xFF8B949E),
      };

  @override
  Widget build(BuildContext context) {
    final color = _color(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        '$type: $count',
        style:
            TextStyle(fontSize: 9, color: color, fontFamily: 'ShareTechMono'),
      ),
    );
  }
}

class _DiscoveryRow extends StatelessWidget {
  const _DiscoveryRow(this.r);
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final row = r['row'] as int? ?? 0;
    final col = r['col'] as int? ?? 0;
    final type = r['cell_type'] as String? ?? '?';
    final by = r['explored_by'] as String? ?? '?';
    final ts = r['first_explored_at'] as String? ?? '';
    final timeStr = ts.length >= 19 ? ts.substring(11, 19) : '—';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              '($row,$col)',
              style: const TextStyle(
                  fontSize: 9,
                  color: Color(0xFF8B949E),
                  fontFamily: 'ShareTechMono'),
            ),
          ),
          Expanded(
            child: Text(
              type,
              style: const TextStyle(fontSize: 9, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            by,
            style: const TextStyle(fontSize: 9, color: Color(0xFF00D4FF)),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 6),
          Text(
            timeStr,
            style: const TextStyle(
                fontSize: 9,
                color: Color(0xFF8B949E),
                fontFamily: 'ShareTechMono'),
          ),
        ],
      ),
    );
  }
}

// ── Inventory card ────────────────────────────────────────────────────────────

class WmsInventoryCard extends StatelessWidget {
  const WmsInventoryCard(this.data, {super.key});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final total = data['total_racks'] as int? ?? 0;
    final full = data['fully_stocked'] as int? ?? 0;
    final low = data['low_stock'] as int? ?? 0;
    final oos = data['out_of_stock'] as int? ?? 0;
    final items = (data['items'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [];

    if (total == 0) {
      return const Card(
        color: Color(0xFF161B22),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.inventory_2_outlined,
                  size: 14, color: Color(0xFF8B949E)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No inventory discovered yet.  Start robot exploration — the WMS populates as robots scan rack locations.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      color: const Color(0xFF161B22),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _InvBadge('$total Racks', const Color(0xFF8B949E)),
                _InvBadge('$full Full', const Color(0xFF00FF88)),
                _InvBadge('$low Low', const Color(0xFFFFCC00)),
                _InvBadge('$oos OOS', const Color(0xFFFF4444)),
              ],
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text('LOC',
                        style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 1,
                            color: Color(0xFF8B949E))),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text('SKU',
                        style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 1,
                            color: Color(0xFF8B949E))),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text('FILL',
                        style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 1,
                            color: Color(0xFF8B949E))),
                  ),
                  Expanded(
                    child: Text('CONF',
                        style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 1,
                            color: Color(0xFF8B949E))),
                  ),
                ],
              ),
              const Divider(color: Color(0xFF21262D), height: 8),
              ...items.take(15).map((item) => _InventoryRow(item)),
            ],
          ],
        ),
      ),
    );
  }
}

class _InvBadge extends StatelessWidget {
  const _InvBadge(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withAlpha(25),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withAlpha(80)),
        ),
        child: Text(
          label,
          style:
              TextStyle(fontSize: 9, color: color, fontFamily: 'ShareTechMono'),
        ),
      );
}

class _InventoryRow extends StatelessWidget {
  const _InventoryRow(this.item);
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final row = item['row'] as int? ?? 0;
    final col = item['col'] as int? ?? 0;
    final sku = item['sku_id'] as String? ?? '—';
    final fillPct = (item['fill_pct'] as num?)?.toDouble() ?? 0.0;
    final conf = (item['wms_confidence'] as num?)?.toDouble() ?? 0.0;

    final fillColor = fillPct == 0
        ? const Color(0xFFFF4444)
        : fillPct < 50
            ? const Color(0xFFFFCC00)
            : const Color(0xFF00FF88);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              '($row,$col)',
              style: const TextStyle(
                  fontSize: 9,
                  color: Color(0xFF8B949E),
                  fontFamily: 'ShareTechMono'),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              sku,
              style: const TextStyle(fontSize: 9, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 90,
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: fillPct / 100,
                      minHeight: 4,
                      color: fillColor,
                      backgroundColor: const Color(0xFF21262D),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${fillPct.toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 8,
                      color: fillColor,
                      fontFamily: 'ShareTechMono'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              '${(conf * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: 9,
                  color: conf >= 0.8
                      ? const Color(0xFF00FF88)
                      : const Color(0xFFFFCC00),
                  fontFamily: 'ShareTechMono'),
            ),
          ),
        ],
      ),
    );
  }
}
