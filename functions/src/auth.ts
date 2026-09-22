// Request authentication for the HTTPS content endpoints.
//
// Every call must carry a Firebase ID token (anonymous tokens count) in the
// `Authorization: Bearer <token>` header. This makes every request attributable
// to a uid so metering (see metering.ts) can enforce the free tier and so an
// unauthenticated caller can't burn OpenAI/ElevenLabs credits.
//
// App Check is verified too, but in "monitor" mode for now: a missing/invalid
// App Check token is logged, not rejected, so we don't break the live app while
// the client rolls out. Flip APP_CHECK_ENFORCED to true once the app ships with
// App Attest configured.

import type { Request } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { getAuth } from "firebase-admin/auth";
import { getAppCheck } from "firebase-admin/app-check";

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

const APP_CHECK_ENFORCED = false;

/** Extracts and verifies the Firebase ID token; returns the caller's uid. */
export async function requireUser(req: Request): Promise<string> {
  const header = req.get("Authorization") ?? "";
  const match = header.match(/^Bearer (.+)$/i);
  if (!match) {
    throw new HttpError(401, "missing_token", "Authorization bearer token required");
  }
  try {
    const decoded = await getAuth().verifyIdToken(match[1]);
    return decoded.uid;
  } catch (err) {
    logger.warn("ID token verification failed", err as Error);
    throw new HttpError(401, "invalid_token", "Invalid or expired token");
  }
}

/** Verifies the App Check token. Logs only unless APP_CHECK_ENFORCED is true. */
export async function requireAppCheck(req: Request): Promise<void> {
  const token = req.get("X-Firebase-AppCheck");
  if (!token) {
    if (APP_CHECK_ENFORCED) throw new HttpError(401, "missing_app_check", "App Check token required");
    logger.debug("App Check token absent (monitor mode)");
    return;
  }
  try {
    await getAppCheck().verifyToken(token);
  } catch (err) {
    if (APP_CHECK_ENFORCED) throw new HttpError(401, "invalid_app_check", "Invalid App Check token");
    logger.warn("App Check verification failed (monitor mode)", err as Error);
  }
}

/** Writes an HttpError (or a generic 500) to an Express-style response as JSON. */
export function sendError(res: { status: (n: number) => { json: (b: object) => void } }, err: unknown): void {
  if (err instanceof HttpError) {
    res.status(err.status).json({ error: err.code, message: err.message });
  } else {
    logger.error("unhandled error", err as Error);
    res.status(500).json({ error: "internal" });
  }
}
