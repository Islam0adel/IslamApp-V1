# backend/app/services/hr_salary_calculator.py

"""
حساب الراتب الشهري للموظف

القواعد الجديدة (بناءً على delay_rules من إعدادات الموظف):
- قيمة اليوم = الراتب الأساسي / 30
- قيمة الساعة = قيمة اليوم / ساعات العمل (افتراضي 8)
- الإجازات (official + weekly + vacation) = مدفوعة بدون خصم
- الغياب = خصم حسب delay_rules['absence'] (افتراضي: 3 يوم)
- الغياب بإذن = خصم حسب delay_rules['absence_with_permission'] (افتراضي: 1 يوم)
- التأخير = خصم حسب delay_rules (يُحدد الشريحة من late_minutes)
- الإضافي = (دقائق / 60) × قيمة الساعة × multiplier
"""

from typing import Optional
from datetime import datetime
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.models import (
    Employee,
    HRAttendance,
    HRVacation,
    HRAdjustment,
    HRSettings,
    HREmployeeSettings,
)


# ============================================================
# قيم افتراضية (لو مفيش إعدادات)
# ============================================================

DEFAULT_WORK_HOURS_PER_DAY = 8.0
DEFAULT_LATE_GRACE_MINUTES = 15
DEFAULT_OVERTIME_MULTIPLIER = 1.5
DEFAULT_WEEKLY_VACATION_DAY = 5  # الجمعة
DEFAULT_DAYS_PER_MONTH = 30


# ============================================================
# ✅ قواعد الخصم الافتراضية للتأخير والغياب
#
# كل قيمة = عدد أيام الخصم
# مثال: delay_15min = 0.25 → خصم ربع يوم
# ============================================================

DEFAULT_DELAY_RULES = {
    'delay_10min': 0.0,                 # حتى 10 دقائق → بدون خصم
    'delay_15min': 0.25,                # 10-30 دقيقة → ربع يوم
    'delay_30min': 0.5,                 # 30-60 دقيقة → نصف يوم
    'delay_60min': 1.0,                 # 60-120 دقيقة → يوم كامل
    'delay_120min': 2.0,                # أكثر من 120 دقيقة → يومان
    'absence': 3.0,                     # غياب بدون إذن → يوم كامل
    'absence_with_permission': 1.0,     # غياب بإذن → نصف يوم
}

def _time_to_minutes(t: str) -> int:
    """يحوّل 'HH:MM' إلى عدد دقائق من منتصف الليل"""
    if not t:
        return 0
    try:
        h, m = t.split(':')
        return int(h) * 60 + int(m)
    except (ValueError, AttributeError):
        return 0


# ============================================================
# Helper: تحديد أيام الخصم من دقائق التأخير
# ============================================================

def _get_delay_deduction_days(late_minutes: int, rules: dict) -> float:
    """
    يرجع عدد أيام الخصم حسب دقائق التأخير

    الشرائح:
    - 0-10 دقيقة     → delay_10min
    - 11-30 دقيقة    → delay_15min
    - 31-60 دقيقة    → delay_30min
    - 61-120 دقيقة   → delay_60min
    - أكثر من 120    → delay_120min
    """
    if late_minutes <= 10:
        return float(rules.get('delay_10min', 0.0))
    elif late_minutes <= 30:
        return float(rules.get('delay_15min', 0.25))
    elif late_minutes <= 60:
        return float(rules.get('delay_30min', 0.5))
    elif late_minutes <= 120:
        return float(rules.get('delay_60min', 1.0))
    else:
        return float(rules.get('delay_120min', 2.0))


# ============================================================
# Helper: جلب إعدادات HR
# ============================================================

