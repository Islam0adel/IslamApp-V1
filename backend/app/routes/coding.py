from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel

router = APIRouter()

class CodingModel(BaseModel):
    company_code: str
    category: str  # safes, suppliers, items, etc.
    code: str
    name: str

@router.post("/save")
async def save_code(data: CodingModel):
    try:
        # التخزين بنظام: coding -> [كود الشركة] -> [القسم] -> [الكود]
        db.collection("coding").document(data.company_code)\
          .collection(data.category).document(data.code).set({
            "name": data.name,
            "code": data.code
        })
        return {"status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    docs = db.collection("coding").document(company_code).collection(category).stream()
    return [{"code": d.id, "name": d.to_dict()["name"]} for d in docs]

@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(company_code: str, category: str, code: str):
    db.collection("coding").document(company_code).collection(category).document(code).delete()
    return {"status": "deleted"}