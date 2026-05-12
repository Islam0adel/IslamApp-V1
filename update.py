import subprocess
import os
from datetime import datetime

def run_git_commands():
    try:
        # 1. التأكد من وجود Git
        if not os.path.exists(".git"):
            print("❌ folder not acces try path again !")
            return

        # 2. إضافة كل التغييرات (add .)
        print("⏳ Loading....")
        subprocess.run(["git", "add", "."], check=True)

        # 3. تجهيز رسالة تلقائية بالتاريخ والوقت
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        auto_message = f"Auto-Update: {now} - IslamApp V1.0"

        # 4. تنفيذ الـ Commit بالرسالة التلقائية
        print(f"💾 Save {auto_message}")
        subprocess.run(["git", "commit", "-m", auto_message], check=True)

        # 5. الرفع النهائي (Push)
        print("🚀 Loading....")
        subprocess.run(["git", "push"], check=True)

        print(f"\n✅Done,,,")

    except subprocess.CalledProcessError:
        print("\n⚠️ No New File or Update")
    except Exception as e:
        print(f"\n❌  {e}")

if __name__ == "__main__":
    run_git_commands()