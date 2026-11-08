import firebase_admin
from firebase_admin import credentials, firestore
import os
import json

def setup_firebase():
    try:
        # منع تكرار الـ initialization
        if not firebase_admin._apps:
            
            # 1. المحاولة الأولى: البحث عن "Secret" في إعدادات السيرفر (Hugging Face / Vercel)
            firebase_keys_json = os.getenv("FIREBASE_KEYS")
            
            if firebase_keys_json:
                print("✅ Firebase: Loading from Environment Secrets (Cloud)...")
                key_dict = json.loads(firebase_keys_json)
                cred = credentials.Certificate(key_dict)
            
            else:
                # 2. المحاولة الثانية: العمل محلياً (Local) من خلال ملف الـ JSON
                print("🏠 Firebase: Loading from local JSON file...")
                
                base_dir = os.path.dirname(os.path.abspath(__file__))
                local_key_path = os.path.join(base_dir, "serviceAccountKey.json")
                
                if not os.path.exists(local_key_path):
                    local_key_path = os.path.join(base_dir, "../../serviceAccountKey.json")

                if os.path.exists(local_key_path):
                    cred = credentials.Certificate(local_key_path)
                    print(f"✅ تم تحميل الملف المحلي من: {local_key_path}")
                else:
                    raise FileNotFoundError("❌ لم يتم العثور على ملف المفاتيح لا في السكرت ولا محلياً!")

            firebase_admin.initialize_app(cred)
            
        return firestore.client()
        
    except Exception as e:
        print(f"⚠️ خطأ في الاتصال بفايربيز: {e}")
        return None


# تصدير كائن db ليتم استخدامه في auth.py وباقي الأجزاء
db = setup_firebase()


# ⭐ expose the default app for FCM (used by firebase_admin.messaging)
# لو الـ init نجح، الـ app موجود → FCM سيعمل تلقائياً بنفس الـ credentials.
firebase_app = None
try:
    if firebase_admin._apps:
        firebase_app = firebase_admin.get_app()
        print("✅ Firebase Admin app is ready for FCM messaging")
    else:
        print("⚠️ Firebase Admin app NOT initialized — FCM disabled")
except Exception as _e:
    print(f"⚠️ Firebase app not available for messaging: {_e}")