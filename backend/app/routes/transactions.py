from fastapi import APIRouter, HTTPException, Query
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional
from google.cloud import firestore

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


# 🔥 [دالة المعاملة الذرية المؤمّنة لمنع تكرار السيريال نهائياً]
@firestore.transactional
def run_save_transaction(transaction, records_ref, data: TransactionModel, is_update: bool):
    if is_update:
        final_serial = data.serial
    else:
        # جلب آخر سيريال مسجل "لهذا الفرع تحديداً" بشكل مؤمن داخل المعاملة الحالية
        query = records_ref.where("branch", "==", data.branch).order_by("serial", direction=firestore.Query.DESCENDING).limit(1)
        docs = list(query.stream(transaction=transaction))
        
        final_serial = 1
        if docs:
            final_serial = int(docs[0].to_dict().get("serial", 0)) + 1
            
    # تحويل بيانات الموديل إلى قاموس
    transaction_data = data.dict()
    transaction_data["serial"] = final_serial
    transaction_data["updated_at"] = firestore.SERVER_TIMESTAMP 
    
    # إنشاء المعرف الفريد الثابت للمستند بناءً على اسم الفرع والسيريال
    safe_branch_name = data.branch.replace(" ", "_").replace("/", "-")
    unique_doc_id = f"{safe_branch_name}_{final_serial}"
    
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
@router.delete("/delete/{company_code}/{branch}/{serial}")
async def delete_transaction(company_code: str, branch: str, serial: int):
    try:
        # تحويل اسم الفرع إلى الصيغة الآمنة لمطابقة المعرف الفريد في الفايربيز
        safe_branch_name = branch.replace(" ", "_").replace("/", "-")
        unique_doc_id = f"{safe_branch_name}_{serial}"

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
# 2. جلب قائمة الأذون للمعاينة المفلترة بالتاريخ والفرع ذكياً
# ==========================================
@router.get("/list/{company_code}")
async def get_transactions(
    company_code: str, 
    start_date: str, 
    end_date: str, 
    branch: Optional[str] = Query(None) 
):
    try:
        # 1️⃣ بناء الاستعلام الأساسي المفلتر بنطاق التاريخ
        query = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("date", ">=", start_date)\
            .where("date", "<=", end_date)
        
        # 2️⃣ شرط الفلترة الذكي: لو الفلاتر ممرر فرع معين قم بفلترة الفايربيز فوراً
        if branch and branch != "الكل" and branch != "كل الفروع":
            query = query.where("branch", "==", branch)
            
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
# 6. جلب آخر سيريال (تم تطويرها ذكياً لدعم الفروع ومنع التداخل المنطقي)
# ==========================================
@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str, branch: Optional[str] = Query(None)):
    try:
        query = db.collection("transactions").document(company_code).collection("daily_records")
        
        # إذا تم تمرير الفرع من التطبيق، يتم جلب آخر سيريال خاص بهذا الفرع فقط
        if branch and branch != "الكل" and branch != "كل الفروع":
            query = query.where("branch", "==", branch)
            
        docs = query.order_by("serial", direction=firestore.Query.DESCENDING).limit(1).get()
        
        if not docs:
            return {"last_serial": 0}
        return {"last_serial": docs[0].to_dict().get("serial", 0)}
    except Exception as e:
        return {"last_serial": 0}