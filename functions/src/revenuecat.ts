// RevenueCat webhook → the server's source of truth for subscription state.
//
// RevenueCat POSTs subscription lifecycle events here; we verify the shared secret it sends in the
// Authorization header, then write `users/{uid}.subscription`. The metering function reads that doc,
// so the client can't fake "subscribed". `app_user_id` is the Firebase uid because the app calls
// Purchases.logIn(uid).
//
// Set the secret once:  firebase functions:secrets:set REVENUECAT_WEBHOOK_SECRET
// and paste the same value into RevenueCat → Integrations → Webhooks → Authorization header.

import { onRequest } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const REVENUECAT_WEBHOOK_SECRET = defineSecret("REVENUECAT_WEBHOOK_SECRET");

export const revenuecatWebhook = onRequest(
  { secrets: [REVENUECAT_WEBHOOK_SECRET] },
  async (req, res) => {
    if (req.get("Authorization") !== REVENUECAT_WEBHOOK_SECRET.value()) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const event = req.body?.event;
    const uid: string | undefined = event?.app_user_id;
    if (!event || !uid) {
      res.status(400).json({ error: "missing event or app_user_id" });
      return;
    }

    const type: string = event.type ?? "";
    const expiresMs: number | undefined = event.expiration_at_ms;
    // Active unless this is an expiration, and only while the expiry is in the future.
    const active = type !== "EXPIRATION" && (!expiresMs || expiresMs > Date.now());

    await getFirestore().collection("users").doc(uid).set(
      {
        subscription: {
          active,
          productId: event.product_id ?? null,
          store: event.store ?? null,
          expiresAt: expiresMs ? Timestamp.fromMillis(expiresMs) : null,
          lastEvent: type,
          updatedAt: Timestamp.now(),
        },
      },
      { merge: true }
    );

    logger.info("revenuecat webhook applied", { uid, type, active });
    res.json({ ok: true });
  }
);
