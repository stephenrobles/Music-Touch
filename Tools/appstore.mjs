#!/usr/bin/env node
// Fills in the App Store Connect listing for Music Touch (Mac) from AppStore/metadata.md, uploads
// screenshots, attaches the latest processed build and submits for review.
//
// Usage: node Tools/appstore.mjs <command>
//   bundleid     register the fm.beard.MusicTouch bundle ID for macOS (the app record itself must be created in App Store Connect's web UI)
//   metadata     name/subtitle/privacy URL, categories, version text (description, keywords, …), review details
//   prepare      content rights, age rating (nothing applies), free price, availability in all territories
//   screenshots  replace the Mac screenshot set with AppStore/screenshots/mac-*.png (2880 × 1800)
//   attach       attach the newest processed build to the version
//   submit       submit the version for review
//   release      automatic release after approval, or --manual to release by hand
//   status       print versions, builds and review state
// Auth: App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
import { createPrivateKey, sign, createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const KEY_ID = process.env.ASC_KEY_ID || "Z5YD293RLM";
const ISSUER_ID = process.env.ASC_ISSUER_ID || "69a6de84-dcf8-47e3-e053-5b8c7c11a4d1";
const BUNDLE_ID = "fm.beard.MusicTouch";
const PLATFORM = "MAC_OS";
const VERSION = "1.0";
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const API = "https://api.appstoreconnect.apple.com/v1";

// ---------- auth ----------
const b64url = (b) => Buffer.from(b).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
function token() {
  const key = createPrivateKey(readFileSync(join(homedir(), ".appstoreconnect/private_keys", `AuthKey_${KEY_ID}.p8`)));
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: KEY_ID, typ: "JWT" }));
  const payload = b64url(JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 1100, aud: "appstoreconnect-v1" }));
  const sig = sign("sha256", Buffer.from(`${header}.${payload}`), { key, dsaEncoding: "ieee-p1363" });
  return `${header}.${payload}.${b64url(sig)}`;
}
async function api(method, path, body) {
  const url = path.startsWith("http") ? path : (path.startsWith("/v2") ? "https://api.appstoreconnect.apple.com" + path : API + path);
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return null;
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${typeof json === "string" ? json : JSON.stringify(json.errors ?? json)}`);
  return json;
}
const get = (p) => api("GET", p), post = (p, b) => api("POST", p, b), patch = (p, b) => api("PATCH", p, b), del = (p) => api("DELETE", p);
async function all(path) {
  let out = [], next = path;
  while (next) { const page = await get(next); out = out.concat(page.data); next = page.links?.next; }
  return out;
}

// ---------- metadata.md ----------
const md = readFileSync(join(ROOT, "AppStore/metadata.md"), "utf8");
const field = (label) => { const m = md.match(new RegExp(`\\*\\*${label}[^*]*\\*\\*\\s*(.+)`)); return m ? m[1].trim() : null; };
const block = (label) => { const m = md.match(new RegExp(`\\*\\*${label}[^*]*\\*\\*\\n([\\s\\S]*?)\\n\\n(?=\\*\\*|## )`)); return m ? m[1].trim() : null; };
const META = {
  name: field("Name:"),
  subtitle: field("Subtitle \\(30\\):"),
  privacyPolicyUrl: field("Privacy Policy URL:"),
  supportUrl: field("Support URL:"),
  marketingUrl: field("Marketing URL:"),
  copyright: field("Copyright:"),
  promotionalText: block("Promotional text"),
  description: block("Description"),
  keywords: block("Keywords"),
  whatsNew: block("What's New"),
  reviewNotes: (md.match(/- \*\*Notes:\*\*\n([\s\S]*?)\n\n## /) || [])[1]?.replace(/\n  /g, " ").trim(),
};

// ---------- lookups ----------
async function app() {
  const apps = await get(`/apps?filter[bundleId]=${BUNDLE_ID}`);
  if (!apps.data.length) throw new Error(`No app with bundle id ${BUNDLE_ID}. Create it in App Store Connect (My Apps › + › New App, Mac, bundle ID fm.beard.MusicTouch, SKU MusicTouch) and run again.`);
  return apps.data[0];
}
async function version(appId) {
  const versions = await get(`/apps/${appId}/appStoreVersions?filter[platform]=${PLATFORM}&limit=5`);
  let v = versions.data.find((x) => x.attributes.versionString === VERSION) ?? versions.data.find((x) => !["READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"].includes(x.attributes.appStoreState));
  if (!v) {
    v = (await post("/appStoreVersions", { data: { type: "appStoreVersions", attributes: { platform: PLATFORM, versionString: VERSION, copyright: META.copyright }, relationships: { app: { data: { type: "apps", id: appId } } } } })).data;
    console.log(`created ${PLATFORM} version ${VERSION}`);
  }
  return v;
}

/// The review contact phone already on file for one of Stephen's other apps.
async function reviewPhoneFromOtherApp() {
  for (const bundle of ["fm.beard.Leveler", "fm.beard.Transcriber", "fm.beard.Captioner", "fm.beard.KanDo", "fm.beard.HomePad", "fm.beard.Lookout"]) {
    const apps = await get(`/apps?filter[bundleId]=${bundle}`).catch(() => null);
    for (const other of apps?.data ?? []) {
      const versions = await get(`/apps/${other.id}/appStoreVersions?limit=3`).catch(() => null);
      for (const v of versions?.data ?? []) {
        const d = await get(`/appStoreVersions/${v.id}/appStoreReviewDetail`).catch(() => null);
        if (d?.data?.attributes?.contactPhone) return d.data.attributes.contactPhone;
      }
    }
  }
  return null;
}

// ---------- commands ----------
async function bundleid() {
  const existing = await get(`/bundleIds?filter[identifier]=${BUNDLE_ID}`);
  if (existing.data.length) { console.log(`bundle ID already registered: ${existing.data[0].id}`); return; }
  const b = await post("/bundleIds", { data: { type: "bundleIds", attributes: { identifier: BUNDLE_ID, name: "Music Touch", platform: "MAC_OS" } } });
  console.log(`registered bundle ID ${BUNDLE_ID} (${b.data.id})`);
}

async function metadata() {
  const a = await app();
  const infos = await get(`/apps/${a.id}/appInfos`);
  const info = infos.data.find((x) => x.attributes.appStoreState !== "READY_FOR_SALE") ?? infos.data[0];
  for (const each of infos.data) {
    const locs = await get(`/appInfos/${each.id}/appInfoLocalizations`);
    for (const loc of locs.data.filter((l) => l.attributes.locale === "en-US")) {
      // App Store Connect drops privacyPolicyUrl when it is patched together with other
      // attributes on a fresh app info record, so send it on its own.
      try {
        await patch(`/appInfoLocalizations/${loc.id}`, { data: { type: "appInfoLocalizations", id: loc.id, attributes: { name: META.name, subtitle: META.subtitle } } });
        await patch(`/appInfoLocalizations/${loc.id}`, { data: { type: "appInfoLocalizations", id: loc.id, attributes: { privacyPolicyUrl: META.privacyPolicyUrl } } });
        console.log(`app info localization updated (${each.attributes.appStoreState}):`, loc.attributes.name);
      } catch (e) { console.log(`app info localization ${loc.id}: ${e.message.slice(0, 200)}`); }
    }
  }
  const cats = await get(`/appCategories?filter[platforms]=MAC_OS&limit=200`);
  const cat = (id) => cats.data.find((c) => c.id === id) ? { type: "appCategories", id } : null;
  try {
    await patch(`/appInfos/${info.id}`, { data: { type: "appInfos", id: info.id, relationships: {
      primaryCategory: { data: cat("MUSIC") }, secondaryCategory: { data: cat("ENTERTAINMENT") } } } });
    console.log("categories set: Music, Entertainment");
  } catch (e) { if (!/INVALID_STATE/.test(e.message)) throw e; console.log(`categories unchanged (${info.attributes.appStoreState})`); }

  const v = await version(a.id);
  await patch(`/appStoreVersions/${v.id}`, { data: { type: "appStoreVersions", id: v.id, attributes: { copyright: META.copyright, versionString: VERSION } } });
  const vlocs = await get(`/appStoreVersions/${v.id}/appStoreVersionLocalizations`);
  let loc = vlocs.data.find((l) => l.attributes.locale === "en-US");
  const attrs = { description: META.description, keywords: META.keywords, promotionalText: META.promotionalText, supportUrl: META.supportUrl, marketingUrl: META.marketingUrl, whatsNew: META.whatsNew };
  // A first release has no "What's New"; App Store Connect rejects the field, so drop it on that error.
  const save = async (x) => {
    if (!loc) loc = (await post("/appStoreVersionLocalizations", { data: { type: "appStoreVersionLocalizations", attributes: { locale: "en-US", ...x }, relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: v.id } } } } })).data;
    else await patch(`/appStoreVersionLocalizations/${loc.id}`, { data: { type: "appStoreVersionLocalizations", id: loc.id, attributes: x } });
  };
  try { await save(attrs); } catch (e) {
    if (!/whatsNew/.test(e.message)) throw e;
    const { whatsNew, ...rest } = attrs; await save(rest);
  }
  const details = await get(`/appStoreVersions/${v.id}/appStoreReviewDetail`).catch(() => null);
  const review = { contactFirstName: "Stephen", contactLastName: "Robles", contactEmail: "steve@beard.fm", demoAccountRequired: false, notes: META.reviewNotes };
  const phone = process.env.ASC_PHONE || await reviewPhoneFromOtherApp();
  if (phone) review.contactPhone = phone;
  if (details?.data) await patch(`/appStoreReviewDetails/${details.data.id}`, { data: { type: "appStoreReviewDetails", id: details.data.id, attributes: review } });
  else await post("/appStoreReviewDetails", { data: { type: "appStoreReviewDetails", attributes: review, relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: v.id } } } } });
  console.log(`${PLATFORM} ${VERSION}: text and review details set`);
}

