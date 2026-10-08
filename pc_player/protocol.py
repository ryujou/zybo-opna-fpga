from __future__ import annotations

from dataclasses import dataclass
import ctypes.util
from pathlib import Path
import time
from typing import Iterable, Optional

import usb.core
import usb.backend.libusb1
import usb.util


SYNC0 = 0x4F
SYNC1 = 0x50

TYPE_HELLO = 0x01
TYPE_ENTER_STREAM = 0x02
TYPE_OPL_EVENT = 0x03
TYPE_STOP = 0x04
TYPE_RESET_OPL = 0x05
TYPE_STATUS = 0x06
TYPE_EXIT_STREAM = 0x07
TYPE_UPLOAD_BEGIN = 0x08
TYPE_UPLOAD_CHUNK = 0x09
TYPE_UPLOAD_END = 0x0A
TYPE_PLAY_BUFFERED = 0x0B
TYPE_PAUSE_BUFFERED = 0x0C
TYPE_RESUME_BUFFERED = 0x0D
TYPE_ERROR = 0x7F
RESPONSE_MASK = 0x80

USB_VID = 0xCAFE
USB_PID = 0x4012
USB_INTERFACE = 0
DEFAULT_UPLOAD_CHUNK_BYTES = 1024

_LIBUSB_CANDIDATES = [
    str(Path(__file__).resolve().with_name("libusb-1.0.dll")),
    r"C:\Espressif\tools\dfu-util\0.11\dfu-util-0.11-win64\libusb-1.0.dll",
    r"C:\Program Files (x86)\STMicroelectronics\stlink_server\libusb-1.0.dll",
]


@dataclass
class OplWrite:
    bank: int
    reg: int
    value: int


@dataclass
class StreamStatus:
    free_slots: int
    queued_slots: int
    playing: bool


@dataclass
class HelloInfo:
    version_major: int
    version_minor: int
    queue_capacity: int
    stream_baud: int
    cli_baud: int
    preload_capacity: int
    max_frame_payload: int
    upload_chunk_bytes: int
    transport_flags: int


@dataclass
class UsbDeviceInfo:
    key: str
    label: str
    vendor_id: int
    product_id: int
    manufacturer: str
    product: str
    serial_number: str


class ProtocolError(RuntimeError):
    pass


def _get_backend():
    for candidate in _LIBUSB_CANDIDATES:
        if Path(candidate).exists():
            backend = usb.backend.libusb1.get_backend(find_library=lambda _name, c=candidate: c)
            if backend is not None:
                return backend

    found = ctypes.util.find_library("libusb-1.0")
    if found:
        backend = usb.backend.libusb1.get_backend(find_library=lambda _name, f=found: f)
        if backend is not None:
            return backend

    return usb.backend.libusb1.get_backend()


def _checksum(frame_type: int, payload: bytes) -> int:
    length = len(payload)
    return (frame_type + (length & 0xFF) + ((length >> 8) & 0xFF) + sum(payload)) & 0xFF


def encode_frame(frame_type: int, payload: bytes = b"") -> bytes:
    length = len(payload)
    header = bytes([SYNC0, SYNC1, frame_type, length & 0xFF, (length >> 8) & 0xFF])
    return header + payload + bytes([_checksum(frame_type, payload)])


def _device_key(device: usb.core.Device) -> str:
    bus = getattr(device, "bus", 0)
    address = getattr(device, "address", 0)
    return f"{device.idVendor:04x}:{device.idProduct:04x}:{bus}:{address}"


def _safe_get_string(device: usb.core.Device, index: int) -> str:
    if not index:
        return ""
    try:
        return usb.util.get_string(device, index) or ""
    except (usb.core.USBError, ValueError):
        return ""


def list_usb_devices(active_key=None) -> list[UsbDeviceInfo]:
    backend = _get_backend()
    if backend is None:
        raise ProtocolError("未找到 libusb 后端，请先安装可用的 libusb-1.0.dll")
    devices = usb.core.find(find_all=True, idVendor=USB_VID, idProduct=USB_PID, backend=backend)
    result: list[UsbDeviceInfo] = []
    for device in devices:
        owned = _device_key(device) == active_key
        manufacturer = "" if owned else _safe_get_string(device, device.iManufacturer)
        product = "" if owned else _safe_get_string(device, device.iProduct)
        serial = "" if owned else _safe_get_string(device, device.iSerialNumber)
        label = "Zybo OPL3 USB"
        suffix = f"{device.idVendor:04X}:{device.idProduct:04X}"
        bus = getattr(device, "bus", 0)
        address = getattr(device, "address", 0)
        label = f"{label} ({suffix}, Bus {bus}, Addr {address})"
        result.append(
            UsbDeviceInfo(
                key=_device_key(device),
                label=label,
                vendor_id=device.idVendor,
                product_id=device.idProduct,
                manufacturer=manufacturer,
                product=product,
                serial_number=serial,
            )
        )
    return result


