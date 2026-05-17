from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

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
    employee: Optional[str] = "غير محدد"  # يحمل اسم المستخدم الفعلي المسجل
    branch: Optional[str] = "الالفرع الرئيسي"  # يحمل اسم الفرع

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

# 2. جلب قائمة الأذون للمعاينة المفلترة بالتاريخ
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
            
        return sorted(results, key=lambda x: x.get('serial', 0), reverse=True)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 3. حذف إذن
@router.delete("/delete/{company_code}/{serial}")
async def delete_transaction(company_code: str, serial: int):
    try:
        db.collection("transactions").document(company_code)\
            .collection("daily_records").document(str(serial)).delete()
        return {"status": "success", "message": "تم حذف الإذن بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 4. ملخص الأرصدة المطور ليفحص الفرع المختار
@router.get("/summary/{company_code}")
async def get_summary(company_code: str, treasury: Optional[str] = None, branch: Optional[str] = "كل الفروع"):
    try:
        category_types = {}
        types_docs = db.collection("coding").document(company_code).collection("types").stream()
        for t_doc in types_docs:
            t_data = t_doc.to_dict()
            if t_data.get('name'):
                category_types[t_data.get('name')] = t_data.get('type', 'صادر')

        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records").stream()
        
        cash = 0.0
        visa = 0.0
        
        for d in docs:
            item = d.to_dict()
            
            # 🟢 التصفية الذكية حسب الفرع:
            item_branch = item.get('branch', 'الفرع الرئيسي')
            if branch != "كل الفروع" and item_branch != branch:
                continue

            # فلترة الحركات بناءً على الخزينة
            if treasury and item.get('treasury') != treasury:
                continue

            amt = float(item.get('amount', 0))
            cat = item.get('category', '')
            tx_type = item.get('type', 'cash')

            cat_direction = category_types.get(cat, 'صادر')

            if cat == "تحويل من النقدي":
                cash -= amt
                visa += amt
                continue
                
            elif cat == "تحويل من الفيزا":
                cash += amt
                visa -= amt
                continue

            if tx_type == "cash":
                if cat_direction == "وارد":
                    cash += amt
                else:
                    cash -= amt
            elif tx_type == "visa":
                if cat_direction == "وارد":
                    visa += amt
                else:
                    visa -= amt

        return {"cash_balance": cash, "visa_balance": visa}
    except Exception as e:
        return {"cash_balance": 0.0, "visa_balance": 0.0}

# 5. جلب آخر سيريال
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