/// Content rights, age rating (nothing applies), a free price and availability everywhere.
async function prepare() {
  const a = await app();
  await patch(`/apps/${a.id}`, { data: { type: "apps", id: a.id, attributes: { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" } } });
  console.log("content rights: does not use third-party content");

  const v = await version(a.id);
  const infos = await get(`/apps/${a.id}/appInfos`);
  const info = infos.data.find((x) => x.attributes.appStoreState !== "READY_FOR_SALE") ?? infos.data[0];
  const infoDecl = await get(`/appInfos/${info.id}/ageRatingDeclaration`).catch(() => null);
  const none = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity", "gunsOrOtherWeapons",
    "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic"];
  const no = ["gambling", "unrestrictedWebAccess", "lootBox", "advertising", "messagingAndChat", "userGeneratedContent", "parentalControls", "healthOrWellnessTopics", "socialMedia"];
  const attrs = { ageAssurance: false, kidsAgeBand: null };
  for (const k of none) attrs[k] = "NONE";
  for (const k of no) attrs[k] = false;
  for (const id of [v.id, infoDecl?.data?.id].filter(Boolean)) {
    try {
      await patch(`/ageRatingDeclarations/${id}`, { data: { type: "ageRatingDeclarations", id, attributes: attrs } });
      console.log(`age rating declared on ${id} (nothing applies)`);
    } catch (e) { console.log(`age rating on ${id}: ${e.message.slice(0, 300)}`); }
  }

  console.log("privacy: set 'Data Not Collected' in App Store Connect › App Privacy and publish (no API)");

  const schedule = await get(`/apps/${a.id}/appPriceSchedule`).catch(() => null);
  const manual = schedule?.data ? await get(`/appPriceSchedules/${schedule.data.id}/manualPrices?limit=5`).catch(() => null) : null;
  if (!manual?.data?.length) {
    const points = await get(`/apps/${a.id}/appPricePoints?filter[territory]=USA&limit=200`);
    const free = points.data.find((p) => Number(p.attributes.customerPrice) === 0);
    if (!free) throw new Error("no free price point found");
    await post("/appPriceSchedules", { data: { type: "appPriceSchedules", relationships: {
      app: { data: { type: "apps", id: a.id } }, baseTerritory: { data: { type: "territories", id: "USA" } },
      manualPrices: { data: [{ type: "appPrices", id: "${price-free}" }] } } },
      included: [{ type: "appPrices", id: "${price-free}", attributes: { startDate: null }, relationships: { appPricePoint: { data: { type: "appPricePoints", id: free.id } } } }] });
    console.log("pricing: free (base USA)");
  } else {
    console.log("pricing: already set");
  }

  const availability = await get(`/apps/${a.id}/appAvailabilityV2?include=territoryAvailabilities&limit[territoryAvailabilities]=200`).catch(() => null);
  const available = (availability?.included ?? []).filter((t) => t.attributes.available).length;
  if (available < 100) {
    const territories = await all(`/territories?limit=200`);
    await post("/v2/appAvailabilities", { data: { type: "appAvailabilities", attributes: { availableInNewTerritories: true }, relationships: {
      app: { data: { type: "apps", id: a.id } },
      territoryAvailabilities: { data: territories.map((t, i) => ({ type: "territoryAvailabilities", id: `\${t${i}}` })) } } },
      included: territories.map((t, i) => ({ type: "territoryAvailabilities", id: `\${t${i}}`, attributes: { available: true }, relationships: { territory: { data: { type: "territories", id: t.id } } } })) });
    console.log(`availability: all ${territories.length} territories`);
  } else {
    console.log(`availability: already ${available} territories`);
  }
}

async function screenshots() {
  const a = await app();
  const v = await version(a.id);
  const vlocs = await get(`/appStoreVersions/${v.id}/appStoreVersionLocalizations`);
  const loc = vlocs.data.find((l) => l.attributes.locale === "en-US");
  if (!loc) throw new Error("run `metadata` first so the en-US localization exists");
  const files = readdirSync(join(ROOT, "AppStore/screenshots")).filter((f) => f.startsWith("mac-") && f.endsWith(".png")).sort();
  if (!files.length) throw new Error("no AppStore/screenshots/mac-*.png");
  const sets = await get(`/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`);
  let set = sets.data.find((s) => s.attributes.screenshotDisplayType === "APP_DESKTOP");
  if (set) { for (const shot of (await get(`/appScreenshotSets/${set.id}/appScreenshots`)).data) await del(`/appScreenshots/${shot.id}`); }
  else set = (await post("/appScreenshotSets", { data: { type: "appScreenshotSets", attributes: { screenshotDisplayType: "APP_DESKTOP" }, relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc.id } } } } })).data;
  for (const file of files) {
    const data = readFileSync(join(ROOT, "AppStore/screenshots", file));
    const shot = (await post("/appScreenshots", { data: { type: "appScreenshots", attributes: { fileName: file, fileSize: data.length }, relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set.id } } } } })).data;
    for (const op of shot.attributes.uploadOperations) {
      const chunk = data.subarray(op.offset, op.offset + op.length);
      const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]));
      const r = await fetch(op.url, { method: op.method, headers, body: chunk });
      if (!r.ok) throw new Error(`upload chunk failed: ${r.status}`);
    }
    await patch(`/appScreenshots/${shot.id}`, { data: { type: "appScreenshots", id: shot.id, attributes: { uploaded: true, sourceFileChecksum: createHash("md5").update(data).digest("hex") } } });
    console.log(`uploaded ${file}`);
  }
}

