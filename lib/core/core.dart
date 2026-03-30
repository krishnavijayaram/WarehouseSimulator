/// core.dart — Infrastructure layer barrel export.
///
/// This layer handles all I/O boundaries:
///   • HTTP REST calls to the WIOS gateway [ApiClient]
///   • WebSocket frame stream from the simulation engine [SimFrameNotifier]
///   • Authentication state + JWT management [AuthProvider]
///
/// Nothing in this layer contains business rules.
library core;

export 'api_client.dart';
export 'sim_ws.dart';
export 'auth/auth_provider.dart';
