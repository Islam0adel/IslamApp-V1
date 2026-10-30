from contextvars import ContextVar
from typing import Any, Dict, Optional

# هوية موثقة من Firebase مرتبطة بطلب HTTP الحالي وتُستخدم داخل بث الأحداث.
current_user_context: ContextVar[Optional[Dict[str, Any]]] = ContextVar(
    "current_user_context", default=None
)
