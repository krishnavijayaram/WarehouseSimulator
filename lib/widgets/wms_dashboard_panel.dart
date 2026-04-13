/// wms_dashboard_panel.dart
/// Public widget: shows layout scouting progress + WMS inventory.
/// Polls GET /api/v1/wms/dashboard every 10 s.
/// Used by both DashboardScreen (mobile) and AdaptiveShell DataTabs (desktop).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api_client.dart';
import '../core/sim_ws.dart';
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Listen to inboundTrucksProvider: whenever a pick/drop updates the truck
    // data, immediately re-fetch the WMS dashboard so staging counts refresh
    // without waiting for the 10 s timer.
    ref.listen<AsyncValue<InboundTruckData>>(inboundTrucksProvider, (_, next) {
      if (next is AsyncData) {
        _fetch();
      }
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
      // Fall back to a local snapshot for 404 (warehouse not yet in DB) and
      // connection errors so the panel stays useful even when the backend is
      // unreachable or the warehouse hasn't been published yet.
      final isNetworkOrNotFound = e is ApiException
          ? (e.statusCode == 404 || e.statusCode == 0)
          : true; // SocketException / TimeoutException etc.
      if (mounted) {
        if (isNetworkOrNotFound) {
          final localData = _buildLocalSnapshot(
              widget.config, ref.read(exploredCellsProvider));
          setState(() {
            _data = localData;
            _loading = false;
            _fetchError = null;
          });
        } else {
          setState(() {
            _loading = false;
            _fetchError = e.toString();
          });
        }
      }
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
    final cargoMap = ref.watch(robotCargoProvider);
    // Build a robotId → name lookup from the live frame
    final frameRobots = ref.watch(simFrameProvider).robots;
    final robotNameById = {for (final r in frameRobots) r.id: r.name};
    // Live truck data (kept in sync: invalidated after every PICK)
    final trucksData = ref.watch(inboundTrucksProvider);
    final inboundTrucks = trucksData.valueOrNull?.trucks ?? const [];
    final shipmentsByTruck =
        trucksData.valueOrNull?.shipmentsByTruck ?? const {};

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

    final exploration =
        (displayData['exploration'] as Map?)?.cast<String, dynamic>() ?? {};
    final inventory =
        (displayData['inventory'] as Map?)?.cast<String, dynamic>() ?? {};
    // Staging data only comes from the backend (no local equivalent)
    final staging = (_data?['staging'] as Map?)?.cast<String, dynamic>() ?? {};

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
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(
                minHeight: 1,
                backgroundColor: Color(0xFF21262D),
                color: Color(0xFF00D4FF),
              ),
            ),
          if (_fetchError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '⚠ $_fetchError',
                style: const TextStyle(color: Color(0xFFFF4444), fontSize: 9),
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
          // ── Inbound Trucks (remaining / total per SKU) ──────────────────
          if (inboundTrucks.isNotEmpty) ...[
            const _PanelHeader('Inbound Trucks'),
            ...inboundTrucks.map((t) {
              final tid = t['truck_id'] as String? ?? '';
              return _WmsTruckCard(
                truck: t,
                shipments: shipmentsByTruck[tid] ?? const [],
              );
            }),
            const SizedBox(height: 14),
          ],
          // ── Robots in transit (carrying a pallet right now) ─────────────
          if (cargoMap.isNotEmpty) ...[
            const _PanelHeader('Inbound Robot On-Hand'),
            _InTransitCard(cargoMap: cargoMap, robotNameById: robotNameById),
            const SizedBox(height: 14),
          ],
          // ── Staging buffer (shows pallets received but not yet putaway) ────
          if (!opsStarted ||
              (staging['total_pallets_staged'] as int? ?? 0) > 0) ...[
            const _PanelHeader('Inbound Staging'),
            _StagingCard(staging),
            const SizedBox(height: 14),
          ],
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
// ── Compact Truck Card (WMS panel — remaining/total per SKU) ─────────────────

class _WmsTruckCard extends StatelessWidget {
  const _WmsTruckCard({required this.truck, required this.shipments});
  final Map<String, dynamic> truck;
  final List<Map<String, dynamic>> shipments;

  @override
  Widget build(BuildContext context) {
    final truckId = truck['truck_id'] as String? ?? '?';
    final status = truck['status_actual'] as String? ?? '?';
    final statusColor = switch (status) {
      'ENROUTE' => const Color(0xFFFFCC00),
      'ARRIVED' || 'YARD_ASSIGNED' => const Color(0xFF00D4FF),
      'WAITING' || 'UNLOADING' => const Color(0xFF00FF88),
      _ => const Color(0xFF8B949E),
    };

    // Group shipments by SKU
    final grouped = <String, ({int expected, int remaining})>{};
    for (final s in shipments) {
      final sku = s['sku_id'] as String? ?? '?';
      final exp = (s['qty_expected'] as num? ?? 0).toInt();
      final rem = (s['qty_remaining'] as num? ?? 0).toInt();
      final cur = grouped[sku];
      grouped[sku] = (
        expected: (cur?.expected ?? 0) + exp,
        remaining: (cur?.remaining ?? 0) + rem,
      );
    }

    // Use pre-computed pallet counts from API (qty_pallets_expected / qty_pallets_remaining).
    // These are normalised server-side regardless of which creation path produced the shipment.
    final totalExpPal = shipments.fold<int>(
        0, (s, e) => s + ((e['qty_pallets_expected'] as num? ?? 0).toInt()));
    final totalRemPal = shipments.fold<int>(
        0, (s, e) => s + ((e['qty_pallets_remaining'] as num? ?? 0).toInt()));

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: statusColor.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ────────────────────────────────────────────────
          Row(children: [
            const Icon(Icons.local_shipping_outlined,
                size: 11, color: Color(0xFF8B949E)),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                truckId,
                style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFE6EDF3),
                    fontWeight: FontWeight.bold,
                    fontFamily: 'ShareTechMono'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(20),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(status,
                  style: TextStyle(
                      fontSize: 8,
                      color: statusColor,
                      fontWeight: FontWeight.bold)),
            ),
            if (totalExpPal > 0) ...[
              const SizedBox(width: 8),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold),
                  children: [
                    TextSpan(
                      text: '$totalRemPal',
                      style: TextStyle(
                          color: totalRemPal < totalExpPal
                              ? const Color(0xFFFFCC00)
                              : const Color(0xFF00D4FF)),
                    ),
                    const TextSpan(
                      text: ' / ',
                      style: TextStyle(color: Color(0xFF484F58)),
                    ),
                    TextSpan(
                      text: '$totalExpPal pal',
                      style: const TextStyle(color: Color(0xFF484F58)),
                    ),
                  ],
                ),
              ),
            ],
          ]),
          // ── Per-SKU rows ──────────────────────────────────────────────
          if (grouped.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Divider(color: Color(0xFF30363D), height: 1),
            const SizedBox(height: 5),
            ...grouped.entries.map((e) {
              // Find pallet counts from the raw shipment list for this SKU
              final skuShipments =
                  shipments.where((s) => s['sku_id'] == e.key).toList();
              final expPal = skuShipments.fold<int>(
                  0,
                  (s, x) =>
                      s + ((x['qty_pallets_expected'] as num? ?? 0).toInt()));
              final remPal = skuShipments.fold<int>(
                  0,
                  (s, x) =>
                      s + ((x['qty_pallets_remaining'] as num? ?? 0).toInt()));
              final picked = expPal - remPal;
              final fill = e.value.expected > 0
                  ? e.value.remaining / e.value.expected
                  : 1.0;
              final countColor = picked > 0
                  ? const Color(0xFFFFCC00)
                  : const Color(0xFF00D4FF);
              return Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      const Text('📦', style: TextStyle(fontSize: 10)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          e.key,
                          style: const TextStyle(
                              fontSize: 9, color: Color(0xFFCDD9E5)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      RichText(
                        text: TextSpan(
                          style: const TextStyle(
                              fontSize: 10, fontWeight: FontWeight.bold),
                          children: [
                            TextSpan(
                              text: '$remPal',
                              style: TextStyle(color: countColor),
                            ),
                            const TextSpan(
                              text: ' / ',
                              style: TextStyle(color: Color(0xFF484F58)),
                            ),
                            TextSpan(
                              text: '$expPal pal',
                              style: const TextStyle(color: Color(0xFF484F58)),
                            ),
                          ],
                        ),
                      ),
                      if (picked > 0) ...[
                        const SizedBox(width: 6),
                        Text(
                          '−$picked',
                          style: const TextStyle(
                              fontSize: 9, color: Color(0xFFFF8800)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: fill,
                        minHeight: 2,
                        backgroundColor: const Color(0xFF21262D),
                        valueColor: AlwaysStoppedAnimation<Color>(countColor),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

// ── In-Transit Card (robots currently carrying a pallet) ─────────────────────

class _InTransitCard extends StatelessWidget {
  const _InTransitCard({required this.cargoMap, required this.robotNameById});
  final Map<String, PalletData> cargoMap;
  final Map<String, String> robotNameById;

  @override
  Widget build(BuildContext context) {
    final entries = cargoMap.entries.toList();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFFF8800).withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.precision_manufacturing,
                size: 13, color: Color(0xFFFF8800)),
            const SizedBox(width: 6),
            Text(
              '${entries.length} robot${entries.length == 1 ? '' : 's'} carrying',
              style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFFF8800),
                  fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            const Text(
              'IN TRANSIT',
              style: TextStyle(
                  fontSize: 8, color: Color(0xFF8B949E), letterSpacing: 1),
            ),
          ]),
          const SizedBox(height: 8),
          const Divider(color: Color(0xFF30363D), height: 1),
          const SizedBox(height: 6),
          ...entries.map((e) {
            final name = robotNameById[e.key] ?? e.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(children: [
                const Icon(Icons.smart_toy_outlined,
                    size: 11, color: Color(0xFFFF8800)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    name,
                    style:
                        const TextStyle(fontSize: 10, color: Color(0xFFE6EDF3)),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF8800).withAlpha(20),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color: const Color(0xFFFF8800).withAlpha(60)),
                  ),
                  child: Text(
                    e.value.skuId,
                    style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFFFF8800),
                        fontFamily: 'ShareTechMono',
                        fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  e.value.truckId,
                  style: const TextStyle(fontSize: 9, color: Color(0xFF8B949E)),
                ),
              ]),
            );
          }),
        ],
      ),
    );
  }
}
// ── Inbound Staging Card ─────────────────────────────────────────────────────

