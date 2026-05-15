from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

router = APIRouter()

# 1. تحديث الموديل عشان يقبل الحقول الإضافية للأصناف
class CodingModel(BaseModel):
    company_code: str
    category: str
    code: str
    name: str
    barcode: Optional[str] = ""        # حقل اختياري
    price: Optional[float] = 0.0       # حقل اختياري
    quantity: Optional[float] = 0.0    # حقل اختياري
    total_value: Optional[float] = 0.0 # حقل اختياري

@router.post("/save")
async def save_code(data: CodingModel):
    try:
        # 2. تجهيز البيانات في قاموس (Dict)
        save_data = {
            "name": data.name,
            "code": data.code
        }

        # 3. لو القسم أصناف (items) ضيف الحقول الخاصة بيها
        if data.category == "items":
            save_data.update({
                "barcode": data.barcode,
                "price": data.price,
                "quantity": data.quantity,
                "total_value": data.total_value
            })

        # التخزين في فايربيز
        db.collection("coding").document(data.company_code)\
          .collection(data.category).document(data.code).set(save_data)
          
        return {"status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    try:
        docs = db.collection("coding").document(company_code).collection(category).stream()
        results = []
        for d in docs:
            item_data = d.to_dict()
            item_data["code"] = d.id  # نضمن إن الكود دايمًا موجود
            results.append(item_data)
        return results
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(company_code: str, category: str, code: str):
    try:
        db.collection("coding").document(company_code).collection(category).document(code).delete()
        return {"status": "deleted"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))