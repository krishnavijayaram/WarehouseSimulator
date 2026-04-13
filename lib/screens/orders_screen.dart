/// orders_screen.dart — Inbound and Outbound order creation & tracking.
///
/// Inbound: user specifies SKUs + pallet quantities → a truck appears in the
///          inbound bay exactly 60 seconds after the order is placed.
/// Outbound: user specifies SKUs + qty in pallets/cases/loose (or a mix).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../core/api_client.dart';

// ── Colour aliases (match AdaptiveShell palette) ──────────────────────────────

const _bg = Color(0xFF0D1117);
const _surface = Color(0xFF161B22);
const _border = Color(0xFF21262D);
const _cyan = Color(0xFF00D4FF);
const _green = Color(0xFF00FF88);
const _yellow = Color(0xFFFFCC00);
const _red = Color(0xFFFF4444);
const _muted = Color(0xFF8B949E);
const _text = Color(0xFFE6EDF3);

// ── Orders Screen ─────────────────────────────────────────────────────────────

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _surface,
          title: const Text(
            'ORDERS',
            style: TextStyle(
              color: _cyan,
              fontSize: 13,
              letterSpacing: 2,
              fontWeight: FontWeight.bold,
            ),
          ),
          bottom: const TabBar(
            labelColor: _cyan,
            unselectedLabelColor: _muted,
            indicatorColor: _cyan,
            tabs: [
              Tab(text: '📦 INBOUND'),
              Tab(text: '🚚 OUTBOUND'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _InboundTab(),
            _OutboundTab(),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// INBOUND TAB
// ══════════════════════════════════════════════════════════════════════════════

class _InboundTab extends ConsumerStatefulWidget {
  const _InboundTab();

  @override
  ConsumerState<_InboundTab> createState() => _InboundTabState();
}

class _InboundTabState extends ConsumerState<_InboundTab> {
  List<Map<String, dynamic>> _orders = [];
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg == null) return;
    try {
      final orders = await ApiClient.instance.getOrders(cfg.id, 'INBOUND');
      if (mounted) setState(() => _orders = orders);
    } catch (_) {
      // silently ignore poll errors
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SectionHeader(
          label: 'INBOUND ORDERS (${_orders.length})',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _cyan,
              foregroundColor: _bg,
              textStyle:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            onPressed: () => _showOrderDialog(context),
            icon: const Icon(Icons.add, size: 14),
            label: const Text('PLACE INBOUND ORDER'),
          ),
        ),
        Expanded(
          child: _orders.isEmpty
              ? const _EmptyState(
                  icon: Icons.local_shipping_outlined,
                  message:
                      'No active inbound orders.\nPlace an order to dispatch one.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _orders.length,
                  itemBuilder: (_, i) => _OrderCard(
                    order: _orders[i],
                    onRefresh: _load,
                  ),
                ),
        ),
      ],
    );
  }

  void _showOrderDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _InboundOrderDialog(onCreated: () {
        _load();
        Navigator.of(ctx).pop();
      }),
    );
  }
}

// ── Inbound Order Dialog ──────────────────────────────────────────────────────

class _InboundOrderDialog extends ConsumerStatefulWidget {
  const _InboundOrderDialog({required this.onCreated});
  final VoidCallback onCreated;

  @override
  ConsumerState<_InboundOrderDialog> createState() =>
      _InboundOrderDialogState();
}

class _InboundOrderDialogState extends ConsumerState<_InboundOrderDialog> {
  List<Map<String, dynamic>> _skus = [];
  final List<_InboundLine> _lines = [];
  bool _skusLoading = true;
  bool _submitting = false;
  String? _error;
  String _truckType = 'M';

  @override
  void initState() {
    super.initState();
    _fetchSkus();
  }

