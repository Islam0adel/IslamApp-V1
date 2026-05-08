import firebase_admin
from firebase_admin import credentials, firestore
import os

# تحديد المسار بدقة
base_dir = os.path.dirname(os.path.abspath(__file__))
key_path = os.path.join(base_dir, "serviceAccountKey.json")

def initialize_db():
    try:
        if not firebase_admin._apps:
            if os.path.exists(key_path):
                cred = credentials.Certificate(key_path)
                firebase_admin.initialize_app(cred)
                print(f"✅ تم تحميل ملف الفايربيز من: {key_path}")
            else:
                print(f"❌ ملف المفاتيح مش موجود في: {key_path}")
                return None
        
        return firestore.client()
    except Exception as e:
        print(f"⚠️ خطأ في الاتصال بفايربيز: {e}")
        return None

# تصدير الـ db
db = initialize_db()