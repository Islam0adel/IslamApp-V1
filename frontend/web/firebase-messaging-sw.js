// web/firebase-messaging-sw.js
//
// Service Worker يستقبل إشعارات FCM عندما يكون التطبيق
// مغلقاً أو في الخلفية (يُسجَّل تلقائياً بواسطة Firebase SDK).
//
// يعرض الإشعارات مستخدماً data-only messages (بدون notification payload)
// للحصول على تحكم كامل في المحتوى والأيقونة.

importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDpBqnzHBdY_uti60LB2UQ0K1-XFgbNhAo",
  appId: "1:11267289622:web:41c4829ddbc2e36a73fb37",
  messagingSenderId: "11267289622",
  projectId: "islam-app-d6139",
  authDomain: "islam-app-d6139.firebaseapp.com",
  storageBucket: "islam-app-d6139.firebasestorage.app",
  databaseURL: "https://islam-app-d6139-default-rtdb.europe-west1.firebasedatabase.app/",
});

const messaging = firebase.messaging();

// استقبل الرسائل في الخلفية واعرضها
messaging.onBackgroundMessage((payload) => {
  console.log("[firebase-messaging-sw.js] Background message:", payload);

  const data = payload.data || {};
  const title = data.title || "إشعار جديد";
  const body = data.body || "";

  const notificationOptions = {
    body: body,
    icon: "/icons/Icon-192.png",
    badge: "/icons/Icon-192.png",
    dir: "rtl",
    lang: "ar",
    // tag: يمنع تراكم إشعارات متعددة لنفس الحدث
    tag: data.event_id || "default",
    data: {
      type: data.type || "",
      section: data.section || "",
      action: data.action || "",
      event_id: data.event_id || "",
    },
  };

  self.registration.showNotification(title, notificationOptions);
});

// عند الضغط على إشعار → ركّز على التطبيق أو افتحه
self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  event.waitUntil(
    clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((clientList) => {
        // لو التطبيق مفتوح بالفعل → ركّز عليه
        for (const client of clientList) {
          if ("focus" in client) {
            return client.focus();
          }
        }
        // لو مقفول → افتحه
        if (clients.openWindow) {
          return clients.openWindow("/");
        }
      })
  );
});