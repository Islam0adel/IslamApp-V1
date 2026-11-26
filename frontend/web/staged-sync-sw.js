// web/staged-sync-sw.js
// Downloads the daily-journal changes when a push arrives and keeps them in a
// separate IndexedDB store. It never touches Hive. The app merges them at open.
// Pilot scope: daily journal (/transactions/changes). Failure always means
// "stage nothing", and the normal incremental sync at open covers it.

const SS_DB = "islam_staged_sync";
const SS_OVERLAP_MS = 60 * 1000;      // same 1 minute overlap the app uses
const SS_TIMEOUT_MS = 8000;
const SS_MAX_BATCHES = 50;            // bound the store; page drops on a hole
const SS_MODULES = new Set(["daily", "journal", ""]); // push `section` values that mean "daily changed"

function ssOpen() {
  return new Promise((res, rej) => {
    const r = indexedDB.open(SS_DB, 1);
    r.onupgradeneeded = () => {
      r.result.createObjectStore("batches");
      r.result.createObjectStore("meta");
    };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
// Scope check and batch write in ONE transaction, so a clear/scope change cannot slip in between them.
function ssPutIfScope(db, scopeKey, key, value) {
  return new Promise((res, rej) => {
    const t = db.transaction(["meta", "batches"], "readwrite");
    let ok = false;
    const g = t.objectStore("meta").get("scope");
    g.onsuccess = () => {
      const cur = g.result;
      if (cur && cur.scopeKey === scopeKey) { t.objectStore("batches").put(value, key); ok = true; }
    };
    t.oncomplete = () => res(ok);
    t.onerror = () => rej(t.error);
    t.onabort = () => rej(t.error);
  });
}
function ssReq(db, store, mode, fn) {
  return new Promise((res, rej) => {
    const t = db.transaction(store, mode);
    const out = fn(t.objectStore(store));
    t.oncomplete = () => res(out && out.result);
    t.onerror = () => rej(t.error);
  });
}

// The backend sends updated_at as UTC without a zone suffix. Date.parse would
// read that as local time, so a missing zone means UTC here.
function ssParse(v) {
  if (typeof v !== "string") return NaN;
  return Date.parse(/(Z|[+-]\d\d:?\d\d)$/.test(v) ? v : v + "Z");
}

let ssRunning = null, ssAgain = false;

// Bursts share one run plus at most one trailing run.
function stagedSyncOnMessage(data) {
  if (data && data.section === "treasury_transfers") return stagedSyncTreasury();
  if (data && data.section === "coding") return stagedSyncCoding();
  if (data && data.section === "hr_employees") return Promise.all([stagedSyncEmployees(), stagedSyncCommercial("hr-settings")]).then((r) => r[0]);
  if (data && data.section === "employees") return stagedSyncEmployees();
  if (data && (data.section === "purchases" || data.section === "supplier")) return stagedSyncSupplier();
  if (data && (data.section === "settlements" || data.section === "settlement")) return stagedSyncSettlement();
  if (data && data.section === "inventory") return stagedSyncInventory();
  if (data && SS_CM_SECTIONS[data.section]) return stagedSyncCommercial(SS_CM_SECTIONS[data.section]);
  if (!SS_MODULES.has((data && data.section) || "")) return Promise.resolve("skip-section");
  if (ssRunning) { ssAgain = true; return ssRunning; }
  ssRunning = (async () => {
    try {
      let result = await ssOnce();
      while (ssAgain) { ssAgain = false; result = await ssOnce(); }
      console.log("[staged-sync] result:", result);
      try { const d = await ssOpen(); await ssReq(d, "meta", "readwrite", (st) => st.put({ result, at: Date.now() }, "lastResult")); } catch (_) {}
      return result;
    } finally { ssRunning = null; }
  })();
  return ssRunning;
}

// Renew an expired ID token through the official Firebase Auth SDK running in the worker
// (https://firebase.google.com/docs/auth/web/service-worker-sessions). The SDK restores the
// signed-in user from the same IndexedDB the page uses and refreshes the token itself, so we
// never read Firebase's internal storage format. Only for the uid the app published.
let ssAuth = null;
function ssGetAuth(meta) {
  if (ssAuth) return ssAuth;
  if (typeof firebase === "undefined" || !firebase.auth) return null;
  ssAuth = firebase.auth();
  // Local emulator runs only: the page publishes an emulator securetoken URL.
  const m = /^(http:\/\/127\.0\.0\.1:9099)\//.exec(meta.refreshUrl || "");
  if (m) ssAuth.useEmulator(m[1]);
  return ssAuth;
}

async function ssRefreshToken(db, meta) {
  if (!meta.uid) return "token-expired";
  const auth = ssGetAuth(meta);
  if (!auth) return "refresh-sdk-missing";
  try {
    await new Promise((res) => { const un = auth.onAuthStateChanged(() => { un(); res(); }); });
    const u = auth.currentUser;
    if (!u || u.uid !== meta.uid) return "refresh-no-session";
    const tr = await Promise.race([u.getIdTokenResult(true),
      new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), SS_TIMEOUT_MS))]);
    // Sign-out or account switch while we were waiting: drop the new token.
    const cur = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
    if (!cur || cur.scopeKey !== meta.scopeKey || !auth.currentUser || auth.currentUser.uid !== meta.uid) return "scope-changed";
    const exp = Date.parse(tr.expirationTime);
    meta.token = tr.token; meta.tokenExp = exp;
    await ssReq(db, "meta", "readwrite", (s) => s.put({ ...cur, token: tr.token, tokenExp: exp }, "scope"));
    return "ok";
  } catch (e) { return "refresh-failed:" + String((e && (e.code || e.message)) || e).slice(0, 40); }
}

