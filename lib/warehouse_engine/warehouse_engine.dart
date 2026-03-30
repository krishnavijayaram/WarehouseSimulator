/// warehouse_engine — Flutter rendering support layer
///
/// Contains ONLY what the Flutter "body" needs to render the warehouse:
///   • Constants  — grid dimensions, packaging specs, sim timing
///   • Models     — data shapes for UI rendering (Robot, Bin, Layout, PTL, Clock)
///   • Pathfinding — local A* for smooth path animation on the canvas
///   • TemplateFactory — warehouse layout generator for the creator screen
///
/// INTENTIONALLY EXCLUDED (these are WIOS "brain" responsibilities):
///   • Robot dispatch / state machine    → WIOS simulation/agents/
///   • Greedy / wave assignment          → WIOS simulation/agents/a5_wave_planner.py
///   • Order tracking                    → WIOS warehouse_core/routers/oms_router.py
///   • Agent interface / AI routing      → WIOS simulation/agents/base_agent.py
///
/// Import this single file to access all rendering support:
///
/// ```dart
/// import 'package:flutter_wois/warehouse_engine/warehouse_engine.dart';
/// ```
library warehouse_engine;

// ── Constants ─────────────────────────────────────────────────────────────────
export 'constants/grid_constants.dart';
export 'constants/packaging_constants.dart';
export 'constants/sim_constants.dart';

// ── Models (UI data shapes — populated from WIOS WebSocket / REST) ────────────
export 'models/robot.dart';
export 'models/warehouse_layout.dart';
export 'models/warehouse_state.dart';
export 'models/ptl_light.dart';
export 'models/sim_clock.dart';

// ── Services (rendering support only — no business decisions) ─────────────────
export 'services/pathfinding.dart'; // Local path animation preview
export 'services/warehouse_template_factory.dart'; // Warehouse creator screen
