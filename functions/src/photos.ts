// Photo retrieval from Wikimedia Commons. We search Commons (File namespace) for each
// of the LLM's photo_queries and collect real, licensed images with attribution.

import * as logger from "firebase-functions/logger";

export interface Photo {
  url: string;
  source: string;
  attribution: string;
  license: string;
}

function stripHtml(html?: string): string {
  if (!html) return "";
  return html.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
}

async function searchCommons(query: string): Promise<Photo[]> {
  const url =
    `https://commons.wikimedia.org/w/api.php?action=query&generator=search` +
    `&gsrsearch=${encodeURIComponent(query)}&gsrnamespace=6&gsrlimit=3` +
    `&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=1024&format=json&origin=*`;
  const res = await fetch(url);
  const json = (await res.json()) as any;
  const pages = json?.query?.pages ?? {};
  const photos: Photo[] = [];

  for (const key of Object.keys(pages)) {
    const ii = pages[key]?.imageinfo?.[0];
    if (!ii?.url) continue;
    if (!/\.(jpe?g|png)$/i.test(ii.url)) continue; // skip svg/gif/maps
    const meta = ii.extmetadata ?? {};
    photos.push({
      url: ii.thumburl || ii.url,
      source: "Wikimedia Commons",
      attribution: stripHtml(meta.Artist?.value) || "Unknown",
      license: stripHtml(meta.LicenseShortName?.value) || "See source",
    });
  }
  return photos;
}

/** Fetch up to `limit` distinct photos across all queries. */
export async function fetchPhotos(queries: string[], limit = 4): Promise<Photo[]> {
  const out: Photo[] = [];
  const seen = new Set<string>();

  for (const q of queries) {
    if (out.length >= limit) break;
    try {
      const found = await searchCommons(q);
      for (const p of found) {
        if (out.length >= limit) break;
        if (seen.has(p.url)) continue;
        seen.add(p.url);
        out.push(p);
      }
    } catch (e) {
      logger.warn(`commons search failed for "${q}"`, e as Error);
    }
  }
  return out;
}
