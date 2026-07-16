/// outbound_stage.dart — what is staged for shipping, and where.
///
/// Maps a stage cell (a pack-station cell in this increment) to the SKU of the
/// pallet sitting on it. A PickRobotBrain places here; an OutboundRobotBrain
/// (P4 next) takes from here to load a truck.
///
/// NOTE (SC-3 refinement): the design pins a distinct `CellType.outboundStage`
/// separate from packStation. This increment reuses packStation cells to avoid
/// the enum/exhaustive-switch churn; the distinct cell type lands with pack/load.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class OutboundStageNotifier extends StateNotifier<Map<String, String>> {
  OutboundStageNotifier() : super(const {});

  String _key(int row, int col) => '${row}_$col';

  bool isFree(int row, int col) => !state.containsKey(_key(row, col));

  void place(int row, int col, String skuId) {
    state = {...state, _key(row, col): skuId};
  }

  /// Remove and return the SKU staged at a cell (null if empty).
  String? take(int row, int col) {
    final k = _key(row, col);
    final v = state[k];
    if (v == null) return null;
    state = {...state}..remove(k);
    return v;
  }

  void clear() => state = const {};
}

final outboundStageProvider =
    StateNotifierProvider<OutboundStageNotifier, Map<String, String>>(
  (_) => OutboundStageNotifier(),
);