async function attach() {
  const a = await app();
  const v = await version(a.id);
  const builds = await get(`/builds?filter[app]=${a.id}&filter[preReleaseVersion.platform]=${PLATFORM}&sort=-uploadedDate&limit=10`);
  const build = builds.data.find((b) => b.attributes.processingState === "VALID");
  if (!build) { console.log(`no processed build yet (${builds.data.map((b) => b.attributes.version + ":" + b.attributes.processingState).join(", ") || "none"})`); process.exitCode = 2; return; }
  await patch(`/appStoreVersions/${v.id}/relationships/build`, { data: { type: "builds", id: build.id } });
  console.log(`attached build ${build.attributes.version} (${build.id})`);
}

async function submit() {
  const a = await app();
  const v = await version(a.id);
  if (["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE"].includes(v.attributes.appStoreState)) {
    console.log(`${VERSION}: already ${v.attributes.appStoreState}`); return;
  }
  const open = await get(`/apps/${a.id}/reviewSubmissions?filter[platform]=${PLATFORM}&filter[state]=READY_FOR_REVIEW&limit=5`);
  let sub = open.data[0];
  if (!sub) sub = (await post("/reviewSubmissions", { data: { type: "reviewSubmissions", attributes: { platform: PLATFORM }, relationships: { app: { data: { type: "apps", id: a.id } } } } })).data;
  const items = await get(`/reviewSubmissions/${sub.id}/items`);
  if (!items.data.length) {
    await post("/reviewSubmissionItems", { data: { type: "reviewSubmissionItems", relationships: { reviewSubmission: { data: { type: "reviewSubmissions", id: sub.id } }, appStoreVersion: { data: { type: "appStoreVersions", id: v.id } } } } });
  }
  await patch(`/reviewSubmissions/${sub.id}`, { data: { type: "reviewSubmissions", id: sub.id, attributes: { submitted: true } } });
  console.log(`submitted for review (${sub.id})`);
}

