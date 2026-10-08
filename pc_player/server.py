"""Local HTTP controls, static page and 30 Hz WebSocket snapshots."""
import asyncio
from contextlib import asynccontextmanager
from pathlib import Path
import sys
from typing import Literal

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from playback import Player
from protocol import ProtocolError


class Control(BaseModel):
    action: Literal["select", "play", "pause", "resume", "stop", "restart"]
    id: str | None = None
    device_id: str | None = None


class Voices(BaseModel):
    voices: list[int]


def create_app(visual_test=False):
    @asynccontextmanager
    async def lifespan(app):
        app.state.player = Player(visual_test)
        try:
            yield
        finally:
            await asyncio.to_thread(app.state.player.close)

    app = FastAPI(lifespan=lifespan)

    async def command(action, **args):
        try:
            return await asyncio.wrap_future(app.state.player.submit(action, **args))
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        except (OSError, RuntimeError, ProtocolError) as exc:
            raise HTTPException(503, str(exc)) from exc

    @app.get("/api/state")
    def state():
        return app.state.player.state

    @app.get("/api/devices")
    def devices():
        return app.state.player.state["devices"]

    @app.post("/api/files")
    async def files(request: Request, name: str):
        return await command("load", data=await request.body(), name=name)

    @app.get("/api/song")
    async def song(id: str):
        return await command("song", id=id)

    @app.post("/api/control")
    async def control(body: Control):
        return await command(body.action, id=body.id, device_id=body.device_id)

    @app.post("/api/voices")
    async def voices(body: Voices):
        return await command("voices", voices=body.voices)

    @app.websocket("/ws")
    async def frames(socket: WebSocket):
        await socket.accept()
        try:
            while True:
                await socket.send_json(app.state.player.state)
                await asyncio.sleep(1 / 30)
        except WebSocketDisconnect:
            return

    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
    web = root / "web" if getattr(sys, "frozen", False) else root / "pc_player/web/dist"
    if web.is_dir():
        app.mount("/", StaticFiles(directory=web, html=True), name="web")
    else:
        @app.get("/")
        def missing_web():
            raise HTTPException(503, "请先在 pc_player/web 执行 npm ci 和 npm run build")
    return app
