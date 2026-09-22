// Per-user usage metering — the free-tier engine.
//
// Enforced server-side so the client can't bypass it. All state lives in
// users/{uid} and every check runs inside a Firestore transaction so concurrent
// requests can't race past a limit.
//
// Free model (per the product decision):
//   * A user gets 5 lifetime "active days". The FIRST guide opened on a new
//     local calendar day spends one day-token; unused days cost nothing and the
//     5 days need not be consecutive. After 5 distinct active days a non-
//     subscriber is blocked (402) until they subscribe.
//   * A token-bucket rate limiter applies to EVERYONE (incl. subscribers) to
//     stop scripted abuse within an active day.
//   * A per-day cap on cache-MISS generations bounds worst-case API cost.
//
// Subscribers skip the day-token gate and get a higher generation cap.

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpError } from "./auth";

// ---- Tunables -------------------------------------------------------------
const FREE_ACTIVE_DAYS = 5;          // lifetime free calendar-days
const BUCKET_CAPACITY = 10;          // burst size
const BUCKET_REFILL_PER_SEC = 1 / 6; // ~10 requests/min sustained
const FREE_DAILY_GEN_CAP = 30;       // new (cache-miss) generations per active day, free
const SUB_DAILY_GEN_CAP = 300;       // abuse ceiling for subscribers
// ---------------------------------------------------------------------------

// Lazy — must not run before index.ts calls initializeApp() (this module is imported first).
function db() {
  return getFirestore();
}

export interface MeterInput {
  /** Minutes the client is offset from UTC (e.g. -240 for EDT). Used to derive the user's local day. */
  tzOffsetMinutes: number;
  /** True when this request will actually generate (cache miss) — the expensive path. */
  isCacheMiss: boolean;
  /** Whether the user currently holds an active subscription. */
  subscribed: boolean;
}

interface UserDoc {
  usedDays?: string[];
  dailyGenerations?: { date: string; count: number };
  rateBucket?: { tokens: number; updatedAt: number };
  subscription?: { active?: boolean };
  createdAt?: Timestamp;
}

/** Server-derived local calendar date ("YYYY-MM-DD") for the given tz offset. Never trusts the device clock. */
function localDate(tzOffsetMinutes: number): string {
  const clamped = Math.max(-840, Math.min(840, Math.trunc(tzOffsetMinutes || 0)));
  const shifted = new Date(Date.now() + clamped * 60_000);
  return shifted.toISOString().slice(0, 10);
}

/**
 * Atomically applies all limits for one request. Throws HttpError (402/429) when
 * a limit is hit — callers must run this BEFORE doing any paid work.
 *
 * Call with isCacheMiss=false before the cache lookup (day-token + rate limit),
 * then again with isCacheMiss=true only on a miss (adds the generation-cap charge).
 */
export async function checkAndConsume(uid: string, input: MeterInput): Promise<void> {
  const ref = db().collection("users").doc(uid);
  const today = localDate(input.tzOffsetMinutes);
  const now = Date.now();

  await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data: UserDoc = snap.exists ? (snap.data() as UserDoc) : {};
    const subscribed = input.subscribed || data.subscription?.active === true;

    // 1) Day-token gate (subscribers exempt).
    const usedDays = data.usedDays ?? [];
    let newUsedDays = usedDays;
    if (!subscribed) {
      if (!usedDays.includes(today)) {
        if (usedDays.length >= FREE_ACTIVE_DAYS) {
          throw new HttpError(402, "free_limit_reached", "Out of free days — subscribe to keep exploring");
        }
        newUsedDays = [...usedDays, today];
      }
    }

    // 2) Token-bucket rate limit (everyone).
    const bucket = data.rateBucket ?? { tokens: BUCKET_CAPACITY, updatedAt: now };
    const elapsedSec = Math.max(0, (now - bucket.updatedAt) / 1000);
    let tokens = Math.min(BUCKET_CAPACITY, bucket.tokens + elapsedSec * BUCKET_REFILL_PER_SEC);
    if (tokens < 1) {
      throw new HttpError(429, "rate_limited", "Too many requests — slow down a moment");
    }
    tokens -= 1;

    // 3) Per-day generation cap (only charged on a real generation).
    let daily = data.dailyGenerations ?? { date: today, count: 0 };
    if (daily.date !== today) daily = { date: today, count: 0 };
    if (input.isCacheMiss) {
      const cap = subscribed ? SUB_DAILY_GEN_CAP : FREE_DAILY_GEN_CAP;
      if (daily.count >= cap) {
        throw new HttpError(429, "daily_cap_reached", "Daily limit reached — try again tomorrow");
      }
      daily = { date: today, count: daily.count + 1 };
    }

    const update: UserDoc = {
      usedDays: newUsedDays,
      rateBucket: { tokens, updatedAt: now },
      dailyGenerations: daily,
    };
    if (!snap.exists) update.createdAt = Timestamp.now();
    tx.set(ref, update, { merge: true });
  });
}

/** Reads whether the user currently has an active subscription (written by the RevenueCat webhook). */
export async function isSubscribed(uid: string): Promise<boolean> {
  const snap = await db().collection("users").doc(uid).get();
  return (snap.data() as UserDoc | undefined)?.subscription?.active === true;
}
