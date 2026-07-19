# app/routers/supplier.py
from fastapi import APIRouter, HTTPException, Query
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import List, Optional
from google.cloud import firestore
from datetime import datetime

router = APIRouter()

class SupplierItemModel(BaseModel):
    code: str
    name: str
    quantity: float
    price: float
    type: str
    discountRate: float
    discountAmount: float
    total: float

class SupplierTransactionModel(BaseModel):
    company_code: str
    branch_code: str
    store_code: str
    serial: int
    date: str
    supplier_name: str
    payment_method: str
    treasury: str
    is_add_to_store: bool
    employee: str
    items: List[SupplierItemModel]
    total_amount: float
    paid_amount: float
    updated_at: Optional[str] = None
    doc_id: Optional[str] = None

@router.post("/save")
async def save_supplier_transaction(data: SupplierTransactionModel):
    try:
        doc_id = data.doc_id or f"{data.company_code}_{data.branch_code}_{data.serial}_{datetime.now().timestamp()}"
        doc_ref = db.collection("supplier_records").document(doc_id)
        save_data = data.dict()
        save_data["updated_at"] = firestore.SERVER_TIMESTAMP
        save_data["doc_id"] = doc_id
        doc_ref.set(save_data)
        return {"status": "success", "doc_id": doc_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/list/{company_code}")
async def list_supplier_transactions(
    company_code: str,
    branch_code: Optional[str] = Query(None),
    supplier_name: Optional[str] = Query(None),
    start_date: Optional[str] = Query(None),
    end_date: Optional[str] = Query(None),
):
    try:
        query = db.collection("supplier_records").where("company_code", "==", company_code)
        if branch_code:
            query = query.where("branch_code", "==", branch_code)
        if supplier_name:
            query = query.where("supplier_name", "==", supplier_name)
        if start_date:
            query = query.where("date", ">=", start_date)
        if end_date:
            query = query.where("date", "<=", end_date)
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
async def delete_supplier_transaction(company_code: str, doc_id: str):
    try:
        doc_ref = db.collection("supplier_records").document(doc_id)
        doc_ref.delete()
        return {"status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))