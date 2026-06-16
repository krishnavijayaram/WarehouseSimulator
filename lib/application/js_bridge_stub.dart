// js_bridge_stub.dart
//
// Non-web stub. The Android / iOS / desktop builds get this version because
// the conditional import in robot_scout_simulation.dart falls back to this
// file when `dart.library.js` is not available.
//
// On non-web platforms the sendBeacon path is moot — there is no browser
// navigation to survive — so callers fall through to the HTTP POST after
// this returns. Keep the function silent: no print, no log, no throw.

void sendBeaconViaJs(String url, String payload) {
  // intentional no-op on non-web platforms
}
