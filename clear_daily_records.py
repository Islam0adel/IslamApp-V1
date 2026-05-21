import os
import sys


# 1. إدخال بايثون داخل مجلد backend ليقرأ المحتويات بشكل صحيح
backend_path = os.path.join(os.path.dirname(__file__), 'backend')
if backend_path not in sys.path:
    sys.path.append(backend_path)

try:
    # 🟢 الحل هنا: الاستيراد المباشر من app لأننا أضفنا backend للمسارات بالفعل
    from app.core.firebase_setup import db
    print("✅ تم الاتصال بقاعدة بيانات الفايربيز بنجاح.")
except ImportError as e:
    print(f"❌ خطأ في الاستيراد: {e}")
    print("💡 محاولة الاستيراد بالطريقة البديلة...")
    try:
        # محاولة احتياطية في حال تشغيل الملف من داخل مجلد backend بالخطأ
        from backend.app.core.firebase_setup import db
        print("✅ تم الاتصال بقاعدة بيانات الفايربيز عبر المسار البديل.")
    except ImportError:
        print("❌ خطأ قاتل: لم يتم العثور على ملف firebase_setup. تأكد من وجود السكريبت في المجلد الرئيسي للمشروع.")
        sys.exit(1)

def delete_all_daily_records(company_code: str):
    """
    دالة تقوم بحذف كافة الحركات والعمليات المالية (الأذون اليومية) لشركة معينة نهائياً.
    """
    print(f"\n🔄 جاري البدء في مسح الأذون اليومية للشركة ذات الكود: {company_code} ...")
    
    collection_ref = db.collection("transactions").document(company_code).collection("daily_records")
    docs = list(collection_ref.list_documents())
    
    if not docs:
        print(f"💡 لا توجد أي أذون مسجلة حالياً للشركة ({company_code})، قاعدة البيانات نظيفة بالفعل!")
        return

    print(f"⚠️ تم العثور على ({len(docs)}) إذن مسجل. جاري الحذف الآن...")
    
    deleted_count = 0
    for doc in docs:
        doc.delete()
        deleted_count += 1
        print(f"🗑️ تم حذف الإذن رقم/المعرف: {doc.id} ({deleted_count}/{len(docs)})")
        
    print(f"\n✨ عملية التطهير تمت بنجاح! تم حذف جميع الأذون الـ {deleted_count} بالكامل.")

if __name__ == "__main__":
    TARGET_COMPANY_CODE = "01" 
    
    print("====================================================")
    print("🚨 تحذير أمني: هذا السكريبت سيقوم بحذف الأذون المالية نهائياً!")
    print("====================================================")
    
    confirm = input(f"هل أنت متأكد تماماً من رغبتك في مسح كافة أذون الشركة '{TARGET_COMPANY_CODE}'؟ (اكتب نعم للتأكيد): ")
    
    if confirm.strip() == "نعم":
        delete_all_daily_records(company_code=TARGET_COMPANY_CODE)
    else:
        print("❌ تم إلغاء العملية ولم يتم حذف أي شيء.")