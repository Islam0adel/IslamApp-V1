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

        collection_ref = db.collection("coding").document(company_code).collection(category)
        doc_ref = collection_ref.document(code)

        # التحقق مما إذا كان المستند موجوداً بالفعل (لتحديد هل هي إضافة أم تعديل)
        doc_snapshot = doc_ref.get()
        is_new = not doc_snapshot.exists

        # تحويل الموديل إلى قاموس مع توافق Pydantic v1/v2
        try:
            save_data = data.model_dump()
        except AttributeError:
            save_data = data.dict()

        # إضافة الحقول الإلزامية (إن لم تكن موجودة)
        save_data["company_code"] = company_code
        save_data["category"] = category
        save_data["updated_at"] = firestore.SERVER_TIMESTAMP
        # حفظ المستند (سيتم استبدال البيانات إذا كان موجوداً)
        doc_ref.set(save_data)

        return {
            "status": "success",
            "message": "تم حفظ التكويد بنجاح",
            "code": code,
            "action": "insert" if is_new else "update"
        }

    except HTTPException:
        raise
    except Exception as e:
        print("❌ خطأ في save_code:")
        print(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"خطأ في السيرفر: {str(e)}")


# ==============================================
#          🟢 مسار جلب القائمة (مع البيانات الافتراضية)
# ==============================================
@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    try:
        collection_ref = db.collection("coding").document(company_code).collection(category)

        existing_docs = list(collection_ref.stream())

        # نستثني مستندات التحكم القديمة (version_control) إن وجدت
        real_docs = [d for d in existing_docs if d.id != "version_control"]

        # إذا لم توجد مستندات حقيقية، ندرج البيانات الافتراضية
        if len(real_docs) == 0:
            if category == "types":
                for index, item in enumerate(DEFAULT_TYPES, start=1):
                    code = str(index)
                    doc_data = {
                        "name": item["name"],
                        "type": item["type"],
                        "code": code,
                        "company_code": company_code,
                        "category": category
                    }
                    collection_ref.document(code).set(doc_data)
            elif category in DEFAULT_CATEGORIES_DATA:
                for index, item in enumerate(DEFAULT_CATEGORIES_DATA[category], start=1):
                    code = str(index)
                    doc_data = {
                        "name": item["name"],
                        "code": code,
                        "company_code": company_code,
                        "category": category
                    }
                    collection_ref.document(code).set(doc_data)

            # إعادة قراءة المستندات بعد الإدراج
            existing_docs = list(collection_ref.stream())

        # تجميع النتائج مع استثناء version_control
        results = []
        for d in existing_docs:
            if d.id == "version_control":
                continue
            item_data = d.to_dict()
            item_data["code"] = d.id
            results.append(item_data)

        # ترتيب تصاعدي حسب الكود (كرقم)
        results.sort(key=lambda x: int(x["code"]) if x["code"].isdigit() else x["code"])
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ==============================================
#          🟢 مسار الحذف
# ==============================================
@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(company_code: str, category: str, code: str):
    try:
        collection_ref = db.collection("coding").document(company_code).collection(category)
        doc_ref = collection_ref.document(code)
        doc_ref.delete()
        return {"status": "success", "message": "تم حذف التكويد بنجاح"}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))