# World Guide — Architecture & System Map

> **This file is the canonical context document.** It explains what the app is, the full
> stack, and **how every component connects**. Paste it into a new chat to give Claude full
> project context cheaply. Companion file: `prompts/place_content_prompt.md` (the LLM
> request/response contract). Status/todo list is at the bottom.

## What it is

An iOS tour-guide app: a Google-Maps-style **MapKit** map shows tour-worthy places around you
and, when you tap one, streams a fun, accurate guide — description, history, stories, fun facts,
photos, and **natural audio narration**. You can get **directions** (walk/drive/transit) and save
places into **to-do lists**. Today it's **tap/search driven**; proactive "auto mode" (narrate as
you walk) is planned (needs a physical device + paid Apple account).

## Tech stack

| Concern | Choice | Notes |
|---|---|---|
| App framework | **SwiftUI** (iOS), bundle `com.cole.WorldGuide` | Synced from `ios-src/` via `scripts/install-ios-files.sh` |
| Map display | **Apple MapKit** | Free tiles; in-app route lines |
| POI data | **Google Places API (New)** | `searchNearby` (attraction-biased) + `searchText` |
| Autocomplete | **MKLocalSearchCompleter** (Apple) | Free, nearby-biased type-ahead |
| Directions | **Apple `MKDirections`** (walk/drive) + **Google Routes API** (transit) | In-app polyline + Apple Maps handoff |
| Location | **Core Location** | When-in-use; recenter button |
| Backend / DB / storage | **Firebase** (`your-firebase-project-id`, Blaze) | Firestore + Cloud Functions + Storage |
| Content generation | **OpenAI** (gpt-4o, JSON mode, **streamed**) | Grounded in Wikipedia |
| Fact grounding | **Wikipedia / Wikidata** | Geosearch + name-match → low hallucination |
| Photos | **Wikimedia Commons** | Real licensed images (URLs hot-linked) |
| Text-to-speech | **OpenAI TTS** (standard) / **ElevenLabs** (premium) | Tiered by review count; cached MP3 in Storage |
| To-do storage | **On-device** (UserDefaults) | Cloud sync planned with Auth |

## System connection map

```
┌──────────────────────────── iOS App (SwiftUI, ios-src/) ─────────────────────────────┐
│                                                                                       │
│  LocationManager ─┐                                  SearchCompleter (MKLocalSearch)   │
│  (Core Location)  ▼                                          │ suggestions             │
│            ┌────────────┐   pins / search / route / todo     ▼                         │
│            │ MapScreen  │◄────────────► MapViewModel ◄──── PlacesService (Google)       │
│            │ (MapKit)   │                   │  ▲             searchNearby / searchText  │
│            └────────────┘                   │  │                                        │
│              category & saved-bookmark pins │  │ PlaceContent / PartialPlaceContent     │
│                    │ tap                     │  │                                        │
│                    ▼                         │  ├── ContentService ──► (SSE stream) ──┐  │
│            BottomSheetView (peek/40%/full)   │  ├── DirectionsService ─► Google Routes│  │
│             ├─ tabs: Guide/Recent/Explore/Saved │  │   (transit polyline)             │  │
│             ├─ PlaceDetailView (skeletons →  │  └── SpeechService (AVAudioPlayer ─────┼──┼─► cached MP3
│             │   sections, photos, Listen,    │        download+play, AVSpeech fallback)│  │   (Storage)
│             │   Directions menu+ETAs, Save)  │                                        │  │
│             └─ TodoView / TodoListDetailView ─► TodoStore (UserDefaults, named lists)  │  │
└───────────────────────────────────────────────────────────────────────────────────────┼──┘
                                                  │ HTTPS POST (URLSession)               │ GET mp3
                                                  ▼                                       │
        ┌──────────────── Firebase Cloud Functions (functions/, TypeScript) ─────────────┴───┐
        │  getPlaceContent (JSON)  ·  streamPlaceContent (SSE: partial→partial→complete)      │
        │                                                                                     │
        │   1. Firestore lookup places/{place_id} ──► cache hit returns stored doc ◄────────┐ │
        │   2. miss: fetchReviewCount (Google Routes/Places, server key) → tier             │ │
        │   3.       fetchWikipediaGrounding → OpenAI (stream, gpt-4o)                       │ │ cache
        │   4.       buildRecord: fetchPhotos (Commons) ∥ generateAndStoreAudio (TTS→Storage)│ │
        │   5.       write places/{place_id} (content+photos+audio_url+tier) ───────────────┘ │
        └───────┬───────────────┬───────────────┬────────────────┬───────────────┬───────────┘
                ▼               ▼               ▼                ▼               ▼
           OpenAI API     ElevenLabs      Wikipedia/Wikidata  Wikimedia    Firebase Storage
        (text + std TTS) (premium TTS)     (grounding)        (photos)     (audio/{id}.mp3)
```

