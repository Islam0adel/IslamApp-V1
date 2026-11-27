# update_backend_main.py
# سكريبت مزامنة main مع development - IslamApp V1.0
# main بيبقى نفس محتوى development (باك إند وواجهة والمشروع كله) ما عدا:
#   - backend/tests  - frontend/test  - tempCodeRunnerFile.py  - backend/app/feed_migrations (ملفات SQL)
# بيعمل commit جديد فوق main (تاريخ الفرعين مفصول، فمفيش merge ومفيش force push).
# لو الرفع محتاج force بيقف ويقولك، ومش بيعمله لوحده.
# الرفع على main بيشغّل النشر التلقائي على السيرفر، والسكريبت بيرفع على طول من غير سؤال.
# لازم تكون واقف على development، وكل شغلك محفوظ ومرفوع بـ update_dev.py قبل ما تشغّله.

import subprocess
import os
import sys

DEV = "development"
MAIN = "main"

EXCLUDED_PREFIXES = (
    "backend/tests/",
    "frontend/test/",
    "backend/app/feed_migrations/",
)
EXCLUDED_FILES = ("tempCodeRunnerFile.py",)

# ملفات لازم تفضل موجودة على main عشان النشر يشتغل
REQUIRED_ON_MAIN = (
    ".github/workflows/hf-sync.yml",
    "Dockerfile",
    "requirements.txt",
    "backend/app/main.py",
)


def run(cmd, env=None):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", env=env)
    except FileNotFoundError:
        print("❌ Git مش متسطب أو مش متاح من التيرمينال ده. السكريبت وقف من غير أي تغيير.")
        sys.exit(1)


class Stop(Exception):
    pass


def stop(stage, code):
    print(f"❌ خطوة «{stage}» فشلت (كود الخطأ: {code}).")
    print("   السكريبت وقف هنا من غير ما يكمل أي خطوة بعدها.")
    raise Stop()


def lines(result):
    return [l for l in (result.stdout or "").splitlines() if l.strip()]


def current_branch():
    r = run(["git", "branch", "--show-current"])
    return r.stdout.strip() if r.returncode == 0 else ""


def rev(ref):
    r = run(["git", "rev-parse", ref])
    return r.stdout.strip() if r.returncode == 0 else None


def is_excluded(path):
    return path in EXCLUDED_FILES or path.startswith(EXCLUDED_PREFIXES)


def tracked_changes():
    r = run(["git", "status", "--porcelain", "--untracked-files=no"])
    if r.returncode != 0:
        return r.returncode, None
    return 0, lines(r)


def check_dev_ready():
    code, changed = tracked_changes()
    if code != 0:
        stop("فحص حالة الملفات (git status)", code)
    if changed:
        print("⛔ فيه تعديلات لسه ماتحفظتش على development.")
        print("   شغّل update_dev.py الأول وبعدين شغّل السكريبت ده. وقفت من غير أي تغيير.")
        raise Stop()
    if run(["git", "fetch", "origin"]).returncode != 0:
        stop("تحديث معلومات الـremote (git fetch)", 1)
    local, remote = rev(DEV), rev(f"origin/{DEV}")
    if not local or not remote:
        print("⛔ مش لاقي development محليًا أو على origin. وقفت.")
        raise Stop()
    if local != remote:
        print("⛔ development عندك مش مطابق للي على origin (فيه commits مش مرفوعة أو العكس).")
        print("   شغّل update_dev.py الأول (أو حدّث الفرع) وبعدين شغّل السكريبت ده. وقفت من غير أي تغيير.")
        raise Stop()


def build_tree():
    """شجرة development من غير المستبعد، من غير ما نلمس الملفات ولا الـindex الحقيقي."""
    gd = run(["git", "rev-parse", "--git-dir"]).stdout.strip()
    idx = os.path.join(gd, "sync-main.index")
    if os.path.exists(idx):
        os.remove(idx)
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    try:
        if run(["git", "read-tree", DEV], env=env).returncode != 0:
            stop("قراءة شجرة development", 1)
        ls = run(["git", "ls-files"], env=env)
        if ls.returncode != 0:
            stop("قراءة الملفات", ls.returncode)
        drop = [p for p in lines(ls) if is_excluded(p)]
        for i in range(0, len(drop), 100):
            if run(["git", "rm", "-q", "--cached", "--"] + drop[i:i + 100], env=env).returncode != 0:
                stop("استبعاد الملفات", 1)
        wt = run(["git", "write-tree"], env=env)
        if wt.returncode != 0:
            stop("بناء الشجرة", wt.returncode)
        return wt.stdout.strip(), drop
    finally:
        if os.path.exists(idx):
            os.remove(idx)


