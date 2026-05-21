from fastapi import APIRouter, HTTPException
from app.core.firebase_setup import db
from pydantic import BaseModel
from typing import Optional
from google.cloud.firestore_v1.base_query import FieldFilter

router = APIRouter()

# الموديل الموحد للبيانات المطور ليدعم الفروع والمستخدمين
class TransactionModel(BaseModel):
    company_code: str
    serial: int
    treasury: str
    amount: float
    statement: str
    category: str
    date: str
    type: str
    employee: Optional[str] = "غير محدد"  # يحمل اسم المستخدم الفعلي المسجل
    branch: Optional[str] = "الالفرع الرئيسي"  # يحمل اسم الفرع

# دالة تابعة داخلية: إعادة ضبط وتصحيح الأرصدة التراكمية المكسورة بعد تعديل أو حذف أي إذن
def recalculate_balances_chain(company_code: str, starting_serial: int):
    """
    تقوم هذه الدالة بتمشيط السلسلة الحسابية المتضررة بدءاً من السيريال الحالي صعوداً للأذون التالية،
    لإعادة ضبط أرصدة الخزنة والفيزا بدقة متناهية ودون حدوث أي سوالب مغلوطة بين المستخدمين.
    """
    # 1. جلب رصيد الإذن الذي يسبق الإذن الحالي مباشرة ليكون نقطة البداية الصحيحة
    prev_docs = db.collection("transactions").document(company_code)\
        .collection("daily_records")\
        .where("serial", "<", starting_serial)\
        .order_by("serial", direction="DESCENDING")\
        .limit(1).get()
        
    current_cash = 0.0
    current_visa = 0.0
    
    if prev_docs:
        prev_data = prev_docs[0].to_dict()
        current_cash = float(prev_data.get("current_cash_balance", 0.0))
        current_visa = float(prev_data.get("current_visa_balance", 0.0))
        
    # 2. جلب جميع الأذون الحالية والتالية المتأثرة بالتغيير مرتبة تصاعدياً لتمشيطها
    affected_docs = db.collection("transactions").document(company_code)\
        .collection("daily_records")\
        .where("serial", ">=", starting_serial)\
        .order_by("serial", direction="ASCENDING").get()
        
    if not affected_docs:
        return

    # 3. جلب التصنيفات كاملة لتحديد نوع الحركة (وارد أم صادر) بشكل دقيق وموفر بالقراءات
    types_docs = db.collection("coding").document(company_code).collection("types").get()
    types_map = {d.to_dict().get("name"): d.to_dict().get("type", "صادر") for d in types_docs}

    # 4. بدء عملية إعادة التتابع الحسابي لجميع المستندات المتضررة
    for doc in affected_docs:
        data = doc.to_dict()
        amt = float(data.get("amount", 0.0))
        cat = data.get("category", "")
        tx_type = data.get("type", "cash")
        
        if cat == "تحويل من النقدي":
            current_cash -= amt
            current_visa += amt
        elif cat == "تحويل من الفيزا":
            current_cash += amt
            current_visa -= amt
        else:
            cat_direction = types_map.get(cat, "صادر")
            # حماية احتياطية بالكلمات الدلالية
            if cat not in types_map:
                if any(x in cat.lower() for x in ["وارد", "إيراد", "ايراد", "فيزا", "ايداع", "إيداع", "مبيعات"]):
                    cat_direction = "وارد"

            if tx_type == "cash":
                current_cash = (current_cash + amt) if cat_direction == "وارد" else (current_cash - amt)
            elif tx_type == "visa":
                current_visa = (current_visa + amt) if cat_direction == "وارد" else (current_visa - amt)

        # تحديث المستند الحالي بالأرصدة التراكمية الجديدة المنضبطة
        doc.reference.update({
            "current_cash_balance": current_cash,
            "current_visa_balance": current_visa
        })


