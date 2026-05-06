import firebase_admin
from firebase_admin import credentials, firestore
import os
import json

def setup_firebase():
    try:
        # بنتحقق لو الـ app مش معمول له initialize قبل كدة لمنع التكرار
        if not firebase_admin._apps:
            
            # 1. بنشوف هل إحنا على السيرفر (Hugging Face) ومعانا السكريت؟
            firebase_keys_json = os.getenv("FIREBASE_KEYS")
            
            if firebase_keys_json:
                # لو موجود، بنحول النص (String) لقاموس (Dictionary) ونستخدمه مباشرة
                print("Firebase: Loading from Environment Secrets...")
                key_dict = json.loads(firebase_keys_json)
                cred = credentials.Certificate(key_dict)
            else:
                # 2. لو مش موجود، بنشتغل بالطريقة المحلية (Local) ونقرأ من الملف
                print("Firebase: Loading from local JSON file...")
                
                # تحديد المسار النسبي لملف المفاتيح
                current_dir = os.path.dirname(os.path.abspath(__file__))
                # بنطلع مستويين عشان نوصل لفولدر الـ backend الرئيسي
                service_account_path = os.path.join(current_dir, "../../serviceAccountKey.json")
                
                if not os.path.exists(service_account_path):
                    raise FileNotFoundError(f"لم يتم العثور على ملف المفاتيح في: {service_account_path}")
                
                cred = credentials.Certificate(service_account_path)
            
            # تشغيل الربط
            firebase_admin.initialize_app(cred)
            print("Firebase: Initialization Successful!")
            
        return firestore.client()
        
    except Exception as e:
        print(f"Error connecting to Firebase: {e}")
        return None

# تنفيذ الاتصال وتصدير الكائن db
db = setup_firebase()