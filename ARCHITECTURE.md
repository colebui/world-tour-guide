# World Guide — Architecture & System Map

> **This file is the canonical context document.** It explains what the app is, the full
> stack, and **how every component connects**. Paste it into a new chat to give Claude full
> project context cheaply. Companion files: `prompts/place_content_prompt.md` (the exact LLM
> request/response contract) and the build plan (phased implementation steps).

## What it is

An iOS tour-guide app: a Google-Maps-style **MapKit** map shows what's around you and gives
fun, accurate descriptions, history, stories, photos, and audio narration of places — either
on **tap (manual mode)** or **automatically as you walk (auto mode, the default)**.

## Tech stack (decided)

| Concern | Choice | Notes |
|---|---|---|
| App framework | **SwiftUI** (iOS) | Native MapKit + bottom-sheet support |
| Map display | **Apple MapKit** | Free tiles, no per-render billing |
| POI data | **Google Places API** | Nearby search + stable `place_id` (the cache key) |
| Location / triggers | **Core Location** | Region monitoring + significant-location-change |
| Backend / DB / auth / storage | **Firebase** | Firestore + Cloud Functions + Storage + Auth |
| Content generation | **OpenAI API** | Structured Outputs JSON; contract in prompt file |
| Fact grounding | **Wikipedia / Wikidata** | Real facts → low hallucination + citations |
| Photos | **Wikimedia Commons / Google Places Photos** | Real licensed images — never AI-generated |
| Text-to-speech | **AVSpeechSynthesizer** (v1) → OpenAI TTS / ElevenLabs (upgrade) | Hands-free audio guide |

## System connection map

```
┌─────────────────────────── iOS App (SwiftUI) ───────────────────────────┐
│                                                                          │
│  LocationManager ──► MapViewModel ──► MapScreen (MapKit map + pins)       │
│   (Core Location)        │                  │                            │
│                          │                  ▼                            │
│                          │           BottomSheetView ──► PlaceDetailView │
│                          │                  │            (renders sections)│
│                          ▼                  ▼                            │
│                   PlacesService      ContentService     SpeechService    │
│                   (Google Places)    (calls backend)    (TTS)            │
│                          │                  │                            │
└──────────────────────────┼──────────────────┼───────────────────────────┘
                           │ (bundle-restricted│ HTTPS (callable function)
                           │  Places key)      │
                           ▼                  ▼
                 ┌─────────────────┐   ┌──────────────────────────────────┐
                 │ Google Places   │   │  Firebase Cloud Function          │
                 │ Nearby Search   │   │  getPlaceContent(place_id, ...)   │
                 └─────────────────┘   │                                  │
                                       │  1. Firestore lookup by place_id │◄─┐
                                       │  2. miss → Wikipedia/Wikidata     │  │ cache
                                       │  3. → OpenAI (prompt file)        │  │
                                       │  4. → fetch photos                │  │
                                       │  5. → write Firestore + Storage ──┼──┘
                                       └──────────┬───────────────────────┘
                                                  │  (OpenAI key = secret, backend only)
                          ┌───────────────────────┼───────────────┐
                          ▼                       ▼               ▼
                    OpenAI API            Wikipedia/Wikidata   Photo sources
                                                              (Commons / Places Photos)
```

**The one rule:** the **OpenAI key lives only in the backend** (Cloud Functions secret). The
**Google Places key** may live on-device **only if** restricted to this app's bundle ID +
Places API. The app never calls OpenAI directly.

## Component responsibilities

| Component | Responsibility |
|---|---|
| `LocationManager` | Wraps `CLLocationManager`; auth, current location, (Phase 4) geofences |
| `PlacesService` | Google Places **Nearby Search** → `[Place]` with `place_id`, name, coords, types |
| `ContentService` | Calls `getPlaceContent` Cloud Function; returns `PlaceContent` |
| `SpeechService` | Speaks `tour_guide_intro`; mute toggle; background audio |
| `MapViewModel` | Holds nearby places, selected place, its content, current mode |
| `MapScreen` / `BottomSheetView` / `PlaceDetailView` / `ExploreView` | UI |
| `getPlaceContent` (backend) | Cache-first: Firestore → Wikipedia → OpenAI → photos → store → return |

## Integration contracts

**App → backend** (`getPlaceContent`, Firebase HTTPS function via `URLSession`)
- _Phase 1 note:_ implemented as a plain HTTPS `onRequest` endpoint so the iOS app needs
  **no Firebase SDK** yet (just `URLSession`). Switches to a callable function with App
  Check in Phase 5 when Auth lands.