def step_main():
    print("🔀 بيزامن main مع development (من غير الاستثناءات)...")
    if run(["git", "checkout", MAIN]).returncode != 0:
        print("⛔ مقدرتش أبدّل لفرع main (ممكن مش موجود محليًا أو فيه ملفات غير متتبّعة بتعارض). وقفت.")
        raise Stop()
    if run(["git", "pull", "--ff-only", "origin", MAIN]).returncode != 0:
        print("⛔ مقدرتش أحدّث main من origin (مش هعمل merge). وقفت قبل أي تغيير على main.")
        raise Stop()
    code, changed = tracked_changes()
    if code != 0 or changed:
        print("⛔ main مش نضيف بعد التحديث. وقفت.")
        raise Stop()

    tree, dropped = build_tree()
    main_tree = rev(f"{MAIN}^{{tree}}")
    ls = run(["git", "ls-tree", "-r", "--name-only", tree])
    present = set(lines(ls))
    missing = [p for p in REQUIRED_ON_MAIN if p not in present]
    if missing:
        print("⛔ ملفات لازمة للنشر مش موجودة في development:")
        for p in missing:
            print(f"   - {p}")
        print("   وقفت من غير أي تغيير على main.")
        raise Stop()

    if tree == main_tree:
        print("ℹ️  main نفس development (من غير الاستثناءات). مفيش حاجة تتحفظ أو تترفع.")
        return

    d = run(["git", "diff", "--name-status", "--no-renames", MAIN, tree])
    changes = [l.split("\t", 1) for l in lines(d)]
    n_add = sum(1 for s, _ in changes if s == "A")
    n_mod = sum(1 for s, _ in changes if s == "M")
    gone = [p for s, p in changes if s == "D"]
    print(f"📋 هيتغير على main: {n_add} ملف جديد، {n_mod} معدّل، {len(gone)} هيتمسح.")
    if gone:
        print("🗑️  هيتمسح من main (مش موجود في development):")
        for p in gone[:50]:
            print(f"   - {p}")
        if len(gone) > 50:
            print(f"   ... و{len(gone) - 50} كمان")
    print(f"🚫 مستبعد من development ({len(dropped)} ملف): backend/tests و frontend/test و tempCodeRunnerFile.py و feed_migrations.")

    ct = run(["git", "commit-tree", tree, "-p", rev(MAIN), "-m",
              "Sync main with development (without tests and temp files)"])
    if ct.returncode != 0 or not ct.stdout.strip():
        stop("بناء الـcommit", ct.returncode)
    new = ct.stdout.strip()
    # الـcommit فوق main مباشرة، فده fast-forward عادي
    if run(["git", "merge", "--ff-only", new]).returncode != 0:
        run(["git", "reset", "-q", "--hard", "HEAD"])
        print("⛔ مقدرتش أحدّث main محليًا. رجّعت main زي ما كان.")
        raise Stop()
    print("💾 تم الحفظ على main.")

    print("🚀 بيرفع على main دلوقتي. الرفع بيشغّل النشر التلقائي على السيرفر ...")
    refspec = f"refs/heads/{MAIN}:refs/heads/{MAIN}"
    up = run(["git", "rev-parse", "--abbrev-ref", f"{MAIN}@{{upstream}}"])
    cmd = ["git", "push", "origin", refspec] if up.returncode == 0 \
        else ["git", "push", "-u", "origin", refspec]
    if run(cmd).returncode != 0:
        print("❌ الرفع على main ما اتأكدش. مقدرش أقول وصلت حاجة للـremote ولا لأ.")
        print("   الـcommit موجود على main عندك محليًا بس. افتح صفحة الريبو وشوف آخر commit قبل ما تعيد المحاولة.")
        print("   السكريبت مش بيستخدم force push. لو الرفع اترفض لأن main على origin اتحرك، شغّل السكريبت تاني.")
        print("   هرجّعك لـ development.")
        raise Stop()
    print("✅ main بقى مزامَن مع development.")


def go_back():
    if current_branch() == DEV:
        return True
    if run(["git", "checkout", DEV]).returncode == 0 and current_branch() == DEV:
        print("↩️  رجعتك لفرع development.")
        return True
    print("⚠️  مقدرتش أرجّعك لـ development أوتوماتيك. بدّل بنفسك: git checkout development")
    return False


def main():
    if not os.path.exists(".git"):
        print("❌ الفولدر ده مش مستودع Git. شغّل السكريبت من جوه فولدر المشروع.")
        sys.exit(1)
    current = current_branch()
    if not current:
        print("❌ مش قادر أحدد الفرع الحالي. السكريبت وقف من غير أي تغيير.")
        sys.exit(1)
    if current != DEV:
        print(f"⛔ إنت واقف على فرع «{current}» مش development.")
        print("   السكريبت وقف من غير ما يحفظ أو يرفع أي حاجة. بدّل لـ development وشغّله تاني.")
        sys.exit(1)
    remote = run(["git", "remote", "get-url", "--push", "origin"])
    if remote.returncode != 0 or not remote.stdout.strip():
        print("❌ مفيش remote اسمه origin متظبط في المستودع. السكريبت وقف من غير رفع.")
        sys.exit(1)

    ok = True
    try:
        check_dev_ready()
        step_main()
    except Stop:
        ok = False
    finally:
        back = go_back()
    if not ok or not back:
        sys.exit(1)
    print("🎉 خلص: main مزامَن مع development، وإنت راجع على development.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n⏹️  السكريبت اتوقف بإلغاء منك.")
        go_back()
        sys.exit(1)
    except SystemExit:
        raise
    except Exception as e:
        print(f"❌ حصل خطأ غير متوقع ({type(e).__name__}). السكريبت وقف.")
        go_back()
        sys.exit(1)
