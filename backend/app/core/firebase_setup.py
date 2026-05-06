import firebase_admin
from firebase_admin import credentials, firestore
import os

# المسار لملف المفتاح السري اللي إنت نزلته من Firebase
# تأكد إن الملف ده موجود في فولدر backend باسم serviceAccountKey.json
current_dir = os.path.dirname(os.path.abspath(__file__))
service_account_path = os.path.join(current_dir, "../../serviceAccountKey.json")

def setup_firebase():
    try:
        # بنتحقق لو الـ app مش معمول له initialize قبل كدة
        if not firebase_admin._apps:
            cred = credentials.Certificate(service_account_path)
            firebase_admin.initialize_app(cred)
        
        return firestore.client()
    except Exception as e:
        print(f"Error connecting to Firebase: {e}")
        return None

# تنفيذ الاتصال
db = setup_firebase()