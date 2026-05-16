from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

router = APIRouter()

# التكويدات الافتراضية لقسم "التصنيف"
DEFAULT_TYPES = [
    "ايراد",
    "فيزا",
    "استهلاكات بضاعة",
    "انترنت",
    "ايجار",
    "بوفية",
    "عمولة",
    "صيانة",
    "ضرائب",
    "مرتبات",
    "نظافة",
    "تأمينات",
    "نقل بضاعة",
    "ارباح",
    "بضاعة",
    "تحويل من الفيزا",
    "تحويل من النقدي"
]

# موديل البيانات
class CodingModel(BaseModel):
    company_code: str
    category: str
    code: str
    name: str
    barcode: Optional[str] = ""
    price: Optional[float] = 0.0
    quantity: Optional[float] = 0.0
    total_value: Optional[float] = 0.0


@router.post("/save")
async def save_code(data: CodingModel):
    try:
        save_data = {
            "name": data.name,
            "code": data.code
        }

        # لو القسم أصناف ضيف البيانات الإضافية
        if data.category == "items":
            save_data.update({
                "barcode": data.barcode,
                "price": data.price,
                "quantity": data.quantity,
                "total_value": data.total_value
            })

        db.collection("coding")\
            .document(data.company_code)\
            .collection(data.category)\
            .document(data.code)\
            .set(save_data)

        return {"status": "success"}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    try:
        collection_ref = db.collection("coding")\
            .document(company_code)\
            .collection(category)

        # لو قسم التصنيف، نتأكد إن التكويدات الافتراضية موجودة
        if category == "types":
            existing_docs = list(collection_ref.stream())

            if len(existing_docs) == 0:
                for index, name in enumerate(DEFAULT_TYPES, start=1):
                    code = str(index)
                    collection_ref.document(code).set({
                        "name": name,
                        "code": code
                    })

        docs = collection_ref.stream()

        results = []
        for d in docs:
            item_data = d.to_dict()
            item_data["code"] = d.id
            results.append(item_data)

        # ترتيب حسب الكود
        results.sort(key=lambda x: int(x["code"]))

        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(company_code: str, category: str, code: str):
    try:
        db.collection("coding")\
            .document(company_code)\
            .collection(category)\
            .document(code)\
            .delete()

        return {"status": "deleted"}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))