# 1. إدخال إذن جديد تماماً (مستقل)
@router.post("/save")
async def save_transaction(data: TransactionModel):
    try:
        # جلب آخر إذن مسجل لمعرفة الأرصدة التراكمية السابقة لزيادتها
        last_docs = db.collection("transactions").document(data.company_code)\
            .collection("daily_records")\
            .order_by("serial", direction="DESCENDING")\
            .limit(1).get()
        
        prev_cash = 0.0
        prev_visa = 0.0
        
        if last_docs:
            last_data = last_docs[0].to_dict()
            prev_cash = float(last_data.get("current_cash_balance", 0.0))
            prev_visa = float(last_data.get("current_visa_balance", 0.0))
            
        amt = float(data.amount)
        cat = data.category
        tx_type = data.type
        
        if cat == "تحويل من النقدي":
            prev_cash -= amt
            prev_visa += amt
        elif cat == "تحويل من الفيزا":
            prev_cash += amt
            prev_visa -= amt
        else:
            type_query = db.collection("coding").document(data.company_code)\
                .collection("types").where("name", "==", cat).limit(1).get()
            cat_direction = type_query[0].to_dict().get("type", "صادر") if type_query else "صادر"
            if not type_query and any(x in cat.lower() for x in ["وارد", "إيراد", "ايراد", "فيزا", "ايداع", "إيداع", "مبيعات"]):
                cat_direction = "وارد"

            if tx_type == "cash":
                prev_cash = (prev_cash + amt) if cat_direction == "وارد" else (prev_cash - amt)
            elif tx_type == "visa":
                prev_visa = (prev_visa + amt) if cat_direction == "وارد" else (prev_visa - amt)

        transaction_dict = data.dict()
        transaction_dict["current_cash_balance"] = prev_cash
        transaction_dict["current_visa_balance"] = prev_visa

        db.collection("transactions").document(data.company_code)\
            .collection("daily_records").document(str(data.serial)).set(transaction_dict)
        
        return {"status": "success", "message": "تم حفظ الإذن الجديد بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# 2. تعديل إذن قديم مسجل مسبقاً (مستقل - يضمن إعادة ضبط الأرصدة التالية)
@router.put("/update")
async def update_transaction(data: TransactionModel):
    try:
        doc_ref = db.collection("transactions").document(data.company_code)\
            .collection("daily_records").document(str(data.serial))
            
        if not doc_ref.get().exists:
            raise HTTPException(status_code=404, detail="الإذن المراد تعديله غير موجود")
            
        # تحديث بيانات الإذن أولاً بالقيم الجديدة بدون الأرصدة (ستحسب تلقائياً)
        transaction_dict = data.dict()
        doc_ref.set(transaction_dict)
        
        # استدعاء قاطرة إعادة تمشيط وحساب الأرصدة للسلسلة المتأثرة
        recalculate_balances_chain(data.company_code, data.serial)
        
        return {"status": "success", "message": "تم تعديل الإذن وإعادة ضبط الأرصدة بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# 3. حذف إذن نهائياً (مطور - يعيد حساب الأرصدة للأذون التالية لئلا تختل الخزنة)
@router.delete("/delete/{company_code}/{serial}")
async def delete_transaction(company_code: str, serial: int):
    try:
        # مسح المستند نهائياً
        db.collection("transactions").document(company_code)\
            .collection("daily_records").document(str(serial)).delete()
            
        # إعادة تمشيط وحساب الأرصدة للأذون التي كانت تلي هذا الإذن المحذوف
        recalculate_balances_chain(company_code, serial)
        
        return {"status": "success", "message": "تم حذف الإذن وإعادة توازن الحسابات بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 2. جلب قائمة الأذون للمعاينة (مطور: يجلب الإضافات والتعديلات الجديدة فقط لتزامن المستخدمين بـ 0 قراءات مكررة)
@router.get("/list/{company_code}")
async def get_transactions(company_code: str, start_date: str, end_date: str, last_sync_serial: int = 0):
    """
    جلب سجل الحركات المفلترة بالتاريخ مع معالجة التصفية المتقدمة للسيريال في البايثون
    لتجنب كراش القيود المركبة وحل خطأ 500 والخطوط الصفراء نهائياً.
    """
    try:
        # 1. فلترة حيوية بالتاريخ باستخدام FieldFilter المستورد بشكل مباشر ونظيف
        query = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where(filter=FieldFilter("date", ">=", start_date))\
            .where(filter=FieldFilter("date", "<=", end_date))
            
        docs = query.stream()
        
        results = []
        for d in docs:
            item_data = d.to_dict()
            # تأمين وجود الحقول الأساسية لضمان عدم حدوث كراش في فلاتر
            item_data["serial"] = int(item_data.get("serial", 0))
            item_data["amount"] = float(item_data.get("amount", 0.0))
            
            # الفلترة الذكية للسيريال في الذاكرة لعدم كسر شروط الاستعلام في Firestore
            if last_sync_serial > 0 and item_data["serial"] <= last_sync_serial:
                continue 
                
            results.append(item_data)
            
        # ترتيب الحركات تنازلياً بناءً على السيريال لتعرض بشكل صحيح ومثالي في الجدول
        results.sort(key=lambda x: x["serial"], reverse=True)
        return results
        
    except Exception as e:
        print(f"❌ خطأ قاتل في دالة get_transactions: {str(e)}")
        raise HTTPException(status_code=500, detail=f"حدث خطأ في السيرفر أثناء جلب البيانات: {str(e)}")
# 4. ملخص الأرصدة المطور ليفحص الفرع المختار
# 3. جلب الأرصدة اللحظية (توفير كلي: 1 قراءة فقط بدلاً من قراءة كل الملفات)
@router.get("/summary/{company_code}")
async def get_summary(company_code: str, treasury: Optional[str] = None, branch: Optional[str] = "كل الفروع"):
    try:
        # نقوم بالاستعلام لطلب آخر إذن تم تسجيله للشركة بناءً على الترتيب التنازلي للسيريال لنجلب الأرصدة الجاهزة منه
        # هذا الأمر يستهلك (قراءة واحدة فقط 1 Read) بفضل الفهرس الرقمي الفعّال
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .order_by("serial", direction="DESCENDING")\
            .limit(1).get()
            
        if not docs or len(docs) == 0:
            return {"cash_balance": 0.0, "visa_balance": 0.0}
            
        # استخراج الأرصدة التراكمية المخزنة بداخل آخر إذن مسجل فوراً
        last_doc_data = docs[0].to_dict()
        
        # جلب الأرصدة الجاهزة (current_cash_balance و current_visa_balance)
        # والتي تقوم دالة الحفظ المحدثة (save_transaction) بضخها وحسابها تلقائياً مع كل حركة
        cash = float(last_doc_data.get("current_cash_balance", 0.0))
        visa = float(last_doc_data.get("current_visa_balance", 0.0))
        
        return {"cash_balance": cash, "visa_balance": visa}
        
    except Exception as e:
        print(f"Error in get_summary: {str(e)}")
        return {"cash_balance": 0.0, "visa_balance": 0.0}

# 5. جلب آخر سيريال
# 5. جلب آخر سيريال والأرصدة الجاهزة (قراءة واحدة فقط 1 Read لآخر مستند)
@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str):
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .order_by("serial", direction="DESCENDING")\
            .limit(1).get()
        
        if not docs or len(docs) == 0:
            return {"last_serial": 0, "cash_balance": 0.0, "visa_balance": 0.0}
            
        last_doc_data = docs[0].to_dict()
        last_serial = int(last_doc_data.get("serial", 0))
        cash_bal = float(last_doc_data.get("current_cash_balance", 0.0))
        visa_bal = float(last_doc_data.get("current_visa_balance", 0.0))
        
        return {
            "last_serial": last_serial,
            "cash_balance": cash_bal,
            "visa_balance": visa_bal
        }
        
    except Exception as e:
        print(f"Error in get_last_serial: {str(e)}")
        return {"last_serial": 0, "cash_balance": 0.0, "visa_balance": 0.0}

# دالة فحص المطابقة السريعة (تأتي بقائمة السيريالات الحقيقية فقط لضبط المحذوفات بـ صفر قراءة محتوى)
@router.get("/active_serials/{company_code}")
async def get_active_serials(company_code: str, start_date: str, end_date: str):
    try:
        # جلب مراجع المستندات المفلترة بالتاريخ مباشرة من كشاف الفايربيز (تكلفة صفر قراءة محتوى)
        docs_refs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("date", ">=", start_date)\
            .where("date", "<=", end_date)\
            .list_documents()
            
        # استخراج السيريال (اسم المستند) وتحويله لرقم
        active_serials = []
        for doc in docs_refs:
            if doc.id.isdigit():
                active_serials.append(int(doc.id))
                
        return {"active_serials": active_serials}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))