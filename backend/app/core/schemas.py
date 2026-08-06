from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from datetime import datetime

# ===================== التكويد =====================
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

# ===================== اليوميات =====================
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

# ===================== الجرد =====================
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

# ===================== الموردين =====================
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
    employee: str
    items: List[SupplierItemModel]
    total_amount: float
    paid_amount: float
    updated_at: Optional[str] = None
    doc_id: Optional[str] = None

# ===================== نماذج إضافية للصلاحيات =====================
class PermissionsUpdateModel(BaseModel):
    email: str
    permissions: Dict[str, Dict[str, bool]]
    allowed_branches: Optional[List[str]] = None

# ===================== نماذج إضافية للشركات =====================
class CompanyModel(BaseModel):
    code: str
    name: str

class CompanyUpdateModel(BaseModel):
    old_code: str
    new_code: str
    new_name: str
    admin_job_code: str