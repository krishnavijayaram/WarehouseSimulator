/// env.dart — Environment / endpoint configuration for WOIS Flutter client.
///
/// Dev:  flutter run -d chrome --dart-define=ENV=dev
/// Prod: flutter build apk --dart-define=ENV=prod --dart-define=GATEWAY_URL=https://your.domain
///
/// Android emulator maps 10.0.2.2 → host machine localhost.
/// Physical device: set GATEWAY_URL to your local IP (e.g. http://192.168.1.x:8000).
library;

import 'package:flutter/foundation.dart' show kIsWeb;

const _env = String.fromEnvironment('ENV', defaultValue: 'dev');
const _gatewayUrl = String.fromEnvironment('GATEWAY_URL', defaultValue: '');
const _simWsUrl = String.fromEnvironment('SIM_WS_URL', defaultValue: '');
const _gatewayApiKey =
    String.fromEnvironment('GATEWAY_API_KEY', defaultValue: '');

/// Base URL of the WIOS API gateway.
///   dev:  http://10.0.2.2:8004  (emulator) / http://localhost:8004 (web/desktop)
///   prod: set via --dart-define=GATEWAY_URL=https://...
const _prodGatewayUrl =
    'https://wios-gateway.victoriousisland-b9d5fbf6.centralindia.azurecontainerapps.io';
// WebSocket proxied through the gateway — wios-sim is internal-only.
const _prodSimWsUrl =
    'wss://wios-gateway.victoriousisland-b9d5fbf6.centralindia.azurecontainerapps.io/ws/sim';

String get gatewayBaseUrl {
  if (_gatewayUrl.isNotEmpty) return _gatewayUrl;
  if (_env == 'prod') return _prodGatewayUrl;
  return _isWeb ? 'http://localhost:8004' : 'http://10.0.2.2:8004';
}

/// WebSocket URL for the 20 Hz sim frame stream (simulation engine :8002).
String get simWsUrl {
  if (_simWsUrl.isNotEmpty) return _simWsUrl;
  if (_env == 'prod') return _prodSimWsUrl;
  return _isWeb ? 'ws://localhost:8002/ws/sim' : 'ws://10.0.2.2:8002/ws/sim';
}

/// Custom deep-link scheme used as OAuth callback redirect.
/// Register in AndroidManifest.xml / Info.plist (see README).
const oauthCallbackScheme = 'wois';
const oauthCallbackHost = 'auth-callback';

bool get isDev => _env == 'dev';
bool get isProd => _env == 'prod';

bool get _isWeb => kIsWeb;

/// API key for the X-API-Key header sent to the gateway.
///   dev:  hardcoded local dev key
///   prod: set via --dart-define=GATEWAY_API_KEY=...
String get gatewayApiKey {
  if (_gatewayApiKey.isNotEmpty) return _gatewayApiKey;
  return 'wois-gateway-internal-key-2026'; // local dev default
}
