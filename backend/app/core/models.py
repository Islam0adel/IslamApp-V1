from sqlalchemy import (
    Column,
    String,
    Integer,
    Float,
    Boolean,
    DateTime,
    JSON,
    Text,
    Index,
    text,
    UniqueConstraint,
)
from sqlalchemy.sql import func

from app.core.database import Base


# ==========================================
# 1. جدول الشركات (Companies)
# ==========================================
class Company(Base):
    __tablename__ = "companies"

    code = Column(
        String(50),
        primary_key=True,
        index=True,
        nullable=False,
    )

    name = Column(
        String(255),
        nullable=False,
    )

    is_active = Column(
        Boolean,
        default=True,
    )

    created_at = Column(
        DateTime,
        server_default=func.now(),
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )


# ==========================================
# 2. جدول الفروع (Branches)
# ==========================================
class Branch(Base):
    __tablename__ = "branches"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    code = Column(
        String(50),
        nullable=False,
    )

    name = Column(
        String(255),
        nullable=False,
    )

    created_at = Column(
        DateTime,
        server_default=func.now(),
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    __table_args__ = (
        Index(
            'idx_branches_company_code',
            'company_code',
        ),

        Index(
            'idx_branches_company_code_code',
            'company_code',
            'code',
            unique=True,
        ),
    )


# ==========================================
# 3. جدول التكويدات (Coding Records)
# ==========================================
class CodingRecord(Base):
    __tablename__ = "coding_records"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    category = Column(
        String(50),
        nullable=False,
        index=True,
    )

    code = Column(
        String(50),
        nullable=False,
    )

    name = Column(
        String(255),
        nullable=False,
    )

    type = Column(
        String(50),
        default="وارد",
    )

    barcode = Column(
        String(100),
        default="",
    )

    wholesale_price = Column(
        Float,
        default=0.0,
    )

    selling_price = Column(
        Float,
        default=0.0,
    )

    profit_margin = Column(
        Float,
        default=0.0,
    )

    profit_percent = Column(
        Float,
        default=0.0,
    )

    # وقت آخر تعديل
    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    # Soft Delete
    #
    # False = السجل طبيعي ويظهر للمستخدم
    # True  = السجل محذوف ويجب حذفه من Hive
    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        Index(
            'idx_coding_company_category',
            'company_code',
            'category',
        ),

        Index(
            'idx_coding_company_category_code',
            'company_code',
            'category',
            'code',
            unique=True,
        ),

        # تسريع /changes
        Index(
            'idx_coding_changes',
            'company_code',
            'updated_at',
        ),

        # تسريع /list التي تستبعد المحذوف
        Index(
            'idx_coding_active',
            'company_code',
            'category',
            'is_deleted',
        ),
    )


# ==========================================
# 4. جدول اليوميات (Transactions)
# ==========================================
class Transaction(Base):
    __tablename__ = "transactions"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    branch_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    serial = Column(
        Integer,
        nullable=False,
    )

    treasury = Column(
        String(255),
        nullable=False,
    )

    amount = Column(
        Float,
        nullable=False,
    )

    statement = Column(
        Text,
        default="",
    )

    category = Column(
        String(100),
        default="",
    )

    date = Column(
        String(20),
        nullable=False,
    )

    type = Column(
        String(50),
        default="وارد",
    )

    employee = Column(
        String(255),
        default="غير محدد",
    )

    # وقت آخر تعديل
    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    # Soft Delete
    #
    # السجل لا يتم حذفه من Neon.
    # يتم تغيير هذه القيمة إلى True.
    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        Index(
            'idx_transactions_company_branch_serial',
            'company_code',
            'branch_code',
            'serial',
            unique=True,
        ),

        Index(
            'idx_transactions_company_date',
            'company_code',
            'date',
        ),

        Index(
            'idx_transactions_company_branch',
            'company_code',
            'branch_code',
        ),

        Index(
            'idx_transactions_company_branch_date',
            'company_code',
            'branch_code',
            'date',
        ),

        # مهم جداً للمزامنة التزايدية
        Index(
            'idx_transactions_changes',
            'company_code',
            'updated_at',
        ),

        # مهم لاستعلامات البيانات العادية
        Index(
            'idx_transactions_active',
            'company_code',
            'branch_code',
            'is_deleted',
        ),
    )