**Key rule:** the **OpenAI, ElevenLabs, and server-Google keys live only in the backend**
(Functions secrets). The **on-device Google key** is bundle-restricted (Places + Routes). The app
never calls OpenAI/ElevenLabs directly.

## Component responsibilities (current files)

| Component | Responsibility |
|---|---|
| `LocationManager` | `CLLocationManager` wrapper; when-in-use auth, current location |
| `PlacesService` | Google `searchNearby` (attraction `includedTypes`) + `searchText` → `[Place]` |
| `SearchCompleter` | `MKLocalSearchCompleter` type-ahead suggestions, region-biased |
| `ContentService` | Calls `streamPlaceContent` (SSE) → `ContentEvent` stream; `getPlaceContent` fallback |
| `DirectionsService` | Google Routes API transit → decoded `MKPolyline` + summary |
| `SpeechService` | Downloads + plays cached MP3 (`AVAudioPlayer`); `AVSpeechSynthesizer` fallback; mute |
| `TodoStore` | Named to-do lists in UserDefaults; reorder, check, save-to-list |
| `MapViewModel` | Nearby/selected/streaming content, route state + ETAs, search, recent |
| `MapScreen` | MapKit map, category/saved pins, route polyline, search bar, locate, peek-detent sheet |
| `BottomSheetView` | Peek bar + tabbed sheet (Guide/Recent/Explore/Saved), mute, auto-narrate |
| `PlaceDetailView` | Renders sections w/ skeletons; actions (Listen, Directions menu+ETAs, Navigate, Save) |
| `TodoView` / `TodoListDetailView` | Lists screen + per-list checkboxes/reorder/add-highlighted |
| `Place` / `PlaceCategory` | POI model + type→pin icon/tint mapping |
| `PlaceContent` / `PartialPlaceContent` | Strict + all-optional (streaming) content models |
| `Shimmer` / `SkeletonBar` | Loading placeholders |
| backend `index.ts` | The two endpoints + `decideTier`/`buildRecord`/`createCompletion` |
| backend `wikipedia.ts` / `photos.ts` / `tts.ts` / `placeDetails.ts` / `prompt.ts` | Grounding / photos / TTS+Storage / review-count / prompt |

## Integration contracts

**App → backend** (`URLSession`, no Firebase SDK)
- `streamPlaceContent` (primary, **SSE**): POST `{ place_id, name, types[], lat, lng, locality }`
  → events `data: {type:"partial", content}` … then `data: {type:"complete", source, content}`.
- `getPlaceContent` (fallback, JSON): same body → `{ source, content }`.
- `content` schema in `prompts/place_content_prompt.md`, plus `photos[]`, `audio_url`, `tier`,
  `review_count`, `meta{}`.

**App → Google (on-device key)**: `searchNearby` (attraction `includedTypes`) for pins;
`searchText` for the search bar; **Routes API** for transit polylines. Apple `MKDirections` does
walk/drive locally (free).

**Backend → providers**: Place Details `userRatingCount` (server Google key) → tier; Wikipedia
extract → OpenAI (streamed); `photo_queries` → Commons; narration script → OpenAI/ElevenLabs →
Firebase Storage (`audio/{place_id}.mp3`, public).

## Key flows

- **Cache hit:** tap → `streamPlaceContent` → Firestore has doc → one `complete` event (~0.13s).
- **Cache miss:** tier (review count) → Wikipedia → **OpenAI streamed** (summary ~2–3s, sections
  fill in, skeletons for the rest) → photos + audio in parallel → write cache → `complete`.
- **Tiered TTS:** `userRatingCount > 10000` ⇒ premium (ElevenLabs) else standard (OpenAI); whole
  guide is narrated, chunked under the TTS char limit, MP3 cached in Storage.
- **Directions:** open chooser → compute Walk/Drive (Apple) + Transit (Google) ETAs once, cached →
  pick a mode → draw polyline + minimize sheet; **Navigate** hands off to Apple Maps.

## Data model