async function ssOnce() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(meta.scopeKey + "|")).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  if (meta.appCursorV2) return ssOnceV2(db, meta, mine);
  let cursor = meta.appCursor ? Date.parse(meta.appCursor) : NaN;
  if (isNaN(cursor)) return "no-app-cursor";        // app never finished a full sync here
  if (mine.length) {
    const last = await ssReq(db, "batches", "readonly", (s) => s.get(mine[mine.length - 1]));
    if (last && Date.parse(last.to) > cursor) cursor = Date.parse(last.to); // batch.to is always written as Z
  }
  const sinceUsed = new Date(cursor - SS_OVERLAP_MS).toISOString();
  let items;
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
    const resp = await fetch(`${meta.baseUrl}/transactions/changes/${encodeURIComponent(meta.company)}?since=${encodeURIComponent(sinceUsed)}`,
      { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
    clearTimeout(timer);
    if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
    if (resp.status !== 200) return "http-" + resp.status;
    items = await resp.json();
  } catch (_) { return "network"; }
  if (!Array.isArray(items) || items.length === 0) return "empty";
  let to = cursor;
  for (const it of items) { const t = ssParse(it.updated_at); if (!isNaN(t) && t > to) to = t; }
  if (to <= cursor) return "nothing-new";            // only overlap rows came back
  // The account may have changed while the request was running.
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  const id = String(Date.now()).padStart(15, "0") + "-" + Math.random().toString(36).slice(2, 6);
  if (!(await ssPutIfScope(db, meta.scopeKey, meta.scopeKey + "|" + id,
    { id, scopeKey: meta.scopeKey, sinceUsed, to: new Date(to).toISOString(), items }))) return "scope-changed";
  return "staged:" + items.length;
}

// ---- commit-safe feed (/transactions/changes-v2), cursor "tx:id" ----
function ssCmp(a, b) {
  const [a1, a2] = String(a).split(":").map(BigInt), [b1, b2] = String(b).split(":").map(BigInt);
  return a1 !== b1 ? (a1 < b1 ? -1 : 1) : (a2 === b2 ? 0 : (a2 < b2 ? -1 : 1));
}