# ==========================================
# 5. جدول الجردات (Inventories)
# ==========================================
class InventoryRecord(Base):
    __tablename__ = "inventory_records"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    branch_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    store_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    date = Column(
        String(20),
        nullable=False,
    )

    inventory_type = Column(
        String(50),
        default="specific",
    )

    items = Column(
        JSON,
        default=list,
    )

    total_wholesale = Column(
        Float,
        default=0.0,
    )

    total_retail = Column(
        Float,
        default=0.0,
    )

    serial = Column(
        Integer,
        nullable=True,
    )

    employee = Column(
        String(255),
        default="غير محدد",
    )

    # وقت آخر تعديل
    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    # Soft Delete
    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        # ✅ Partial Unique Index
        # يمنع وجود سجلين نشطين بنفس المفتاح
        # لكن يسمح بوجود سجلات محذوفة متعددة
        Index(
            'idx_inventory_unique_active',
            'company_code',
            'branch_code',
            'store_code',
            'date',
            unique=True,
            postgresql_where=text('is_deleted = FALSE'),
        ),

        Index(
            'idx_inventory_company_serial',
            'company_code',
            'serial',
        ),

        # مهم للمزامنة
        Index(
            'idx_inventory_changes',
            'company_code',
            'updated_at',
        ),

        # مهم للقوائم العادية
        Index(
            'idx_inventory_active',
            'company_code',
            'branch_code',
            'store_code',
            'is_deleted',
        ),
    )


# ==========================================
# 6. جدول حركات الموردين
# ==========================================
class SupplierRecord(Base):
    __tablename__ = "supplier_records"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    branch_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    store_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    serial = Column(
        Integer,
        nullable=False,
    )

    date = Column(
        String(20),
        nullable=False,
    )

    supplier_name = Column(
        String(255),
        nullable=False,
        index=True,
    )

    payment_method = Column(
        String(100),
        nullable=False,
    )

    treasury = Column(
        String(255),
        nullable=False,
    )

    is_add_to_store = Column(
        Boolean,
        default=False,
    )

    is_add_to_coding = Column(
    Boolean,
    default=False,
)

    employee = Column(
        String(255),
        default="غير محدد",
    )

    items = Column(
        JSON,
        default=list,
    )

    total_amount = Column(
        Float,
        default=0.0,
    )

    paid_amount = Column(
        Float,
        default=0.0,
    )

    # وقت آخر تعديل
    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    # Soft Delete
    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
    # ✅ Partial Unique Index
    # يمنع وجود سجلين نشطين بنفس المفتاح
    # لكن يسمح بوجود سجلات محذوفة متعددة
    Index(
        'idx_supplier_company_branch_serial_active',
        'company_code',
        'branch_code',
        'serial',
        unique=True,
        postgresql_where=text('is_deleted = FALSE'),
    ),

    Index(
        'idx_supplier_company_supplier_name',
        'company_code',
        'supplier_name',
    ),

    Index(
        'idx_supplier_company_date',
        'company_code',
        'date',
    ),

    Index(
        'idx_supplier_changes',
        'company_code',
        'updated_at',
    ),

    Index(
        'idx_supplier_active',
        'company_code',
        'branch_code',
        'store_code',
        'is_deleted',
    ),
)