async function release() {
  const a = await app();
  const manual = process.argv.includes("--manual");
  const v = await version(a.id);
  await patch(`/appStoreVersions/${v.id}`, { data: { type: "appStoreVersions", id: v.id, attributes: { releaseType: manual ? "MANUAL" : "AFTER_APPROVAL" } } });
  console.log(`${VERSION}: release type set to ${manual ? "manual" : "automatic (after approval)"}`);
}

async function status() {
  const a = await app();
  console.log(`${a.attributes.name} (${a.id})`);
  const versions = await get(`/apps/${a.id}/appStoreVersions?filter[platform]=${PLATFORM}&limit=5`);
  for (const v of versions.data) console.log(`  ${v.attributes.versionString}: ${v.attributes.appStoreState}`);
  const builds = await get(`/builds?filter[app]=${a.id}&filter[preReleaseVersion.platform]=${PLATFORM}&sort=-uploadedDate&limit=5`);
  for (const b of builds.data) console.log(`    build ${b.attributes.version}: ${b.attributes.processingState}`);
  const subs = await get(`/apps/${a.id}/reviewSubmissions?filter[platform]=${PLATFORM}&limit=5`).catch(() => ({ data: [] }));
  for (const s of subs.data) console.log(`  submission ${s.id}: ${s.attributes.state}`);
}

const commands = { bundleid, metadata, prepare, screenshots, attach, submit, release, status };
const cmd = process.argv[2];
if (!commands[cmd]) { console.error("usage: node Tools/appstore.mjs bundleid|metadata|prepare|screenshots|attach|submit|release|status"); process.exit(1); }
await commands[cmd]();
