import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError('DefaultFirebaseOptions are not supported for this platform.');
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: "AIzaSyDpBqnzHBdY_uti60LB2UQ0K1-XFgbNhAo",
    appId: "1:11267289622:web:41c4829ddbc2e36a73fb37",
    messagingSenderId: "11267289622",
    projectId: "islam-app-d6139",
    authDomain: "islam-app-d6139.firebaseapp.com",
    storageBucket: "islam-app-d6139.firebasestorage.app",
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'اكتب_الـ_API_Key_بتاع_الأندرويد',
    appId: 'اكتب_الـ_App_Id_بتاع_الأندرويد',
    messagingSenderId: 'رقم_المرسل',
    projectId: 'islam-app-v1',
    storageBucket: 'islam-app-v1.appspot.com',
  );
}