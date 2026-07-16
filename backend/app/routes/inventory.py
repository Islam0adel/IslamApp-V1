from fastapi import APIRouter, HTTPException, Query
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import List, Optional
from google.cloud import firestore
from datetime import datetime

router = APIRouter()

class InventoryItemModel(BaseModel):
    code: str
    name: str
    quantity: float
    wholesalePrice: float
    retailPrice: float
    wholesaleValue: float
    retailValue: float

class InventoryModel(BaseModel):
    company_code: str
    branch_code: str
    store_code: str
    date: str
    inventory_type: str
    items: List[InventoryItemModel]
    total_wholesale: float
    total_retail: float
    updated_at: Optional[str] = None
    doc_id: Optional[str] = None
    serial: Optional[int] = None  # ✅ إضافة serial

@router.post("/save")
async def save_inventory(data: InventoryModel):
    try:
        doc_id = data.doc_id or f"{data.company_code}_{data.branch_code}_{data.store_code}_{data.date}_{datetime.now().timestamp()}"
        doc_ref = db.collection("inventory_records").document(doc_id)

        save_data = data.dict()
        save_data["updated_at"] = firestore.SERVER_TIMESTAMP
        save_data["doc_id"] = doc_id
        # التأكد من حفظ serial
        if data.serial is not None:
            save_data["serial"] = data.serial

        doc_ref.set(save_data)

        return {"status": "success", "doc_id": doc_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/list/{company_code}")
async def list_inventory(
    company_code: str,
    branch_code: Optional[str] = Query(None),
    store_code: Optional[str] = Query(None),
    date: Optional[str] = Query(None),
):
    try:
        query = db.collection("inventory_records").where("company_code", "==", company_code)
        if branch_code:
            query = query.where("branch_code", "==", branch_code)
        if store_code:
            query = query.where("store_code", "==", store_code)
        if date:
            query = query.where("date", "==", date)

        docs = query.stream()
        results = []
        for doc in docs:
            data = doc.to_dict()
            data["doc_id"] = doc.id
            results.append(data)
        return results
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.delete("/delete/{company_code}/{doc_id}")
async def delete_inventory(company_code: str, doc_id: str):
    try:
        doc_ref = db.collection("inventory_records").document(doc_id)
        doc_ref.delete()
        return {"status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))