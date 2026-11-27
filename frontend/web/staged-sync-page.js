// frontend/web/staged-sync-page.js
// Page side of the staged-sync store (same IndexedDB the service worker uses).
// كائن stagedSync على نافذة الصفحة: يقرأ ويمسح التغييرات المؤقتة التي خزّنها الـservice worker
window.stagedSync = (function () {
  // اسم قاعدة IndexedDB المشتركة مع الـservice worker
  const DB = "islam_staged_sync";

  // يفتح قاعدة IndexedDB
  function open() {
    return new Promise((res, rej) => {
      const r = indexedDB.open(DB, 1);
      r.onupgradeneeded = () => {
        r.result.createObjectStore("batches");
        r.result.createObjectStore("meta");
      };
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    });
  }

  // يشغّل طلب على مخزن في القاعدة ويعيد نتيجته
  function rq(db, store, mode, fn) {
    return new Promise((res, rej) => {
      const t = db.transaction(store, mode);
      const o = fn(t.objectStore(store));
      t.oncomplete = () => res(o && o.result);
      t.onerror = () => rej(t.error);
    });
  }

  // يمسح الدفعات القديمة ويُبقي المطلوب فقط
  async function purge(db, keep) {
    const keys = await rq(db, "batches", "readonly", (s) => s.getAllKeys());
    const drop = (keys || []).filter((k) => !keep || !(String(k).startsWith(keep + "|") || String(k).startsWith("tt:" + keep + "|") || String(k).startsWith("cd:" + keep + "|") || String(k).startsWith("em:" + keep + "|") || String(k).startsWith("sp:" + keep + "|") || String(k).startsWith("sl:" + keep + "|") || String(k).startsWith("iv:" + keep + "|") || String(k).startsWith("c1:" + keep + "|") || String(k).startsWith("c2:" + keep + "|") || String(k).startsWith("c3:" + keep + "|") || String(k).startsWith("c4:" + keep + "|") || String(k).startsWith("c5:" + keep + "|") || String(k).startsWith("c6:" + keep + "|") || String(k).startsWith("c7:" + keep + "|") || String(k).startsWith("c8:" + keep + "|")));
    if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
  }

  // Startup prefetch: runs while Flutter boots. The first read() of this page load may use it (once);
  // any write drops it. peekCount() answers "is anything staged for this scope" without a new read.
  // قراءة مسبقة للدفعات تبدأ عند فتح الصفحة
  let pre = null;

  // يقرأ كل الدفعات المخزّنة
  async function readAll() {
    const db = await open();
    const keys = ((await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || []).slice().sort();
    const out = [];
    for (const k of keys) out.push([String(k), await rq(db, "batches", "readonly", (s) => s.get(k))]);
    return out;
  }
  try { pre = readAll(); pre.catch(() => {}); } catch (e) { pre = null; }
  return {
    // يعيد عدد الدفعات المنتظرة لنطاق معين (أو -1 إذا لم تكن جاهزة)
    async peekCount(scopeKey) {
      if (!pre) return -1;
      try {
        const all = await pre;
        return all.filter((e) => e[0].startsWith(scopeKey + "|") || e[0].startsWith("tt:" + scopeKey + "|") || e[0].startsWith("cd:" + scopeKey + "|") || e[0].startsWith("em:" + scopeKey + "|") || e[0].startsWith("sp:" + scopeKey + "|") || e[0].startsWith("sl:" + scopeKey + "|") || e[0].startsWith("iv:" + scopeKey + "|") || e[0].startsWith("c1:" + scopeKey + "|") || e[0].startsWith("c2:" + scopeKey + "|") || e[0].startsWith("c3:" + scopeKey + "|") || e[0].startsWith("c4:" + scopeKey + "|") || e[0].startsWith("c5:" + scopeKey + "|") || e[0].startsWith("c6:" + scopeKey + "|") || e[0].startsWith("c7:" + scopeKey + "|") || e[0].startsWith("c8:" + scopeKey + "|")).length;
      } catch (e) { return -1; }
    },
    // metaJson: {scopeKey, baseUrl, company, token, tokenExp(ms), appCursor(ISO)}
    // Also deletes every batch that belongs to a different scope.
    // ينشر بيانات النطاق (المستخدم والرمز والمؤشر) للـservice worker
    async publish(metaJson) {
      pre = null;
      const db = await open();
      const meta = JSON.parse(metaJson);
      // A publish built before the last clearAll (sign-out, account switch) must not
      // resurrect the old scope: issuedAt is taken before the token is requested.
      // The freshness check and the scope write happen in one transaction, so a clearAll cannot
      // interleave between them and leave a stale scope live.
      const accepted = await new Promise((res, rej) => {
        const t = db.transaction("meta", "readwrite");
        const s = t.objectStore("meta");
        let ok = false;
        const g = s.get("clearedAt");
        g.onsuccess = () => {
          const clearedAt = g.result || 0;
          if (meta.issuedAt && clearedAt < meta.issuedAt) { s.put(meta, "scope"); ok = true; }
        };
        t.oncomplete = () => res(ok);
        t.onerror = () => rej(t.error);
        t.onabort = () => rej(t.error);
      });
      if (!accepted) return false;
      await purge(db, meta.scopeKey);
      return true;
    },
    // Owner-scoped clear: drops the staged scope only when it belongs to this uid and company.
    // A different account's staged data (or an unreadable scope with another owner) is left alone.
    // يمسح دفعات المستخدم والشركة لليومية
    async clearFor(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      await rq(db, "meta", "readwrite", (s) => { s.delete("scope"); s.put(Date.now(), "clearedAt"); return null; });
      await purge(db, null);
      return true;
    },
    // Drops only the treasury module batches (read right for treasury transfers was lost).
    // يمسح دفعات الخزائن للمستخدم والشركة
    async clearTreasury(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith("tt:"));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // Drops only the coding catalog batches (coding read right or cost right was lost).
    // يمسح دفعات الكودنج للمستخدم والشركة
    async clearCoding(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith("cd:"));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // يمسح كل الدفعات المخزّنة
    async clearAll() {
      pre = null;
      const db = await open();
      await rq(db, "meta", "readwrite", (s) => { s.delete("scope"); s.put(Date.now(), "clearedAt"); return null; });
      await purge(db, null);
      return true;
    },
    // يقرأ دفعات اليومية للنطاق
    async read(scopeKey) {
      if (pre) {
        const p = pre;
        pre = null;
        try {
          const all = await p;
          return JSON.stringify(all.filter((e) => e[0].startsWith(scopeKey + "|")).map((e) => e[1]));
        } catch (e) { /* fall through to a normal read */ }
      }
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith(scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // Treasury module batches (key prefix "tt:"), kept apart from the daily reader.
    // يقرأ دفعات الخزائن للنطاق
    async readTreasury(scopeKey) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith("tt:" + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يقرأ دفعات الكودنج للنطاق
    async readCoding(scopeKey) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith("cd:" + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يزيل دفعات كودنج معينة بعد دمجها
    async removeCoding(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete("cd:" + scopeKey + "|" + i)); return null; });
      return true;
    },
    // Drops only the employee batches (employees read right, HR or salary right was lost).
    // يمسح دفعات الموظفين للمستخدم والشركة
    async clearEmployees(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith("em:"));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // يقرأ دفعات الموظفين للنطاق
    async readEmployees(scopeKey) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith("em:" + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يزيل دفعات موظفين معينة بعد دمجها
    async removeEmployees(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete("em:" + scopeKey + "|" + i)); return null; });
      return true;
    },
    // Drops only the supplier batches (supplier read right or cost right was lost).
    // يمسح دفعات الموردين للمستخدم والشركة
    async clearSupplier(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith("sp:"));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // يقرأ دفعات الموردين للنطاق
    async readSupplier(scopeKey) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith("sp:" + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يزيل دفعات موردين معينة بعد دمجها
    async removeSupplier(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete("sp:" + scopeKey + "|" + i)); return null; });
      return true;
    },
    // Drops only the inventory batches (inventory read right or cost right was lost).
    // يمسح دفعات المخزون للمستخدم والشركة
    async clearInventory(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith("iv:"));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // يقرأ دفعات المخزون للنطاق
    async readInventory(scopeKey) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith("iv:" + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يزيل دفعات مخزون معينة بعد دمجها
    async removeInventory(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete("iv:" + scopeKey + "|" + i)); return null; });
      return true;
    },
    // Commercial feeds (sales c1:, returns c2:, customer payments c3:, transfers c4:): one generic set.
    // يمسح دفعات قسم تجاري أو موارد بشرية حسب البادئة
    async clearCommercial(uid, company, pfx) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith(pfx));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // يقرأ دفعات قسم تجاري أو موارد بشرية حسب البادئة
    async readCommercial(scopeKey, pfx) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith(pfx + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يزيل دفعات تجارية معينة بعد دمجها
    async removeCommercial(scopeKey, pfx, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete(pfx + scopeKey + "|" + i)); return null; });
      return true;
    },
    // Drops only the settlement batches (settlement read right or cost right was lost).
    // يمسح دفعات التسويات للمستخدم والشركة
    async clearSettlement(uid, company) {
      pre = null;
      const db = await open();
      const sc = await rq(db, "meta", "readonly", (s) => s.get("scope"));
      if (sc && (sc.uid !== uid || sc.company !== company)) return false;
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const drop = keys.filter((k) => String(k).startsWith("sl:"));
      if (drop.length) await rq(db, "batches", "readwrite", (s) => { drop.forEach((k) => s.delete(k)); return null; });
      return true;
    },
    // يقرأ دفعات التسويات للنطاق
    async readSettlement(scopeKey) {
      pre = null;
      const db = await open();
      const keys = (await rq(db, "batches", "readonly", (s) => s.getAllKeys())) || [];
      const out = [];
      for (const k of keys.filter((k) => String(k).startsWith("sl:" + scopeKey + "|")).sort())
        out.push(await rq(db, "batches", "readonly", (s) => s.get(k)));
      return JSON.stringify(out);
    },
    // يزيل دفعات تسويات معينة بعد دمجها
    async removeSettlement(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete("sl:" + scopeKey + "|" + i)); return null; });
      return true;
    },
    // يزيل دفعات خزائن معينة بعد دمجها
    async removeTreasury(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete("tt:" + scopeKey + "|" + i)); return null; });
      return true;
    },
    // يزيل دفعات اليومية المعينة بعد دمجها
    async remove(scopeKey, idsJson) {
      pre = null;
      const db = await open();
      const ids = JSON.parse(idsJson);
      await rq(db, "batches", "readwrite", (s) => { ids.forEach((i) => s.delete(scopeKey + "|" + i)); return null; });
      return true;
    },
    // يسجّل فشل تطبيق دفعة ويعيد عدد مرات الفشل
    async recordFailure(scopeKey, id) {
      const db = await open();
      const key = "fail|" + scopeKey + "|" + id;
      const n = ((await rq(db, "meta", "readonly", (s) => s.get(key))) || 0) + 1;
      await rq(db, "meta", "readwrite", (s) => s.put(n, key));
      return n;
    },
  };
})();