async function ssOnceV2(db, meta, mine) {
  let cur = meta.appCursorV2;
  if (mine.length) {
    const last = await ssReq(db, "batches", "readonly", (s) => s.get(mine[mine.length - 1]));
    if (last && last.toCursor && ssCmp(last.toCursor, cur) > 0) cur = last.toCursor;
  }
  const fromCursor = cur;
  const items = [];
  let fpr = "";
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}/transactions/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cur)}&limit=200&scope=${encodeURIComponent(meta.appScopeV2 || "")}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      for (const it of body.items || []) items.push(it);
      cur = String(body.next_cursor);
      if (body.scope) fpr = String(body.scope);
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (items.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  const id = String(Date.now()).padStart(15, "0") + "-" + Math.random().toString(36).slice(2, 6);
  if (!(await ssPutIfScope(db, meta.scopeKey, meta.scopeKey + "|" + id,
    { id, scopeKey: meta.scopeKey, fromCursor, toCursor: cur, fingerprint: fpr || meta.appScopeV2 || "", items }))) return "scope-changed";
  return "staged-v2:" + items.length;
}

// ---- treasury transfers (/treasury-transfers/changes/records), cursor = server revision ----
// The raw response is stored per cursor step. The page applies it through the same validation code
// as its live refresh, against the permission it has at open time. Batch keys start with "tt:" so
// the daily reader (prefix scopeKey + "|") never sees them.
let ssTtRunning = null, ssTtAgain = false;
function stagedSyncTreasury() {
  if (ssTtRunning) { ssTtAgain = true; return ssTtRunning; }
  ssTtRunning = (async () => {
    try {
      let result = await ssOnceTreasury();
      while (ssTtAgain) { ssTtAgain = false; result = await ssOnceTreasury(); }
      console.log("[staged-sync] treasury result:", result);
      return result;
    } finally { ssTtRunning = null; }
  })();
  return ssTtRunning;
}

let ssTtSeq = 0;
async function ssOnceTreasury() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  // The app publishes these only after a valid treasury snapshot exists under read permission.
  if (!Number.isInteger(meta.ttCursor) || typeof meta.ttScope !== "string" || !meta.ttScope) return "no-tt-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = "tt:" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta.ttCursor, scope = meta.ttScope;
  // Chain order comes from cursor continuity (each batch starts where the previous one ended),
  // never from key order, so equal timestamps or a restarted counter cannot reorder it.
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        const r = b.response;
        if (!Number.isInteger(r.cursor) || typeof r.scope !== "string") continue;
        used.add(b.id); cursor = r.cursor; scope = r.scope; again = true; break;
      }
    }
  }
  let body;
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
    const resp = await fetch(`${meta.baseUrl}/treasury-transfers/changes/records/${encodeURIComponent(meta.company)}?cursor=${cursor}&scope=${encodeURIComponent(scope)}`,
      { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
    clearTimeout(timer);
    if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
    if (resp.status !== 200) return "http-" + resp.status;
    body = await resp.json();
  } catch (_) { return "network"; }
  if (!body || body.protocol !== 2 || !Number.isInteger(body.cursor) || typeof body.scope !== "string" || !Array.isArray(body.items)) return "bad-response";
  if (body.items.length === 0 && body.reset !== true) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  // Unique even for equal timestamps or a restarted counter. Order is not taken from this id.
  const id = String(Date.now()).padStart(15, "0") + "-" + String(++ssTtSeq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
  if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
    { id, scopeKey: meta.scopeKey, module: "treasury_transfers", fromCursor: cursor, fromScope: scope, response: body }))) return "scope-changed";
  return "staged-tt:" + body.items.length;
}

