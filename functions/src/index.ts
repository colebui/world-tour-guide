// World Guide backend — Phase 1 walking skeleton.
//
// Single HTTPS endpoint `getPlaceContent`:
//   1. Look up places/{place_id} in Firestore (the cache).
//   2. Cache hit  -> return stored content.
//   3. Cache miss -> call OpenAI, store the result, return it.
//
// The OpenAI key is a Cloud Functions SECRET and never leaves the backend.
// Set it once with:  firebase functions:secrets:set OPENAI_API_KEY

import { onRequest } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import OpenAI from "openai";
import { parse as partialParse } from "partial-json";
import { SYSTEM_PROMPT, buildUserPrompt, PROMPT_VERSION } from "./prompt";
import { fetchWikipediaGrounding } from "./wikipedia";
import { fetchPhotos } from "./photos";
import { fetchReviewCount } from "./placeDetails";
import { generateAndStoreAudio, buildNarrationScript } from "./tts";
import { requireUser, requireAppCheck, sendError, HttpError } from "./auth";
import { checkAndConsume, isSubscribed } from "./metering";

export { revenuecatWebhook } from "./revenuecat";

initializeApp();
const db = getFirestore();

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");
const ELEVENLABS_API_KEY = defineSecret("ELEVENLABS_API_KEY");
const GOOGLE_API_KEY = defineSecret("GOOGLE_API_KEY"); // server key for review-count lookup

const MODEL = "gpt-4o";          // standard text model
const PREMIUM_MODEL = "gpt-4o";  // bigger model for famous places; falls back to MODEL on error
const PREMIUM_REVIEW_THRESHOLD = 10000;
const SECRETS = [OPENAI_API_KEY, ELEVENLABS_API_KEY, GOOGLE_API_KEY];

type Tier = "standard" | "premium";

export const getPlaceContent = onRequest(
  { secrets: SECRETS, cors: true, timeoutSeconds: 120 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Use POST" });
      return;
    }

    const { place_id, name, types, lat, lng, locality, tz_offset_minutes } = req.body ?? {};
    if (!place_id || !name) {
      res.status(400).json({ error: "place_id and name are required" });
      return;
    }

    const ref = db.collection("places").doc(String(place_id));

    try {
      // Auth + metering gate (before any paid work).
      await requireAppCheck(req);
      const uid = await requireUser(req);
      const subscribed = await isSubscribed(uid);
      const tz = Number(tz_offset_minutes) || 0;
      await checkAndConsume(uid, { tzOffsetMinutes: tz, isCacheMiss: false, subscribed });

      // 1 + 2: cache check
      const snap = await ref.get();
      if (snap.exists) {
        logger.info("cache hit", { place_id, uid });
        res.json({ source: "cache", content: snap.data() });
        return;
      }

      // 3: generate — charge the per-day generation cap first.
      await checkAndConsume(uid, { tzOffsetMinutes: tz, isCacheMiss: true, subscribed });
      logger.info("cache miss -> generating", { place_id, name, uid });

      // 3a: tier (by review count) + Wikipedia grounding (best-effort)
      const tier = await decideTier(place_id);
      const wiki = await fetchWikipediaGrounding(name, locality, lat, lng);
      if (wiki) logger.info("grounded in wikipedia", { title: wiki.title });

      // 3b: generate content (premium model for famous places, with fallback)
      const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const userPrompt = buildUserPrompt({ place_id, name, types, lat, lng, locality, wikipediaExtract: wiki?.extract });
      const { model: modelUsed, result } = await createCompletion(
        client, tier === "premium" ? PREMIUM_MODEL : MODEL, userPrompt, false
      );
      const raw = (result as any).choices[0]?.message?.content ?? "{}";
      const content = JSON.parse(raw);

      // 3c: photos + audio + provenance
      const record = await buildRecord(place_id, name, content, wiki?.url ?? null, tier, modelUsed);
      await ref.set(record);

      res.json({ source: "generated", content: record });
    } catch (err) {
      if (err instanceof HttpError) { sendError(res, err); return; }
      logger.error("getPlaceContent failed", err as Error);
      res.status(500).json({ error: "generation failed" });
    }
  }
);

// Deletes all of a user's data (their saved lists + the users/{uid} doc holding metering +
// subscription state). Required for in-app account deletion (Apple Guideline 5.1.1(v)). The client
// calls this with its Firebase token, then deletes its own Auth account.
export const deleteUserData = onRequest({ cors: true }, async (req, res) => {
  try {
    if (req.method !== "POST") { res.status(405).json({ error: "Use POST" }); return; }
    const uid = await requireUser(req);
    const userRef = db.collection("users").doc(uid);
    const lists = await userRef.collection("lists").get();
    const batch = db.batch();
    lists.forEach((d) => batch.delete(d.ref));
    batch.delete(userRef);
    await batch.commit();
    logger.info("deleted user data", { uid, lists: lists.size });
    res.json({ ok: true });
  } catch (err) {
    sendError(res, err);
  }
});

