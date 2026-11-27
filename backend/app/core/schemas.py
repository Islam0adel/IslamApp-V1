# backend/app/core/schemas.py
from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from datetime import datetime


# ============================================================
# التكويد
# ============================================================


# نموذج بيانات سجل الكودنج
class CodingModel(BaseModel):
    company_code: str
    category: str
    code: str
    name: str
    branch_code: Optional[str] = None

    type: Optional[str] = "وارد"
    barcode: Optional[str] = ""

    wholesale_price: Optional[float] = 0.0
    selling_price: Optional[float] = 0.0

    profit_margin: Optional[float] = 0.0
    profit_percent: Optional[float] = 0.0
    # تأكيد صريح من المستخدم أن سعر الشراء صفر عن قصد.
    # مطلوب لإزالة علامة "غير محدد" عند حفظ صفر — الحفظ
    # العادي وحده لا يُعتبر موافقة على الصفر.
    confirm_zero_cost: Optional[bool] = False


# ============================================================
# اليوميات
# ============================================================


# نموذج بيانات معاملة اليومية
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
    supplier_name: Optional[str] = None
    add_to_settlement: bool = False
    link_id: Optional[str] = None
    unlink_settlement: bool = False
    operation_id: Optional[str] = Field(default=None, min_length=16, max_length=64)
    base_updated_at: Optional[str] = None


# ============================================================
# نموذج استجابة/مزامنة اليوميات
#
# لا يتم إرساله عند الحفظ من المستخدم.
# يستخدمه الـBackend في changes / WebSocket.
# ============================================================


# نموذج مزامنة معاملة اليومية (استجابة)
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
    link_id: Optional[str] = None
    supplier_name: Optional[str] = None

    updated_at: Optional[datetime] = None

    # Soft Delete
    is_deleted: bool = False

    # insert / update / delete
    action: Optional[str] = None


# ============================================================
# الجرد
# ============================================================


# نموذج صنف داخل المخزون
class InventoryItemModel(BaseModel):
    code: str
    name: str

    quantity: float

    wholesalePrice: float
    retailPrice: float

    wholesaleValue: float
    retailValue: float


# نموذج حفظ سجل مخزون
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


# نموذج مزامنة سجل المخزون
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


# نموذج صنف داخل معاملة مورد
class SupplierItemModel(BaseModel):
    code: str
    name: str

    quantity: float
    price: float

    type: str

    discountRate: float
    discountAmount: float

    total: float


# نموذج حفظ معاملة مورد
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


# نموذج حفظ تسوية مورد
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
    add_to_daily: bool = False
    link_id: Optional[str] = None
    unlink_daily: bool = False


# نموذج مزامنة تسوية المورد
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
    link_id: Optional[str] = None

    is_deleted: bool = False

    action: Optional[str] = None
# ============================================================
# نموذج استجابة/مزامنة الموردين
# ============================================================


# نموذج مزامنة سجل المورد
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


# نموذج مزامنة سجل الكودنج
class CodingSyncModel(BaseModel):
    id: int

    company_code: str
    category: str

    code: str
    name: str
    branch_code: Optional[str] = None

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


# نموذج تحديث صلاحيات مستخدم
class PermissionsUpdateModel(BaseModel):
    email: str

    permissions: Dict[
        str,
        Dict[str, bool]
    ]

    allowed_branches: Optional[
        List[str]
    ] = None


# نموذج فاتورة مبيعات
class SaleModel(BaseModel):
    id: str
    company_code: str
    branch_code: str
    store_code: str
    serial: int = 0
    date: str
    customer_code: str = ""
    customer_name: str = "عميل نقدي"
    cashier: str = ""
    seller: str = ""
    items: List[Dict[str, Any]] = Field(default_factory=list)
    subtotal: float = 0.0
    discount: float = 0.0
    total: float = 0.0
    paid: float = 0.0
    due: float = 0.0
    payments: List[Dict[str, Any]] = Field(default_factory=list)
    employee: str = ""
    base_updated_at: Optional[str] = None