// ---- coding catalog (/coding/changes-v2), cursor "tx:id" + scope fingerprint ----
// One stored batch per fetched page, chained by cursor continuity (fromCursor/fromScope -> response
// next_cursor/scope). Keys start with "cd:" so the daily and treasury readers never see them.
let ssCdRunning = null, ssCdAgain = false;
function stagedSyncCoding() {
  if (ssCdRunning) { ssCdAgain = true; return ssCdRunning; }
  ssCdRunning = (async () => {
    try {
      let result = await ssOnceCoding();
      while (ssCdAgain) { ssCdAgain = false; result = await ssOnceCoding(); }
      console.log("[staged-sync] coding result:", result);
      return result;
    } finally { ssCdRunning = null; }
  })();
  return ssCdRunning;
}

let ssCdSeq = 0;
async function ssOnceCoding() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  if (typeof meta.codCursor !== "string" || !meta.codCursor || typeof meta.codScope !== "string" || !meta.codScope) return "no-cod-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = "cd:" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta.codCursor;
  const scope = meta.codScope;
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        if (typeof b.response.next_cursor !== "string" || b.response.scope !== scope) continue;
        used.add(b.id); cursor = b.response.next_cursor; again = true; break;
      }
    }
  }
  const staged = [];
  let total = 0;
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}/coding/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cursor)}&limit=200&scope=${encodeURIComponent(scope)}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      if (!body || !Array.isArray(body.items) || typeof body.next_cursor !== "string" || body.scope !== scope) return "bad-response";
      if (body.items.length === 0 && !body.has_more) break;   // nothing new: the cursor alone is not staged
      staged.push({ fromCursor: cursor, response: body });
      total += body.items.length;
      cursor = body.next_cursor;
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (staged.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  for (const b of staged) {
    const id = String(Date.now()).padStart(15, "0") + "-" + String(++ssCdSeq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
    if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
      { id, scopeKey: meta.scopeKey, module: "coding", fromCursor: b.fromCursor, fromScope: scope, response: b.response }))) return "scope-changed";
  }
  return "staged-cd:" + total;
}

// ---- employees (/employees/changes-v2), cursor "tx:id" + scope fingerprint ----
// One stored batch per fetched page, chained by cursor continuity (fromCursor/fromScope -> response
// next_cursor/scope). Keys start with "em:" so the other readers never see them.
let ssEmRunning = null, ssEmAgain = false;
function stagedSyncEmployees() {
  if (ssEmRunning) { ssEmAgain = true; return ssEmRunning; }
  ssEmRunning = (async () => {
    try {
      let result = await ssOnceEmployees();
      while (ssEmAgain) { ssEmAgain = false; result = await ssOnceEmployees(); }
      console.log("[staged-sync] employees result:", result);
      return result;
    } finally { ssEmRunning = null; }
  })();
  return ssEmRunning;
}

let ssEmSeq = 0;
async function ssOnceEmployees() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  if (typeof meta.empCursor !== "string" || !meta.empCursor || typeof meta.empScope !== "string" || !meta.empScope) return "no-emp-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = "em:" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta.empCursor;
  const scope = meta.empScope;
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        if (typeof b.response.next_cursor !== "string" || b.response.scope !== scope) continue;
        used.add(b.id); cursor = b.response.next_cursor; again = true; break;
      }
    }
  }
  const staged = [];
  let total = 0;
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}/employees/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cursor)}&limit=200&scope=${encodeURIComponent(scope)}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      if (!body || !Array.isArray(body.items) || typeof body.next_cursor !== "string" || body.scope !== scope) return "bad-response";
      if (body.items.length === 0 && !body.has_more) break;   // nothing new: the cursor alone is not staged
      staged.push({ fromCursor: cursor, response: body });
      total += body.items.length;
      cursor = body.next_cursor;
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (staged.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  for (const b of staged) {
    const id = String(Date.now()).padStart(15, "0") + "-" + String(++ssEmSeq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
    if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
      { id, scopeKey: meta.scopeKey, module: "employees", fromCursor: b.fromCursor, fromScope: scope, response: b.response }))) return "scope-changed";
  }
  return "staged-em:" + total;
}

