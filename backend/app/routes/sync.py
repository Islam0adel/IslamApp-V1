# backend/app/routes/sync.py

from fastapi import (
    APIRouter,
    WebSocket,
    WebSocketDisconnect,
)

from app.core.sync import manager


router = APIRouter()


# ============================================================
# WebSocket
# ============================================================

@router.websocket("/ws/{company_code}")
async def websocket_endpoint(
    websocket: WebSocket,
    company_code: str,
):
    """
    فتح اتصال WebSocket لجهاز تابع للشركة.

    WebSocket يستخدم للتحديث الفوري للأجهزة المتصلة.

    أما الأجهزة Offline فتعتمد على:
        /changes/{company_code}?since=...

    للحصول على التحديثات التي فاتتها.
    """

    await manager.connect(
        company_code,
        websocket,
    )

    try:
        while True:
            # ------------------------------------------------
            # استقبال أي رسالة من العميل للمحافظة على الاتصال
            # ------------------------------------------------
            await websocket.receive_text()

    except WebSocketDisconnect:
        # ----------------------------------------------------
        # العميل فصل الاتصال بشكل طبيعي
        # ----------------------------------------------------
        manager.disconnect(
            company_code,
            websocket,
        )

    except Exception as e:
        # ----------------------------------------------------
        # أي خطأ آخر أثناء الاتصال
        # ----------------------------------------------------
        print(
            f"⚠️ خطأ في WebSocket | "
            f"company={company_code} | "
            f"error={e}"
        )

        manager.disconnect(
            company_code,
            websocket,
        )