# نموذج مرتجع مبيعات
class SaleReturnModel(BaseModel):
    id: str
    company_code: str
    branch_code: str
    store_code: str
    serial: int = 0
    date: str
    sale_id: str = ""
    invoice_serial: int = 0
    customer_code: str = ""
    customer_name: str = "عميل نقدي"
    items: List[Dict[str, Any]] = Field(default_factory=list)
    total: float = 0.0
    settlement_mode: str = "credit_first"
    credit_amount: float = 0.0
    refund_amount: float = 0.0
    payments: List[Dict[str, Any]] = Field(default_factory=list)
    employee: str = ""
    base_updated_at: Optional[str] = None


# نموذج دفعة عميل
class CustomerPaymentModel(BaseModel):
    id: str
    company_code: str
    branch_code: str
    serial: int = 0
    date: str
    customer_code: str = ""
    customer_name: str
    amount: float
    payments: List[Dict[str, Any]] = Field(default_factory=list)
    statement: str = ""
    employee: str = ""
    base_updated_at: Optional[str] = None


# نموذج تحويل مخزني
class StockTransferModel(BaseModel):
    id: str
    company_code: str
    from_branch_code: str
    from_store_code: str
    to_branch_code: str
    to_store_code: str
    serial: int = 0
    date: str
    items: List[Dict[str, Any]] = Field(default_factory=list)
    statement: str = ""
    employee: str = ""
    base_updated_at: Optional[str] = None


# ============================================================
# نماذج إضافية للشركات
# ============================================================


# نموذج إنشاء شركة
class CompanyModel(BaseModel):
    code: str
    name: str


# نموذج تعديل بيانات شركة (كودها القديم والجديد)
class CompanyUpdateModel(BaseModel):
    old_code: str

    new_code: str

    new_name: str

    admin_job_code: str

# ============================================================
# الموظفين (Employees)
# ============================================================


# نموذج حفظ موظف
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


# نموذج مزامنة موظف
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


# نموذج حفظ أو تعديل حضور
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


# نموذج استجابة ومزامنة الحضور
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


# نموذج حفظ أو تعديل إجازة
class HRVacationModel(BaseModel):
    """نموذج حفظ/تعديل إجازة"""
    company_code: str
    branch_code: Optional[str] = None       # null = كل الفروع
    employee_code: Optional[str] = None     # ✅ NEW: null = كل الموظفين
    date: str
    name: str
    type: Optional[str] = "official"        # official / weekly


# نموذج استجابة ومزامنة الإجازة
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


# نموذج حفظ أو تعديل تسوية مالية
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


# نموذج استجابة ومزامنة التسوية
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


# نموذج إعدادات الموارد البشرية للشركة
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


# بند واحد في كشف الراتب
class HRAdjustmentLine(BaseModel):
    """بند واحد في كشف الراتب"""
    type: str  # base / bonus / deduction / loan / overtime / absence / late
    label: str
    amount: float


# نموذج تقرير الراتب الشهري الكامل
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


# نموذج إعدادات الموارد البشرية لموظف
class HREmployeeSettingsModel(BaseModel):
    company_code: str
    employee_code: str
    weekly_vacation_day: Optional[int] = None  # 0-6
    default_check_in: Optional[str] = "09:00"
    default_check_out: Optional[str] = "17:00"
    flexible_hours: Optional[bool] = False
    delay_rules: Optional[Dict[str, float]] = None
    use_fixed_month_days: Optional[bool] = True


# ============================================================
# FCM Device Registration
# ============================================================
# نموذج تسجيل جهاز لإشعارات النظام
class FcmDeviceModel(BaseModel):
    """تسجيل جهاز لإشعارات النظام"""
    fcm_token: str
    platform: Optional[str] = "web"
