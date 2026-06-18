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
import { SYSTEM_PROMPT, buildUserPrompt, PROMPT_VERSION } from "./prompt";
import { fetchWikipediaGrounding } from "./wikipedia";
import { fetchPhotos } from "./photos";

initializeApp();
const db = getFirestore();

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");
const MODEL = "gpt-4o"; // structured-output capable; tune later

export const getPlaceContent = onRequest(
  { secrets: [OPENAI_API_KEY], cors: true, timeoutSeconds: 60 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Use POST" });
      return;
    }

    const { place_id, name, types, lat, lng, locality } = req.body ?? {};
    if (!place_id || !name) {
      res.status(400).json({ error: "place_id and name are required" });
      return;
    }

    const ref = db.collection("places").doc(String(place_id));

    try {
      // 1 + 2: cache check
      const snap = await ref.get();
      if (snap.exists) {
        logger.info("cache hit", { place_id });
        res.json({ source: "cache", content: snap.data() });
        return;
      }

      // 3: generate
      logger.info("cache miss -> generating", { place_id, name });

      // 3a: ground in Wikipedia (best-effort; null if no good match)
      const wiki = await fetchWikipediaGrounding(name, locality, lat, lng);
      if (wiki) logger.info("grounded in wikipedia", { title: wiki.title });

      // 3b: generate content
      const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const completion = await client.chat.completions.create({
        model: MODEL,
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          {
            role: "user",
            content: buildUserPrompt({
              place_id, name, types, lat, lng, locality,
              wikipediaExtract: wiki?.extract,
            }),
          },
        ],
        response_format: { type: "json_object" },
        temperature: 0.8,
      });

      const raw = completion.choices[0]?.message?.content ?? "{}";
      const content = JSON.parse(raw);

      // 3c: fetch real, attributed photos for the LLM's photo_queries
      const queries: string[] = Array.isArray(content.photo_queries) && content.photo_queries.length
        ? content.photo_queries
        : [name];
      const photos = await fetchPhotos(queries, 4);
      logger.info("fetched photos", { count: photos.length });

      // Persist with provenance so we can regenerate when the prompt improves.
      const record = {
        ...content,
        place_id: String(place_id),
        photos,
        meta: {
          prompt_version: PROMPT_VERSION,
          model: MODEL,
          generated_at: FieldValue.serverTimestamp(),
          sources: wiki ? [wiki.url] : [],
        },
      };
      await ref.set(record);

      res.json({ source: "generated", content: record });
    } catch (err) {
      logger.error("getPlaceContent failed", err as Error);
      res.status(500).json({ error: "generation failed" });
    }
  }
);
