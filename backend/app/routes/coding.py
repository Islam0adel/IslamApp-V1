from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional
import traceback
from google.cloud import firestore

router = APIRouter()

# 1. التكويدات الافتراضية لقسم "التصنيف" (types) مع الاتجاهات الصحيحة
DEFAULT_TYPES = [
    {"name": "ايراد", "type": "وارد"},
    {"name": "فيزا", "type": "وارد"},
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
    {"name": "ارباح", "type": "صادر"},
    {"name": "بضاعة", "type": "صادر"}
]

# 2. التكويدات الافتراضية لباقي الأقسام
DEFAULT_CATEGORIES_DATA = {
    "safes": [{"name": "نقدي"},
              {"name": "فيزا"},
              {"name": "محفظة الكترونية"}],
    "customers": [{"name": "عميل نقدي"}],
    "stores": [{"name": "المخزن الرئيسي"}],
    "branches": [{"name": "الفرع الرئيسي"}],
    "payment_methods": [
        {"name": "نقدي"},
        {"name": "فيزا"},
        {"name": "محفظة الكترونية"}
    ]
}

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


# ==============================================
#          🟢 مسار الحفظ (بدون Transaction)
#          الكود يُحدد من قبل المستخدم مباشرة
# ==============================================
@router.post("/save")
async def save_code(data: CodingModel):
    try:
        company_code = data.company_code
        category = data.category
        code = data.code

        if not code:
            raise HTTPException(status_code=400, detail="الكود مطلوب ولا يمكن أن يكون فارغاً")

        # 🌟 التعديل هنا: استخدام مسار واحد لكل التكويدات لسهولة قراءتها بالرادار
        doc_id = f"{company_code}_{category}_{code}"
        doc_ref = db.collection("coding_records").document(doc_id)

        doc_snapshot = doc_ref.get()
        is_new = not doc_snapshot.exists

        try:
            save_data = data.model_dump()
        except AttributeError:
            save_data = data.dict()

        save_data["company_code"] = company_code
        save_data["category"] = category
        save_data["updated_at"] = firestore.SERVER_TIMESTAMP # إضافة حقل الوقت
        
        doc_ref.set(save_data)

        return {
            "status": "success",
            "message": "تم حفظ التكويد بنجاح",
            "code": code,
            "action": "insert" if is_new else "update"
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"خطأ في السيرفر: {str(e)}")

# ==============================================
#          🟢 مسار جلب القائمة
# ==============================================
@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    try:
        # 🌟 جلب البيانات من المسار المسطح بناءً على الشركة والقسم
        collection_ref = db.collection("coding_records")
        query = collection_ref.where("company_code", "==", company_code).where("category", "==", category)
        existing_docs = list(query.stream())

        if len(existing_docs) == 0:
            if category == "types":
                for index, item in enumerate(DEFAULT_TYPES, start=1):
                    code = str(index)
                    doc_id = f"{company_code}_{category}_{code}"
                    doc_data = {
                        "name": item["name"],
                        "type": item["type"],
                        "code": code,
                        "company_code": company_code,
                        "category": category,
                        "updated_at": firestore.SERVER_TIMESTAMP
                    }
                    collection_ref.document(doc_id).set(doc_data)
            elif category in DEFAULT_CATEGORIES_DATA:
                for index, item in enumerate(DEFAULT_CATEGORIES_DATA[category], start=1):
                    code = str(index)
                    doc_id = f"{company_code}_{category}_{code}"
                    doc_data = {
                        "name": item["name"],
                        "code": code,
                        "company_code": company_code,
                        "category": category,
                        "updated_at": firestore.SERVER_TIMESTAMP
                    }
                    collection_ref.document(doc_id).set(doc_data)

            existing_docs = list(query.stream())

        results = []
        for d in existing_docs:
            item_data = d.to_dict()
            # نتأكد إننا بناخد الكود من جوه الداتا مش من الـ ID لأنه بقى مدمج
            results.append(item_data)

        results.sort(key=lambda x: int(x.get("code", 0)) if str(x.get("code", "")).isdigit() else str(x.get("code", "")))
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# ==============================================
#          🟢 مسار الحذف
# ==============================================
@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(company_code: str, category: str, code: str):
    try:
        # 🌟 الحذف من المسار المسطح الجديد
        doc_id = f"{company_code}_{category}_{code}"
        doc_ref = db.collection("coding_records").document(doc_id)
        doc_ref.delete()
        return {"status": "success", "message": "تم حذف التكويد بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))