// ---- supplier (/supplier/changes-v2), cursor "tx:id" + scope fingerprint ----
// One stored batch per fetched page, chained by cursor continuity (fromCursor/fromScope -> response
// next_cursor/scope). Keys start with "sp:" so the other readers never see them.
let ssSpRunning = null, ssSpAgain = false;
function stagedSyncSupplier() {
  if (ssSpRunning) { ssSpAgain = true; return ssSpRunning; }
  ssSpRunning = (async () => {
    try {
      let result = await ssOnceSupplier();
      while (ssSpAgain) { ssSpAgain = false; result = await ssOnceSupplier(); }
      console.log("[staged-sync] supplier result:", result);
      return result;
    } finally { ssSpRunning = null; }
  })();
  return ssSpRunning;
}

let ssSpSeq = 0;
async function ssOnceSupplier() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  if (typeof meta.supCursor !== "string" || !meta.supCursor || typeof meta.supScope !== "string" || !meta.supScope) return "no-sup-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = "sp:" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta.supCursor;
  const scope = meta.supScope;
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        if (typeof b.response.next_cursor !== "string" || b.response.scope !== scope) continue;
        used.add(b.id); cursor = b.response.next_cursor; again = true; break;
      }
    }
  }
  const staged = [];
  let total = 0;
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}/supplier/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cursor)}&limit=200&scope=${encodeURIComponent(scope)}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      if (!body || !Array.isArray(body.items) || typeof body.next_cursor !== "string" || body.scope !== scope) return "bad-response";
      if (body.items.length === 0 && !body.has_more) break;   // nothing new: the cursor alone is not staged
      staged.push({ fromCursor: cursor, response: body });
      total += body.items.length;
      cursor = body.next_cursor;
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (staged.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  for (const b of staged) {
    const id = String(Date.now()).padStart(15, "0") + "-" + String(++ssSpSeq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
    if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
      { id, scopeKey: meta.scopeKey, module: "supplier", fromCursor: b.fromCursor, fromScope: scope, response: b.response }))) return "scope-changed";
  }
  return "staged-sp:" + total;
}

// ---- inventory (/inventory/changes-v2), cursor "tx:id" + scope fingerprint ----
// One stored batch per fetched page, chained by cursor continuity (fromCursor/fromScope -> response
// next_cursor/scope). Keys start with "iv:" so the other readers never see them.
let ssIvRunning = null, ssIvAgain = false;
function stagedSyncInventory() {
  if (ssIvRunning) { ssIvAgain = true; return ssIvRunning; }
  ssIvRunning = (async () => {
    try {
      let result = await ssOnceInventory();
      while (ssIvAgain) { ssIvAgain = false; result = await ssOnceInventory(); }
      console.log("[staged-sync] inventory result:", result);
      return result;
    } finally { ssIvRunning = null; }
  })();
  return ssIvRunning;
}

let ssIvSeq = 0;
async function ssOnceInventory() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  if (typeof meta.invCursor !== "string" || !meta.invCursor || typeof meta.invScope !== "string" || !meta.invScope) return "no-inv-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = "iv:" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta.invCursor;
  const scope = meta.invScope;
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        if (typeof b.response.next_cursor !== "string" || b.response.scope !== scope) continue;
        used.add(b.id); cursor = b.response.next_cursor; again = true; break;
      }
    }
  }
  const staged = [];
  let total = 0;
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}/inventory/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cursor)}&limit=200&scope=${encodeURIComponent(scope)}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      if (!body || !Array.isArray(body.items) || typeof body.next_cursor !== "string" || body.scope !== scope) return "bad-response";
      if (body.items.length === 0 && !body.has_more) break;   // nothing new: the cursor alone is not staged
      staged.push({ fromCursor: cursor, response: body });
      total += body.items.length;
      cursor = body.next_cursor;
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (staged.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  for (const b of staged) {
    const id = String(Date.now()).padStart(15, "0") + "-" + String(++ssIvSeq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
    if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
      { id, scopeKey: meta.scopeKey, module: "inventory", fromCursor: b.fromCursor, fromScope: scope, response: b.response }))) return "scope-changed";
  }
  return "staged-iv:" + total;
}

