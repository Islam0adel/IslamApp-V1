# update_main.py
# سكريبت الرفع على main فقط - IslamApp V1.0
# بيحفظ كل التعديلات ويرفعها على main في الـremote المسمى origin
# لو إنت واقف على فرع تاني، السكريبت يقف من غير ما يعمل أي حاجة

import subprocess
import os
import sys
from datetime import datetime


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print("❌ Git مش متسطب أو مش متاح من التيرمينال ده. السكريبت وقف من غير أي تغيير.")
        sys.exit(1)


def fail(stage, code):
    # من غير ما نطبع نص خطأ Git الخام (ممكن يحتوي عناوين أو بيانات دخول)
    print(f"❌ خطوة «{stage}» فشلت (كود الخطأ: {code}).")
    print("   السكريبت وقف هنا من غير ما يكمل أي خطوة بعدها.")
    sys.exit(1)


def main():
    # 1. التأكد إننا جوه مستودع Git
    if not os.path.exists(".git"):
        print("❌ الفولدر ده مش مستودع Git. شغّل السكريبت من جوه فولدر المشروع.")
        sys.exit(1)

    # 2. التأكد إن الفرع الحالي هو main
    branch = run(["git", "branch", "--show-current"])
    current = branch.stdout.strip()
    if branch.returncode != 0 or not current:
        print("❌ مش قادر أحدد الفرع الحالي. السكريبت وقف من غير أي تغيير.")
        sys.exit(1)
    if current != "main":
        print(f"⛔ إنت واقف على فرع «{current}» مش main.")
        print("   السكريبت ده للرفع على main بس، فوقف من غير ما يحفظ أو يرفع أي حاجة.")
        sys.exit(1)

    # 3. التأكد إن فيه remote اسمه origin (العنوان نفسه مش هيتطبع عشان الأمان)
    remote = run(["git", "remote", "get-url", "--push", "origin"])
    if remote.returncode != 0 or not remote.stdout.strip():
        print("❌ مفيش remote اسمه origin متظبط في المستودع. السكريبت وقف من غير رفع.")
        sys.exit(1)

    print(f"📌 الفرع: {current}  |  الرفع إلى: فرع main في الـremote المسمى origin (حسب إعداداتك)")

    # 4. تجهيز كل التغييرات
    add = run(["git", "add", "."])
    if add.returncode != 0:
        fail("تجهيز الملفات (git add)", add.returncode)

    # 5. هل فيه تغييرات متجهزة للحفظ؟
    staged = run(["git", "diff", "--cached", "--quiet"])
    if staged.returncode == 0:
        committed_now = False
        print("ℹ️  مفيش تعديلات جديدة للحفظ. هتأكد من الـremote نفسه لو فيه commits لسه مترفعتش.")
    elif staged.returncode == 1:
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        message = f"Auto-Update: {now} - IslamApp V1.0"
        commit = run(["git", "commit", "-m", message])
        if commit.returncode != 0:
            fail("الحفظ (git commit)", commit.returncode)
        committed_now = True
        print(f"💾 تم الحفظ: {message}")
    else:
        fail("فحص التغييرات (git diff)", staged.returncode)

    # 6. الرفع الفعلي على الـremote: من main المحلي لـ main على origin بالتحديد
    #    الرفع دايمًا بيتم، حتى لو مفيش commit جديد، عشان نتأكد من حالة الـremote الحقيقية
    print("🚀 بيرفع على فرع main في origin ...")
    push = run(["git", "push", "origin", "refs/heads/main:refs/heads/main"])
    push_output = (push.stdout or "") + (push.stderr or "")

    if push.returncode != 0:
        print("❌ الرفع ما اتأكدش. مقدرش أقول وصلت حاجة للـremote ولا لأ.")
        print("   الـcommits المحفوظة عندك موجودة محليًا ومش ضاعت.")
        print("   افتح صفحة الريبو على جيت هب وشوف آخر commit قبل ما تعيد المحاولة،")
        print("   وماتستخدمش force push.")
        sys.exit(1)

    if not committed_now and "Everything up-to-date" in push_output:
        print("✅ اتأكدنا من الـremote نفسه: كل حاجة مترفعة أصلًا على main. مفيش حاجة جديدة.")
    else:
        print("✅ تم الرفع على main بنجاح.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n⏹️  السكريبت اتوقف بإلغاء منك.")
        sys.exit(1)
    except Exception as e:
        print(f"❌ حصل خطأ غير متوقع ({type(e).__name__}). السكريبت وقف.")
        sys.exit(1)
