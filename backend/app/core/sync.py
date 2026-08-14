# backend/app/core/sync.py

from typing import Dict, Set

from fastapi import WebSocket


class ConnectionManager:
    """
    مدير اتصالات WebSocket.

    كل شركة لها مجموعة مستقلة من الأجهزة المتصلة.

    مثال:

    company 01
        ├── device A
        ├── device B
        └── device C

    company 02
        ├── device D
        └── device E
    """

    def __init__(self):
        self.active_connections: Dict[
            str,
            Set[WebSocket]
        ] = {}

    # ============================================================
    # اتصال جهاز
    # ============================================================

    async def connect(
        self,
        company_code: str,
        websocket: WebSocket,
    ):
        await websocket.accept()

        if company_code not in self.active_connections:
            self.active_connections[company_code] = set()

        self.active_connections[company_code].add(websocket)

        print(
            f"🔌 WebSocket connected | "
            f"company={company_code} | "
            f"connections={len(self.active_connections[company_code])}"
        )

    # ============================================================
    # فصل جهاز
    # ============================================================

    def disconnect(
        self,
        company_code: str,
        websocket: WebSocket,
    ):
        connections = self.active_connections.get(
            company_code
        )

        if not connections:
            return

        connections.discard(websocket)

        # لو مفيش أجهزة متصلة للشركة
        # نحذف مجموعة الشركة لتقليل استخدام الذاكرة.
        if not connections:
            self.active_connections.pop(
                company_code,
                None,
            )

        print(
            f"🔌 WebSocket disconnected | "
            f"company={company_code}"
        )

    # ============================================================
    # إرسال تحديث لكل أجهزة الشركة
    # ============================================================

    async def broadcast(
        self,
        company_code: str,
        message: dict,
    ):
        connections = self.active_connections.get(
            company_code
        )

        if not connections:
            return

        # --------------------------------------------------------
        # نعمل نسخة من الـset
        #
        # عشان لو حصل disconnect أثناء الإرسال
        # ما يحصلش تعديل على المجموعة أثناء iteration.
        # --------------------------------------------------------

        connections_copy = list(connections)

        dead_connections = []

        for connection in connections_copy:
            try:
                await connection.send_json(message)

            except Exception as e:
                print(
                    f"⚠️ فشل إرسال WebSocket | "
                    f"company={company_code} | "
                    f"error={e}"
                )

                dead_connections.append(
                    connection
                )

        # --------------------------------------------------------
        # تنظيف الاتصالات الميتة
        # --------------------------------------------------------

        for connection in dead_connections:
            self.disconnect(
                company_code,
                connection,
            )

    # ============================================================
    # عدد الأجهزة المتصلة
    # ============================================================

    def connection_count(
        self,
        company_code: str,
    ) -> int:
        connections = self.active_connections.get(
            company_code
        )

        if not connections:
            return 0

        return len(connections)

    # ============================================================
    # هل الشركة عندها أجهزة متصلة؟
    # ============================================================

    def has_connections(
        self,
        company_code: str,
    ) -> bool:
        return self.connection_count(
            company_code
        ) > 0


# ============================================================
# Global Connection Manager
# ============================================================

manager = ConnectionManager()