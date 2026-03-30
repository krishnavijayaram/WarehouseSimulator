/// application.dart — Application layer barrel export.
///
/// This layer contains Riverpod state notifiers, use-case orchestrators,
/// and the event bus that mediate between the domain (warehouse_engine)
/// and the presentation (screens / widgets) layers.
///
/// Nothing in this layer draws pixels.  Everything here depends on either
/// [core] (infrastructure adapters) or [warehouse_engine] (domain logic).
library application;

export 'providers.dart';
export 'event_bus.dart';
export 'manual_robot_controller.dart';
export 'robot_scout_simulation.dart';