  Future<void> _fetchSkus() async {
    try {
      final skus = await ApiClient.instance.getGlobalSkus();
      if (mounted) {
        setState(() {
          _skus = skus;
          _skusLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _skusLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _addLine() {
    if (_skus.isEmpty) return;
    setState(
        () => _lines.add(_InboundLine(skuId: _skus.first['sku_id'] as String)));
  }

  Future<void> _submit() async {
    if (_lines.isEmpty) {
      setState(() => _error = 'Add at least one SKU line.');
      return;
    }
    for (final l in _lines) {
      if (l.qtyPallets <= 0) {
        setState(() => _error = 'All lines must have qty > 0.');
        return;
      }
    }
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg == null) {
      setState(() => _error = 'No warehouse configured.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance.createInboundOrder(
        warehouseId: cfg.id,
        lines: _lines
            .map((l) => {'sku_id': l.skuId, 'qty_pallets': l.qtyPallets})
            .toList(),
        truckType: _truckType,
      );
      if (mounted) {
        final truckId = result['truck_id'] as String? ?? '?';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _green.withAlpha(200),
            content: Text(
              'Truck $truckId dispatched — arriving in ~60 sec',
              style: const TextStyle(color: _bg, fontWeight: FontWeight.bold),
            ),
          ),
        );
        widget.onCreated();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              const Text('📦 NEW INBOUND ORDER',
                  style: TextStyle(
                      color: _cyan,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 4),
              const Text(
                  'Pallets will arrive at inbound bay within 60 seconds.',
                  style: TextStyle(color: _muted, fontSize: 11)),
              const SizedBox(height: 16),

              // Truck type selector
              Row(
                children: [
                  const Text('TRUCK SIZE:',
                      style: TextStyle(
                          color: _muted, fontSize: 11, letterSpacing: 1)),
                  const SizedBox(width: 12),
                  ..._buildTruckTypeChips(),
                ],
              ),
              const SizedBox(height: 16),

              // SKU Lines header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('SKU LINES',
                      style: TextStyle(
                          color: _muted, fontSize: 11, letterSpacing: 1)),
                  TextButton.icon(
                    onPressed: _skusLoading ? null : _addLine,
                    icon: const Icon(Icons.add, size: 12, color: _green),
                    label: const Text('ADD SKU',
                        style: TextStyle(color: _green, fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // SKU lines list
              Flexible(
                child: _skusLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: _cyan, strokeWidth: 2))
                    : _skus.isEmpty
                        ? const Text('No SKUs available in master data.',
                            style: TextStyle(color: _red, fontSize: 11))
                        : _lines.isEmpty
                            ? const Text('No lines yet — press ADD SKU.',
                                style: TextStyle(color: _muted, fontSize: 11))
                            : SingleChildScrollView(
                                child: Column(
                                  children: [
                                    for (int i = 0; i < _lines.length; i++)
                                      _InboundLineRow(
                                        line: _lines[i],
                                        skus: _skus,
                                        onChanged: (l) =>
                                            setState(() => _lines[i] = l),
                                        onRemove: () =>
                                            setState(() => _lines.removeAt(i)),
                                      ),
                                  ],
                                ),
                              ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: _red, fontSize: 11)),
              ],

              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('CANCEL',
                        style: TextStyle(color: _muted, fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: _cyan, foregroundColor: _bg),
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _bg))
                        : const Text('DISPATCH TRUCK',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTruckTypeChips() {
    const sizes = ['S', 'M', 'L', 'XL'];
    const labels = {'S': 'Small', 'M': 'Medium', 'L': 'Large', 'XL': 'XL'};
    return sizes.map((s) {
      final selected = _truckType == s;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(labels[s]!,
              style: TextStyle(
                  color: selected ? _bg : _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
          selected: selected,
          selectedColor: _cyan,
          backgroundColor: _border,
          side: BorderSide(color: selected ? _cyan : _border),
          onSelected: (_) => setState(() => _truckType = s),
        ),
      );
    }).toList();
  }
}

class _InboundLine {
  String skuId;
  int qtyPallets;
  _InboundLine({required this.skuId, this.qtyPallets = 1});
  _InboundLine copyWith({String? skuId, int? qtyPallets}) => _InboundLine(
      skuId: skuId ?? this.skuId, qtyPallets: qtyPallets ?? this.qtyPallets);
}

class _InboundLineRow extends StatelessWidget {
  const _InboundLineRow({
    required this.line,
    required this.skus,
    required this.onChanged,
    required this.onRemove,
  });
  final _InboundLine line;
  final List<Map<String, dynamic>> skus;
  final ValueChanged<_InboundLine> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _bg,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          // SKU selector
          Expanded(
            flex: 3,
            child: DropdownButton<String>(
              value: line.skuId,
              dropdownColor: _surface,
              style: const TextStyle(color: _text, fontSize: 11),
              underline: const SizedBox.shrink(),
              isExpanded: true,
              items: skus.map((s) {
                final id = s['sku_id'] as String;
                final name = s['sku_name'] as String? ?? id;
                return DropdownMenuItem(
                  value: id,
                  child: Text('$id — $name',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) onChanged(line.copyWith(skuId: v));
              },
            ),
          ),
          const SizedBox(width: 8),
          // Qty pallets
          SizedBox(
            width: 80,
            child: _NumberField(
              label: 'Pallets',
              value: line.qtyPallets,
              onChanged: (v) => onChanged(line.copyWith(qtyPallets: v)),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 14, color: _muted),
            onPressed: onRemove,
            tooltip: 'Remove line',
          ),
        ],
      ),
    );
  }
}

// ── Unified Order Card ────────────────────────────────────────────────────────
// Displays one OrderHeader row (INBOUND or OUTBOUND) with its embedded lines.

class _OrderCard extends ConsumerStatefulWidget {
  const _OrderCard({required this.order, required this.onRefresh});
  final Map<String, dynamic> order;
  final VoidCallback onRefresh;

  @override
  ConsumerState<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends ConsumerState<_OrderCard> {
  bool _dispatching = false;

  /// Navigates to the Floor screen and selects the truck so the user can
  /// see it on the road and then direct it to an inbound bay.
  void _dispatchTruck(String truckId) {
    // Signal Floor screen to auto-select this truck.
    ref.read(pendingTruckSelectionProvider.notifier).state = truckId;
    // Switch to the Floor tab (index 1).
    ref.read(navigateToTabProvider.notifier).state = 1;
  }

  static const _unitsPerPallet = 192;

  Future<void> _dispatchOutbound(String orderId) async {
    setState(() => _dispatching = true);
    try {
      final result = await ApiClient.instance.dispatchOutbound(orderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _green.withAlpha(200),
          content: Text(
            result['message'] as String? ?? 'Order dispatched.',
            style: const TextStyle(color: _bg, fontWeight: FontWeight.bold),
          ),
        ),
      );
      widget.onRefresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _red.withAlpha(200),
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
            style: const TextStyle(color: _text),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _dispatching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final orderType = order['order_type'] as String? ?? 'INBOUND';
    final isInbound = orderType == 'INBOUND';

    final orderId = order['order_id'] as String? ?? '?';
    final status = order['status'] as String? ?? '?';
    final expectedDate = order['expected_date'] as String?;

    // INBOUND sub-fields
    final truckId = order['truck_id'] as String?;
    final truckType = order['truck_type'] as String?;
    final carrier = order['carrier_name'] as String? ?? 'AUTO';

    // OUTBOUND sub-fields
    final customer = order['customer_id'] as String? ?? 'WALK-IN';
    final destination = order['destination'] as String? ?? 'TBD';

    final lines =
        (order['lines'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    final statusColor = switch (status) {
      'ENROUTE' => _yellow,
      'ARRIVED' => _cyan,
      'IN_YARD' => _cyan,
      'WAITING' => _green,
      'UNLOADING' => _green,
      'PENDING' => _yellow,
      'ALLOCATED' => _cyan,
      'PICKING' => _cyan,
      'PACKED' => _green,
      'LOADING' => _green,
      'DISPATCHED' => _muted,
      'COMPLETE' => _muted,
      _ => _muted,
    };

    String fmtTime(String? iso) {
      if (iso == null || iso.isEmpty) return '';
      if (iso.contains('T')) return iso.split('T').last.substring(0, 5);
      return iso;
    }

    final dateLabel = isInbound ? 'ETA' : 'DUE';
    final dateValue = fmtTime(expectedDate);
    final icon = isInbound ? Icons.local_shipping : Icons.outbox;
    final accentColor = isInbound ? _cyan : _green;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(icon, color: accentColor, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Row 1: order ID + type badge
                      Row(
                        children: [
                          Text(orderId,
                              style: const TextStyle(
                                  color: _text,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),
                          if (truckType != null)
                            _Badge(label: truckType, color: _border),
                        ],
                      ),
                      // Row 2: secondary info
                      Row(
                        children: [
                          if (dateValue.isNotEmpty)
                            Text('$dateLabel $dateValue  ',
                                style: const TextStyle(
                                    color: _muted, fontSize: 10)),
                          if (isInbound && carrier.isNotEmpty)
                            Text('· $carrier',
                                style: const TextStyle(
                                    color: _muted, fontSize: 10)),
                          if (!isInbound)
                            Text('$customer · $destination',
                                style: const TextStyle(
                                    color: _muted, fontSize: 10),
                                overflow: TextOverflow.ellipsis),
                        ],
                      ),
                      // Row 3: truck ID
                      if (truckId != null)
                        Text('Truck: $truckId',
                            style: const TextStyle(color: _muted, fontSize: 9)),
                    ],
                  ),
                ),
                _StatusBadge(status: status, color: statusColor),
              ],
            ),
          ),
          // ── Dispatch Truck button (INBOUND + ENROUTE only) ──
          // Once the truck is WAITING at a dock, the inbound robot handles
          // unloading automatically — no manual action needed.
          if (isInbound && status == 'ENROUTE' && truckId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _yellow.withAlpha(30),
                    foregroundColor: _yellow,
                    side: const BorderSide(color: _yellow),
                    textStyle: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () => _dispatchTruck(truckId),
                  icon: const Icon(Icons.local_shipping, size: 14),
                  label: const Text('TRUCK ON ROAD → VIEW ON FLOOR SCREEN'),
                ),
              ),
            ),
          // ── Outbound pick-robot status info row ──
          if (!isInbound && (status == 'PICKING' || status == 'PACKED')) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                children: [
                  const Icon(Icons.precision_manufacturing, size: 12, color: _green),
                  const SizedBox(width: 6),
                  Text(
                    status == 'PICKING'
                        ? '🤖 Pick robot staging cargo to pallet zone…'
                        : '📦 All items staged — ready to dispatch',
                    style: const TextStyle(color: _green, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
          // ── Dispatch Outbound Truck button (OUTBOUND + PACKED only) ──
          if (!isInbound && status == 'PACKED')
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _green.withAlpha(30),
                    foregroundColor: _green,
                    side: const BorderSide(color: _green),
                    textStyle: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: _dispatching
                      ? null
                      : () => _dispatchOutbound(orderId),
                  icon: _dispatching
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _green))
                      : const Icon(Icons.outbox, size: 14),
                  label: Text(_dispatching
                      ? 'DISPATCHING…'
                      : 'DISPATCH OUTBOUND TRUCK'),
                ),
              ),
            ),
          // ── Inbound bay / robot status info row ──
          if (isInbound && (status == 'WAITING' || status == 'UNLOADING')) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                children: [
                  Icon(
                    status == 'UNLOADING'
                        ? Icons.precision_manufacturing
                        : Icons.local_shipping,
                    size: 12,
                    color: _green,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status == 'UNLOADING'
                        ? '🤖 Inbound robot unloading cargo…'
                        : '🚛 Truck at inbound bay — robot en route',
                    style: const TextStyle(color: _green, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
          // ── Order lines ──
          if (lines.isNotEmpty) ...[
            const Divider(color: _border, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isInbound ? 'CARGO' : 'ITEMS',
                      style: const TextStyle(
                          color: _muted, fontSize: 9, letterSpacing: 1)),
                  const SizedBox(height: 4),
                  for (final line in lines)
                    _OrderDetailLine(
                        line: line,
                        isInbound: isInbound,
                        unitsPerPallet: _unitsPerPallet),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OrderDetailLine extends StatelessWidget {
  const _OrderDetailLine({
    required this.line,
    required this.isInbound,
    required this.unitsPerPallet,
  });
  final Map<String, dynamic> line;
  final bool isInbound;
  final int unitsPerPallet;

  @override
  Widget build(BuildContext context) {
    final skuId = line['sku_id'] as String? ?? '?';
    final qtyPallets = (line['qty_pallets'] as num? ?? 0).toInt();
    final qtyUnits = (line['qty_ordered'] as num? ?? 0).toInt();
    final unitType = (line['unit_type'] as String? ?? 'PALLET').toUpperCase();
    final lineStatus = line['status'] as String? ?? 'PENDING';

    final statusColor = switch (lineStatus) {
      'COMPLETE' => _muted,
      'PARTIAL' => _cyan,
      'CANCELLED' => _red,
      _ => _yellow,
    };

    // Display qty as pallets when possible, otherwise units
    final qtyLabel = (qtyPallets > 0)
        ? '$qtyPallets pallet${qtyPallets == 1 ? '' : 's'}'
        : '$qtyUnits ${unitType.toLowerCase()}${qtyUnits == 1 ? '' : 's'}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.inventory_2_outlined, size: 11, color: _muted),
          const SizedBox(width: 6),
          Expanded(
            child:
                Text(skuId, style: const TextStyle(color: _text, fontSize: 10)),
          ),
          Text(qtyLabel,
              style: const TextStyle(
                  color: _cyan, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text(lineStatus, style: TextStyle(color: statusColor, fontSize: 9)),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label, style: const TextStyle(color: _muted, fontSize: 9)),
      );
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.color});
  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withAlpha(80)),
        ),
        child: Text(status,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      );
}

// ══════════════════════════════════════════════════════════════════════════════
// OUTBOUND TAB
// ══════════════════════════════════════════════════════════════════════════════

class _OutboundTab extends ConsumerStatefulWidget {
  const _OutboundTab();

  @override
  ConsumerState<_OutboundTab> createState() => _OutboundTabState();
}

class _OutboundTabState extends ConsumerState<_OutboundTab> {
  List<Map<String, dynamic>> _orders = [];
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg == null) return;
    try {
      final orders = await ApiClient.instance.getOrders(cfg.id, 'OUTBOUND');
      if (mounted) setState(() => _orders = orders);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SectionHeader(
          label: 'OUTBOUND ORDERS (${_orders.length})',
          action: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: _bg,
              textStyle:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            onPressed: () => _showOrderDialog(context),
            icon: const Icon(Icons.add, size: 14),
            label: const Text('PLACE OUTBOUND ORDER'),
          ),
        ),
        Expanded(
          child: _orders.isEmpty
              ? const _EmptyState(
                  icon: Icons.outbox_outlined,
                  message:
                      'No outbound orders yet.\nPlace an order to dispatch goods.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _orders.length,
                  itemBuilder: (_, i) => _OrderCard(
                    order: _orders[i],
                    onRefresh: _load,
                  ),
                ),
        ),
      ],
    );
  }

  void _showOrderDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _OutboundOrderDialog(onCreated: () {
        _load();
        Navigator.of(ctx).pop();
      }),
    );
  }
}

