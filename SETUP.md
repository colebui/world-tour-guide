# World Guide — Setup (Phase 1)

Everything in `functions/` and `ios-src/` is already written. This guide covers the
account + Xcode steps only you can do. Steps marked **[you]** need your hands; the rest
Claude can run for you.

When done, you'll have a map that shows nearby places, and tapping one shows an
AI-generated guide (cached after the first view).

---

## 1. Google Places API key  **[you]**
1. Go to https://console.cloud.google.com → create a project (e.g. "world-guide").
2. Enable **Places API (New)**: APIs & Services → Library → search "Places API (New)" → Enable.
3. Make sure the project has a **billing account** attached.
4. APIs & Services → Credentials → Create credentials → **API key**.
5. Restrict the key: Application restrictions → **iOS apps** → add your bundle ID
   (e.g. `com.cole.worldguide`); API restrictions → restrict to **Places API (New)**.
6. Copy the key — you'll paste it into `Secrets.swift` in step 5.

> Tip: pick your bundle ID now (e.g. `com.cole.worldguide`) and reuse it everywhere.

## 2. Firebase project + backend  **[you, then Claude]**
1. https://console.firebase.google.com → **Add project**. You can reuse the Google Cloud
   project from step 1 (recommended) so billing is shared.
2. Upgrade to the **Blaze** plan (Settings → Usage and billing). Required for Cloud
   Functions; the free tier still covers light dev for ~$0.
3. Copy your **Project ID** (Project settings → General).
4. Create your local `.firebaserc` from the template and put the Project ID in it
   (`.firebaserc` is gitignored):
   `cp .firebaserc.example .firebaserc`
5. **[you]** Log in once from the terminal (interactive): type
   `! firebase login` in the chat, or run `firebase login` in a terminal.
6. **[you]** Set the backend secrets (each prompts for the value; they're stored in Google
   Cloud Secret Manager, never in this repo):
   ```
   firebase functions:secrets:set OPENAI_API_KEY
   firebase functions:secrets:set ELEVENLABS_API_KEY
   firebase functions:secrets:set GOOGLE_API_KEY            # server-side Places key
   firebase functions:secrets:set REVENUECAT_WEBHOOK_SECRET # RevenueCat webhook auth header
   ```
   Check them anytime with `firebase functions:secrets:get <NAME>`.
7. Claude deploys: `firebase deploy --only functions` and `firebase deploy --only firestore:rules`.
8. Copy the **function URL** Firebase prints (looks like
   `https://getplacecontent-xxxxxxxx-uc.a.run.app`) for step 5.

## 3. Create the Xcode project  **[you]**
1. Open Xcode → File → New → Project → iOS → **App** → Next.
2. Product Name: **WorldGuide**, Interface: **SwiftUI**, Language: **Swift**.
3. Organization identifier: set so the bundle ID matches step 1 (e.g. `com.cole`).
4. Save **into** this repo's root folder (so the project folder is
   `.../world-guide/WorldGuide`).
5. In the Firebase console, add an **iOS app** with your bundle ID and download its
   `GoogleService-Info.plist`. Save it as `WorldGuide/GoogleService-Info.plist`
   (gitignored; `WorldGuide/GoogleService-Info.example.plist` shows the expected shape).
   Restrict its `API_KEY` in Google Cloud Console → Credentials to your iOS bundle ID.

## 4. Install the app code  **[Claude]**
Run the installer (copies `ios-src/` into the project, removes the template
`ContentView.swift`, creates `Secrets.swift`):
```
./scripts/install-ios-files.sh
```
The files appear automatically in Xcode (synchronized folders).

## 5. Configure the app  **[you]**
1. Open `Secrets.swift` in Xcode and paste your **Google Places key** and **function URL**.
2. Add the location permission string: select the project → your target → **Info** tab →
   add key **"Privacy - Location When In Use Usage Description"** with a value like
   *"World Guide uses your location to tell you about places around you."*

## 6. Run it  **[you]**
1. Pick an **iPhone 17 simulator** and press **Run** (▶).
2. In the simulator: **Features → Location → Custom Location…** and enter a landmark,
   e.g. Eiffel Tower `48.8584, 2.2945`. (Or Apple Park `37.3349, -122.0090`.)
3. Allow location when prompted. Pins appear; **tap one** → the sheet shows a generated
   guide. Tap the same place again later → it loads from the Firestore cache (faster; you
   can see the document in the Firebase console under the `places` collection).

---

## Where keys live
| Key | Where it's stored | In git? |
|---|---|---|
| OpenAI, ElevenLabs, server Google key, RevenueCat webhook secret | Firebase Functions secrets (Google Cloud Secret Manager) | No |
| On-device Google Places key, RevenueCat public `appl_` key, function URLs | `WorldGuide/WorldGuide/Secrets.swift` on your Mac (gitignored) | No |
| Firebase iOS config (`WorldGuide/GoogleService-Info.plist`) and `.firebaserc` | Your Mac (gitignored; download the plist again from Firebase console → Project settings if lost). The plist's `API_KEY` ships inside the app, so it is also restricted to bundle ID `com.cole.WorldGuide` in Google Cloud → Credentials | No (only the `.example` templates) |

Never commit `Secrets.swift`, `functions/.secret.local`, `.env*`, `.p8`/`.p12` keys or service-account JSON; `.gitignore` blocks them.

## Troubleshooting
- **No pins:** check the Places key in `Secrets.swift` and that Places API (New) is
  enabled + billing is on. Watch Xcode's console for `loadNearby error`.
- **Sheet says "Couldn't load guide":** check the function URL in `Secrets.swift` and run
  `firebase functions:log` to see backend errors (often a missing OpenAI secret).
- **Location never updates:** in the simulator, set a Custom Location (it has none by default).
