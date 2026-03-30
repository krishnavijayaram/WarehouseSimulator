# flutter_wois — WIOS Flutter Client

Mobile + web frontend for the **Warehouse AI Operations Simulator (WOIS)**.  
Mirrors `warehouse_sim.html` on Android/iOS/web with full WAAS v4 support.

---

## Prerequisites

| Tool | Version |
|------|---------|
| Flutter SDK | ≥ 3.22 |
| Dart SDK | ≥ 3.4 (bundled with Flutter) |
| Android Studio | Hedgehog or later |
| Python | 3.11+ (for backend) |

Install Flutter: https://docs.flutter.dev/get-started/install/windows

---

## Quick Start

### 1. Start the WIOS backend

```powershell
cd WIOS
.\scripts\start_all.ps1
```

Services started:
| Service | Port |
|---------|------|
| Gateway | 8000 |
| Sim engine | 8002 |
| Warehouse core | 8005 |

### 2. Install Flutter dependencies

```powershell
cd flutter_wois
flutter pub get
```

### 3. Run

#### Android emulator
```powershell
flutter run -d <emulator-id>   # list with: flutter emulators
```

The app auto-detects the Android emulator and uses `10.0.2.2` to reach `localhost`.

#### Web (Chrome)
```powershell
flutter run -d chrome
```

#### Physical Android device
```powershell
# Set the correct gateway URL at build time:
flutter run --dart-define=GATEWAY_URL=http://<your-pc-ip>:8000
```

---

## Configuration

All URLs are resolved in [lib/env.dart](lib/env.dart):

| Variable | Default | Description |
|----------|---------|-------------|
| `GATEWAY_URL` | auto-detected | Override gateway base URL |
| `SIM_WS_URL` | auto-detected | Override WebSocket URL |
| `ENV` | `dev` | Set to `prod` to switch prod URLs |

Pass with `--dart-define`:
```powershell
flutter run --dart-define=GATEWAY_URL=https://my.prod.host --dart-define=ENV=prod
```

---

## OAuth Deep-Link (Android)

The `wois://auth-callback` scheme is registered in  
`android/app/src/main/AndroidManifest.xml`.

After OAuth login the gateway redirects to:
```
wois://auth-callback?wois_token=<JWT>&wois_user=<base64-json>
```

`uni_links_plus` intercepts this and calls `AuthNotifier.handleOAuthCallback()`.

For local testing without OAuth credentials, use **Dev Mode** on the login screen.

---

## Project Structure

```
flutter_wois/
├── lib/
│   ├── main.dart                    # App entry, GoRouter, deep-link listener
│   ├── env.dart                     # URL config (emulator / web / prod)
│   ├── models/
│   │   ├── sim_frame.dart           # Robot, KpiSnapshot, SimFrame …
│   │   └── user.dart                # WoisUser, WoisSession, role levels
│   ├── core/
│   │   ├── api_client.dart          # HTTP client for all WIOS endpoints
│   │   ├── sim_ws.dart              # WebSocket Riverpod provider (20 Hz)
│   │   └── auth/
│   │       └── auth_provider.dart   # Auth state machine (OAuth + devlogin)
│   ├── screens/
│   │   ├── login_screen.dart        # OAuth buttons + dev mode
│   │   ├── dashboard_screen.dart    # KPIs, fleet list, sim controls
│   │   ├── floor_screen.dart        # CustomPainter grid with robot dots
│   │   ├── game_screen.dart         # WAAS v4 game modes + saboteur panel
│   │   └── chat_screen.dart         # AI conversational interface
│   └── widgets/
│       ├── kpi_card.dart            # Dark metric tile
│       ├── robot_card.dart          # Robot state card
│       ├── credit_bar.dart          # Saboteur credit progress bar
│       └── connection_banner.dart   # WebSocket status strip
├── android/
│   └── app/src/main/
│       └── AndroidManifest.xml      # wois:// deep-link intent filter
└── pubspec.yaml
```

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_riverpod` | State management |
| `go_router` | Declarative navigation |
| `web_socket_channel` | 20 Hz sim WebSocket |
| `http` | REST API calls |
| `url_launcher` | Open OAuth consent page |
| `uni_links_plus` | Receive `wois://` deep-link |
| `shared_preferences` | Persist auth token |
| `google_fonts` | ShareTechMono font |
| `fl_chart` | Optional charts |

---

## Role-Based Access

| Role | Level | Game tab | Saboteur | Layout approve |
|------|-------|----------|----------|----------------|
| Viewer | 1 | ✗ | ✗ | ✗ |
| Operator | 2 | ✗ | ✗ | ✗ |
| Supervisor | 3 | ✗ | ✗ | ✗ |
| Admin | 4 | ✓ | ✗ | ✓ |
| Saboteur | 5 | ✓ | ✓ | ✓ |
| AIObserver | 6 | ✓ | ✗ | ✓ |

---

## Notes

- Flutter SDK is **not** required to read or edit the Dart source. Install it only to build/run.
- After `flutter create .` (if regenerating), re-apply the `wois://` intent filter in the manifest.
- The sim WebSocket at `:8002` is direct (not proxied through the gateway) for minimal latency.