async def _get_settings(
    db: AsyncSession,
    company_code: str,
    branch_code: Optional[str] = None,
) -> dict:
    """
    يجيب إعدادات HR:
    - الأول: إعدادات الفرع (لو موجودة)
    - الثاني: إعدادات الشركة (branch_code = null)
    - الثالث: القيم الافتراضية
    """

    # 1) إعدادات الفرع
    if branch_code:
        stmt = select(HRSettings).where(
            HRSettings.company_code == company_code,
            HRSettings.branch_code == branch_code,
        )
        result = await db.execute(stmt)
        settings = result.scalar_one_or_none()
        if settings:
            return {
                'work_hours': settings.work_hours_per_day or DEFAULT_WORK_HOURS_PER_DAY,
                'grace_minutes': settings.late_grace_minutes or DEFAULT_LATE_GRACE_MINUTES,
                'overtime_multiplier': settings.overtime_multiplier or DEFAULT_OVERTIME_MULTIPLIER,
                'weekly_vacation_day': settings.weekly_vacation_day if settings.weekly_vacation_day is not None else DEFAULT_WEEKLY_VACATION_DAY,
            }

    # 2) إعدادات الشركة
    stmt = select(HRSettings).where(
        HRSettings.company_code == company_code,
        HRSettings.branch_code.is_(None),
    )
    result = await db.execute(stmt)
    settings = result.scalar_one_or_none()
    if settings:
        return {
            'work_hours': settings.work_hours_per_day or DEFAULT_WORK_HOURS_PER_DAY,
            'grace_minutes': settings.late_grace_minutes or DEFAULT_LATE_GRACE_MINUTES,
            'overtime_multiplier': settings.overtime_multiplier or DEFAULT_OVERTIME_MULTIPLIER,
            'weekly_vacation_day': settings.weekly_vacation_day if settings.weekly_vacation_day is not None else DEFAULT_WEEKLY_VACATION_DAY,
        }

    # 3) افتراضي
    return {
        'work_hours': DEFAULT_WORK_HOURS_PER_DAY,
        'grace_minutes': DEFAULT_LATE_GRACE_MINUTES,
        'overtime_multiplier': DEFAULT_OVERTIME_MULTIPLIER,
        'weekly_vacation_day': DEFAULT_WEEKLY_VACATION_DAY,
    }


# ============================================================
# Helper: عدد أيام الشهر
# ============================================================

def _days_in_month(month: str) -> int:
    """month = 'YYYY-MM' → عدد أيام الشهر"""
    parts = month.split('-')
    year = int(parts[0])
    m = int(parts[1])
    if m == 12:
        nxt = datetime(year + 1, 1, 1)
    else:
        nxt = datetime(year, m + 1, 1)
    cur = datetime(year, m, 1)
    return (nxt - cur).days


# ============================================================
# Helper: هل التاريخ إجازة أسبوعية؟
# ============================================================

def _is_weekly_vacation(date_str: str, weekly_day: int) -> bool:
    """
    date_str = 'YYYY-MM-DD'
    weekly_day = 0 (الأحد) ... 5 (الجمعة) ... 6 (السبت)
    """
    try:
        dt = datetime.strptime(date_str, '%Y-%m-%d')
        py_day = dt.weekday()  # 0=Mon
        our_day = (py_day + 1) % 7  # 0=Sun
        return our_day == weekly_day
    except (ValueError, TypeError):
        return False


# ============================================================
# الدالة الرئيسية: حساب الراتب
# ============================================================

