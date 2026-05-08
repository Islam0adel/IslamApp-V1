from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel
from app.core.firebase_setup import db
from google.cloud import firestore
from typing import List, Optional
from datetime import datetime

router = APIRouter()

# 1. تعريف شكل البيانات (Schema) للعملية المالية
class Transaction(BaseModel):
    date: str
    type: str  # مثل: "توريد", "صرف"
    category: str # مثل: "مبيعات", "مشتريات", "رواتب"
    amount: float
    details: Optional[str] = None
    userName: str  # اسم الموظف اللي عمل العملية
    company_code: str  # كود الشركة (الأساسي للفصل)

# 2. دالة إضافة عملية جديدة
@router.post("/add")
async def add_transaction(transaction: Transaction):
    try:
        # تحويل البيانات لقاموس (Dictionary)
        transaction_data = transaction.dict()
        
        # إضافة طابع زمني من السيرفر للتنظيم
        transaction_data["server_timestamp"] = firestore.SERVER_TIMESTAMP
        
        # حفظ العملية في مجموعة transactions
        # كل عملية بتنزل ومعاها الـ company_code بتاعها
        db.collection("transactions").add(transaction_data)
        
        return {"status": "success", "message": "تم تسجيل العملية بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"خطأ أثناء الحفظ: {str(e)}")

# 3. دالة جلب العمليات (مفلترة بكود الشركة)
@router.get("/all")
async def get_transactions(company_code: str = Query(...)):
    """
    هذه الدالة هي المسؤولة عن 'الفصل'. 
    تستقبل كود الشركة وبترجع فقط البيانات الخاصة بيها.
    """
    try:
        # الاستعلام من فايربيز مع شرط المساواة (where)
        docs = db.collection("transactions")\
                 .where("company_code", "==", company_code)\
                 .order_by("server_timestamp", direction=firestore.Query.DESCENDING)\
                 .stream()
        
        transactions_list = []
        for doc in docs:
            data = doc.to_dict()
            data["id"] = doc.id  # إضافة معرف الوثيقة
            # تحويل الـ timestamp لنص عشان يتبعت للفلاتر صح لو محتاجه
            if "server_timestamp" in data and data["server_timestamp"]:
                data["server_timestamp"] = data["server_timestamp"].isoformat()
            transactions_list.append(data)
            
        return transactions_list
    except Exception as e:
        # ملاحظة: لو أول مرة تشغل الـ OrderBy، فايربيز هيطلب منك عمل Index (رابط هيظهر في الـ Logs)
        raise HTTPException(status_code=500, detail=f"خطأ أثناء جلب البيانات: {str(e)}")

# 4. دالة لحذف عملية (اختياري)
@router.delete("/delete/{doc_id}")
async def delete_transaction(doc_id: str, company_code: str):
    try:
        doc_ref = db.collection("transactions").document(doc_id)
        doc = doc_ref.get()
        
        if not doc.exists:
            raise HTTPException(status_code=404, detail="العملية غير موجودة")
            
        # زيادة في الأمان: نتحقق إن اللي بيمسح تبع نفس الشركة
        if doc.to_dict().get("company_code") != company_code:
            raise HTTPException(status_code=403, detail="ليس لديك صلاحية لحذف هذه البيانات")
            
        doc_ref.delete()
        return {"message": "تم الحذف بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))