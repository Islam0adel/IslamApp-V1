from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from datetime import datetime


# ============================================================
# التكويد
# ============================================================

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


# ============================================================
# اليوميات
# ============================================================

class TransactionModel(BaseModel):
    company_code: str
    serial: int

    treasury: str
    amount: float

    statement: str
    category: str

    date: str
    type: str

    employee: Optional[str] = "غير محدد"
    branch_code: Optional[str] = "1"


# ============================================================
# نموذج استجابة/مزامنة اليوميات
#
# لا يتم إرساله عند الحفظ من المستخدم.
# يستخدمه الـBackend في changes / WebSocket.
# ============================================================

class TransactionSyncModel(BaseModel):
    id: int

    company_code: str
    branch_code: str

    serial: int

    treasury: str
    amount: float

    statement: str
    category: str

    date: str
    type: str

    employee: Optional[str] = "غير محدد"

    updated_at: Optional[datetime] = None

    # Soft Delete
    is_deleted: bool = False

    # insert / update / delete
    action: Optional[str] = None


# ============================================================
# الجرد
# ============================================================

class InventoryItemModel(BaseModel):
    code: str
    name: str

    quantity: float

    wholesalePrice: float
    retailPrice: float

    wholesaleValue: float
    retailValue: float


class InventoryModel(BaseModel):
    company_code: str
    branch_code: str
    store_code: str

    date: str
    inventory_type: str

    items: List[InventoryItemModel]

    total_wholesale: float
    total_retail: float

    updated_at: Optional[str] = None

    doc_id: Optional[str] = None

    serial: Optional[int] = None

    employee: Optional[str] = "غير محدد"


# ============================================================
# نموذج استجابة/مزامنة الجرد
# ============================================================

class InventorySyncModel(BaseModel):
    id: int

    company_code: str
    branch_code: str
    store_code: str

    date: str
    inventory_type: str

    items: List[InventoryItemModel]

    total_wholesale: float
    total_retail: float

    serial: Optional[int] = None

    updated_at: Optional[datetime] = None

    doc_id: Optional[str] = None

    # Soft Delete
    is_deleted: bool = False

    # insert / update / delete
    action: Optional[str] = None


# ============================================================
# الموردين
# ============================================================

class SupplierItemModel(BaseModel):
    code: str
    name: str

    quantity: float
    price: float

    type: str

    discountRate: float
    discountAmount: float

    total: float


class SupplierTransactionModel(BaseModel):
    company_code: str
    branch_code: str
    store_code: str

    serial: int
    date: str

    supplier_name: str
    payment_method: str
    treasury: str

    is_add_to_store: bool
    is_add_to_coding: Optional[bool] = False

    employee: str

    items: List[SupplierItemModel]

    total_amount: float
    paid_amount: float

    updated_at: Optional[str] = None

    doc_id: Optional[str] = None

# ============================================================
# تسويات الموردين
# ============================================================

class SupplierSettlementModel(BaseModel):
    company_code: str
    branch_code: str

    serial: int
    date: str

    supplier_name: str

    payment_method: str
    treasury: str

    amount: float

    statement: str = ""
    employee: str = "غير محدد"

    updated_at: Optional[str] = None
    doc_id: Optional[str] = None


class SupplierSettlementSyncModel(BaseModel):
    id: int

    company_code: str
    branch_code: str

    serial: int
    date: str

    supplier_name: str

    payment_method: str
    treasury: str

    amount: float

    statement: str = ""
    employee: str = "غير محدد"

    updated_at: Optional[datetime] = None

    doc_id: Optional[str] = None

    is_deleted: bool = False

    action: Optional[str] = None
# ============================================================
# نموذج استجابة/مزامنة الموردين
# ============================================================

class SupplierSyncModel(BaseModel):
    id: int

    company_code: str
    branch_code: str
    store_code: str

    serial: int
    date: str

    supplier_name: str
    payment_method: str
    treasury: str

    is_add_to_store: bool

    employee: str

    items: List[SupplierItemModel]

    total_amount: float
    paid_amount: float

    updated_at: Optional[datetime] = None

    doc_id: Optional[str] = None

    # Soft Delete
    is_deleted: bool = False

    # insert / update / delete
    action: Optional[str] = None