// ---- commercial feeds (/commercial/{kind}/changes-v2): sales, returns, customer payments, transfers ----
// Same chaining as inventory. The cursor is opaque ("tx:" or "tx:i<id>"). Keys: c1: sales, c2: returns,
// c3: customer payments, c4: transfers.
const SS_CM_SECTIONS = { sales: "sales", sales_returns: "returns", customer_payments: "customer-payments", stock_transfers: "transfers", hr_attendance: "hr-attendance", hr_vacations: "hr-vacations", hr_adjustments: "hr-adjustments" };
const SS_CM = { "sales": "c1", "returns": "c2", "customer-payments": "c3", "transfers": "c4", "hr-attendance": "c5", "hr-vacations": "c6", "hr-adjustments": "c7", "hr-settings": "c8" };
const SS_HR_ROUTES = { "hr-attendance": "/hr/attendance", "hr-vacations": "/hr/vacations", "hr-adjustments": "/hr/adjustments", "hr-settings": "/hr/employee-settings" };
const ssCmState = {};
function stagedSyncCommercial(kind) {
  const st = ssCmState[kind] || (ssCmState[kind] = { running: null, again: false, seq: 0 });
  if (st.running) { st.again = true; return st.running; }
  st.running = (async () => {
    try {
      let result = await ssOnceCommercial(kind, st);
      while (st.again) { st.again = false; result = await ssOnceCommercial(kind, st); }
      console.log("[staged-sync] commercial " + kind + " result:", result);
      return result;
    } finally { st.running = null; }
  })();
  return st.running;
}

async function ssOnceCommercial(kind, st) {
  const pf = SS_CM[kind];
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  const curKey = pf + "Cursor", scKey = pf + "Scope";
  if (typeof meta[curKey] !== "string" || typeof meta[scKey] !== "string" || !meta[scKey]) return "no-cm-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = pf + ":" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta[curKey];
  const scope = meta[scKey];
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        if (typeof b.response.next_cursor !== "string" || b.response.scope !== scope) continue;
        used.add(b.id); cursor = b.response.next_cursor; again = true; break;
      }
    }
  }
  const staged = [];
  let total = 0;
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}${SS_HR_ROUTES[kind] || "/commercial/" + kind}/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cursor)}&limit=200&scope=${encodeURIComponent(scope)}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      if (!body || !Array.isArray(body.items) || typeof body.next_cursor !== "string" || body.scope !== scope) return "bad-response";
      if (body.items.length === 0 && !body.has_more) break;   // nothing new: the cursor alone is not staged
      staged.push({ fromCursor: cursor, response: body });
      total += body.items.length;
      cursor = body.next_cursor;
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (staged.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  for (const b of staged) {
    const id = String(Date.now()).padStart(15, "0") + "-" + String(++st.seq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
    if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
      { id, scopeKey: meta.scopeKey, module: kind, fromCursor: b.fromCursor, fromScope: scope, response: b.response }))) return "scope-changed";
  }
  return "staged-" + pf + ":" + total;
}

