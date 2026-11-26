// web/firebase-messaging-sw.js

importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-auth-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDpBqnzHBdY_uti60LB2UQ0K1-XFgbNhAo",
  appId: "1:11267289622:web:41c4829ddbc2e36a73fb37",
  messagingSenderId: "11267289622",
  projectId: "islam-app-d6139",
  authDomain: "islam-app-d6139.firebaseapp.com",
  storageBucket: "islam-app-d6139.firebasestorage.app",
  databaseURL: "https://islam-app-d6139-default-rtdb.europe-west1.firebasedatabase.app/",
});

importScripts("staged-sync-sw.js");

const messaging = firebase.messaging();

// ============================================================
// IndexedDB helpers for badge count (shared with window)
// ============================================================
function openBadgeDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open("islam_badge_db", 1);
    req.onupgradeneeded = (e) => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains("badge")) {
        db.createObjectStore("badge");
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function getBadgeCount() {
  try {
    const db = await openBadgeDb();
    return new Promise((resolve) => {
      const tx = db.transaction("badge", "readonly");
      const req = tx.objectStore("badge").get("count");
      req.onsuccess = () => resolve(parseInt(req.result) || 0);
      req.onerror = () => resolve(0);
    });
  } catch (_) {
    return 0;
  }
}

// App-level "alerts muted" preference (written by the page, see index.html).
async function getAlertsMuted() {
  try {
    const db = await openBadgeDb();
    return await new Promise((resolve) => {
      const tx = db.transaction("badge", "readonly");
      const req = tx.objectStore("badge").get("muted");
      req.onsuccess = () => resolve(req.result === true);
      req.onerror = () => resolve(false);
    });
  } catch (_) {
    return false;
  }
}

async function putBadgeCount(count) {
  try {
    const db = await openBadgeDb();
    await new Promise((resolve) => {
      const tx = db.transaction("badge", "readwrite");
      tx.objectStore("badge").put(count, "count");
      tx.oncomplete = resolve;
      tx.onerror = resolve;
    });
  } catch (_) {}
}

async function updateAppBadge(count) {
  try {
    if (count > 0) {
      if (self.registration && "setAppBadge" in self.registration) {
        await self.registration.setAppBadge(count);
      } else if (self.navigator && "setAppBadge" in self.navigator) {
        await self.navigator.setAppBadge(count);
      }
    } else {
      if (self.registration && "clearAppBadge" in self.registration) {
        await self.registration.clearAppBadge();
      } else if (self.navigator && "clearAppBadge" in self.navigator) {
        await self.navigator.clearAppBadge();
      }
    }
  } catch (_) {}
}

// ============================================================
// Background message handler
// ============================================================
messaging.onBackgroundMessage(async (payload) => {
  console.log("[firebase-messaging-sw.js] Background message:", payload);

  const data = payload.data || {};
  const title = data.title || "IslamApp";
  const body = data.body || "";

  const notificationOptions = {
    body: body,
    icon: "/icons/Icon-192.png",
    badge: "/icons/Icon-192.png",
    dir: "rtl",
    lang: "ar",
    tag: data.event_id || "default",
    data: {
      type: data.type || "",
      section: data.section || "",
      action: data.action || "",
      event_id: data.event_id || "",
    },
  };

  // Quiet data-update push (the user's alert preference for this section is off): one generic
  // notice that replaces the previous one, always silent, not counted on the icon badge because
  // no inbox item exists for it.
  const quiet = data.quiet === "1";
  if (quiet) {
    notificationOptions.tag = "data-sync";
    notificationOptions.silent = true;
  }

  // ⭐ زيادة العدد على الأيقونة (فتح بقراءة العدد من IndexedDB، +1، حفظ، تحديث)
  if (!quiet) try {
    const oldCount = await getBadgeCount();
    const newCount = oldCount + 1;
    await putBadgeCount(newCount);
    await updateAppBadge(newCount);
  } catch (e) {
    console.warn("[SW] Badge increment failed:", e);
  }

  // Muted: still a normal visible notification (the platform requires one for
  // every push), only without sound or vibration. Never auto-closed.
  if (await getAlertsMuted()) {
    notificationOptions.silent = true;
  }
  const shown = self.registration.showNotification(title, notificationOptions);
  // Pre-download the daily changes. Failure only means the app syncs at open.
  let staged = Promise.resolve();
  try { staged = stagedSyncOnMessage(data).catch(() => {}); } catch (_) {}
  // Staging must finish even if showing fails (e.g. permission revoked).
  await Promise.allSettled([shown, staged]);
});

// ============================================================
// ⭐ Notification click → Deep Link
//
// حالتان:
//   A. التطبيق مفتوح → نبعت postMessage للتاب المفتوح
//   B. التطبيق مقفول → نفتح URL فيه ?notif=<json>
// ============================================================
self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const notifData = (event.notification && event.notification.data) || {};
  const payload = {
    section: notifData.section || "",
    action: notifData.action || "",
    type: notifData.type || "",
    event_id: notifData.event_id || "",
  };

  event.waitUntil(
    clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((clientList) => {
        // ─── A. التطبيق مفتوح ───
        for (const client of clientList) {
          try {
            if (
              client.url &&
              client.url.indexOf(location.origin) === 0 &&
              "postMessage" in client
            ) {
              client.postMessage({
                type: "deep_link",
                payload: payload,
              });
              if ("focus" in client) {
                return client.focus();
              }
            }
          } catch (_) {}
        }

        // ─── B. التطبيق مقفول → افتح URL فيه notif param ───
        const encoded = encodeURIComponent(JSON.stringify(payload));
        const targetUrl = "/?notif=" + encoded;

        if (clients.openWindow) {
          return clients.openWindow(targetUrl);
        }
      })
  );
});