# ============================================================
# نموذج التكويد للمزامنة
# ============================================================

class CodingSyncModel(BaseModel):
    id: int

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

    updated_at: Optional[datetime] = None

    # Soft Delete
    is_deleted: bool = False

    # insert / update / delete
    action: Optional[str] = None


# ============================================================
# نماذج إضافية للصلاحيات
# ============================================================

class PermissionsUpdateModel(BaseModel):
    email: str

    permissions: Dict[
        str,
        Dict[str, bool]
    ]

    allowed_branches: Optional[
        List[str]
    ] = None


# ============================================================
# نماذج إضافية للشركات
# ============================================================

class CompanyModel(BaseModel):
    code: str
    name: str


class CompanyUpdateModel(BaseModel):
    old_code: str

    new_code: str

    new_name: str

    admin_job_code: str

# ============================================================
# الموظفين (Employees)
# ============================================================

class EmployeeModel(BaseModel):
    """
    نموذج حفظ/تعديل الموظف
    (نفس شكل CodingModel للتوافق مع الواجهة)
    """
    company_code: str
    code: str
    name: str

    # بيانات أساسية
    phone: Optional[str] = None
    email: Optional[str] = None
    national_id: Optional[str] = None
    address: Optional[str] = None
    gender: Optional[str] = None
    birth_date: Optional[str] = None  # ISO 8601

    # بيانات وظيفية
    job_title: Optional[str] = None
    department: Optional[str] = None
    branch_code: Optional[str] = None
    hire_date: Optional[str] = None
    end_date: Optional[str] = None
    salary: Optional[float] = 0.0
    contract_type: Optional[str] = None
    status: Optional[str] = "active"
    manager_uid: Optional[str] = None

    # ربط Firebase (اختياري)
    user_uid: Optional[str] = None
    user_email: Optional[str] = None

    # إضافي
    emergency_contact: Optional[str] = None
    bank_account: Optional[str] = None
    bank_name: Optional[str] = None
    notes: Optional[str] = None
    meta: Optional[Dict[str, Any]] = None


class EmployeeSyncModel(BaseModel):
    """
    نموذج استجابة/مزامنة الموظف
    نفس شكل CodingSyncModel للتوافق مع الواجهة
    """
    id: int

    company_code: str
    code: str
    name: str

    phone: Optional[str] = None
    email: Optional[str] = None
    national_id: Optional[str] = None
    address: Optional[str] = None
    gender: Optional[str] = None
    birth_date: Optional[str] = None

    job_title: Optional[str] = None
    department: Optional[str] = None
    branch_code: Optional[str] = None
    hire_date: Optional[str] = None
    end_date: Optional[str] = None
    salary: Optional[float] = 0.0
    contract_type: Optional[str] = None
    status: Optional[str] = "active"
    manager_uid: Optional[str] = None

    user_uid: Optional[str] = None
    user_email: Optional[str] = None

    emergency_contact: Optional[str] = None
    bank_account: Optional[str] = None
    bank_name: Optional[str] = None
    notes: Optional[str] = None
    meta: Optional[Dict[str, Any]] = None

    updated_at: Optional[datetime] = None
    is_deleted: bool = False
    action: Optional[str] = None

# ============================================================
# الموارد البشرية (HR)
# ============================================================

class HRAttendanceModel(BaseModel):
    """نموذج حفظ/تعديل الحضور"""
    company_code: str
    branch_code: str
    employee_code: str
    date: str  # "YYYY-MM-DD"

    status: Optional[str] = "present"
    check_in: Optional[str] = None   # "HH:MM"
    check_out: Optional[str] = None  # "HH:MM"

    late_minutes: Optional[int] = 0
    early_leave_minutes: Optional[int] = 0
    overtime_minutes: Optional[int] = 0

    notes: Optional[str] = None


