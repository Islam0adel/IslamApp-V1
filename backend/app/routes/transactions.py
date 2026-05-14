from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

router = APIRouter()

class TransactionModel(BaseModel):
    company_code: str
    serial: int
    treasury: str  # وحدنا الاسم
    amount: float
    statement: str
    category: str  # وحدنا الاسم
    date: str
    type: str

@router.post("/save")
async def save_transaction(data: TransactionModel):
    try:
        doc_ref = db.collection("transactions").document(data.company_code)\
            .collection("daily_records").document(str(data.serial))
        
        # بنحفظ البيانات زي ما هي جاية من الموديل
        doc_ref.set(data.dict())
        return {"status": "success", "message": "تم الحفظ بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

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
            elif cat not in ["فيزا", "تحويل من النقدي"]:
                cash -= amt

            # منطق الفيزا
            if cat in ["فيزا", "تحويل من النقدي"]:
                visa += amt
            elif cat == "تحويل من الفيزا":
                visa -= amt

        return {"cash_balance": cash, "visa_balance": visa}
    except Exception as e:
        return {"cash_balance": 0.0, "visa_balance": 0.0}

@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records").order_by("serial", direction="DESCENDING").limit(1).get()
        if not docs: return {"last_serial": 0}
        return {"last_serial": docs[0].to_dict().get('serial', 0)}
    except: return {"last_serial": 0}