async def calculate_salary(
    db: AsyncSession,
    company_code: str,
    employee_code: str,
    month: str,  # "YYYY-MM"
) -> dict:
    """
    يحسب راتب موظف في شهر معين

    Returns:
        dict يحتوي على كل التفاصيل + البنود
    """

    # ============================================================
    # 1) الموظف
    # ============================================================
    stmt = select(Employee).where(
        Employee.company_code == company_code,
        Employee.code == employee_code,
        Employee.is_deleted.is_(False),
    )
    result = await db.execute(stmt)
    employee = result.scalar_one_or_none()

    if not employee:
        raise ValueError(f"الموظف [{employee_code}] غير موجود")

    base_salary = employee.salary or 0.0
    branch_code = employee.branch_code or "1"

    # ============================================================
    # 2) إعدادات الموظف
    # ============================================================
    stmt = select(HREmployeeSettings).where(
        HREmployeeSettings.company_code == company_code,
        HREmployeeSettings.employee_code == employee_code,
    )
    result = await db.execute(stmt)
    emp_settings = result.scalar_one_or_none()

    # القيم الافتراضية
    weekly_day = emp_settings.weekly_vacation_day if emp_settings else None
    default_check_in = emp_settings.default_check_in if emp_settings else "09:00"
    default_check_out = emp_settings.default_check_out if emp_settings else "17:00"
    flexible_hours = emp_settings.flexible_hours if emp_settings else False
        # ⭐ جديد: هل الشهر ثابت 30 يوم؟
    use_fixed_month_days = (
        emp_settings.use_fixed_month_days
        if emp_settings
        else True
    )

    # ✅ قواعد التأخير من إعدادات الموظف (مع defaults)
    delay_rules = dict(DEFAULT_DELAY_RULES)
    if emp_settings and isinstance(emp_settings.delay_rules, dict):
        for k, v in emp_settings.delay_rules.items():
            if isinstance(v, (int, float)):
                delay_rules[k] = float(v)

    # ============================================================
    # 3) إعدادات HR العامة
    # ============================================================
    settings = await _get_settings(db, company_code, branch_code)
    work_hours = settings['work_hours']
    grace_minutes = settings['grace_minutes']
    overtime_multiplier = settings['overtime_multiplier']
    weekly_vacation_day = settings['weekly_vacation_day']

       # ============================================================
    # 4) الحسابات الأساسية
    # ============================================================
    days_in_month = _days_in_month(month)

    # ⭐ daily_rate حسب إعداد الموظف
    if use_fixed_month_days:
        daily_rate = base_salary / DEFAULT_DAYS_PER_MONTH  # 30
    else:
        daily_rate = base_salary / days_in_month if days_in_month > 0 else 0

    hourly_rate = daily_rate / work_hours if work_hours > 0 else 0
    minute_rate = hourly_rate / 60

    # ⭐ حساب الأيام اللي عدّت من الشهر
    today = datetime.now().date()
    selected_month_first = datetime.strptime(
        f"{month}-01", '%Y-%m-%d'
    ).date()
    selected_month_last = datetime(
        selected_month_first.year,
        selected_month_first.month,
        days_in_month,
    ).date()

    if today > selected_month_last:
        elapsed_days = days_in_month
    elif today < selected_month_first:
        elapsed_days = 0
    else:
        elapsed_days = today.day

    # ============================================================
    # 5) حضور الشهر
    # ============================================================
    stmt = select(HRAttendance).where(
        HRAttendance.company_code == company_code,
        HRAttendance.employee_code == employee_code,
        HRAttendance.date.like(f"{month}-%"),
        HRAttendance.is_deleted.is_(False),
    )
    result = await db.execute(stmt)
    attendance_docs = result.scalars().all()

    attendance_by_date = {a.date: a for a in attendance_docs}

    # ============================================================
    # 6) إجازات الشهر (رسمية + أسبوعية + موظف)
    # ============================================================
    stmt = select(HRVacation).where(
        HRVacation.company_code == company_code,
        HRVacation.date.like(f"{month}-%"),
        HRVacation.is_deleted.is_(False),
    )
    result = await db.execute(stmt)
    vacation_docs = result.scalars().all()

    applicable_vacations = set()
    for v in vacation_docs:
        if v.employee_code is not None:
            if v.employee_code == employee_code:
                applicable_vacations.add(v.date)
        elif v.branch_code is not None:
            if v.branch_code == branch_code:
                applicable_vacations.add(v.date)
        else:
            applicable_vacations.add(v.date)

    # ============================================================
    # 7) حساب الحضور والغياب (بناءً على delay_rules)
    # ============================================================
    present_days = 0
    absent_days = 0
    vacation_days = 0
    permission_days = 0
    total_late_minutes = 0
    total_early_leave_minutes = 0
    total_overtime_minutes = 0
    # ⭐ جديد: عدد الأيام المستقبلية (لسه ما جاتش)
    future_days = 0

    # ✅ عدادات أيام الخصم
    delay_deduction_days = 0.0
    absence_deduction_days = 0.0
    permission_deduction_days = 0.0

    attendance_details = []

    for day_num in range(1, days_in_month + 1):
        date_str = f"{month}-{day_num:02d}"

        is_weekly = _is_weekly_vacation(date_str, weekly_day) if weekly_day is not None else False
        is_vacation = date_str in applicable_vacations
        att = attendance_by_date.get(date_str)

        try:
            day_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            today_date = datetime.now().date()
            is_future = day_date > today_date
        except (ValueError, TypeError):
            is_future = False

        # ====================================================
        # ✅ الأولوية: سجل الحضور أولاً (حتى لو يوم إجازة)
        # ====================================================
        if att is not None:

            # إجازة مسجلة يدويًا
            if att.status == 'vacation':
                vacation_days += 1
                attendance_details.append({
                    'date': date_str, 'status': 'vacation',
                    'note': 'إجازة', 'check_in': None, 'check_out': None,
                    'late_minutes': 0, 'overtime_minutes': 0,
                    'deduction_days': 0.0,
                })
                continue

            # غياب مسجل
            if att.status == 'absent':
                absent_days += 1
                deduction = float(delay_rules.get('absence', 3.0))
                absence_deduction_days += deduction
                attendance_details.append({
                    'date': date_str, 'status': 'absent',
                    'note': att.notes or 'غياب',
                    'check_in': None, 'check_out': None,
                    'late_minutes': 0, 'overtime_minutes': 0,
                    'deduction_days': deduction,
                })
                continue

            # إذن (غياب بإذن)
            if att.status == 'permission':
                permission_days += 1
                present_days += 1
                deduction = float(delay_rules.get('absence_with_permission', 1.0))
                permission_deduction_days += deduction
                attendance_details.append({
                    'date': date_str, 'status': 'permission',
                    'note': att.notes or 'إذن',
                    'check_in': att.check_in, 'check_out': att.check_out,
                    'late_minutes': 0, 'overtime_minutes': 0,
                    'deduction_days': deduction,
                })
                continue

            # ====================================================
            # ✅ حاضر / متأخر
            # ====================================================
            present_days += 1
            late = 0
            overtime_min = 0
            early_leave = (att.early_leave_minutes or 0)

            if flexible_hours:
                # مرونة: الإضافي فقط لو worked > required
                # (لا يوجد تأخير في حالة المرونة)
                if att.check_in and att.check_out:
                    in_min = _time_to_minutes(att.check_in)
                    out_min = _time_to_minutes(att.check_out)
                    worked_min = out_min - in_min if out_min > in_min else 0
                    required_min = int(work_hours * 60)

                    if worked_min > required_min:
                        overtime_min = worked_min - required_min
                    # else: late = 0, overtime_min = 0
            else:
                # دوام ثابت
                late = att.late_minutes or 0
                overtime_min = att.overtime_minutes or 0
                if late <= grace_minutes:
                    late = 0

            total_late_minutes += late
            total_early_leave_minutes += early_leave
            total_overtime_minutes += overtime_min

            delay_deduction = 0.0
            if late > 0:
                delay_deduction = _get_delay_deduction_days(late, delay_rules)
                delay_deduction_days += delay_deduction

            note_suffix = ' (عمل في يوم إجازة)' if (is_weekly or is_vacation) else ''
            attendance_details.append({
                'date': date_str,
                'status': att.status,
                'note': (att.notes or '') + note_suffix,
                'check_in': att.check_in,
                'check_out': att.check_out,
                'late_minutes': late,
                'overtime_minutes': overtime_min,
                'deduction_days': delay_deduction,
            })
            continue

        # ====================================================
        # مفيش سجل حضور
        # ====================================================
        if is_future:
            future_days += 1
            attendance_details.append({
                'date': date_str, 'status': 'future',
                'note': 'لم يأتِ بعد', 'check_in': None, 'check_out': None,
                'late_minutes': 0, 'overtime_minutes': 0,
                'deduction_days': 0.0,
            })
            continue

        if is_weekly or is_vacation:
            vacation_days += 1
            attendance_details.append({
                'date': date_str, 'status': 'vacation',
                'note': 'إجازة أسبوعية' if is_weekly else 'إجازة رسمية',
                'check_in': None, 'check_out': None,
                'late_minutes': 0, 'overtime_minutes': 0,
                'deduction_days': 0.0,
            })
            continue

        # غياب (بدون سجل + يوم ماضي + مفيش إجازة)
        absent_days += 1
        deduction = float(delay_rules.get('absence', 3.0))
        absence_deduction_days += deduction
        attendance_details.append({
            'date': date_str, 'status': 'absent',
            'note': 'بدون سجل', 'check_in': None, 'check_out': None,
            'late_minutes': 0, 'overtime_minutes': 0,
            'deduction_days': deduction,
        })

    # ============================================================
    # 8) حساب البنود المالية (بناءً على الأيام)
    # ============================================================
    absence_deduction = absence_deduction_days * daily_rate
    permission_deduction = permission_deduction_days * daily_rate
    delay_deduction = delay_deduction_days * daily_rate
    overtime_bonus = total_overtime_minutes * minute_rate * overtime_multiplier

    # early_leave_deduction لم يعد مستخدمًا (مشمول في delay_rules)
    early_leave_deduction = 0.0

    # ============================================================
    # 9) التسويات (مكافآت / خصومات / سلف)
    # ============================================================
    stmt = select(HRAdjustment).where(
        HRAdjustment.company_code == company_code,
        HRAdjustment.employee_code == employee_code,
        HRAdjustment.month == month,
        HRAdjustment.is_deleted.is_(False),
    )
    result = await db.execute(stmt)
    adjustments = result.scalars().all()

    bonuses_total = 0.0
    deductions_total = 0.0
    loans_total = 0.0

    adjustment_lines = []

    for adj in adjustments:
        amount = adj.amount or 0.0
        if adj.type == 'bonus':
            bonuses_total += amount
            adjustment_lines.append({
                'type': 'bonus',
                'label': f"مكافأة{': ' + adj.reason if adj.reason else ''}",
                'amount': amount,
            })
        elif adj.type == 'deduction':
            deductions_total += amount
            adjustment_lines.append({
                'type': 'deduction',
                'label': f"خصم{': ' + adj.reason if adj.reason else ''}",
                'amount': -amount,
            })
        elif adj.type == 'loan':
            loans_total += amount
            label = "قسط سلفة"
            if adj.installment_ref:
                label += f" ({adj.installment_ref})"
            if adj.reason:
                label += f" - {adj.reason}"
            adjustment_lines.append({
                'type': 'loan',
                'label': label,
                'amount': -amount,
            })

    # ============================================================
    # 10) صافي الراتب
    # ============================================================
    base_pay = elapsed_days * daily_rate

    net_salary = (
        base_pay
        - absence_deduction
        - permission_deduction
        - delay_deduction
        - deductions_total
        - loans_total
        + overtime_bonus
        + bonuses_total
    )

    # # لو الصافي سالب، نخليه صفر
    # if net_salary < 0:
    #     net_salary = 0.0

    # ============================================================
    # 11) النتيجة النهائية
    # ============================================================
    return {
        'company_code': company_code,
        'branch_code': branch_code,
        'employee_code': employee_code,
        'employee_name': employee.name,
        'month': month,

        # الإعدادات
        'flexible_hours': flexible_hours,
        'default_check_in': default_check_in,
        'default_check_out': default_check_out,
        'weekly_vacation_day': weekly_day,
        'use_fixed_month_days': use_fixed_month_days, 

        # الحضور
        'base_salary': round(base_salary, 2),
        'work_days': days_in_month,
        'elapsed_days': elapsed_days,     # ⭐ جديد
        'present_days': present_days,
        'absent_days': absent_days,
        'vacation_days': vacation_days,
        'future_days': future_days,       # ⭐ جديد
        'absent_days': absent_days,
        'vacation_days': vacation_days,
        'future_days': future_days,  
        'permission_days': permission_days,
        'late_minutes_total': total_late_minutes,
        'overtime_minutes_total': total_overtime_minutes,
        'early_leave_minutes_total': total_early_leave_minutes,

        # ✅ أيام الخصم (جديد)
        'absence_deduction_days': round(absence_deduction_days, 2),
        'delay_deduction_days': round(delay_deduction_days, 2),
        'permission_deduction_days': round(permission_deduction_days, 2),

        # البنود المالية
        'base_pay': round(base_pay, 2),
        'absence_deduction': round(absence_deduction, 2),
        'permission_deduction': round(permission_deduction, 2),
        'late_deduction': round(delay_deduction, 2),
        'early_leave_deduction': round(early_leave_deduction, 2),
        'overtime_bonus': round(overtime_bonus, 2),

        'bonuses_total': round(bonuses_total, 2),
        'deductions_total': round(deductions_total, 2),
        'loans_total': round(loans_total, 2),

         'net_salary': round(net_salary, 2),
        'debt_remaining': round(max(0.0, -net_salary), 2),  # ⭐ جديد

        # التفاصيل
        'adjustment_lines': adjustment_lines,
        'attendance_details': attendance_details,

        # ✅ قواعد التأخير المستخدمة (للمراجعة)
        'delay_rules': delay_rules,
    }