# ==========================================
# 7. تسويات الموردين
# ==========================================
class SupplierSettlementRecord(Base):
    __tablename__ = "supplier_settlements"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    branch_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    serial = Column(
        Integer,
        nullable=False,
    )

    date = Column(
        String(20),
        nullable=False,
    )

    supplier_name = Column(
        String(255),
        nullable=False,
        index=True,
    )

    payment_method = Column(
        String(100),
        nullable=False,
    )

    treasury = Column(
        String(255),
        nullable=False,
    )

    amount = Column(
        Float,
        nullable=False,
        default=0.0,
    )

    statement = Column(
        Text,
        default="",
    )

    employee = Column(
        String(255),
        default="غير محدد",
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
    # ✅ Partial Unique Index
    Index(
        'idx_settlement_company_branch_serial_active',
        'company_code',
        'branch_code',
        'serial',
        unique=True,
        postgresql_where=text('is_deleted = FALSE'),
    ),

    Index(
        'idx_settlement_company_supplier',
        'company_code',
        'supplier_name',
    ),

    Index(
        'idx_settlement_changes',
        'company_code',
        'updated_at',
    ),

    Index(
        'idx_settlement_active',
        'company_code',
        'branch_code',
        'is_deleted',
    ),
)

# ==========================================
# 8. إشعارات المستخدمين وسجل التدقيق
# ==========================================
class Notification(Base):
    __tablename__ = "notifications"

    id = Column(Integer, primary_key=True, autoincrement=True, index=True)
    event_id = Column(String(36), nullable=False, index=True)
    recipient_uid = Column(String(128), nullable=False, index=True)
    recipient_email = Column(String(255), nullable=False, index=True)
    company_code = Column(String(50), nullable=False, index=True)
    branch_code = Column(String(50), nullable=False, default="")
    section = Column(String(50), nullable=False, index=True)
    action = Column(String(20), nullable=False)
    actor_uid = Column(String(128), nullable=False, default="")
    actor_name = Column(String(255), nullable=False, default="")
    title = Column(String(255), nullable=False)
    body = Column(Text, nullable=False, default="")
    entity_id = Column(String(255), nullable=False, default="")
    created_at = Column(DateTime, nullable=False, server_default=func.now(), index=True)
    is_read = Column(Boolean, nullable=False, default=False, server_default="false")
    read_at = Column(DateTime, nullable=True)

    __table_args__ = (
        UniqueConstraint("event_id", "recipient_uid", name="uq_notifications_event_recipient"),
        Index("idx_notifications_recipient_company_created", "recipient_uid", "company_code", "created_at"),
    )


class NotificationPreference(Base):
    __tablename__ = "notification_preferences"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_uid = Column(String(128), nullable=False, index=True)
    user_email = Column(String(255), nullable=False, index=True)
    company_code = Column(String(50), nullable=False, index=True)
    sections = Column(JSON, nullable=False, default=dict)
    actions = Column(JSON, nullable=False, default=dict)
    retention_days = Column(Integer, nullable=False, default=90)
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())

    __table_args__ = (
        UniqueConstraint("user_uid", "company_code", name="uq_notification_preferences_user_company"),
    )


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    event_id = Column(String(36), nullable=False, index=True)
    company_code = Column(String(50), nullable=False, index=True)
    branch_code = Column(String(50), nullable=False, default="")
    actor_uid = Column(String(128), nullable=False, default="")
    actor_email = Column(String(255), nullable=False, default="")
    actor_name = Column(String(255), nullable=False, default="")
    section = Column(String(50), nullable=False, index=True)
    action = Column(String(20), nullable=False)
    entity_id = Column(String(255), nullable=False, default="")
    details = Column(JSON, nullable=False, default=dict)
    created_at = Column(DateTime, nullable=False, server_default=func.now(), index=True)

