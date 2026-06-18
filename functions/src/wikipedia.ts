// Wikipedia grounding: find the article for a place and return its intro extract.
// Strategy: prefer geosearch (articles physically near the coordinates, great for a
// location app), fall back to a name-based text search. We only accept a result whose
// title plausibly matches the place name, so an unnamed café doesn't get grounded in a
// random nearby landmark's article.

import * as logger from "firebase-functions/logger";

const WIKI_API = "https://en.wikipedia.org/w/api.php";
const WIKI_REST = "https://en.wikipedia.org/api/rest_v1";

export interface WikiGrounding {
  title: string;
  extract: string;
  url: string;
}

function normalize(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9 ]/g, " ").replace(/\s+/g, " ").trim();
}

/** True if the title shares a meaningful token with the place name. */
function titleMatchesName(title: string, name: string): boolean {
  const titleTokens = new Set(normalize(title).split(" ").filter((t) => t.length > 3));
  const nameTokens = normalize(name).split(" ").filter((t) => t.length > 3);
  return nameTokens.some((t) => titleTokens.has(t));
}

async function geoSearchTitle(name: string, lat: number, lng: number): Promise<string | null> {
  const url =
    `${WIKI_API}?action=query&list=geosearch&gscoord=${lat}%7C${lng}` +
    `&gsradius=1000&gslimit=10&format=json&origin=*`;
  const res = await fetch(url);
  const json = (await res.json()) as any;
  const results: Array<{ title: string; dist: number }> = json?.query?.geosearch ?? [];
  if (results.length === 0) return null;

  // Prefer a name match; otherwise accept the closest only if it's essentially on top of us.
  const named = results.find((r) => titleMatchesName(r.title, name));
  if (named) return named.title;
  if (results[0].dist <= 75) return results[0].title;
  return null;
}

async function textSearchTitle(name: string, locality?: string): Promise<string | null> {
  const query = locality ? `${name} ${locality}` : name;
  const url =
    `${WIKI_API}?action=query&list=search&srsearch=${encodeURIComponent(query)}` +
    `&srlimit=1&format=json&origin=*`;
  const res = await fetch(url);
  const json = (await res.json()) as any;
  const hit = json?.query?.search?.[0];
  if (!hit) return null;
  return titleMatchesName(hit.title, name) ? hit.title : null;
}

export async function fetchWikipediaGrounding(
  name: string,
  locality?: string,
  lat?: number,
  lng?: number
): Promise<WikiGrounding | null> {
  try {
    let title: string | null = null;
    if (lat != null && lng != null) {
      title = await geoSearchTitle(name, lat, lng);
    }
    if (!title) {
      title = await textSearchTitle(name, locality);
    }
    if (!title) return null;

    const sumRes = await fetch(`${WIKI_REST}/page/summary/${encodeURIComponent(title)}`);
    if (!sumRes.ok) return null;
    const sum = (await sumRes.json()) as any;
    const extract: string = sum?.extract ?? "";
    if (!extract) return null;

    return {
      title,
      extract,
      url:
        sum?.content_urls?.desktop?.page ??
        `https://en.wikipedia.org/wiki/${encodeURIComponent(title)}`,
    };
  } catch (e) {
    logger.warn("wikipedia grounding failed", e as Error);
    return null;
  }
}