- Request: `{ place_id, name, types[], lat, lng, locality }`
- Response: a `PlaceContent` JSON object — **schema defined in `prompts/place_content_prompt.md`**
  (always-present: `summary`, `tour_guide_intro`, `notification_blurb`, `notify_worthy`, `tone`,
  `richness_score`, `tags`; optional rich sections; `photos[]` with attribution).

**App → Google Places** (on-device, bundle-restricted key)
- Nearby Search around the user → POIs with `place_id` (the cache key) for pins.

**Backend → OpenAI / Wikipedia / Photos** — see prompt file for the exact OpenAI system+user
messages and JSON schema. Wikipedia extract is injected as grounding; `photo_queries` from the
model drive photo retrieval.

## Sequence flows

**Cache hit (most requests):** App taps place → `ContentService` → `getPlaceContent` →
Firestore has `places/{place_id}` → returns stored content (fast, $0).

**Cache miss (first visitor):** App → `getPlaceContent` → Firestore empty → fetch
Wikipedia/Wikidata → call OpenAI with prompt → fetch photos for `photo_queries` → write
`places/{place_id}` (+ photos to Storage) → return. Everyone after hits the cache.

**Auto-mode trigger (Phase 4):** `LocationManager` enters a geofence around a `notify_worthy`
place → if foreground, auto-open sheet + speak intro (unless muted); if background, push
notification using `notification_blurb`. Cooldown prevents re-triggering the same place.

## Data model (Firestore)

```
places/{place_id}          # the cache; key = Google place_id
  name, tone, summary, tour_guide_intro, notification_blurb, notify_worthy,
  richness_score, tags, history?, fun_facts?, stories?, details?, significance?,
  visiting_tips?, nearby_theme?, confidence, uncertain_claims[],
  photos: [{ url, source, attribution, license }],
  meta: { prompt_version, model, generated_at, sources[] }

users/{uid}                # mode: auto|manual, muted, notifications_enabled, history[], language
popular_places/{place_id}  # view_count, last_viewed → drives cache warming
```

`meta.prompt_version` + `meta.model` let content be regenerated as the prompt improves.

## Modes

- **Auto (default):** on open, fetch nearest notable place → show + speak (unless muted);
  while moving, surface content automatically; background push for notify-worthy places.
- **Manual:** pins show, but content is fetched **only on tap**. Cheapest; user in control.
- **Gating:** auto-triggers/notifications fire only when `notify_worthy == true`
  (≈ `richness_score >= 55`, excluding routine POIs) — keeps notifications rare and delightful.

## Location strategy (battery + cost)

- Significant-location-change + region monitoring, **not** continuous GPS.
- iOS allows only **20 active geofences** → maintain a dynamic ring around nearest notable
  places, re-registering as the user moves.
- **Cache-warming**: pre-fetch nearby `place_id`s so auto mode feels instant (hides the
  first-visitor cold-cache delay).

## Security / keys

| Key | Location | Restriction |
|---|---|---|
| OpenAI | Backend only (Functions secret) | Never in the app binary |
| Google Places | On-device | Bundle ID + Places API only |
| Firebase config | `GoogleService-Info.plist` in app | Public-safe; protect data via Firestore rules |

## Repo file map

```
world-guide/
  ARCHITECTURE.md                      # this file — canonical context
  prompts/place_content_prompt.md      # LLM request/response contract + JSON schema
  ios-src/                             # canonical Swift sources (synced into the Xcode app
                                       #   via scripts/install-ios-files.sh — edit these)
    WorldGuideApp.swift, Secrets.swift
    Models/PlaceContent.swift, Place.swift, TodoItem.swift
    Services/LocationManager.swift, PlacesService.swift, ContentService.swift,
             SpeechService.swift, TodoStore.swift
    ViewModels/MapViewModel.swift
    Views/MapScreen.swift, BottomSheetView.swift, PlaceDetailView.swift, TodoView.swift
  WorldGuide/                          # generated Xcode project (build target)
  functions/                           # Firebase Cloud Functions (TypeScript)
    src/index.ts                       # getPlaceContent (+ later TTS, photos)
  firestore.rules
```

## Build phases (summary; full steps in the plan file)

0. **Setup** — Xcode + Firebase CLI; create SwiftUI project; wire Google Cloud + Firebase (Blaze); store OpenAI secret. ✅ done
1. **Walking skeleton** — map + tap → `getPlaceContent` (cache + OpenAI) → bottom sheet. Simulator. ✅ done
2. **Rich content** — Wikipedia grounding + photos (Wikimedia Commons) + all sections + Explore/Recent tabs. ✅ done
3. **TTS** — narrate `tour_guide_intro` (AVSpeechSynthesizer) + mute + background audio. ✅ done
4. **Auto mode** — geofencing + notifications (needs physical device + paid Apple account).
5. **Polish** — Auth (Sign in with Apple), analytics, cache warming, cost controls.
```
