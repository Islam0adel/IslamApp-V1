from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

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

# 2. التكويدات الافتراضية لباقي الأقسام (تم تنظيف التكرار)
DEFAULT_CATEGORIES_DATA = {
    "safes": [{"name": "نقدي"},
                  {"name": "فيزا"},
                  {"name": "محفظة الكترونية"}],            # الخزائن
    "customers": [{"name": "عميل نقدي"}],                    # العملاء
    "stores": [{"name": "المخزن الرئيسي"}],                  # المخازن
    "branches": [{"name": "الفرع الرئيسي"}],                  # الفروع لضمان وجود فرع افتراضي للربط
    "payment_methods": [                                    # طرق الدفع
        {"name": "نقدي"},
        {"name": "فيزا"},
        {"name": "محفظة الكترونية"}
    ]
}

# موديل البيانات المطور للأصناف والتصنيفات الشامل
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


# 🟢 دالة مساعدة لزيادة رقم النسخة تلقائياً عند (الحفظ أو الحذف أو التعديل)
def bump_version(company_code: str, category: str):
    try:
        doc_ref = db.collection("coding").document(company_code).collection(category).document("version_control")
        doc = doc_ref.get()
        current_version = doc.to_dict().get("version", 1) if doc.exists else 1
        doc_ref.set({"version": current_version + 1}) # تزيد النسخة بمقدار 1 ليعرف الفرونت إند بوجود تغيير
    except Exception as e:
        print(f"Error bumping version: {str(e)}")


# [تعديل دالة 1]: حفظ أو تحديث التكويد مع ترفيع رقم النسخة ذكياً لإعلام الكاش المحلي
@router.post("/save")
async def save_code(data: CodingModel):
    try:
        # تحويل الموديل بالكامل إلى قاموس (حتى لا نفقد أي ميزة أو خاصية قديمة أو مستقبلية)
        save_data = data.dict()
        
        # إزالة الحقول التي تنتمي للمسار وليس لمستند التكويد نفسه
        save_data.pop("company_code", None)
        save_data.pop("category", None)

        # حفظ المستند مباشرة في مساره الصحيح ديناميكياً
        db.collection("coding")\
            .document(data.company_code)\
            .collection(data.category)\
            .document(data.code)\
            .set(save_data)
        
        # 🔥 تحديث النسخة لإجبار الكاش عند العميل على التحديث التلقائي
        bump_version(data.company_code, data.category)
        
        return {"status": "success", "message": "تم حفظ التكويد بنجاح"}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# [تعديل دالة 2]: جلب التكويدات ومعالجة ذكية لحفظ الـ types وتصفية ملفات النسخ
@router.get("/list/{company_code}/{category}")
async def list_codes(company_code: str, category: str):
    try:
        collection_ref = db.collection("coding")\
            .document(company_code)\
            .collection(category)

        existing_docs = list(collection_ref.stream())

        # الفحص الذكي: لو القسم فارغ عند أول فتح للبرنامج أو بعد الحذف الكامل، نملأه بالافتراضيات فوراً
        # ملاحظة: نتحقق من وجود مستندات حقيقية غير مستند تحكم النسخة
        real_docs = [d for d in existing_docs if d.id != "version_control"]

        if len(real_docs) == 0:
            if category == "types":
                for index, item in enumerate(DEFAULT_TYPES, start=1):
                    code = str(index)
                    collection_ref.document(code).set({
                        "name": item["name"],
                        "type": item["type"],
                        "code": code
                    })
            
            elif category in DEFAULT_CATEGORIES_DATA:
                for index, item in enumerate(DEFAULT_CATEGORIES_DATA[category], start=1):
                    code = str(index)
                    collection_ref.document(code).set({
                        "name": item["name"],
                        "code": code
                    })

            # إعادة قراءة المستندات بعد ملء البيانات الافتراضية
            existing_docs = list(collection_ref.stream())

        # تجميع النتائج لترسل للفرونت إند ليحفظها في الـ Hive
        results = []
        for d in existing_docs:
            # 🔥 استثناء ذكي: مستند version_control لا يجب إرساله لقائمة التكويد بالواجهة
            if d.id == "version_control":
                continue
                
            item_data = d.to_dict()
            item_data["code"] = d.id
            results.append(item_data)

        # ترتيب التكويدات بناءً على الكود تصاعدياً
        results.sort(key=lambda x: int(x["code"]) if x["code"].isdigit() else x["code"])
        return results

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# [دالة 3]: حذف التكويد مع ترفيع رقم نسخة التحكم
@router.delete("/delete/{company_code}/{category}/{code}")
async def delete_code(company_code: str, category: str, code: str):
    try:
        db.collection("coding")\
            .document(company_code)\
            .collection(category)\
            .document(code)\
            .delete()
            
        # 🔥 تحديث النسخة عند الحذف ليعلم الكاش أن السيرفر نقُص عن الهاتف
        bump_version(company_code, category)
        return {"status": "success", "message": "تم حذف التكويد بنجاح"}

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# [دالة 4]: جلب رقم النسخة الحالي للقسم من الفايربيز (استدعاء فائق الخفة)
@router.get("/version/{company_code}/{category}")
async def get_coding_version(company_code: str, category: str):
    try:
        doc_ref = db.collection("coding").document(company_code).collection(category).document("version_control")
        doc = doc_ref.get()
        if doc.exists:
            return {"version": doc.to_dict().get("version", 1)}
        else:
            # لو مش موجودة بننشأها أول مرة برقم 1
            doc_ref.set({"version": 1})
            return {"version": 1}
    except Exception as e:
        return {"version": 1}