// ---- settlement (/supplier-settlement/changes-v2), cursor "tx:id" + scope fingerprint ----
// One stored batch per fetched page, chained by cursor continuity (fromCursor/fromScope -> response
// next_cursor/scope). Keys start with "sl:" so the other readers never see them.
let ssSlRunning = null, ssSlAgain = false;
function stagedSyncSettlement() {
  if (ssSlRunning) { ssSlAgain = true; return ssSlRunning; }
  ssSlRunning = (async () => {
    try {
      let result = await ssOnceSettlement();
      while (ssSlAgain) { ssSlAgain = false; result = await ssOnceSettlement(); }
      console.log("[staged-sync] settlement result:", result);
      return result;
    } finally { ssSlRunning = null; }
  })();
  return ssSlRunning;
}

let ssSlSeq = 0;
async function ssOnceSettlement() {
  let db;
  try { db = await ssOpen(); } catch (_) { return "no-db"; }
  const meta = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!meta || !meta.scopeKey || !meta.token || !meta.baseUrl || !meta.company) return "no-scope";
  if (typeof meta.setCursor !== "string" || !meta.setCursor || typeof meta.setScope !== "string" || !meta.setScope) return "no-set-cursor";
  if (!(meta.tokenExp > Date.now() + 30000)) {
    const r = await ssRefreshToken(db, meta);
    if (r !== "ok") return r;
  }
  const prefix = "sl:" + meta.scopeKey + "|";
  const keys = await ssReq(db, "batches", "readonly", (s) => s.getAllKeys());
  const mine = (keys || []).filter((k) => String(k).startsWith(prefix)).sort();
  if (mine.length >= SS_MAX_BATCHES) return "store-full";
  let cursor = meta.setCursor;
  const scope = meta.setScope;
  if (mine.length) {
    const all = [];
    for (const k of mine) { const b = await ssReq(db, "batches", "readonly", (s) => s.get(k)); if (b && b.response) all.push(b); }
    const used = new Set();
    for (let again = true; again;) {
      again = false;
      for (const b of all) {
        if (used.has(b.id) || b.fromCursor !== cursor || b.fromScope !== scope) continue;
        if (typeof b.response.next_cursor !== "string" || b.response.scope !== scope) continue;
        used.add(b.id); cursor = b.response.next_cursor; again = true; break;
      }
    }
  }
  const staged = [];
  let total = 0;
  try {
    for (let page = 0; page < 5; page++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), SS_TIMEOUT_MS);
      const resp = await fetch(`${meta.baseUrl}/supplier-settlement/changes-v2/${encodeURIComponent(meta.company)}?cursor=${encodeURIComponent(cursor)}&limit=200&scope=${encodeURIComponent(scope)}`,
        { headers: { Authorization: "Bearer " + meta.token }, signal: ctl.signal });
      clearTimeout(timer);
      if (resp.status === 401 || resp.status === 403) return "auth-" + resp.status;
      if (resp.status !== 200) return "http-" + resp.status;
      const body = await resp.json();
      if (body.invalid) return body.reason === "scope" ? "scope-invalid" : "cursor-invalid";
      if (!body || !Array.isArray(body.items) || typeof body.next_cursor !== "string" || body.scope !== scope) return "bad-response";
      if (body.items.length === 0 && !body.has_more) break;   // nothing new: the cursor alone is not staged
      staged.push({ fromCursor: cursor, response: body });
      total += body.items.length;
      cursor = body.next_cursor;
      if (!body.has_more) break;
    }
  } catch (_) { return "network"; }
  if (staged.length === 0) return "empty";
  const now = await ssReq(db, "meta", "readonly", (s) => s.get("scope"));
  if (!now || now.scopeKey !== meta.scopeKey) return "scope-changed";
  for (const b of staged) {
    const id = String(Date.now()).padStart(15, "0") + "-" + String(++ssSlSeq).padStart(6, "0") + "-" + Math.random().toString(36).slice(2, 6);
    if (!(await ssPutIfScope(db, meta.scopeKey, prefix + id,
      { id, scopeKey: meta.scopeKey, module: "settlement", fromCursor: b.fromCursor, fromScope: scope, response: b.response }))) return "scope-changed";
  }
  return "staged-sl:" + total;
}