class HRAttendanceSyncModel(BaseModel):
    """نموذج استجابة/مزامنة الحضور"""
    id: int
    company_code: str
    branch_code: str
    employee_code: str
    date: str

    status: str
    check_in: Optional[str] = None
    check_out: Optional[str] = None

    late_minutes: int = 0
    early_leave_minutes: int = 0
    overtime_minutes: int = 0

    notes: Optional[str] = None
    created_by: Optional[str] = None

    updated_at: Optional[datetime] = None
    is_deleted: bool = False
    action: Optional[str] = None


class HRVacationModel(BaseModel):
    """نموذج حفظ/تعديل إجازة"""
    company_code: str
    branch_code: Optional[str] = None       # null = كل الفروع
    employee_code: Optional[str] = None     # ✅ NEW: null = كل الموظفين
    date: str
    name: str
    type: Optional[str] = "official"        # official / weekly


class HRVacationSyncModel(BaseModel):
    """نموذج استجابة/مزامنة إجازة"""
    id: int
    company_code: str
    branch_code: Optional[str] = None
    employee_code: Optional[str] = None     # ✅ NEW
    date: str
    name: str
    type: str
    created_by: Optional[str] = None

    updated_at: Optional[datetime] = None
    is_deleted: bool = False
    action: Optional[str] = None


class HRAdjustmentModel(BaseModel):
    """نموذج حفظ/تعديل تسوية مالية"""
    company_code: str
    branch_code: str
    employee_code: str
    month: str  # "YYYY-MM"
    date: Optional[str] = None  # "YYYY-MM-DD"
    type: str  # deduction / bonus / loan
    amount: float
    reason: Optional[str] = None
    installment_ref: Optional[str] = None
    status: Optional[str] = "approved"


class HRAdjustmentSyncModel(BaseModel):
    """نموذج استجابة/مزامنة تسوية"""
    id: int
    company_code: str
    branch_code: str
    employee_code: str
    month: str
    date: Optional[str] = None
    type: str
    amount: float
    reason: Optional[str] = None
    installment_ref: Optional[str] = None
    status: str
    created_by: Optional[str] = None

    updated_at: Optional[datetime] = None
    is_deleted: bool = False
    action: Optional[str] = None


class HRSettingsModel(BaseModel):
    """نموذج إعدادات HR"""
    company_code: str
    branch_code: Optional[str] = None
    work_hours_per_day: Optional[float] = 8.0
    late_grace_minutes: Optional[int] = 15
    overtime_multiplier: Optional[float] = 1.5
    weekly_vacation_day: Optional[int] = 5  # 0-6


# ============================================================
# تقرير الراتب الشهري (Response)
# ============================================================

class HRAdjustmentLine(BaseModel):
    """بند واحد في كشف الراتب"""
    type: str  # base / bonus / deduction / loan / overtime / absence / late
    label: str
    amount: float


class HRSalaryReportModel(BaseModel):
    """تقرير راتب شهري كامل"""
    company_code: str
    branch_code: str
    employee_code: str
    employee_name: str
    month: str  # "YYYY-MM"

    # البيانات الخام
    base_salary: float
    work_days: int
    present_days: int
    absent_days: int
    vacation_days: int
    late_minutes_total: int
    overtime_minutes_total: int
    early_leave_minutes_total: int

    # الحساب
    base_pay: float
    absence_deduction: float
    late_deduction: float
    early_leave_deduction: float
    overtime_bonus: float

    bonuses_total: float
    deductions_total: float
    loans_total: float

    net_salary: float

    # التفاصيل
    adjustment_lines: List[HRAdjustmentLine]
    attendance_details: List[Dict[str, Any]]  # تفاصيل الحضور اليومي

# ============================================================
# إعدادات الموظف HR
# ============================================================

class HREmployeeSettingsModel(BaseModel):
    company_code: str
    employee_code: str
    weekly_vacation_day: Optional[int] = None  # 0-6
    default_check_in: Optional[str] = "09:00"
    default_check_out: Optional[str] = "17:00"
    flexible_hours: Optional[bool] = False
    delay_rules: Optional[Dict[str, float]] = None
    use_fixed_month_days: Optional[bool] = True  