class ZyboTransport:
    def __init__(self, device_key: str, timeout: float = 1.0) -> None:
        self.device_key = device_key
        self.timeout = timeout
        self.device: Optional[usb.core.Device] = None
        self.backend = _get_backend()
        self.ep_out = None
        self.ep_in = None
        self.rx_buffer = bytearray()
        self.upload_chunk_bytes = DEFAULT_UPLOAD_CHUNK_BYTES

    def _open_device_with_retry(self) -> None:
        last_error: Exception | None = None
        for _attempt in range(5):
            self.device = self._find_device()
            if self.device is None:
                last_error = ProtocolError("USB device not found")
                time.sleep(0.2)
                continue

            try:
                self._configure_device()
                return
            except usb.core.USBError as exc:
                last_error = exc
                try:
                    usb.util.dispose_resources(self.device)
                except Exception:
                    pass
                self.device = None
                self.ep_in = None
                self.ep_out = None
                self.rx_buffer.clear()
                time.sleep(0.3)

        if last_error is not None:
            raise last_error
        raise ProtocolError("USB device open failed")

    def open(self) -> HelloInfo:
        candidate = self._find_device()
        if candidate is None or not candidate.serial_number.startswith("ZOPL3"):
            raise ProtocolError("所选 USB 设备不是 OPL3")
        self._open_device_with_retry()
        hello = self.hello()
        self.upload_chunk_bytes = hello.upload_chunk_bytes or DEFAULT_UPLOAD_CHUNK_BYTES
        self.enter_stream()
        self.reset_opl()
        self._drain_async_frames()
        return hello

        self.device = self._find_device()
        if self.device is None:
            raise ProtocolError("未找到 Zybo OPL3 USB 设备")

        self._configure_device()
        hello = self.hello()
        self.upload_chunk_bytes = hello.upload_chunk_bytes or DEFAULT_UPLOAD_CHUNK_BYTES
        self.enter_stream()
        self.reset_opl()
        self._drain_async_frames()
        return hello

    def close(self) -> None:
        if self.device is None:
            return
        try:
            self.stop()
        except Exception:
            pass
        try:
            usb.util.release_interface(self.device, USB_INTERFACE)
        except Exception:
            pass
        try:
            usb.util.dispose_resources(self.device)
        except Exception:
            pass
        self.device = None
        self.ep_in = None
        self.ep_out = None
        self.rx_buffer.clear()

    def hello(self) -> HelloInfo:
        payload = self._request(TYPE_HELLO)
        if len(payload) < 16:
            raise ProtocolError("HELLO 响应长度不正确")
        return HelloInfo(
            version_major=payload[0],
            version_minor=payload[1],
            queue_capacity=payload[2] | (payload[3] << 8),
            stream_baud=int.from_bytes(payload[4:8], "little"),
            cli_baud=int.from_bytes(payload[8:12], "little"),
            preload_capacity=int.from_bytes(payload[12:16], "little"),
            max_frame_payload=int.from_bytes(payload[16:18], "little") if len(payload) >= 18 else 0,
            upload_chunk_bytes=int.from_bytes(payload[18:20], "little") if len(payload) >= 20 else DEFAULT_UPLOAD_CHUNK_BYTES,
            transport_flags=int.from_bytes(payload[20:24], "little") if len(payload) >= 24 else 0,
        )

    def enter_stream(self) -> None:
        self._request(TYPE_ENTER_STREAM)

    def stop(self) -> None:
        self._request(TYPE_STOP)
        self._drain_async_frames()

    def reset_opl(self) -> None:
        self._request(TYPE_RESET_OPL)
        self._drain_async_frames()

    def exit_stream(self) -> None:
        self._request(TYPE_EXIT_STREAM)
        self._drain_async_frames()

    def query_status(self) -> StreamStatus:
        payload = self._request(TYPE_STATUS)
        if len(payload) < 5:
            raise ProtocolError("STATUS 响应长度不正确")
        return StreamStatus(
            free_slots=payload[0] | (payload[1] << 8),
            queued_slots=payload[2] | (payload[3] << 8),
            playing=bool(payload[4]),
        )

    def send_event(self, delay_us: int, writes: Iterable[OplWrite]) -> None:
        write_list = list(writes)
        if not write_list:
            return
        if len(write_list) > 63:
            raise ProtocolError("单个事件包含的 OPL 写次数过多")

        payload = bytearray()
        payload.extend(int(delay_us).to_bytes(4, "little", signed=False))
        payload.append(len(write_list))
        for write in write_list:
            payload.extend([write.bank & 0x01, write.reg & 0xFF, write.value & 0xFF])
        self._write_frame(TYPE_OPL_EVENT, bytes(payload))

    def upload_song(self, data: bytes, on_progress=None) -> None:
        if not data:
            raise ProtocolError("没有可上传的 OPL 事件数据")
        self._request(TYPE_UPLOAD_BEGIN, len(data).to_bytes(4, "little", signed=False))
        chunk_size = max(64, self.upload_chunk_bytes)
        for offset in range(0, len(data), chunk_size):
            chunk = data[offset : offset + chunk_size]
            self._request(TYPE_UPLOAD_CHUNK, chunk)
            if on_progress is not None:
                on_progress(min(offset + chunk_size, len(data)), len(data))
        self._request(TYPE_UPLOAD_END)

    def play_buffered(self) -> float:
        self._request(TYPE_PLAY_BUFFERED)
        started_at = time.monotonic()
        self._drain_async_frames()
        return started_at

    def pause_buffered(self) -> None:
        self._request(TYPE_PAUSE_BUFFERED)
        self._drain_async_frames()

    def resume_buffered(self) -> float:
        self._request(TYPE_RESUME_BUFFERED)
        resumed_at = time.monotonic()
        self._drain_async_frames()
        return resumed_at

    def _find_device(self) -> Optional[usb.core.Device]:
        if self.backend is None:
            raise ProtocolError("未找到 libusb 后端，请先准备 libusb-1.0.dll")
        for device in usb.core.find(find_all=True, idVendor=USB_VID, idProduct=USB_PID, backend=self.backend):
            if _device_key(device) == self.device_key:
                return device
        return None

    def _configure_device(self) -> None:
        assert self.device is not None
        try:
            self.device.set_configuration()
        except usb.core.USBError:
            pass

        cfg = self.device.get_active_configuration()
        intf = cfg[(USB_INTERFACE, 0)]

        try:
            if self.device.is_kernel_driver_active(USB_INTERFACE):
                self.device.detach_kernel_driver(USB_INTERFACE)
        except (usb.core.USBError, NotImplementedError):
            # WinUSB/libusb on Windows may not implement kernel driver queries.
            pass
        usb.util.claim_interface(self.device, USB_INTERFACE)

        self.ep_out = usb.util.find_descriptor(
            intf,
            custom_match=lambda ep: usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_OUT,
        )
        self.ep_in = usb.util.find_descriptor(
            intf,
            custom_match=lambda ep: usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN,
        )

        if self.ep_out is None or self.ep_in is None:
            raise ProtocolError("USB 端点枚举失败")

    def _request(self, frame_type: int, payload: bytes = b"") -> bytes:
        self._write_frame(frame_type, payload)
        response_type = frame_type | RESPONSE_MASK
        deadline = time.time() + max(self.timeout, 1.0)
        while time.time() < deadline:
            frame = self._read_frame()
            if frame is None:
                continue
            recv_type, recv_payload = frame
            if recv_type == TYPE_ERROR:
                code = recv_payload[0] if recv_payload else -1
                raise ProtocolError(f"板端返回错误码 {code}")
            if recv_type == response_type:
                return recv_payload
        raise ProtocolError("等待板端响应超时")

    def _write_frame(self, frame_type: int, payload: bytes) -> None:
        if self.device is None or self.ep_out is None:
            raise ProtocolError("USB 设备未连接")
        frame = encode_frame(frame_type, payload)
        written = self.ep_out.write(frame, timeout=int(self.timeout * 1000))
        if written != len(frame):
            raise ProtocolError("USB 数据发送不完整")

    def _read_exact(self, size: int) -> bytes:
        deadline = time.time() + max(self.timeout, 1.0)
        while len(self.rx_buffer) < size and time.time() < deadline:
            if self.device is None or self.ep_in is None:
                raise ProtocolError("USB 设备未连接")
            try:
                packet = self.ep_in.read(self.ep_in.wMaxPacketSize, timeout=int(self.timeout * 1000))
                self.rx_buffer.extend(bytes(packet))
            except usb.core.USBTimeoutError:
                continue
        if len(self.rx_buffer) < size:
            raise TimeoutError("USB 读取超时")
        data = bytes(self.rx_buffer[:size])
        del self.rx_buffer[:size]
        return data

    def _read_frame(self) -> Optional[tuple[int, bytes]]:
        try:
            while True:
                first = self._read_exact(1)
                if first[0] != SYNC0:
                    continue
                second = self._read_exact(1)
                if second[0] == SYNC1:
                    break

            header = self._read_exact(3)
            frame_type = header[0]
            length = header[1] | (header[2] << 8)
            payload = self._read_exact(length) if length else b""
            checksum = self._read_exact(1)[0]
            if checksum != _checksum(frame_type, payload):
                raise ProtocolError("收到的帧校验失败")
            return frame_type, payload
        except TimeoutError:
            return None

    def _drain_async_frames(self) -> None:
        deadline = time.time() + 0.05
        while time.time() < deadline:
            frame = self._read_frame()
            if frame is None:
                break
