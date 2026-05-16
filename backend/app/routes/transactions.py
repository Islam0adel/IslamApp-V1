from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

router = APIRouter()

# الموديل الموحد للبيانات
class TransactionModel(BaseModel):
    company_code: str
    serial: int
    treasury: str
    amount: float
    statement: str
    category: str
    date: str
    type: str
    employee: Optional[str] = "غير محدد" # حقل الموظف مهم لتقرير الإكسيل

# 1. حفظ أو تحديث إذن (Save / Update)
@router.post("/save")
async def save_transaction(data: TransactionModel):
    try:
        doc_ref = db.collection("transactions").document(data.company_code)\
            .collection("daily_records").document(str(data.serial))
        
        # حفظ البيانات بالكامل
        doc_ref.set(data.dict())
        return {"status": "success", "message": "تم الحفظ بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 2. جلب قائمة الأذون للمعاينة (الجديدة)
@router.get("/list/{company_code}")
async def get_transactions(company_code: str, start_date: str, end_date: str):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("date", ">=", start_date)\
            .where("date", "<=", end_date)\
            .stream()
        
        results = []
        for d in docs:
            item = d.to_dict()
            results.append(item)
            
        # ترتيب النتائج من الأحدث للأقدم حسب السيريال
        return sorted(results, key=lambda x: x.get('serial', 0), reverse=True)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 3. حذف إذن (الجديدة)
@router.delete("/delete/{company_code}/{serial}")
async def delete_transaction(company_code: str, serial: int):
    try:
        db.collection("transactions").document(company_code)\
            .collection("daily_records").document(str(serial)).delete()
        return {"status": "success", "message": "تم حذف الإذن بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 4. ملخص الأرصدة (الدالة القديمة كما هي)
@router.get("/summary/{company_code}")
async def get_summary(company_code: str):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records").stream()
        
        cash = 0.0
        visa = 0.0
        
        for d in docs:
            item = d.to_dict()
            amt = float(item.get('amount', 0))
            cat = item.get('category', '')

            # منطق النقدي
            if cat in ["ايراد", "تحويل من الفيزا"]:
                cash += amt
            elif cat not in ["فيزا"]:
                cash -= amt

            # منطق الفيزا
            if cat in ["فيزا", "تحويل من النقدي"]:
                visa += amt
            elif cat == "تحويل من الفيزا":
                visa -= amt

        return {"cash_balance": cash, "visa_balance": visa}
    except Exception as e:
        return {"cash_balance": 0.0, "visa_balance": 0.0}

# 5. جلب آخر سيريال (الدالة القديمة كما هي)
@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .order_by("serial", direction="DESCENDING")\
            .limit(1).get()
        
        if not docs:
            return {"last_serial": 0}
        
        return {"last_serial": docs[0].to_dict().get("serial", 0)}
    except Exception as e:
        return {"last_serial": 0}