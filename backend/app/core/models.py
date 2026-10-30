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
