from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional

router = APIRouter()

# 1. تحديث Mالموديل عشان يقبل الحقول الإضافية للأصناف
class CodingModel(BaseModel):
    company_code: str
    category: str
    code: str
    name: str
    barcode: Optional[str] = ""        # حقل اختياري
    price: Optional[float] = 0.0       # حقل اختياري
    quantity: Optional[float] = 0.0    # حقل اختياري
    total_value: Optional[float] = 0.0 # حقل اختياري

# --- قائمة التصنيفات الافتراضية الثابتة بالترتيب والأكواد المطلوبة ---
DEFAULT_CATEGORIES = [
    {"code": "1", "name": "ايراد"},
    {"code": "2", "name": "فيزا"},
    {"code": "3", "name": "استهلاكات بضاعة"},
    {"code": "4", "name": "انترنت"},
    {"code": "5", "name": "ايجار"},
    {"code": "6", "name": "بوفية"},
    {"code": "7", "name": "عمولة"},
    {"code": "8", "name": "صيانة"},
    {"code": "9", "name": "ضرائب"},
    {"code": "10", "name": "مرتبات"},
    {"code": "11", "name": "نظافة"},
    {"code": "12", "name": "تأمينات"},
    {"code": "13", "name": "نقل بضاعة"},
    {"code": "14", "name": "ارباح"},
    {"code": "15", "name": "بضاعة"},
    {"code": "16", "name": "تحويل من الفيزا"},
    {"code": "17", "name": "تحويل من النقدي"}
]

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
        category_set_ref = db.collection("coding").document(company_code).collection(category)
        docs = category_set_ref.stream()
        results = []
        for d in docs:
            item_data = d.to_dict()
            item_data["code"] = d.id  # نضمن إن الكود دايمًا موجود
            results.append(item_data)
            
        # 🔥 الإضافة الذكية: لو القسم المطلوبة هي "categories" وكانت اللستة لسه فاضية في السيرفر (ممسوحة أو شركة جديدة)
        if category == "categories" and not results:
            print(f"📦 Auto-creating 17 default categories for company: {company_code}")
            for default_cat in DEFAULT_CATEGORIES:
                # بنحفظهم فوراً في فايربيز عشان ميروحوش تاني
                category_set_ref.document(default_cat["code"]).set({
                    "name": default_cat["name"],
                    "code": default_cat["code"]
                })
                results.append(default_cat)
                
        # ترتيب العناصر تصاعدياً بناءً على الكود كرقم عشان يظهروا بانتظام (1، 2، 3.. لحد 17)
        try:
            results.sort(key=lambda x: int(x['code']))
        except ValueError:
            results.sort(key=lambda x: x['code'])
            
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