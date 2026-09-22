// Looks up a place's Google review count, used to decide the quality tier.
// Uses a SERVER-side Google key (the on-device key is bundle-restricted and can't be used here).
// Requires the Places API (New) enabled on that key.

import * as logger from "firebase-functions/logger";

export async function fetchReviewCount(placeId: string, apiKey: string): Promise<number> {
  try {
    const res = await fetch(`https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`, {
      headers: {
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "userRatingCount",
      },
    });
    if (!res.ok) {
      logger.warn("review count lookup failed", { status: res.status });
      return 0;
    }
    const json = (await res.json()) as { userRatingCount?: number };
    return json.userRatingCount ?? 0;
  } catch (e) {
    logger.warn("review count lookup error", e as Error);
    return 0;
  }
}
