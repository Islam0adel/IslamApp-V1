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