# backend/app/core/request_context.py
from contextvars import ContextVar
from typing import Any, Dict, Optional

# هوية موثقة من Firebase مرتبطة بطلب HTTP الحالي وتُستخدم داخل بث الأحداث.
# متغير سياق يحمل المستخدم الموثّق للطلب الحالي
current_user_context: ContextVar[Optional[Dict[str, Any]]] = ContextVar(
    "current_user_context", default=None
)