# ==========================================
# 9. كتالوج المنتجات والبحث بالباركود
# ==========================================
class ProductCatalog(Base):
    __tablename__ = "product_catalog"

    barcode = Column(String(14), primary_key=True, nullable=False)
    product_name = Column(String(500), nullable=False, default="")
    brand = Column(String(500), nullable=False, default="")
    quantity = Column(String(120), nullable=False, default="")
    category = Column(String(500), nullable=False, default="")
    manufacturer = Column(String(500), nullable=False, default="")
    origin_country = Column(String(200), nullable=False, default="")
    verification_status = Column(String(30), nullable=False, default="partial")
    product_source = Column(String(100), nullable=False, default="")
    product_source_url = Column(Text, nullable=False, default="")
    product_updated_at = Column(DateTime, nullable=True)
    price_amount = Column(Float, nullable=True)
    price_min = Column(Float, nullable=True)
    price_max = Column(Float, nullable=True)
    price_type = Column(String(30), nullable=False, default="unavailable")
    price_unit = Column(String(50), nullable=False, default="unit")
    price_source = Column(String(200), nullable=False, default="")
    price_source_url = Column(Text, nullable=False, default="")
    price_observed_at = Column(DateTime, nullable=True)
    price_updated_at = Column(DateTime, nullable=True)
    price_checked_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, server_default=func.now())
    updated_at = Column(DateTime, nullable=False, server_default=func.now(), onupdate=func.now())
# ==========================================
# 10. جدول الموظفين (Employees)
#
# مستقل تمامًا عن CodingRecord
# مصمم للتوسع (HR System)
# ==========================================
class Employee(Base):
    __tablename__ = "employees"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # كود الموظف (نفس منطق coding: 1, 2, 3...)
    code = Column(
        String(50),
        nullable=False,
    )

    # ============ بيانات أساسية ============

    name = Column(
        String(255),
        nullable=False,
    )

    phone = Column(
        String(50),
        nullable=True,
    )

    email = Column(
        String(255),
        nullable=True,
    )

    national_id = Column(
        String(50),
        nullable=True,
    )

    address = Column(
        Text,
        nullable=True,
    )

    gender = Column(
        String(20),
        nullable=True,
    )  # male / female

    birth_date = Column(
        DateTime,
        nullable=True,
    )

    # ============ بيانات وظيفية ============

    job_title = Column(
        String(100),
        nullable=True,
    )

    department = Column(
        String(100),
        nullable=True,
    )

    branch_code = Column(
        String(50),
        nullable=True,
        index=True,
    )

    hire_date = Column(
        DateTime,
        nullable=True,
    )

    end_date = Column(
        DateTime,
        nullable=True,
    )

    salary = Column(
        Float,
        default=0.0,
    )

    contract_type = Column(
        String(30),
        nullable=True,
    )  # permanent / temporary / part-time

    status = Column(
        String(30),
        default="active",
        nullable=False,
    )  # active / on_leave / suspended / terminated

    manager_uid = Column(
        String(128),
        nullable=True,
    )

    # ============ الربط بـ Firebase Auth (اختياري) ============

    user_uid = Column(
        String(128),
        nullable=True,
        index=True,
    )

    user_email = Column(
        String(255),
        nullable=True,
        index=True,
    )

    # ============ بيانات إضافية ============

    emergency_contact = Column(
        String(100),
        nullable=True,
    )

    bank_account = Column(
        String(100),
        nullable=True,
    )

    bank_name = Column(
        String(100),
        nullable=True,
    )

    notes = Column(
        Text,
        nullable=True,
    )

    # حقول مرنة للتوسع المستقبلي (HR)
    meta = Column(
        JSON,
        default=dict,
    )

    # ============ مزامنة وحذف ============

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        UniqueConstraint(
            "company_code",
            "code",
            name="uq_employees_company_code",
        ),

        Index(
            "idx_employees_company_code",
            "company_code",
            "code",
        ),

        Index(
            "idx_employees_changes",
            "company_code",
            "updated_at",
        ),

        Index(
            "idx_employees_active",
            "company_code",
            "is_deleted",
        ),

        Index(
            "idx_employees_user_uid",
            "user_uid",
        ),

        Index(
            "idx_employees_branch",
            "company_code",
            "branch_code",
        ),
    )

