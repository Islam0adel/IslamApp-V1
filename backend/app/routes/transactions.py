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
    branch: Optional[str] = "الفرع الرئيسي"  # يحمل اسم الفرع


# =====================================================================
# 🛠️ محرك المزامنة الذكي المساعد (تنبيه الهواتف بالتغييرات فوراً لتوفير القراءات)
# =====================================================================

def trigger_sync_update(company_code: str):
    """
    دالة داخلية تقوم بتحديث مستند صغير جداً في الفايربيز يحمل وقت آخر حركة بالمنظومة
    لتعلم الهواتف بوجود (إضافة/تعديل/حذف) فتقوم بتحديث الكاش المحلي الخاص بها فوراً.
    """
    try:
        from datetime import datetime
        now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        db.collection("sync_metadata").document(company_code).set({
            "last_update_timestamp": now_str
        }, merge=True)
        print(f"🔔 [Sync Engine] تم تحديث نبض الشبكة للشركة {company_code} إلى: {now_str}")
    except Exception as e:
        print(f"⚠️ تحذير: فشل تحديث نبض الشبكة المساعد: {str(e)}")


@router.get("/sync_check/{company_code}")
async def check_network_sync(company_code: str):
    """
    رابط فحص التزامن السريع: يستعلم عن مستند النبض الصغير جداً لمعرفة هل حدث تغيير بالسيستم،
    بدلاً من جلب محتويات الأذون بالكامل في كل مرة ليوفر 90% من قراءات الفايربيز.
    """
    try:
        sync_doc = db.collection("sync_metadata").document(company_code).get()
        if sync_doc.exists:
            return sync_doc.to_dict()
        return {"last_update_timestamp": ""}
    except Exception as e:
        return {"last_update_timestamp": ""}


# =====================================================================
# 📈 قاطرة الحسابات التابعة (إعادة تمشيط وحساب الأرصدة)
# =====================================================================

def recalculate_balances_chain(company_code: str, starting_serial: int):
    """
    تقوم هذه الدالة بتمشيط السلسلة الحسابية المتضررة بدءاً من السيريال الحالي صعوداً للأذون التالية،
    لإعادة ضبط أرصدة الخزنة والفيزا بدقة متناهية ودون حدوث أي سوالب مغلوطة بين المستخدمين.
    """
    try:
        # 1. جلب رصيد الإذن الذي يسبق الإذن الحالي مباشرة ليكون نقطة البداية الصحيحة
        prev_docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where(filter=FieldFilter("serial", "<", starting_serial))\
            .order_by("serial", direction="DESCENDING")\
            .limit(1).get()
            
        running_cash = 0.0
        running_visa = 0.0
        
        if prev_docs:
            prev_data = prev_docs[0].to_dict()
            running_cash = float(prev_data.get("current_cash_balance", 0.0))
            running_visa = float(prev_data.get("current_visa_balance", 0.0))
            
        # 2. جلب كافة الأذون المتأثرة التي تساوي أو تلي السيريال الحالي لترتيب تصاعدي وإعادة تجميعها
        affected_docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where(filter=FieldFilter("serial", ">=", starting_serial))\
            .order_by("serial", direction="ASCENDING").get()
            
        if not affected_docs:
            return
            
        # 3. فتح خط معالجة الحسابات المتسلسلة (Batch Update) لتحديث القيود دفعة واحدة بسرعة
        batch = db.batch()
        
        for doc in affected_docs:
            d_data = doc.to_dict()
            amt = float(d_data.get("amount", 0.0))
            cat = d_data.get("category", "")
            tx_type = d_data.get("type", "cash")
            
            if cat == "تحويل من النقدي":
                running_cash -= amt
                running_visa += amt
            elif cat == "تحويل من الفيزا":
                running_cash += amt
                running_visa -= amt
            else:
                type_query = db.collection("coding").document(company_code)\
                    .collection("types").where("name", "==", cat).limit(1).get()
                cat_direction = type_query[0].to_dict().get("type", "صادر") if type_query else "صادر"
                if not type_query and any(x in cat.lower() for x in ["وارد", "إيراد", "ايراد", "فيزا", "ايداع", "إيداع", "مبيعات"]):
                    cat_direction = "وارد"

                if tx_type == "cash":
                    running_cash = (running_cash + amt) if cat_direction == "وارد" else (running_cash - amt)
                elif tx_type == "visa":
                    running_visa = (running_visa + amt) if cat_direction == "وارد" else (running_visa - amt)
            
            # حقن الأرصدة الجديدة التراكمية في المستند
            d_data["current_cash_balance"] = running_cash
            d_data["current_visa_balance"] = running_visa
            
            batch.set(doc.reference, d_data)
            
        batch.commit()
        print(f"✅ [Recalculate] تم إعادة توازن السلسلة الحسابية بنجاح بدءاً من السيريال {starting_serial}")
    except Exception as e:
        print(f"❌ خطأ أثناء إعادة حساب السلسلة: {str(e)}")