class _StagingCard extends StatelessWidget {
  const _StagingCard(this.staging);
  final Map<String, dynamic> staging;

  @override
  Widget build(BuildContext context) {
    final total = (staging['total_pallets_staged'] as num? ?? 0).toInt();
    final items =
        (staging['items'] as List? ?? []).cast<Map<String, dynamic>>();

    if (total == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: const Row(children: [
          Icon(Icons.inventory_2_outlined, size: 14, color: Color(0xFF8B949E)),
          SizedBox(width: 6),
          Text(
            'No pallets in staging — unload a truck to receive goods',
            style: TextStyle(fontSize: 10, color: Color(0xFF8B949E)),
          ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF00FF88).withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('📦', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Text(
              '$total pallet${total == 1 ? '' : 's'} staged',
              style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF00FF88),
                  fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            const Text(
              'AWAITING PUTAWAY',
              style: TextStyle(
                  fontSize: 8, color: Color(0xFF8B949E), letterSpacing: 1),
            ),
          ]),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(color: Color(0xFF30363D), height: 1),
            const SizedBox(height: 6),
            ...items.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        e['sku_id'] as String? ?? '?',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFFE6EDF3)),
                      ),
                    ),
                    Text(
                      '${e['pallets_staged']} pallet'
                      '${(e['pallets_staged'] as num? ?? 0) == 1 ? '' : 's'}',
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFF00D4FF)),
                    ),
                  ]),
                )),
          ],
        ],
      ),
    );
  }
}
