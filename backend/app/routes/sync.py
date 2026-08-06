from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from app.core.sync import manager

router = APIRouter()

@router.websocket("/ws/{company_code}")
async def websocket_endpoint(websocket: WebSocket, company_code: str):
    await manager.connect(company_code, websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(company_code, websocket)