# =====================================================================
# 💾 دوال العمليات المالية الرئيسية (الحفظ، التعديل، الحذف)
# =====================================================================

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

        # حفظ المستند في الفايربيز
        db.collection("transactions").document(data.company_code)\
            .collection("daily_records").document(str(data.serial)).set(transaction_dict)
        
        # 🔥 [تحديث نبض الشبكة]: إبلاغ الهواتف بوجود حركة جديدة لتحديث الكاش تلقائياً
        trigger_sync_update(data.company_code)
        
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
        
        # 🔥 [تحديث نبض الشبكة]: إبلاغ الهواتف بوجود تعديل لتصحيح المعاينة والكاش فوراً
        trigger_sync_update(data.company_code)
        
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
        
        # 🔥 [تحديث نبض الشبكة]: إبلاغ الهواتف بحدوث حذف ليختفي الإذن من كاش الهاتف فوراً
        trigger_sync_update(company_code)
        
        return {"status": "success", "message": "تم حذف الإذن وإعادة توازن الحسابات بنجاح"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# =====================================================================
# 🔍 دوال الاستعلام، التقارير والأرصدة الجاهزة
# =====================================================================

@router.get("/list/{company_code}")
async def get_transactions(company_code: str, start_date: str, end_date: str, last_sync_serial: int = 0):
    """
    جلب سجل الحركات المفلترة بالتاريخ بالكامل لمطابقة التعديلات والإضافات
    وتسجيلها في كاش الموبايل دفعة واحدة فور حدوث أي نبضة تحديث على الشبكة.
    """
    try:
        # فلترة حيوية بالتاريخ باستخدام الفلتر النظيف للفايربيز
        query = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where(filter=FieldFilter("date", ">=", start_date))\
            .where(filter=FieldFilter("date", "<=", end_date))
            
        docs = query.stream()
        
        results = []
        for d in docs:
            item_data = d.to_dict()
            item_data["serial"] = int(item_data.get("serial", 0))
            item_data["amount"] = float(item_data.get("amount", 0.0))
            
            results.append(item_data)
            
        # ترتيب الحركات تنازلياً بناءً على السيريال لتعرض بشكل صحيح ومثالي في الجدول
        results.sort(key=lambda x: x["serial"], reverse=True)
        return results
        
    except Exception as e:
        print(f"❌ خطأ قاتل في دالة get_transactions: {str(e)}")
        raise HTTPException(status_code=500, detail=f"حدث خطأ في السيرفر أثناء جلب البيانات: {str(e)}")


@router.get("/summary/{company_code}")
async def get_summary(company_code: str, treasury: Optional[str] = None, branch: Optional[str] = "كل الفروع"):
    """
    جلب الأرصدة اللحظية بقراءة قيد واحد فقط (1 Read) لآخر حركة بالسيستم لضمان أعلى توفير.
    """
    try:
        docs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .order_by("serial", direction="DESCENDING")\
            .limit(1).get()
            
        if not docs or len(docs) == 0:
            return {"cash_balance": 0.0, "visa_balance": 0.0}
            
        last_doc_data = docs[0].to_dict()
        cash = float(last_doc_data.get("current_cash_balance", 0.0))
        visa = float(last_doc_data.get("current_visa_balance", 0.0))
        
        return {"cash_balance": cash, "visa_balance": visa}
    except Exception as e:
        print(f"Error in get_summary: {str(e)}")
        return {"cash_balance": 0.0, "visa_balance": 0.0}


@router.get("/last_serial/{company_code}")
async def get_last_serial(company_code: str):
    """
    جلب آخر سيريال مسجل والأرصدة الجاهزة التابعة له في قراءة واحدة سريعة.
    """
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


@router.get("/active_serials/{company_code}")
async def get_active_serials(company_code: str, start_date: str, end_date: str):
    """
    دالة فحص السيريالات النشطة المفلترة بالتاريخ لتمكين الهواتف من تطهير المحذوفات تلقائياً بتكلفة صفر قراءة محتوى.
    """
    try:
        docs_refs = db.collection("transactions").document(company_code)\
            .collection("daily_records")\
            .where("date", ">=", start_date)\
            .where("date", "<=", end_date)\
            .list_documents()
            
        active_serials = []
        for doc in docs_refs:
            if doc.id.isdigit():
                active_serials.append(int(doc.id))
                
        return {"active_serials": active_serials}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))