// ── Outbound Order Dialog ─────────────────────────────────────────────────────

class _OutboundOrderDialog extends ConsumerStatefulWidget {
  const _OutboundOrderDialog({required this.onCreated});
  final VoidCallback onCreated;

  @override
  ConsumerState<_OutboundOrderDialog> createState() =>
      _OutboundOrderDialogState();
}

class _OutboundOrderDialogState extends ConsumerState<_OutboundOrderDialog> {
  List<Map<String, dynamic>> _skus = [];
  final List<_OutboundLine> _lines = [];
  bool _skusLoading = true;
  bool _submitting = false;
  String? _error;

  final _customerCtrl = TextEditingController(text: 'WALK-IN');
  final _destinationCtrl = TextEditingController(text: 'TBD');

  @override
  void initState() {
    super.initState();
    _fetchSkus();
  }

  @override
  void dispose() {
    _customerCtrl.dispose();
    _destinationCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchSkus() async {
    try {
      final skus = await ApiClient.instance.getGlobalSkus();
      if (mounted) {
        setState(() {
          _skus = skus;
          _skusLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _skusLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  void _addLine() {
    if (_skus.isEmpty) return;
    setState(() =>
        _lines.add(_OutboundLine(skuId: _skus.first['sku_id'] as String)));
  }

  Future<void> _submit() async {
    if (_lines.isEmpty) {
      setState(() => _error = 'Add at least one SKU line.');
      return;
    }
    for (final l in _lines) {
      if (l.qty <= 0) {
        setState(() => _error = 'All lines must have qty > 0.');
        return;
      }
    }
    final cfg = ref.read(warehouseConfigProvider);
    if (cfg == null) {
      setState(() => _error = 'No warehouse configured.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance.createOutboundOrder(
        warehouseId: cfg.id,
        lines: _lines
            .map((l) =>
                {'sku_id': l.skuId, 'unit_type': l.unitType, 'qty': l.qty})
            .toList(),
        customerId: _customerCtrl.text.trim().isEmpty
            ? 'WALK-IN'
            : _customerCtrl.text.trim(),
        destination: _destinationCtrl.text.trim().isEmpty
            ? 'TBD'
            : _destinationCtrl.text.trim(),
      );
      if (mounted) {
        final orderId = result['order_id'] as String? ?? '?';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _green.withAlpha(200),
            content: Text(
              'Order $orderId created',
              style: const TextStyle(color: _bg, fontWeight: FontWeight.bold),
            ),
          ),
        );
        widget.onCreated();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🚚 NEW OUTBOUND ORDER',
                  style: TextStyle(
                      color: _green,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
              const SizedBox(height: 4),
              const Text(
                  'Specify SKUs and quantities. Use PALLET, CASE, or LOOSE for each line.',
                  style: TextStyle(color: _muted, fontSize: 11)),
              const SizedBox(height: 16),

              // Customer & Destination
              Row(
                children: [
                  Expanded(
                    child: _LabeledTextField(
                        controller: _customerCtrl, label: 'CUSTOMER ID'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _LabeledTextField(
                        controller: _destinationCtrl, label: 'DESTINATION'),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // SKU Lines header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('SKU LINES',
                      style: TextStyle(
                          color: _muted, fontSize: 11, letterSpacing: 1)),
                  TextButton.icon(
                    onPressed: _skusLoading ? null : _addLine,
                    icon: const Icon(Icons.add, size: 12, color: _green),
                    label: const Text('ADD SKU',
                        style: TextStyle(color: _green, fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Lines header row
              if (_lines.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4, left: 2),
                  child: Row(
                    children: [
                      Expanded(
                          flex: 3,
                          child: Text('SKU',
                              style: TextStyle(
                                  color: _muted,
                                  fontSize: 9,
                                  letterSpacing: 1))),
                      SizedBox(width: 8),
                      SizedBox(
                          width: 110,
                          child: Text('UNIT TYPE',
                              style: TextStyle(
                                  color: _muted,
                                  fontSize: 9,
                                  letterSpacing: 1))),
                      SizedBox(width: 8),
                      SizedBox(
                          width: 70,
                          child: Text('QTY',
                              style: TextStyle(
                                  color: _muted,
                                  fontSize: 9,
                                  letterSpacing: 1))),
                      SizedBox(width: 32),
                    ],
                  ),
                ),

              Flexible(
                child: _skusLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: _cyan, strokeWidth: 2))
                    : _skus.isEmpty
                        ? const Text('No SKUs available.',
                            style: TextStyle(color: _red, fontSize: 11))
                        : _lines.isEmpty
                            ? const Text('No lines yet — press ADD SKU.',
                                style: TextStyle(color: _muted, fontSize: 11))
                            : SingleChildScrollView(
                                child: Column(
                                  children: [
                                    for (int i = 0; i < _lines.length; i++)
                                      _OutboundLineRow(
                                        line: _lines[i],
                                        skus: _skus,
                                        onChanged: (l) =>
                                            setState(() => _lines[i] = l),
                                        onRemove: () =>
                                            setState(() => _lines.removeAt(i)),
                                      ),
                                  ],
                                ),
                              ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(color: _red, fontSize: 11)),
              ],

              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('CANCEL',
                        style: TextStyle(color: _muted, fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: _green, foregroundColor: _bg),
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _bg))
                        : const Text('CREATE ORDER',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutboundLine {
  String skuId;
  String unitType; // PALLET | CASE | LOOSE
  int qty;

  _OutboundLine({required this.skuId, this.unitType = 'PALLET', this.qty = 1});

  _OutboundLine copyWith({String? skuId, String? unitType, int? qty}) =>
      _OutboundLine(
        skuId: skuId ?? this.skuId,
        unitType: unitType ?? this.unitType,
        qty: qty ?? this.qty,
      );
}

class _OutboundLineRow extends StatelessWidget {
  const _OutboundLineRow({
    required this.line,
    required this.skus,
    required this.onChanged,
    required this.onRemove,
  });
  final _OutboundLine line;
  final List<Map<String, dynamic>> skus;
  final ValueChanged<_OutboundLine> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _bg,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          // SKU selector
          Expanded(
            flex: 3,
            child: DropdownButton<String>(
              value: line.skuId,
              dropdownColor: _surface,
              style: const TextStyle(color: _text, fontSize: 11),
              underline: const SizedBox.shrink(),
              isExpanded: true,
              items: skus.map((s) {
                final id = s['sku_id'] as String;
                final name = s['sku_name'] as String? ?? id;
                return DropdownMenuItem(
                  value: id,
                  child: Text('$id — $name',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) onChanged(line.copyWith(skuId: v));
              },
            ),
          ),
          const SizedBox(width: 8),
          // Unit type
          SizedBox(
            width: 110,
            child: DropdownButton<String>(
              value: line.unitType,
              dropdownColor: _surface,
              style: const TextStyle(
                  color: _cyan, fontSize: 11, fontWeight: FontWeight.bold),
              underline: const SizedBox.shrink(),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'PALLET', child: Text('PALLET')),
                DropdownMenuItem(value: 'CASE', child: Text('CASE')),
                DropdownMenuItem(value: 'LOOSE', child: Text('LOOSE')),
              ],
              onChanged: (v) {
                if (v != null) onChanged(line.copyWith(unitType: v));
              },
            ),
          ),
          const SizedBox(width: 8),
          // Qty
          SizedBox(
            width: 70,
            child: _NumberField(
              label: 'Qty',
              value: line.qty,
              onChanged: (v) => onChanged(line.copyWith(qty: v)),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 14, color: _muted),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SHARED WIDGETS
// ══════════════════════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.action});
  final String label;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: _muted, fontSize: 11, letterSpacing: 1)),
          action,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _muted, size: 40),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField(
      {required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _ctrl.text != widget.value.toString()) {
      _ctrl.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.number,
      style: const TextStyle(color: _text, fontSize: 12),
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: const TextStyle(color: _muted, fontSize: 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        enabledBorder:
            const OutlineInputBorder(borderSide: BorderSide(color: _border)),
        focusedBorder:
            const OutlineInputBorder(borderSide: BorderSide(color: _cyan)),
        filled: true,
        fillColor: _surface,
      ),
      onChanged: (v) {
        final parsed = int.tryParse(v);
        if (parsed != null && parsed > 0) widget.onChanged(parsed);
      },
    );
  }
}

class _LabeledTextField extends StatelessWidget {
  const _LabeledTextField({required this.controller, required this.label});
  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: _text, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: _muted, fontSize: 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        enabledBorder:
            const OutlineInputBorder(borderSide: BorderSide(color: _border)),
        focusedBorder:
            const OutlineInputBorder(borderSide: BorderSide(color: _cyan)),
        filled: true,
        fillColor: _bg,
      ),
    );
  }
}