# ==========================================
# 11. الحضور اليومي (HR Attendance)
#
# سجل واحد لكل موظف في اليوم
# ==========================================
class HRAttendance(Base):
    __tablename__ = "hr_attendance"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    branch_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # ربط بـ employees.code
    employee_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # التاريخ (نص ISO: YYYY-MM-DD) — مثل Transaction.date
    date = Column(
        String(20),
        nullable=False,
    )

    # present / absent / vacation / late / half_day
    status = Column(
        String(30),
        nullable=False,
        default="present",
    )

    # الأوقات (نص HH:MM)
    check_in = Column(
        String(10),
        nullable=True,
    )

    check_out = Column(
        String(10),
        nullable=True,
    )

    # دقائق
    late_minutes = Column(
        Integer,
        default=0,
    )

    early_leave_minutes = Column(
        Integer,
        default=0,
    )

    overtime_minutes = Column(
        Integer,
        default=0,
    )

    notes = Column(
        Text,
        nullable=True,
    )

    # who created (email)
    created_by = Column(
        String(255),
        nullable=True,
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        # سجل واحد لكل موظف في اليوم
        Index(
            'idx_hr_attendance_unique',
            'company_code',
            'employee_code',
            'date',
            unique=True,
        ),

        # للمزامنة
        Index(
            'idx_hr_attendance_changes',
            'company_code',
            'updated_at',
        ),

        # لاستعلامات اليوم
        Index(
            'idx_hr_attendance_date',
            'company_code',
            'branch_code',
            'date',
        ),

        # لاستعلامات الموظف
        Index(
            'idx_hr_attendance_employee',
            'company_code',
            'employee_code',
            'date',
        ),
    )


# ==========================================
# 12. الإجازات الرسمية والأسبوعية
# ==========================================
class HRVacation(Base):
    __tablename__ = "hr_vacations"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # null = كل الفروع، غير كده فرع محدد
    branch_code = Column(
        String(50),
        nullable=True,
        index=True,
    )
        # ✅ NEW: null = إجازة عامة، غير كده لموظف محدد
    employee_code = Column(
        String(50),
        nullable=True,
        index=True,
    )

    date = Column(
        String(20),
        nullable=False,
    )

    name = Column(
        String(255),
        nullable=False,
    )

    # official (عيد/مناسبة) أو weekly (يوم راحة أسبوعي)
    type = Column(
        String(30),
        nullable=False,
        default="official",
    )

    created_by = Column(
        String(255),
        nullable=True,
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        # منع تكرار (شركة + تاريخ) لو كل الفروع وكل الموظفين
        Index(
            'idx_hr_vacations_all_branches',
            'company_code',
            'date',
            unique=True,
            postgresql_where=text(
                'branch_code IS NULL AND employee_code IS NULL AND is_deleted = FALSE'
            ),
        ),

        # منع تكرار (شركة + فرع + تاريخ) لو فرع محدد وكل الموظفين
        Index(
            'idx_hr_vacations_branch',
            'company_code',
            'branch_code',
            'date',
            unique=True,
            postgresql_where=text(
                'branch_code IS NOT NULL AND employee_code IS NULL AND is_deleted = FALSE'
            ),
        ),

        # ✅ NEW: منع تكرار (شركة + موظف + تاريخ) لو موظف محدد
        Index(
            'idx_hr_vacations_employee',
            'company_code',
            'employee_code',
            'date',
            unique=True,
            postgresql_where=text(
                'employee_code IS NOT NULL AND is_deleted = FALSE'
            ),
        ),

        # للمزامنة
        Index(
            'idx_hr_vacations_changes',
            'company_code',
            'updated_at',
        ),
    )


