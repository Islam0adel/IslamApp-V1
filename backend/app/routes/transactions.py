from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional
from google.cloud import firestore
from typing import Optional
from fastapi import Query # ⚠️ تأكد من وجود هذا الاستيراد في أعلى الملف مع باقي استيرادات FastAPI

router = APIRouter()

# الموديل الموحد للبيانات المطور ليدعم الفروع والمستخدمين
class TransactionModel(BaseModel):
    company_code: str
    serial: int  
    treasury: str
    amount: float
    statement: str
    category: str
    date: str
    type: str
    employee: Optional[str] = "غير محدد"  
    branch: Optional[str] = "الفرع الرئيسي"  

# ==========================================
# 1. حفظ أو تحديث إذن (Save / Update) - مع المزامنة الفورية في الرادار اللحظي والوقت الدقيق
# ==========================================
@router.post("/save")
async def save_transaction(data: TransactionModel):
    try:
        transaction = db.transaction()
        
        @firestore.transactional
        def create_and_save(tx):
            records_ref = db.collection("transactions").document(data.company_code).collection("daily_records")
            live_ref = db.collection("companies").document(data.company_code).collection("live_updates")
            
            is_update = data.serial > 0
            
            if is_update:
                final_serial = data.serial
            else:
                # جلب آخر سيريال مسجل لهذا الفرع تحديداً
                query = records_ref.where("branch", "==", data.branch).order_by("serial", direction=firestore.Query.DESCENDING).limit(1)
                docs = list(query.stream(transaction=tx))
                
                final_serial = 1
                if docs:
                    final_serial = int(docs[0].to_dict().get("serial", 0)) + 1
            
            transaction_data = data.dict()
            transaction_data["serial"] = final_serial
            
            # 🔥 وقت السيرفر بدقة الملي ثانية للمزامنة اللحظية ومنع التضارب
            transaction_data["updated_at"] = firestore.SERVER_TIMESTAMP 
            transaction_data["is_deleted"] = False  # علامة لنفي الحذف عند الحفظ أو التعديل
            
            # عزل الفروع في التسمية لمنع تداخل السيريال بين فرع وآخر
            safe_branch_name = data.branch.replace(" ", "_").replace("/", "-")
            unique_doc_id = f"{safe_branch_name}_{final_serial}"
            
            # أ) الحفظ في الأرشيف الدائم
            doc_ref = records_ref.document(unique_doc_id)
            tx.set(doc_ref, transaction_data)
            
            # ب) البث الفوري عبر الرادار اللحظي لهواتف الموظفين
            live_doc_ref = live_ref.document(unique_doc_id)
            tx.set(live_doc_ref, transaction_data)
            
            return final_serial

        assigned_serial = create_and_save(transaction)
        
        return {
            "status": "success", 
            "message": "تم الحفظ بنجاح وتحديث قاعدة البيانات والبث عبر الرادار اللحظي",
            "serial": assigned_serial
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 4. حذف إذن من الأرشيف وبث إشارة الحذف للرادار اللحظي
# ==========================================
@router.delete("/delete/{company_code}/{branch}/{serial}")
async def delete_transaction(company_code: str, branch: str, serial: int):
    try:
        safe_branch_name = branch.replace(" ", "_").replace("/", "-")
        unique_doc_id = f"{safe_branch_name}_{serial}"

        # أ) الحذف الفعلي والنهائي من أرشيف المعاملات الدائم
        db.collection("transactions").document(company_code)\
            .collection("daily_records").document(unique_doc_id).delete()
            
        # ب) 🔥 تحديث وهمي في الرادار (Soft Delete) لكي يلتقط الموبايل إشارة الحذف فوراً ويمسحه محلياً
        db.collection("companies").document(company_code)\
            .collection("live_updates").document(unique_doc_id).set({
                "is_deleted": True,
                "updated_at": firestore.SERVER_TIMESTAMP  # تحديث الوقت لضمان ترتيب الحدث
            }, merge=True)
            
        return {
            "status": "success", 
            "message": "تم حذف الإذن من الأرشيف وبث إشارة المسح للرادار بنجاح", 
            "deleted_id": unique_doc_id
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 2. جلب قائمة الأذون للمعاينة المفلترة بالتاريخ والفرع ذكياً
@router.get("/list/{company_code}")
async def get_transactions(
    company_code: str, 
    start_date: str, 
    end_date: str, 
    branch: Optional[str] = Query(None) # 🌟 استقبال الفرع القادم من الفلاتر بشكل اختياري
):
    try:
        # 1️⃣ بناء الاستعلام الأساسي المفلتر بنطاق التاريخ
        query = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("date", ">=", start_date)\
            .where("date", "<=", end_date)
        
        # 2️⃣ شرط الفلترة الذكي: لو الفلاتر ممرر فرع معين (وليس "الكل" أو فارغ)، قم بفلترة الفايربيز فوراً
        if branch and branch != "الكل" and branch != "كل الفروع":
            query = query.where("branch", "==", branch)
            
        # تنفيذ الاستعلام وجلب المستندات
        docs = query.stream()
        
        results = []
        for d in docs:
            item = d.to_dict()
            results.append(item)
            
        # 🌟 التعديل الاحترافي: الترتيب بناءً على التاريخ (أحدث تاريخ أولاً) ثم بناءً على السيريال لمنع تداخل أرقام الفروع عند عرض "كل الفروع"
        return sorted(results, key=lambda x: (x.get('date', ''), x.get('serial', 0)), reverse=True)
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 3. جلب التحديثات بدءاً من رقم إذن معين لتحديث الـ Hive لباقي المستخدمين
@router.get("/updates/{company_code}/{from_serial}")
async def get_transactions_from_serial(company_code: str, from_serial: int):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("serial", ">=", from_serial)\
            .stream()
        
        results = []
        for d in docs:
            results.append(d.to_dict())
            
        return sorted(results, key=lambda x: x.get('serial', 0))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



# 5. ملخص الأرصدة الخفيف والمتوافق مع حسابات الـ Hive المحلية
@router.get("/summary/{company_code}")
async def get_summary(company_code: str):
    try:
        treasuries_docs = db.collection("coding").document(company_code).collection("treasuries").stream()
        active_treasuries = [t.to_dict().get("name") for t in treasuries_docs if t.to_dict().get("name")]
        
        return {"status": "success", "active_treasuries": active_treasuries}
    except Exception as e:
        return {"status": "error", "active_treasuries": [], "detail": str(e)}

# 6. جلب آخر سيريال (تم تصحيح اتجاه الترتيب هنا)
@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .order_by("serial", direction=firestore.Query.DESCENDING)\
            .limit(1).get()
        
        if not docs:
            return {"last_serial": 0}
        return {"last_serial": docs[0].to_dict().get("serial", 0)}
    except Exception as e:
        return {"last_serial": 0}