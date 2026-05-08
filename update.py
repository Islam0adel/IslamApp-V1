import subprocess
import os
from datetime import datetime

def run_git_commands():
    try:
        # 1. التأكد من وجود Git
        if not os.path.exists(".git"):
            print("❌ خطأ: المجلد ده مش مربوط بـ Git!")
            return

        # 2. إضافة كل التغييرات (add .)
        print("⏳ جاري سحب كل التغييرات الجديدة...")
        subprocess.run(["git", "add", "."], check=True)

        # 3. تجهيز رسالة تلقائية بالتاريخ والوقت
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        auto_message = f"Auto-Update: {now} - IslamApp V1.0"

        # 4. تنفيذ الـ Commit بالرسالة التلقائية
        print(f"💾 حفظ التغييرات برسالة: {auto_message}")
        subprocess.run(["git", "commit", "-m", auto_message], check=True)

        # 5. الرفع النهائي (Push)
        print("🚀 طيارة على جيت هب...")
        subprocess.run(["git", "push"], check=True)

        print(f"\n✅ مبروك يا إسلام! كل حاجة اتغيرت اترفت في ثانية.")

    except subprocess.CalledProcessError:
        print("\n⚠️ مفيش تغييرات جديدة تترفع أو فيه مشكلة في الاتصال.")
    except Exception as e:
        print(f"\n❌ خطأ غير متوقع: {e}")

if __name__ == "__main__":
    run_git_commands()