# ==========================================
# 13. التسويات المالية (خصم / مكافأة / سلفة)
#
# كل صف = بند واحد في شهر معين
# السلفة = صفوف متعددة (قسط لكل شهر)
# ==========================================
class HRAdjustment(Base):
    __tablename__ = "hr_adjustments"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    branch_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    employee_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # الشهر (YYYY-MM)
    month = Column(
        String(7),
        nullable=False,
        index=True,
    )

    date = Column(
        String(20),
        nullable=True,
        index=True,
    )

    # deduction / bonus / loan
    type = Column(
        String(30),
        nullable=False,
    )

    amount = Column(
        Float,
        nullable=False,
        default=0.0,
    )

    reason = Column(
        Text,
        nullable=True,
    )

    # للسلف فقط: مرجع القسط (1/3، 2/3...)
    installment_ref = Column(
        String(30),
        nullable=True,
    )

    # حالة (approved / pending / cancelled)
    status = Column(
        String(30),
        nullable=False,
        default="approved",
    )

    created_by = Column(
        String(255),
        nullable=True,
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    is_deleted = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    __table_args__ = (
        Index(
            'idx_hr_adjustments_emp_month',
            'company_code',
            'employee_code',
            'month',
        ),

        Index(
            'idx_hr_adjustments_emp_date',
            'company_code',
            'employee_code',
            'date',
        ),

        Index(
            'idx_hr_adjustments_changes',
            'company_code',
            'updated_at',
        ),

        Index(
            'idx_hr_adjustments_active',
            'company_code',
            'branch_code',
            'is_deleted',
        ),
    )


# ==========================================
# 14. إعدادات HR (اختياري — للمرونة)
#
# لو مش موجود، بنستخدم الافتراضيات
# ==========================================
class HRSettings(Base):
    __tablename__ = "hr_settings"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # null = إعدادات الشركة (default)، غير كده إعدادات فرع
    branch_code = Column(
        String(50),
        nullable=True,
        index=True,
    )

    # ساعات العمل اليومية
    work_hours_per_day = Column(
        Float,
        default=8.0,
    )

    # فترة سماح للتأخير (دقائق)
    late_grace_minutes = Column(
        Integer,
        default=15,
    )

    # معامل الإضافي
    overtime_multiplier = Column(
        Float,
        default=1.5,
    )

    # يوم الراحة الأسبوعي (0=الأحد، 5=الجمعة، 6=السبت)
    weekly_vacation_day = Column(
        Integer,
        default=5,  # الجمعة
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    __table_args__ = (
        Index(
            'idx_hr_settings_company_branch',
            'company_code',
            'branch_code',
            unique=True,
        ),
    )

# ==========================================
# 15. إعدادات الموظف في HR
#
# - يوم الإجازة الأسبوعي
# - مواعيد العمل الثابتة
# - مرونة المواعيد
# ==========================================
class HREmployeeSettings(Base):
    __tablename__ = "hr_employee_settings"

    id = Column(
        Integer,
        primary_key=True,
        index=True,
        autoincrement=True,
    )

    company_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    employee_code = Column(
        String(50),
        nullable=False,
        index=True,
    )

    # 0=الأحد, 1=الاثنين, ..., 5=الجمعة, 6=السبت
    # null = لا يوجد إجازة أسبوعية
    weekly_vacation_day = Column(
        Integer,
        nullable=True,
    )

    # مواعيد العمل الثابتة (HH:MM)
    default_check_in = Column(
        String(10),
        default="09:00",
    )

    default_check_out = Column(
        String(10),
        default="17:00",
    )

    # مرونة المواعيد: لو true، حساب الحضور بالمدة مش بالتوقيت
    flexible_hours = Column(
        Boolean,
        default=False,
    )

    updated_at = Column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
    )

    __table_args__ = (
        UniqueConstraint(
            "company_code",
            "employee_code",
            name="uq_hr_employee_settings",
        ),
        Index(
            "idx_hr_employee_settings",
            "company_code",
            "employee_code",
        ),
    )
    # قواعد الخصم للتأخير/الغياب (JSON)
    # {
    #   "delay_10min": 0.0,
    #   "delay_15min": 0.25,
    #   "delay_30min": 0.5,
    #   "delay_60min": 1.0,
    #   "delay_120min": 2.0,
    #   "absence": 1.0,
    #   "absence_with_permission": 0.5
    # }
    delay_rules = Column(
        JSON,
        default=dict,
    )
    use_fixed_month_days = Column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )