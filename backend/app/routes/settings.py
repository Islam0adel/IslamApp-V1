from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import List
from google.cloud import firestore

router = APIRouter()

class CodingItem(BaseModel):
    category: str  # مثل "safes" أو "suppliers"
    code: str
    name: str
    company_code: str

@router.post("/add-code")
async def add_coding_item(item: CodingItem):
    try:
        # بنخزن التكويد جوه كولكشن خاص بالشركة عشان الخزائن متختلطش ببعض
        doc_ref = db.collection("coding").document(item.company_code)
        category_ref = doc_ref.collection(item.category).document(item.code)
        
        category_ref.set({
            "name": item.name,
            "code": item.code,
            "created_at": firestore.SERVER_TIMESTAMP
        })
        return {"status": "success", "message": f"تم إضافة {item.name} بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/get-codes/{company_code}/{category}")
async def get_coding_items(company_code: str, category: str):
    try:
        docs = db.collection("coding").document(company_code).collection(category).stream()
        items = [{"code": doc.id, "name": doc.to_dict()["name"]} for doc in docs]
        return items
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))