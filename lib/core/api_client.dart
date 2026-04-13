/// api_client.dart — HTTP wrapper for the WIOS API gateway.
///
/// All requests flow through the gateway (:8000 or as configured in env.dart).
/// The session token is injected via [setToken] after login.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../env.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  String? _token;

  void setToken(String token) => _token = token;
  void clearToken() => _token = null;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-API-Key': gatewayApiKey,
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$gatewayBaseUrl$path').replace(queryParameters: query);

  // ── Auth ─────────────────────────────────────────────────────────────────

  /// GET /api/v1/users/sessions/{token} — validate stored token.
  /// Always passes the token as Bearer auth (called before setToken on startup).
  Future<Map<String, dynamic>> validateToken(String token) async {
    final r = await http.get(
      _uri('/api/v1/users/sessions/$token'),
      headers: {..._headers, 'Authorization': 'Bearer $token'},
    );
    return _check(r);
  }

  /// POST /api/v1/users/sessions/{token}/invalidate — logout.
  Future<void> invalidateSession(String token) async {
    await http.post(
      _uri('/api/v1/users/sessions/$token/invalidate'),
      headers: {..._headers, 'Authorization': 'Bearer $token'},
    );
  }

  /// GET /auth/providers — which OAuth providers are configured.
  Future<Map<String, dynamic>> getProviders() async {
    final r = await http.get(_uri('/auth/providers'), headers: _headers);
    return _check(r);
  }

  // ── Simulation control ────────────────────────────────────────────────────

  /// GET /api/v1/simulation/mode
  Future<Map<String, dynamic>> getSimMode() async {
    final r =
        await http.get(_uri('/api/v1/simulation/mode'), headers: _headers);
    return _check(r);
  }

  /// Returns the current game-mode string (e.g. "OPTION_1").
  Future<String> getGameMode() async {
    final d = await getSimMode();
    return d['mode'] as String? ?? 'OPTION_1';
  }

  /// POST /api/v1/simulation/game-mode  body: {mode: "OPTION_3"}
  Future<void> setGameMode(String mode) async {
    await http.post(_uri('/api/v1/simulation/game-mode'),
        headers: _headers, body: jsonEncode({'mode': mode}));
  }

  /// POST /api/v1/simulation/pause
  Future<void> pauseSim() async {
    await http.post(_uri('/api/v1/simulation/pause'), headers: _headers);
  }

  /// POST /api/v1/simulation/resume
  Future<void> resumeSim() async {
    await http.post(_uri('/api/v1/simulation/resume'), headers: _headers);
  }

  // ── Wave ─────────────────────────────────────────────────────────────────

  /// POST /api/v1/agents/A1_wave_planner/run — trigger new wave
  Future<void> triggerWave() async {
    await http.post(_uri('/api/v1/agents/A1_wave_planner/run'),
        headers: _headers);
  }

  // ── Game / Saboteur (WAAS v4) ─────────────────────────────────────────────

  /// GET /api/v1/game/credits/{session_id}
  Future<Map<String, dynamic>> getCredits(String sessionId) async {
    final r = await http.get(_uri('/api/v1/game/credits/$sessionId'),
        headers: _headers);
    return _check(r);
  }

  /// Returns the saboteur credit count for [sessionId].
  Future<int> getCreditCount(String sessionId) async {
    final d = await getCredits(sessionId);
    return (d['credits'] as num?)?.toInt() ?? 0;
  }

  /// POST /api/v1/game/action/{session_id}  body: {action: "BLOCK_CHARGER"}
  Future<Map<String, dynamic>> executeAction(
      String sessionId, String action) async {
    final r = await http.post(
      _uri('/api/v1/game/action/$sessionId'),
      headers: _headers,
      body: jsonEncode({'action': action}),
    );
    return _check(r);
  }

  /// Performs a saboteur action; returns a human-readable result message.
  Future<String> performSaboteurAction({
    required String sessionId,
    required String actionType,
  }) async {
    final d = await executeAction(sessionId, actionType);
    return d['message'] as String? ??
        d['result']?.toString() ??
        'Action executed';
  }

  // ── Layout proposals (D5) ─────────────────────────────────────────────────

  /// GET /api/v1/layout/proposals
  Future<List<dynamic>> getLayoutProposals() async {
    final r =
        await http.get(_uri('/api/v1/layout/proposals'), headers: _headers);
    final d = _check(r);
    return d['proposals'] as List<dynamic>? ?? [];
  }

  /// POST /api/v1/layout/proposals/{id}/approve
  Future<void> approveProposal(String id) async {
    await http.post(_uri('/api/v1/layout/proposals/$id/approve'),
        headers: _headers);
  }

  /// POST /api/v1/layout/proposals/{id}/reject
  Future<void> rejectProposal(String id) async {
    await http.post(_uri('/api/v1/layout/proposals/$id/reject'),
        headers: _headers);
  }

  // ── Chat ─────────────────────────────────────────────────────────────────

  /// POST /api/v1/sim-chat/sessions — creates a session, returns its id.
  Future<String> createChatSession(String token) async {
    final r = await http.post(
      _uri('/api/v1/sim-chat/sessions'),
      headers: _headers,
      body: jsonEncode({'token': token, 'name': 'Flutter chat'}),
    );
    final d = _check(r);
    return d['id'] as String? ?? d['session_id'] as String? ?? '';
  }

  /// POST /api/v1/sim-chat/{session_id}/messages — sends [message], returns reply text.
  Future<String> sendChatMessage({
    required String sessionId,
    required String message,
  }) async {
    final r = await http.post(
      _uri('/api/v1/sim-chat/$sessionId/messages'),
      headers: _headers,
      body: jsonEncode({'message': message}),
    );
    final d = _check(r);
    return d['reply'] as String? ??
        d['response'] as String? ??
        d['content'] as String? ??
        '…';
  }

  /// POST /api/v1/sim-chat/{session_id}/messages (full signature)
  Future<Map<String, dynamic>> sendMessage({
    required String chatSessionId,
    required String message,
    required String userId,
    required String authSessionId,
    Map<String, dynamic>? simContext,
  }) async {
    final r = await http.post(
      _uri('/api/v1/sim-chat/$chatSessionId/messages'),
      headers: _headers,
      body: jsonEncode({
        'message': message,
        'user_id': userId,
        'auth_session_id': authSessionId,
        'sim_context': simContext,
      }),
    );
    return _check(r);
  }

  /// GET /api/v1/sim-chat/{session_id}/messages
  Future<List<dynamic>> getChatHistory(String chatSessionId) async {
    final r = await http.get(
      _uri('/api/v1/sim-chat/$chatSessionId/messages'),
      headers: _headers,
    );
    final d = _check(r);
    return d['messages'] as List<dynamic>? ?? [];
  }

  // ── Self-healing ──────────────────────────────────────────────────────────

  /// GET /api/v1/self-healing/events
  Future<List<dynamic>> getSelfHealingEvents() async {
    final r =
        await http.get(_uri('/api/v1/self-healing/events'), headers: _headers);
    final d = _check(r);
    return d['events'] as List<dynamic>? ?? [];
  }

  // ── WMS Dashboard (scouting progress + inventory) ─────────────────────────

  /// GET /api/v1/robot/positions?warehouse_id=… — live positions of all robots.
  Future<Map<String, dynamic>> getRobotPositions(String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/robot/positions', {'warehouse_id': warehouseId}),
      headers: _headers,
    );
    return _check(r);
  }

  /// GET /api/v1/wms/dashboard?warehouse_id=…
  /// Returns exploration progress and WMS inventory snapshot for the dashboard.
  Future<Map<String, dynamic>> getWmsDashboard(String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/wms/dashboard', {'warehouse_id': warehouseId}),
      headers: _headers,
    );
    return _check(r);
  }

  /// GET /api/v1/wms/explored-cells?warehouse_id=…
  /// Returns all explored [row, col] pairs for fog-of-war restoration on reload.
  Future<List<List<int>>> getExploredCells(String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/wms/explored-cells', {'warehouse_id': warehouseId}),
      headers: _headers,
    );
    final data = _check(r);
    return (data['cells'] as List)
        .map((e) => (e as List).map((v) => v as int).toList())
        .toList();
  }

  // ── Warehouse presence / edit-lock ───────────────────────────────────────

  /// POST /api/v1/warehouses/{id}/heartbeat
  /// Claims the edit lock if the warehouse has no active editor.
  /// Returns {"edit_access": "EDITOR"|"VIEWER", "lock_held_by_name": "…", …}.
  Future<Map<String, dynamic>> heartbeat({
    required String warehouseId,
    required String sessionId,
    required String userId,
    String userName = '',
  }) async {
    final r = await http.post(
      _uri('/api/v1/warehouses/$warehouseId/heartbeat'),
      headers: _headers,
      body: jsonEncode({
        'session_id': sessionId,
        'user_id': userId,
        'user_name': userName,
      }),
    );
    return _check(r);
  }

  /// DELETE /api/v1/warehouses/{id}/heartbeat?session_id=…
  /// Releases presence row immediately (tab close / leave warehouse).
  Future<void> releaseHeartbeat({
    required String warehouseId,
    required String sessionId,
  }) async {
    try {
      await http.delete(
        _uri('/api/v1/warehouses/$warehouseId/heartbeat',
            {'session_id': sessionId}),
        headers: _headers,
      );
    } catch (_) {
      // Best-effort — ignore network errors on cleanup.
    }
  }

  // ── Warehouse lifecycle ───────────────────────────────────────────────────

  /// GET /api/v1/warehouses/{id} — check if the warehouse is in the DB.
  Future<Map<String, dynamic>?> getWarehouseStatus(String warehouseId) async {
    try {
      final r = await http.get(
        _uri('/api/v1/warehouses/$warehouseId'),
        headers: _headers,
      );
      if (r.statusCode == 404) return null;
      return _check(r);
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/warehouses/publish — persist config to DB and seed reality tables.
  /// Called by Flutter _publish() so the warehouse exists in the database.
  Future<Map<String, dynamic>> publishWarehouse({
    required String warehouseId,
    required String name,
    required String configJson,
    String ownerId = 'local',
  }) async {
    final r = await http.post(
      _uri('/api/v1/warehouses/publish'),
      headers: _headers,
      body: jsonEncode({
        'warehouse_id': warehouseId,
        'name': name,
        'config_json': configJson,
        'owner_id': ownerId,
      }),
    );
    return _check(r);
  }

  /// PATCH /api/v1/warehouses/{id}/draft — silently sync an in-progress draft
  /// config to the backend without triggering a full publish (no reality reseed).
  /// Called by the 15-second autosave timer in the creator screen.
  Future<void> patchWarehouseDraft({
    required String warehouseId,
    required String configJson,
    String ownerId = 'local',
  }) async {
    await http.patch(
      _uri('/api/v1/warehouses/$warehouseId/draft'),
      headers: _headers,
      body: jsonEncode({
        'config_json': configJson,
        'owner_id': ownerId,
      }),
    );
    // No error checking — this is a best-effort background save.
  }

  // ── Warehouse SKU management ──────────────────────────────────────────────

  /// GET /api/v1/warehouses/{id}/skus — list SKUs in this warehouse's snapshot.
  Future<List<Map<String, dynamic>>> getWarehouseSkus(
      String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/warehouses/$warehouseId/skus'),
      headers: _headers,
    );
    return _checkList(r).cast<Map<String, dynamic>>();
  }

  /// POST /api/v1/warehouses/{id}/skus/{sku_id} — copy a global SKU into warehouse.
  Future<Map<String, dynamic>> addSkuToWarehouse(
      String warehouseId, String skuId) async {
    final r = await http.post(
      _uri('/api/v1/warehouses/$warehouseId/skus/$skuId'),
      headers: _headers,
    );
    return _check(r);
  }

  /// DELETE /api/v1/warehouses/{id}/skus/{sku_id} — remove SKU from warehouse.
  Future<void> removeSkuFromWarehouse(String warehouseId, String skuId) async {
    await http.delete(
      _uri('/api/v1/warehouses/$warehouseId/skus/$skuId'),
      headers: _headers,
    );
  }

  /// GET /api/v1/master/skus — global SKU template (used before first publish).
  Future<List<Map<String, dynamic>>> getGlobalSkus({
    String? category,
    String? abcClass,
  }) async {
    final query = <String, String>{};
    if (category != null) query['category'] = category;
    if (abcClass != null) query['abc_class'] = abcClass;
    final r = await http.get(
      _uri('/api/v1/master/skus', query.isEmpty ? null : query),
      headers: _headers,
    );
    return _checkList(r).cast<Map<String, dynamic>>();
  }

  /// POST /api/v1/master/skus — super-admin creates a new global SKU.
  Future<Map<String, dynamic>> createGlobalSku({
    required String skuId,
    required String skuName,
    required String category,
    required double unitWeightKg,
    required double unitVolumeM3,
    required double unitCost,
    required double sellingPrice,
    int reorderPoint = 50,
    int reorderQty = 200,
    int leadTimeDays = 7,
    String abcClass = 'B',
    required String requestingEmail,
  }) async {
    final r = await http.post(
      _uri('/api/v1/master/skus'),
      headers: _headers,
      body: jsonEncode({
        'sku_id': skuId,
        'sku_name': skuName,
        'category': category,
        'unit_weight_kg': unitWeightKg,
        'unit_volume_m3': unitVolumeM3,
        'unit_cost': unitCost,
        'selling_price': sellingPrice,
        'reorder_point': reorderPoint,
        'reorder_qty': reorderQty,
        'lead_time_days': leadTimeDays,
        'abc_class': abcClass,
        'requesting_email': requestingEmail,
      }),
    );
    return _check(r);
  }

  // ── Reality / Sabotage (aisle blockers) ──────────────────────────────────

  static const _sabotageKey = 'wois-sabotage-secret-key-2026';

  Map<String, String> get _sabotageHeaders => {
        ..._headers,
        'X-Sabotage-Key': _sabotageKey,
      };

  /// POST /api/v1/reality/aisle_block
  /// Places an obstacle at ([row], [col]) in [warehouseId].
  /// [blockerType] must be `TEMPORARY` (auto-expires) or `PERMANENT`.
  Future<Map<String, dynamic>> placeObstacle({
    required String warehouseId,
    required int row,
    required int col,
    String blockerType = 'TEMPORARY',
    String? obstacleLabel,
    int? durationSeconds,
  }) async {
    final r = await http.post(
      _uri('/api/v1/reality/aisle_block'),
      headers: _sabotageHeaders,
      body: jsonEncode({
        'warehouse_id': warehouseId,
        'row': row,
        'col': col,
        'blocker_type': blockerType,
        if (obstacleLabel != null) 'obstacle_label': obstacleLabel,
        if (durationSeconds != null && blockerType == 'TEMPORARY')
          'duration_seconds': durationSeconds,
      }),
    );
    return _check(r);
  }

  /// DELETE /api/v1/reality/aisle_block/{warehouseId}/{row}/{col}
  /// Removes a previously placed obstacle.
  Future<void> removeObstacle({
    required String warehouseId,
    required int row,
    required int col,
  }) async {
    await http.delete(
      _uri('/api/v1/reality/aisle_block/$warehouseId/$row/$col'),
      headers: _sabotageHeaders,
    );
  }

  /// GET /api/v1/wms/blocked-cells?warehouse_id=…
  /// Returns all currently blocked cells for the floor overlay.
  /// Each element is `{"row": int, "col": int, "blocker_reason": str,
  ///                    "obstacle_type": str, "obstacle_label": str}`.
  Future<List<Map<String, dynamic>>> getBlockedCells(String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/wms/blocked-cells', {'warehouse_id': warehouseId}),
      headers: _headers,
    );
    final d = _check(r);
    return (d['cells'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  // ── Orders (Inbound / Outbound) ───────────────────────────────────────────

  /// POST /api/v1/yms/inbound-orders — place an inbound PO.
  ///
  /// [lines] is a list of `{sku_id: String, qty_pallets: int}`.
  /// Returns `{truck_id, po_id, eta, shipment_ids, message}`.
  Future<Map<String, dynamic>> createInboundOrder({
    required String warehouseId,
    required List<Map<String, dynamic>> lines,
    String truckType = 'M',
    String carrierName = 'AUTO',
  }) async {
    final r = await http.post(
      _uri('/api/v1/yms/inbound-orders'),
      headers: _headers,
      body: jsonEncode({
        'warehouse_id': warehouseId,
        'lines': lines,
        'truck_type': truckType,
        'carrier_name': carrierName,
      }),
    );
    return _check(r);
  }

  /// POST /api/v1/yms/trucks/{truck_id}/force-arrive
  ///
  /// Instantly advances an ENROUTE truck through ARRIVED → YARD_ASSIGNED →
  /// WAITING. Used when the 60-second background task was lost.
  /// Returns `{status, truck_id, slot_id, message}`.
  Future<Map<String, dynamic>> dispatchTruck(String truckId) async {
    final r = await http.post(
      _uri('/api/v1/yms/trucks/$truckId/force-arrive'),
      headers: _headers,
    );
    return _check(r);
  }

  /// POST /api/v1/oms/outbound/{order_id}/dispatch
  ///
  /// Manually dispatches a PACKED outbound order.
  /// Returns `{status, order_id, message}`.
  Future<Map<String, dynamic>> dispatchOutbound(String orderId) async {
    final r = await http.post(
      _uri('/api/v1/oms/outbound/$orderId/dispatch'),
      headers: _headers,
    );
    return _check(r);
  }

  /// POST /api/v1/oms/outbound — create an outbound dispatch order.
  ///
  /// [lines] is a list of `{sku_id, unit_type, qty}` where
  /// unit_type is 'PALLET' | 'CASE' | 'LOOSE'.
  /// Returns `{status, order_id, message}`.
  Future<Map<String, dynamic>> createOutboundOrder({
    required String warehouseId,
    required List<Map<String, dynamic>> lines,
    String customerId = 'WALK-IN',
    String destination = 'TBD',
    int priorityActual = 3,
    int actualSlaHours = 48,
  }) async {
    final r = await http.post(
      _uri('/api/v1/oms/outbound'),
      headers: _headers,
      body: jsonEncode({
        'warehouse_id': warehouseId,
        'lines': lines,
        'customer_id': customerId,
        'destination_actual': destination,
        'priority_actual': priorityActual,
        'actual_sla_hours': actualSlaHours,
      }),
    );
    return _check(r);
  }

  /// GET /api/v1/yms/trucks?warehouse_id=…&truck_direction=INBOUND
  /// Returns inbound trucks sorted by status.
  Future<List<Map<String, dynamic>>> getInboundTrucks(
      String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/yms/trucks', {
        'warehouse_id': warehouseId,
      }),
      headers: _headers,
    );
    return _checkList(r)
        .cast<Map<String, dynamic>>()
        .where((t) =>
            (t['truck_direction'] as String? ?? '') == 'INBOUND' &&
            (t['status_actual'] as String? ?? '') != 'DEPARTED')
        .toList();
  }

  /// GET /api/v1/yms/inbound-shipments?warehouse_id=…
  Future<List<Map<String, dynamic>>> getInboundShipments(
      String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/yms/inbound-shipments', {'warehouse_id': warehouseId}),
      headers: _headers,
    );
    return _checkList(r).cast<Map<String, dynamic>>();
  }

  /// GET /api/v1/oms/orders?warehouse_id=…
  /// Returns all outbound orders for the given warehouse.
  Future<List<Map<String, dynamic>>> getOutboundOrders(
      String warehouseId) async {
    final r = await http.get(
      _uri('/api/v1/oms/orders', {'warehouse_id': warehouseId}),
      headers: _headers,
    );
    return _checkList(r).cast<Map<String, dynamic>>();
  }

  /// GET /api/v1/orders?warehouse_id=…&order_type=…
  /// Returns canonical OrderHeader rows (each with embedded `lines` list).
  Future<List<Map<String, dynamic>>> getOrders(
      String warehouseId, String orderType) async {
    final r = await http.get(
      _uri('/api/v1/orders', {
        'warehouse_id': warehouseId,
        'order_type': orderType,
      }),
      headers: _headers,
    );
    return _checkList(r).cast<Map<String, dynamic>>();
  }

  // ── Robotic transaction protocol ──────────────────────────────────────────

  /// GET /api/v1/staging/slots/available?sku_id=…
  /// Returns the best available staging slot for the given SKU.
  /// Response: {slot_id, assigned_sku_id, is_occupied, pallet_count, match}
  Future<Map<String, dynamic>> getAvailableStagingSlot(String skuId) async {
    final r = await http.get(
      _uri('/api/v1/staging/slots/available', {'sku_id': skuId}),
      headers: _headers,
    );
    return _check(r);
  }

  /// POST /api/v1/transactions/pick — inbound robot picks one pallet from a truck.
  /// [robotId]       robot DB id (e.g. 'rb_01')
  /// [functionalType] 'inbound_pick'
  /// [sourceType]    'TRUCK'
  /// [sourceId]      truck_id
  /// [skuId]         SKU being picked
  Future<Map<String, dynamic>> pickTransaction({
    required String robotId,
    required String functionalType,
    required String sourceType,
    required String sourceId,
    required String skuId,
    int qty = 1,
  }) async {
    final r = await http.post(
      _uri('/api/v1/transactions/pick'),
      headers: _headers,
      body: jsonEncode({
        'robot_id': robotId,
        'functional_type': functionalType,
        'source_type': sourceType,
        'source_id': sourceId,
        'sku_id': skuId,
        'qty': qty,
      }),
    );
    return _check(r);
  }

  /// POST /api/v1/transactions/drop — inbound robot drops pallet at staging slot.
  /// [robotId]  robot DB id
  /// [destType] 'STAGING_SLOT'
  /// [destId]   slot_id string (e.g. 'SS-1774401')
  Future<Map<String, dynamic>> dropTransaction({
    required String robotId,
    required String destType,
    required String destId,
    int qty = 1,
  }) async {
    final r = await http.post(
      _uri('/api/v1/transactions/drop'),
      headers: _headers,
      body: jsonEncode({
        'robot_id': robotId,
        'dest_type': destType,
        'dest_id': destId,
        'qty': qty,
      }),
    );
    return _check(r);
  }

  /// GET /api/v1/transactions/holdings — all robots currently holding cargo (qty_held > 0).
  /// Used to restore [robotCargoProvider] after a page refresh or service restart.
  Future<List<Map<String, dynamic>>> getActiveHoldings() async {
    final r = await http.get(
      _uri('/api/v1/transactions/holdings'),
      headers: _headers,
    );
    return _checkList(r).cast<Map<String, dynamic>>();
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.isEmpty) return {};
      return jsonDecode(r.body) as Map<String, dynamic>;
    }
    String msg;
    try {
      msg = (jsonDecode(r.body) as Map)['detail']?.toString() ?? r.body;
    } catch (_) {
      msg = r.body;
    }
    throw ApiException(r.statusCode, msg);
  }

  List<dynamic> _checkList(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.isEmpty) return [];
      return jsonDecode(r.body) as List<dynamic>;
    }
    String msg;
    try {
      msg = (jsonDecode(r.body) as Map)['detail']?.toString() ?? r.body;
    } catch (_) {
      msg = r.body;
    }
    throw ApiException(r.statusCode, msg);
  }
}
