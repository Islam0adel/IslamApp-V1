from fastapi import APIRouter, HTTPException, Query
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional
from google.cloud import firestore

router = APIRouter()

# 🌟 الموديل الموحد للبيانات المطور ليدعم أكواد الفروع بدلاً من أسمائها
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
    branch_code: Optional[str] = "1"  # 👈 تم التعديل: استخدام كود الفرع الافتراضي بدلاً من الاسم


# 🔥 [دالة المعاملة الذرية المؤمّنة لمنع تكرار السيريال نهائياً]
@firestore.transactional
def run_save_transaction(transaction, records_ref, data: TransactionModel, is_update: bool):
    if is_update:
        final_serial = data.serial
    else:
        # 👈 تم التعديل: جلب آخر سيريال مسجل "لهذا الكود تحديداً" 
        query = records_ref.where("branch_code", "==", data.branch_code).order_by("serial", direction=firestore.Query.DESCENDING).limit(1)
        docs = list(query.stream(transaction=transaction))
        
        final_serial = 1
        if docs:
            final_serial = int(docs[0].to_dict().get("serial", 0)) + 1
            
    # تحويل بيانات الموديل إلى قاموس
    transaction_data = data.dict()
    transaction_data["serial"] = final_serial
    transaction_data["updated_at"] = firestore.SERVER_TIMESTAMP 
    
    # 👈 تم التعديل: إنشاء المعرف الفريد الآمن جداً بناءً على كود الفرع بدلاً من اسمه
    unique_doc_id = f"branch_{data.branch_code}_{final_serial}"
    
    # الحفظ الآمن داخل الـ Transaction
    doc_ref = records_ref.document(unique_doc_id)
    transaction.set(doc_ref, transaction_data)
    
    return final_serial


# ==========================================
# 1. حفظ أو تحديث إذن - تم تأمينه بالكامل عبر الـ Transaction
# ==========================================
@router.post("/save")
async def save_transaction(data: TransactionModel):
    try:
        records_ref = db.collection("transactions").document(data.company_code).collection("daily_records")
        
        # تحديد نوع العملية: تعديل أم إضافة جديدة
        is_update = data.serial > 0
        
        # إنشاء المعاملة واستدعاء الدالة المؤمّنة لضمان طابور منظم ومنع الـ Race Condition
        transaction = db.transaction()
        final_serial = run_save_transaction(transaction, records_ref, data, is_update)
        
        return {
            "status": "success", 
            "message": "تم تعديل الإذن وتحديث قاعدة البيانات بنجاح" if is_update else "تم حفظ الإذن الجديد بنجاح",
            "serial": final_serial,
            "action": "update" if is_update else "insert"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 4. حذف إذن من الأرشيف (الرادار سيلتقط الحذف تلقائياً)
# ==========================================
# 👈 تم التعديل: المسار الآن يستقبل branch_code
@router.delete("/delete/{company_code}/{branch_code}/{serial}")
async def delete_transaction(company_code: str, branch_code: str, serial: int):
    try:
        # 👈 تم التعديل: مطابقة المعرف الفريد الجديد في الفايربيز
        unique_doc_id = f"branch_{branch_code}_{serial}"

        # الحذف الفعلي للمستند (الفلاتر سيلتقط إشارة DocumentChangeType.removed فوراً)
        db.collection("transactions").document(company_code)\
            .collection("daily_records").document(unique_doc_id).delete()
            
        return {
            "status": "success", 
            "message": "تم حذف الإذن بنجاح من الخادم الرئيسي", 
            "deleted_id": unique_doc_id
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 2. جلب قائمة الأذون للمعاينة المفلترة بالتاريخ وكود الفرع ذكياً
# ==========================================
@router.get("/list/{company_code}")
async def get_transactions(
    company_code: str, 
    start_date: str, 
    end_date: str, 
    branch_code: Optional[str] = Query(None) # 👈 تم التعديل هنا
):
    try:
        # 1️⃣ بناء الاستعلام الأساسي المفلتر بنطاق التاريخ
        query = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("date", ">=", start_date)\
            .where("date", "<=", end_date)
        
        # 2️⃣ شرط الفلترة الذكي: بناءً على كود الفرع
        # وضعنا استثناء للكلمات العامة التي قد يرسلها الفلاتر عند اختيار "الكل"
        if branch_code and branch_code not in ["الكل", "كل الفروع", "all", ""]:
            query = query.where("branch_code", "==", branch_code)
            
        # تنفيذ الاستعلام وجلب المستندات
        docs = query.stream()
        
        results = []
        for d in docs:
            item = d.to_dict()
            results.append(item)
            
        # الترتيب بناءً على التاريخ (أحدث تاريخ أولاً) ثم بناءً على السيريال
        return sorted(results, key=lambda x: (x.get('date', ''), x.get('serial', 0)), reverse=True)
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==========================================
# 3. جلب التحديثات بدءاً من رقم إذن معين لتحديث الـ Hive لباقي المستخدمين
# ==========================================
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


# ==========================================
# 5. ملخص الأرصدة الخفيف والمتوافق مع حسابات الـ Hive المحلية
# ==========================================
@router.get("/summary/{company_code}")
async def get_summary(company_code: str):
    try:
        treasuries_docs = db.collection("coding").document(company_code).collection("treasuries").stream()
        active_treasuries = [t.to_dict().get("name") for t in treasuries_docs if t.to_dict().get("name")]
        
        return {"status": "success", "active_treasuries": active_treasuries}
    except Exception as e:
        return {"status": "error", "active_treasuries": [], "detail": str(e)}


# ==========================================
# 6. جلب آخر سيريال 
# ==========================================
@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str, branch_code: Optional[str] = Query(None)): # 👈 تم التعديل هنا
    try:
        query = db.collection("transactions").document(company_code).collection("daily_records")
        
        # 👈 تم التعديل: الفلترة بكود الفرع
        if branch_code and branch_code not in ["الكل", "كل الفروع", "all", ""]:
            query = query.where("branch_code", "==", branch_code)
            
        docs = query.order_by("serial", direction=firestore.Query.DESCENDING).limit(1).get()
        
        if not docs:
            return {"last_serial": 0}
        return {"last_serial": docs[0].to_dict().get("serial", 0)}
    except Exception as e:
        return {"last_serial": 0}