# Dunn Record Keeping

Logs the miles driven to appointments. Pick or type where you're going. If it
matches a saved address, the trip is logged with its driving distance. Runs
on Android and macOS (Flutter).

## Status

| Phase | What | State |
|---|---|---|
| 0 | Tooling, project, Google Cloud guide | Flutter installed; **Xcode upgrade and Android SDK setup still needed** |
| 1 | Core app offline: saved addresses, matching, start-point rule, today's trips | **Done**, demo distances |
| 2 | Google address autocomplete (Places) | **Done**. Needs an API key from the [Google Cloud setup](docs/GOOGLE_CLOUD_SETUP.md) |
| 2 | Real driving distances (Routes), cached per trip | **Done**. Untested against live Google until a key is added |
| 3 | Google sign-in + Google Sheet log | |
| 4 | Settings: account switch, API key, Navigate button | |
| 5 | History, Summary tab, release builds | |

## How trips are measured

- **Start:** the last place you logged a trip to today, otherwise your
  home/office address (Settings). Tap **Change** to override one trip.
- **Addresses are always real:** every destination, saved address, and
  home address must be picked from Google Maps autocomplete (or from your
  saved list, which also came from Google). Typed text alone is never
  accepted. Addresses saved before this change are marked "Not verified"
  until you re-pick them.
- **Matching:** a Google result counts as a saved address when it has the
  same Google place ID, the same address, or is within 75 m of one.
- **Miles:** Google's driving distance (no live traffic, so the same trip
  always measures the same). Each from→to pair is measured once and then
  remembered on the device. If Google can't be reached, the trip isn't
  logged and you see why. Without an API key the app logs a rough estimate
  instead and tags those trips "est."
- **API key:** entered in Settings and kept in the device's secure storage
  (Android Keystore / macOS Keychain), never in the code.

## Run it

```bash
flutter test
```

```bash
flutter run -d macos
```

```bash
flutter run -d android
```

The web build (`flutter build web`) is only for quick previews. Android
and macOS are the real targets.

## Code map

- `lib/models/`: Place, SavedAddress, Trip, AppSettings
- `lib/services/`: address matching, start-point rule, distance (demo),
  on-device storage
- `lib/state/providers.dart`: app state (Riverpod)
- `lib/features/`: Log Trip, Clients, Settings screens

Flutter 3.50 note: Material widgets come from
`package:material_ui/material_ui.dart`. The old `package:flutter/material.dart`
import is deprecated.