// Decides the quality tier from the place's Google review count. The count itself is used only
// transiently here — it is NOT persisted, to respect Google Places' caching terms.
async function decideTier(place_id: string): Promise<Tier> {
  const reviewCount = await fetchReviewCount(String(place_id), GOOGLE_API_KEY.value());
  return reviewCount > PREMIUM_REVIEW_THRESHOLD ? "premium" : "standard";
}

// Builds the final cache record: photos + narration audio (in parallel) + provenance.
async function buildRecord(
  place_id: string,
  name: string,
  content: any,
  wikiUrl: string | null,
  tier: Tier,
  modelUsed: string
) {
  const queries: string[] = Array.isArray(content.photo_queries) && content.photo_queries.length
    ? content.photo_queries
    : [name];

  const [photos, audioUrl] = await Promise.all([
    fetchPhotos(queries, 4),
    generateAndStoreAudio(String(place_id), buildNarrationScript(content), tier, {
      openai: OPENAI_API_KEY.value(),
      elevenlabs: ELEVENLABS_API_KEY.value(),
    }),
  ]);

  return {
    ...content,
    place_id: String(place_id),
    photos,
    audio_url: audioUrl,
    tier,
    meta: {
      prompt_version: PROMPT_VERSION,
      model: modelUsed,
      generated_at: FieldValue.serverTimestamp(),
      sources: wikiUrl ? [wikiUrl] : [],
    },
  };
}

// Creates a chat completion, trying the premium model first and falling back to the standard
// model if the premium one isn't accessible. Set `stream` for the streaming endpoint.
async function createCompletion(client: OpenAI, model: string, userPrompt: string, stream: boolean) {
  const params = {
    messages: [
      { role: "system" as const, content: SYSTEM_PROMPT },
      { role: "user" as const, content: userPrompt },
    ],
    response_format: { type: "json_object" as const },
    temperature: 0.8,
  };
  try {
    return { model, result: await client.chat.completions.create({ ...params, model, stream }) };
  } catch (err) {
    if (model !== MODEL) {
      logger.warn(`premium model ${model} unavailable, falling back to ${MODEL}`);
      return { model: MODEL, result: await client.chat.completions.create({ ...params, model: MODEL, stream }) };
    }
    throw err;
  }
}

// Streaming variant of getPlaceContent. Emits SSE events:
//   {type:"partial", content}   - growing snapshot of the guide as it generates
//   {type:"complete", source, content} - final doc (also written to the cache)
//   {type:"error"}
export const streamPlaceContent = onRequest(
  { secrets: SECRETS, cors: true, timeoutSeconds: 120 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Use POST" });
      return;
    }
    const { place_id, name, types, lat, lng, locality, tz_offset_minutes } = req.body ?? {};
    if (!place_id || !name) {
      res.status(400).json({ error: "place_id and name are required" });
      return;
    }

    const ref = db.collection("places").doc(String(place_id));
    const tz = Number(tz_offset_minutes) || 0;

    // Auth + metering + cache lookup run BEFORE we commit to an SSE 200, so a
    // limit violation can still return a real HTTP status (401/402/429).
    let cached: FirebaseFirestore.DocumentData | undefined;
    let subscribed = false;
    try {
      await requireAppCheck(req);
      const uid = await requireUser(req);
      subscribed = await isSubscribed(uid);
      await checkAndConsume(uid, { tzOffsetMinutes: tz, isCacheMiss: false, subscribed });
      const snap = await ref.get();
      if (snap.exists) {
        cached = snap.data();
      } else {
        await checkAndConsume(uid, { tzOffsetMinutes: tz, isCacheMiss: true, subscribed });
      }
    } catch (err) {
      sendError(res, err);
      return;
    }

    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("X-Accel-Buffering", "no");
    res.flushHeaders();
    const send = (event: object) => res.write(`data: ${JSON.stringify(event)}\n\n`);

    if (cached) {
      logger.info("stream cache hit", { place_id });
      send({ type: "complete", source: "cache", content: cached });
      res.end();
      return;
    }

    try {
      logger.info("stream cache miss -> generating", { place_id, name });
      const tier = await decideTier(place_id);
      const wiki = await fetchWikipediaGrounding(name, locality, lat, lng);

      const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const userPrompt = buildUserPrompt({ place_id, name, types, lat, lng, locality, wikipediaExtract: wiki?.extract });
      const { model: modelUsed, result } = await createCompletion(
        client, tier === "premium" ? PREMIUM_MODEL : MODEL, userPrompt, true
      );

      let raw = "";
      let lastEmit = 0;
      for await (const chunk of result as any) {
        raw += chunk.choices[0]?.delta?.content ?? "";
        const now = Date.now();
        if (now - lastEmit >= 150) {
          lastEmit = now;
          try {
            send({ type: "partial", content: partialParse(raw) });
          } catch { /* not yet parseable; keep accumulating */ }
        }
      }

      const content = JSON.parse(raw);
      const record = await buildRecord(place_id, name, content, wiki?.url ?? null, tier, modelUsed);
      await ref.set(record);
      send({ type: "complete", source: "generated", content: record });
      res.end();
    } catch (err) {
      logger.error("streamPlaceContent failed", err as Error);
      send({ type: "error" });
      res.end();
    }
  }
);
