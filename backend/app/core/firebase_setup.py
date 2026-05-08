import firebase_admin
from firebase_admin import credentials, firestore
import os
import json

def setup_firebase():
    try:
        # منع تكرار الـ initialization
        if not firebase_admin._apps:
            
            # 1. المحاولة الأولى: البحث عن "Secret" في إعدادات السيرفر (Hugging Face / Vercel)
            # تأكد إنك مسمي السكرت في المواقع دي باسم FIREBASE_KEYS
            firebase_keys_json = os.getenv("FIREBASE_KEYS")
            
            if firebase_keys_json:
                print("✅ Firebase: Loading from Environment Secrets (Cloud)...")
                # تحويل النص لقاموس واستخدامه مباشرة
                key_dict = json.loads(firebase_keys_json)
                cred = credentials.Certificate(key_dict)
            
            else:
                # 2. المحاولة الثانية: العمل محلياً (Local) من خلال ملف الـ JSON
                print("🏠 Firebase: Loading from local JSON file...")
                
                # تحديد المسار الحالي للملف
                base_dir = os.path.dirname(os.path.abspath(__file__))
                # بنجرب المسارين اللي انت كنت مستخدمهم لضمان الوصول للملف
                local_key_path = os.path.join(base_dir, "serviceAccountKey.json")
                
                if not os.path.exists(local_key_path):
                    # لو مش جنبه، جرب تطلع مستوى لفوق (حسب هيكلة الفولدرات عندك)
                    local_key_path = os.path.join(base_dir, "../../serviceAccountKey.json")

                if os.path.exists(local_key_path):
                    cred = credentials.Certificate(local_key_path)
                    print(f"✅ تم تحميل الملف المحلي من: {local_key_path}")
                else:
                    raise FileNotFoundError("❌ لم يتم العثور على ملف المفاتيح لا في السكرت ولا محلياً!")

            # تشغيل الربط
            firebase_admin.initialize_app(cred)
            
        return firestore.client()
        
    except Exception as e:
        print(f"⚠️ خطأ في الاتصال بفايربيز: {e}")
        return None

# تصدير كائن db ليتم استخدامه في auth.py وباقي الأجزاء
db = setup_firebase()