from typing import Dict, Set
import json
from fastapi import WebSocket

class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, Set[WebSocket]] = {}

    async def connect(self, company_code: str, websocket: WebSocket):
        await websocket.accept()
        if company_code not in self.active_connections:
            self.active_connections[company_code] = set()
        self.active_connections[company_code].add(websocket)

    def disconnect(self, company_code: str, websocket: WebSocket):
        if company_code in self.active_connections:
            self.active_connections[company_code].discard(websocket)

    async def broadcast(self, company_code: str, message: dict):
        if company_code in self.active_connections:
            for connection in self.active_connections[company_code]:
                try:
                    await connection.send_json(message)
                except Exception:
                    pass

manager = ConnectionManager()