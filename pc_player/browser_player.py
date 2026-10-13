"""Run the unified player in the default browser; Ctrl+C stops playback and exits."""
import socket
from threading import Thread
import time
import webbrowser

import uvicorn
from server import create_app


def main():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(create_app(), log_level="warning", log_config=None,
                                          loop="asyncio", http="h11", ws="websockets"))
    worker = Thread(target=server.run, kwargs={"sockets": [listener]}, name="player-server")
    worker.start()
    try:
        deadline = time.monotonic() + 10
        while not server.started:
            if not worker.is_alive() or time.monotonic() >= deadline:
                raise RuntimeError("本地播放器服务启动失败")
            time.sleep(.05)
        url = f"http://127.0.0.1:{port}"
        print(f"播放器：{url}\n此窗口保持运行；按 Ctrl+C 停止播放并退出。", flush=True)
        webbrowser.open(url)
        while worker.is_alive():
            worker.join(.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.should_exit = True
        worker.join()
        listener.close()


if __name__ == "__main__":
    main()
