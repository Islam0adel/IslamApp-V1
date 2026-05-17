from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

router = APIRouter()

# 1. التكويدات الافتراضية لقسم "التصنيف" (types)
DEFAULT_TYPES = [
    {"name": "ايراد", "type": "وارد"},
    {"name": "فيزا", "type": "وارد"},
    {"name": "تحويل من الفيزا", "type": "وارد"},
    {"name": "تحويل من النقدي", "type": "صادر"},
    {"name": "استهلاكات بضاعة", "type": "صادر"},
    {"name": "انترنت", "type": "صادر"},
    {"name": "ايجار", "type": "صادر"},
    {"name": "بوفية", "type": "صادر"},
    {"name": "عمولة", "type": "صادر"},
    {"name": "صيانة", "type": "صادر"},
    {"name": "ضرائب", "type": "صادر"},
    {"name": "مرتبات", "type": "صادر"},
    {"name": "نظافة", "type": "صادر"},
    {"name": "تأمينات", "type": "صادر"},
    {"name": "نقل بضاعة", "type": "صادر"},
    {"name": "ارباح", "type": "وارد"},
    {"name": "بضاعة", "type": "صادر"}
]

# 2. قاموس يحتوي على باقي التكويدات الافتراضية للأقسام الجديدة بالملي
DEFAULT_CATEGORIES_DATA = {
    "treasuries": [{"name": "الخزينة الرئيسية"}],            # الخزائن
    "customers": [{"name": "عميل نقدي"}],                    # العملاء
    "stores": [{"name": "المخزن الرئيسي"}],                  # المخازن
    "branches": [{"name": "الفرع الرئيسي"}],                  # الفروع
    "payment_methods": [                                    # طرق الدفع
        {"name": "نقدي"},
        {"name": "فيزا"},
        {"name": "محفظة الكترونية"}
    ]
}

# موديل البيانات المطور للأصناف والتصنيفات
class CodingModel(BaseModel):
    company_code: str
    category: str
    code: str
    name: str
    type: Optional[str] = "وارد"
    barcode: Optional[str] = ""
    wholesale_price: Optional[float] = 0.0
    selling_price: Optional[float] = 0.0
    profit_margin: Optional[float] = 0.0
    profit_percent: Optional[float] = 0.0


@router.post("/save")
async def save_code(data: CodingModel):
    try:
        save_data = {
            "name": data.name,
            "code": data.code
        }

        if data.category == "types":
            save_data["type"] = data.type

        if data.category == "items":
            save_data.update({
                "barcode": data.barcode,
                "wholesale_price": data.wholesale_price,
                "selling_price": data.selling_price,
                "profit_margin": data.profit_margin,
                "profit_percent": data.profit_percent
            })

        db.collection("coding")\
            .document(data.company_code)\
            .collection(data.category)\
            .document(data.code)\
            .set(save_data)

        return {"status": "success"}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# قاموس يحتوي على التكويدات الافتراضية للأقسام لو فاضية
DEFAULT_CATEGORIES_DATA = {
    "treasuries": [{"name": "الخزينة الرئيسية"}],
    "customers": [{"name": "عميل نقدي"}],
    "stores": [{"name": "المخزن الرئيسي"}],
    "branches": [{"name": "الفرع الرئيسي"}], # 👈 هنا هينزل الفرع الرئيسي تلقائياً لو الكوليكشن فاضي
    "payment_methods": [
        {"name": "نقدي"},
        {"name": "فيزا"},
        {"name": "محفظة الكترونية"}
    ]
}

@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    try:
        collection_ref = db.collection("coding")\
            .document(company_code)\
            .collection(category)

        existing_docs = list(collection_ref.stream())

        # الفحص الذكي: لو القسم لسه فاضي تماماً
        if len(existing_docs) == 0:
            if category == "types":
                for index, name in enumerate(DEFAULT_TYPES, start=1):
                    code = str(index)
                    collection_ref.document(code).set({
                        "name": name,
                        "code": code
                    })
            # توليد التكويدات الافتراضية لباقي الأقسام (بما فيها الفروع)
            elif category in DEFAULT_CATEGORIES_DATA:
                for index, item in enumerate(DEFAULT_CATEGORIES_DATA[category], start=1):
                    code = str(index)
                    collection_ref.document(code).set({
                        "name": item["name"],
                        "code": code
                    })

        # إعادة القراءة بعد ملء الافتراضيات
        docs = collection_ref.stream()

        results = []
        for d in docs:
            item_data = d.to_dict()
            item_data["code"] = d.id
            results.append(item_data)

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