// Text-to-speech: narrate the WHOLE guide and cache the MP3 in Firebase Storage.
//   standard tier -> OpenAI TTS (tts-1-hd, "nova")
//   premium tier  -> ElevenLabs (more natural)
// Long scripts are chunked (per-request char limits) and the MP3s concatenated.
// Returns a public URL to the stored MP3, or null on failure (app falls back to on-device voice).

import * as logger from "firebase-functions/logger";
import { getStorage } from "firebase-admin/storage";
import OpenAI from "openai";

// A warm, natural ElevenLabs preset voice ("Rachel"). Swap the id to change voices.
const ELEVENLABS_VOICE_ID = "21m00Tcm4TlvDq8ikWAM";
const MAX_CHUNK = 3500; // safely under OpenAI's 4096-char TTS limit

/// Assembles a spoken narration script for the whole guide, in a natural listening order.
export function buildNarrationScript(content: any): string {
  const parts: string[] = [];
  const add = (lead: string, text?: string) => {
    if (text && text.trim()) parts.push(lead ? `${lead} ${text.trim()}` : text.trim());
  };

  add("", content.tour_guide_intro);
  add("A bit of history.", content.history);
  add("Why it matters.", content.significance);

  if (Array.isArray(content.stories)) {
    for (const s of content.stories) {
      if (s?.title || s?.body) parts.push([s.title, s.body].filter(Boolean).join(". "));
    }
  }
  if (Array.isArray(content.fun_facts) && content.fun_facts.length) {
    parts.push("Here are some fun facts. " + content.fun_facts.join(". "));
  }
  if (Array.isArray(content.details)) {
    for (const d of content.details) {
      if (d?.heading || d?.body) parts.push([d.heading, d.body].filter(Boolean).join(". "));
    }
  }
  if (Array.isArray(content.visiting_tips) && content.visiting_tips.length) {
    parts.push("A few tips for visiting. " + content.visiting_tips.join(". "));
  }

  return parts.join("\n\n");
}

export async function generateAndStoreAudio(
  placeId: string,
  script: string,
  tier: "standard" | "premium",
  keys: { openai: string; elevenlabs: string }
): Promise<string | null> {
  const input = script.trim();
  if (!input) return null;

  try {
    const chunks = chunkText(input, MAX_CHUNK);
    const buffers: Buffer[] = [];
    for (const chunk of chunks) {
      const mp3 = tier === "premium"
        ? await elevenLabsTTS(chunk, keys.elevenlabs)
        : await openAITTS(chunk, keys.openai);
      if (mp3) buffers.push(mp3);
    }
    if (!buffers.length) return null;
    const audio = Buffer.concat(buffers);

    const bucket = getStorage().bucket();
    const file = bucket.file(`audio/${placeId}.mp3`);
    await file.save(audio, { contentType: "audio/mpeg", resumable: false });
    await file.makePublic();
    logger.info("stored narration", { placeId, chunks: chunks.length, bytes: audio.length });
    return `https://storage.googleapis.com/${bucket.name}/audio/${placeId}.mp3`;
  } catch (e) {
    logger.warn("audio generation failed", e as Error);
    return null;
  }
}

/// Splits text into <=maxLen pieces at sentence/paragraph boundaries.
function chunkText(text: string, maxLen: number): string[] {
  if (text.length <= maxLen) return [text];
  const sentences = text.split(/(?<=[.!?])\s+/);
  const chunks: string[] = [];
  let current = "";
  for (const s of sentences) {
    if ((current + " " + s).length > maxLen && current) {
      chunks.push(current.trim());
      current = s;
    } else {
      current += (current ? " " : "") + s;
    }
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}

async function openAITTS(input: string, apiKey: string): Promise<Buffer> {
  const client = new OpenAI({ apiKey });
  const response = await client.audio.speech.create({ model: "tts-1-hd", voice: "nova", input });
  return Buffer.from(await response.arrayBuffer());
}

async function elevenLabsTTS(input: string, apiKey: string): Promise<Buffer | null> {
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}`,
    {
      method: "POST",
      headers: { "xi-api-key": apiKey, "Content-Type": "application/json", Accept: "audio/mpeg" },
      body: JSON.stringify({ text: input, model_id: "eleven_multilingual_v2" }),
    }
  );
  if (!res.ok) {
    logger.warn("elevenlabs tts failed", { status: res.status });
    return null;
  }
  return Buffer.from(await res.arrayBuffer());
}