```
Firestore  places/{place_id}     # the cache; key = Google place_id
  name, tone, summary, tour_guide_intro, notification_blurb, notify_worthy, richness_score,
  tags, history?, fun_facts?, stories?, details?, significance?, visiting_tips?, confidence,
  photo_queries[], photos[{url,source,attribution,license}],
  audio_url, tier, review_count,
  meta{ prompt_version, model, generated_at, sources[] }

On-device (UserDefaults)  todo.lists.v1   # [TodoList{ id, name, lastModified, items[TodoItem] }]
```
`meta.prompt_version`/`model` allow selective regeneration. (Planned Firestore: `users/{uid}`,
`popular_places/{place_id}` for Auth + cache-warming.)

## Security / keys

| Key | Location | Restriction |
|---|---|---|
| OpenAI, ElevenLabs | Backend only (Functions secrets) | Never in the app binary |
| Google (server) | Backend secret `GOOGLE_API_KEY` | Places/Routes; for review-count lookup |
| Google (on-device) | `Secrets.swift` (gitignored) | Bundle ID + Places(New)/Routes; sends `X-Ios-Bundle-Identifier` |

Firestore rules deny all direct client access (app only talks to Functions, which use Admin SDK).

## Repo file map

```
world-guide/
  ARCHITECTURE.md                      # this file — canonical context
  SETUP.md                             # account/Xcode setup steps
  prompts/place_content_prompt.md      # LLM request/response contract + JSON schema
  ios-src/                             # canonical Swift sources (edit here, then run installer)
    WorldGuideApp.swift, Secrets.swift (gitignored), Secrets.example.swift
    Models/      Place.swift, PlaceContent.swift, TodoItem.swift, TodoList.swift, TransportMode.swift
    Services/    LocationManager, PlacesService, ContentService, DirectionsService,
                 SearchCompleter, SpeechService, TodoStore .swift
    ViewModels/  MapViewModel.swift
    Views/       MapScreen, BottomSheetView, PlaceDetailView, TodoView, Shimmer .swift
  scripts/install-ios-files.sh         # copies ios-src/ → Xcode target (synchronized folders)
  WorldGuide/                          # generated Xcode project (build target) + Info.plist
  functions/                           # Firebase Cloud Functions (TypeScript)
    src/ index.ts, prompt.ts, wikipedia.ts, photos.ts, tts.ts, placeDetails.ts
  firebase.json, .firebaserc, firestore.rules
```

---

# Status / Todo

### ✅ Built & deployed (verified)
- [x] **Backend**: cache-first `getPlaceContent` + **streaming** `streamPlaceContent` (SSE)
- [x] **MapKit map** + Google Places pins, **biased to attractions** (`includedTypes`)
- [x] **Category pin icons** (monument/museum/religious/park/nature/food/attraction) + **saved bookmark pins**
- [x] **Search bar**: Google `searchText` + **Apple autocomplete**, **"Search this area"**, **locate button**
- [x] **Bottom sheet**: minimized **peek bar** (3 detents) + tabs **Guide / Recent / Explore / Saved**
- [x] **Streaming guide** with **shimmer skeleton** placeholders (text fills in as generated)
- [x] **Wikipedia grounding** + **Wikimedia photos** (carousel w/ attribution)
- [x] **Tiered TTS**: review-count → premium **ElevenLabs** / standard **OpenAI**, **whole-guide** narration, cached MP3 in Storage
- [x] **Audio playback** via `AVAudioPlayer` (download+cache), on-device-voice fallback, **mute / unmute-plays**
- [x] **Directions**: Walk/Drive (Apple) + **Transit (Google Routes)**, **per-mode ETAs**, in-app route line, **Navigate** handoff, minimize-on-select
- [x] **To-do lists** (on-device): named, reorderable lists + items, checkboxes, save-to-list prompt, add-highlighted

### 🔜 Planned / not yet built
- [ ] **Auto mode** — geofencing + push notifications (needs physical iPhone + paid Apple Developer acct)
- [ ] **Premium TEXT model** — currently `PREMIUM_MODEL = gpt-4o` (premium upgrades voice only); pick a bigger model
- [ ] **Auth** (Sign in with Apple) + **cloud-synced to-do** / user settings (`users/{uid}`)
- [ ] **Analytics + cache warming** (`popular_places`, pre-generate hot spots)
- [ ] **Cost guardrails** — budget alerts, generation rate-limit; watch **ElevenLabs free tier (~10k chars/mo)**
- [ ] **Offline / image re-hosting** — optionally store photo bytes in Storage (currently hot-link Commons)

### ⚠️ Ops
- [ ] **Commit & push the backlog** — only the initial commit is on `world-tour-guide`; ~40 files of work are local-only
