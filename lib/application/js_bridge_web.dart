// js_bridge_web.dart
//
// Web-only variant of the JS bridge. Imported conditionally from
// robot_scout_simulation.dart when `dart.library.js_interop` is available.
//
// `woisSendBeacon` is the JS function defined in web/index.html that
// wraps navigator.sendBeacon(). Using sendBeacon — instead of fetch —
// is what lets the scout discovery batch survive page navigation /
// tab close. The call is fire-and-forget; callers fall back to HTTP
// POST if this throws (e.g. JS bridge unavailable during a unit test).

import 'dart:js_interop';

@JS('woisSendBeacon')
external void _woisSendBeacon(String url, String payload);

void sendBeaconViaJs(String url, String payload) {
  _woisSendBeacon(url, payload);
}
