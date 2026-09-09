#!/usr/bin/env python3
"""Process-boundary smoke test for Zim v0.9 MessagePack-RPC.

Uses only the Python standard library so the same test runs on GitHub-hosted
Linux, macOS, and Windows runners.
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
from typing import Any


PROTOCOL_VERSION = 1
API_VERSION = 1
EXPECTED_ZIM_VERSION = "0.9.0"
CALLBACK_ID = 777
TIMEOUT_SECONDS = 20.0


class NeedMore(Exception):
    pass


def pack(value: Any) -> bytes:
    if value is None:
        return b"\xc0"
    if value is False:
        return b"\xc2"
    if value is True:
        return b"\xc3"
    if isinstance(value, int):
        if value < 0:
            if value >= -32:
                return struct.pack("b", value)
            if value >= -128:
                return b"\xd0" + struct.pack("b", value)
            if value >= -32768:
                return b"\xd1" + struct.pack(">h", value)
            if value >= -(1 << 31):
                return b"\xd2" + struct.pack(">i", value)
            return b"\xd3" + struct.pack(">q", value)
        if value <= 0x7F:
            return bytes((value,))
        if value <= 0xFF:
            return b"\xcc" + struct.pack("B", value)
        if value <= 0xFFFF:
            return b"\xcd" + struct.pack(">H", value)
        if value <= 0xFFFFFFFF:
            return b"\xce" + struct.pack(">I", value)
        return b"\xcf" + struct.pack(">Q", value)
    if isinstance(value, str):
        payload = value.encode("utf-8")
        size = len(payload)
        if size <= 31:
            return bytes((0xA0 | size,)) + payload
        if size <= 0xFF:
            return b"\xd9" + struct.pack("B", size) + payload
        if size <= 0xFFFF:
            return b"\xda" + struct.pack(">H", size) + payload
        return b"\xdb" + struct.pack(">I", size) + payload
    if isinstance(value, (list, tuple)):
        size = len(value)
        if size <= 15:
            prefix = bytes((0x90 | size,))
        elif size <= 0xFFFF:
            prefix = b"\xdc" + struct.pack(">H", size)
        else:
            prefix = b"\xdd" + struct.pack(">I", size)
        return prefix + b"".join(pack(item) for item in value)
    if isinstance(value, dict):
        size = len(value)
        if size <= 15:
            prefix = bytes((0x80 | size,))
        elif size <= 0xFFFF:
            prefix = b"\xde" + struct.pack(">H", size)
        else:
            prefix = b"\xdf" + struct.pack(">I", size)
        return prefix + b"".join(pack(k) + pack(v) for k, v in value.items())
    raise TypeError(f"unsupported MessagePack value: {type(value)!r}")


def request(msgid: int, method: str, params: list[Any]) -> bytes:
    return pack([0, msgid, method, params])


def require(data: bytes, offset: int, count: int) -> None:
    if offset + count > len(data):
        raise NeedMore


def read_uint(data: bytes, offset: int, count: int) -> tuple[int, int]:
    require(data, offset, count)
    return int.from_bytes(data[offset : offset + count], "big", signed=False), offset + count


def read_int(data: bytes, offset: int, count: int) -> tuple[int, int]:
    require(data, offset, count)
    return int.from_bytes(data[offset : offset + count], "big", signed=True), offset + count


def decode_one(data: bytes, offset: int = 0) -> tuple[Any, int]:
    require(data, offset, 1)
    marker = data[offset]
    offset += 1

    if marker <= 0x7F:
        return marker, offset
    if marker >= 0xE0:
        return marker - 256, offset
    if 0xA0 <= marker <= 0xBF:
        length = marker & 0x1F
        require(data, offset, length)
        return data[offset : offset + length].decode("utf-8"), offset + length
    if 0x90 <= marker <= 0x9F:
        count = marker & 0x0F
        items = []
        for _ in range(count):
            item, offset = decode_one(data, offset)
            items.append(item)
        return items, offset
    if 0x80 <= marker <= 0x8F:
        count = marker & 0x0F
        result = {}
        for _ in range(count):
            key, offset = decode_one(data, offset)
            value, offset = decode_one(data, offset)
            result[key] = value
        return result, offset

    if marker == 0xC0:
        return None, offset
    if marker == 0xC2:
        return False, offset
    if marker == 0xC3:
        return True, offset
    if marker in (0xCC, 0xCD, 0xCE, 0xCF):
        return read_uint(data, offset, {0xCC: 1, 0xCD: 2, 0xCE: 4, 0xCF: 8}[marker])
    if marker in (0xD0, 0xD1, 0xD2, 0xD3):
        return read_int(data, offset, {0xD0: 1, 0xD1: 2, 0xD2: 4, 0xD3: 8}[marker])
    if marker in (0xD9, 0xDA, 0xDB):
        length_size = {0xD9: 1, 0xDA: 2, 0xDB: 4}[marker]
        length, offset = read_uint(data, offset, length_size)
        require(data, offset, length)
        return data[offset : offset + length].decode("utf-8"), offset + length
    if marker in (0xC4, 0xC5, 0xC6):
        length_size = {0xC4: 1, 0xC5: 2, 0xC6: 4}[marker]
        length, offset = read_uint(data, offset, length_size)
        require(data, offset, length)
        return data[offset : offset + length], offset + length
    if marker in (0xDC, 0xDD):
        count, offset = read_uint(data, offset, 2 if marker == 0xDC else 4)
        items = []
        for _ in range(count):
            item, offset = decode_one(data, offset)
            items.append(item)
        return items, offset
    if marker in (0xDE, 0xDF):
        count, offset = read_uint(data, offset, 2 if marker == 0xDE else 4)
        result = {}
        for _ in range(count):
            key, offset = decode_one(data, offset)
            value, offset = decode_one(data, offset)
            result[key] = value
        return result, offset
    raise AssertionError(f"unsupported MessagePack marker 0x{marker:02x}")


def decode_available(data: bytes) -> tuple[list[Any], int]:
    frames: list[Any] = []
    offset = 0
    while offset < len(data):
        try:
            frame, next_offset = decode_one(data, offset)
        except NeedMore:
            break
        frames.append(frame)
        offset = next_offset
    return frames, offset


def smoke_payload() -> bytes:
    return b"".join(
        (
            request(1, "zim.ping", []),
            request(2, "zim.capabilities", []),
            request(3, "zim.handshake", [999, API_VERSION]),
            request(4, "zim.handshake", [PROTOCOL_VERSION, 999]),
            request(5, "zim.handshake", [PROTOCOL_VERSION, API_VERSION]),
            request(6, "zim.capabilities", []),
            request(7, "zim.command.register", ["RemoteSmoke", "process-boundary smoke", CALLBACK_ID]),
            request(8, "zim.command.execute", ["RemoteSmoke", "hello"]),
        )
    )


def assert_response(frame: Any, msgid: int, *, error: str | None = None) -> Any:
    assert isinstance(frame, list) and len(frame) == 4 and frame[0] == 1, frame
    assert frame[1] == msgid, frame
    assert frame[2] == error, frame
    return frame[3]


def validate_wire(data: bytes, label: str) -> None:
    frames, consumed = decode_available(data)
    assert consumed == len(data), f"{label}: trailing/incomplete bytes ({len(data) - consumed})"
    assert len(frames) == 9, f"{label}: expected 9 frames, got {len(frames)}: {frames!r}"

    assert assert_response(frames[0], 1) == "pong"
    assert_response(frames[1], 2, error="HandshakeRequired")
    assert_response(frames[2], 3, error="ProtocolVersionMismatch")
    assert_response(frames[3], 4, error="ApiVersionMismatch")

    info = assert_response(frames[4], 5)
    assert info["name"] == "zim"
    assert info["zim_version"] == EXPECTED_ZIM_VERSION
    assert info["protocol_version"] == PROTOCOL_VERSION
    assert info["api_version"] == API_VERSION

    capabilities = assert_response(frames[5], 6)
    assert "commands" in capabilities
    assert "rpc.stdio" in capabilities
    assert "rpc.local" in capabilities

    registration_id = assert_response(frames[6], 7)
    assert isinstance(registration_id, int) and registration_id > 0
    assert assert_response(frames[7], 8) is True

    callback = frames[8]
    assert callback == [2, "zim.callback.command", [CALLBACK_ID, "RemoteSmoke", "hello"]], callback


def executable_path() -> Path:
    suffix = ".exe" if os.name == "nt" else ""
    path = Path("zig-out") / "bin" / f"zim{suffix}"
    if not path.exists():
        raise AssertionError(f"built Zim executable not found at {path}")
    return path.resolve()


def isolated_environment(config_root: str) -> dict[str, str]:
    env = os.environ.copy()
    env["XDG_CONFIG_HOME"] = config_root
    return env


def run_stdio_smoke(exe: Path, env: dict[str, str]) -> None:
    result = subprocess.run(
        [str(exe), "--rpc-stdio"],
        input=smoke_payload(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=TIMEOUT_SECONDS,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"stdio server exited {result.returncode}: {result.stderr.decode(errors='replace')}"
        )
    validate_wire(result.stdout, "stdio")


def read_socket_frames(sock: socket.socket) -> bytes:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    wire = bytearray()
    while time.monotonic() < deadline:
        chunk = sock.recv(8192)
        if not chunk:
            break
        wire.extend(chunk)
        frames, _ = decode_available(bytes(wire))
        if len(frames) >= 9:
            return bytes(wire)
    raise AssertionError(f"local Unix socket returned incomplete RPC output: {bytes(wire)!r}")


def connect_unix(path: str, process: subprocess.Popen[bytes]) -> socket.socket:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
            raise AssertionError(f"local RPC server exited before connect: {stderr}")
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.connect(path)
            client.settimeout(2.0)
            return client
        except OSError:
            client.close()
            time.sleep(0.02)
    raise AssertionError(f"timed out connecting to Unix RPC socket {path}")


def windows_pipe_connect(name: str, process: subprocess.Popen[bytes]):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle_t = ctypes.c_void_p
    dword = ctypes.c_uint32

    kernel32.WaitNamedPipeW.argtypes = [ctypes.c_wchar_p, dword]
    kernel32.WaitNamedPipeW.restype = ctypes.c_int
    kernel32.CreateFileW.argtypes = [
        ctypes.c_wchar_p,
        dword,
        dword,
        ctypes.c_void_p,
        dword,
        dword,
        handle_t,
    ]
    kernel32.CreateFileW.restype = handle_t

    path = name if name.startswith("\\\\.\\pipe\\") else f"\\\\.\\pipe\\{name}"
    generic_read = 0x80000000
    generic_write = 0x40000000
    open_existing = 3
    invalid_handle = ctypes.c_void_p(-1).value
    deadline = time.monotonic() + TIMEOUT_SECONDS

    while time.monotonic() < deadline:
        if process.poll() is not None:
            stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
            raise AssertionError(f"named-pipe RPC server exited before connect: {stderr}")
        kernel32.WaitNamedPipeW(path, 100)
        handle = kernel32.CreateFileW(
            path,
            generic_read | generic_write,
            0,
            None,
            open_existing,
            0,
            None,
        )
        if handle and handle != invalid_handle:
            return kernel32, handle
        time.sleep(0.02)
    raise AssertionError(f"timed out connecting to named pipe {path}")


def windows_pipe_exchange(name: str, process: subprocess.Popen[bytes]) -> bytes:
    kernel32, handle = windows_pipe_connect(name, process)
    dword = ctypes.c_uint32
    kernel32.WriteFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, dword, ctypes.POINTER(dword), ctypes.c_void_p]
    kernel32.WriteFile.restype = ctypes.c_int
    kernel32.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, dword, ctypes.POINTER(dword), ctypes.c_void_p]
    kernel32.ReadFile.restype = ctypes.c_int
    kernel32.PeekNamedPipe.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        dword,
        ctypes.c_void_p,
        ctypes.POINTER(dword),
        ctypes.c_void_p,
    ]
    kernel32.PeekNamedPipe.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int

    payload = smoke_payload()
    payload_buffer = ctypes.create_string_buffer(payload)
    written = dword()
    if not kernel32.WriteFile(handle, payload_buffer, len(payload), ctypes.byref(written), None):
        error = ctypes.get_last_error()
        kernel32.CloseHandle(handle)
        raise AssertionError(f"WriteFile to RPC pipe failed with Win32 error {error}")
    assert written.value == len(payload)

    wire = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    try:
        while time.monotonic() < deadline:
            available = dword()
            if not kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(available), None):
                raise AssertionError(f"PeekNamedPipe failed with Win32 error {ctypes.get_last_error()}")
            if available.value:
                count = min(available.value, 8192)
                buffer = ctypes.create_string_buffer(count)
                read = dword()
                if not kernel32.ReadFile(handle, buffer, count, ctypes.byref(read), None):
                    raise AssertionError(f"ReadFile from RPC pipe failed with Win32 error {ctypes.get_last_error()}")
                wire.extend(buffer.raw[: read.value])
                frames, _ = decode_available(bytes(wire))
                if len(frames) >= 9:
                    return bytes(wire)
            if process.poll() is not None:
                stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
                raise AssertionError(f"named-pipe RPC server exited early: {stderr}")
            time.sleep(0.01)
    finally:
        kernel32.CloseHandle(handle)
    raise AssertionError(f"named pipe returned incomplete RPC output: {bytes(wire)!r}")


def run_local_smoke(exe: Path, env: dict[str, str]) -> None:
    if os.name == "nt":
        endpoint = f"zim-rpc-smoke-{os.getpid()}"
    else:
        endpoint = f"/tmp/zim-rpc-smoke-{os.getpid()}.sock"
        try:
            os.unlink(endpoint)
        except FileNotFoundError:
            pass

    process = subprocess.Popen(
        [str(exe), "--headless", "--rpc-listen", endpoint],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    try:
        if os.name == "nt":
            wire = windows_pipe_exchange(endpoint, process)
        else:
            client = connect_unix(endpoint, process)
            try:
                client.sendall(smoke_payload())
                wire = read_socket_frames(client)
            finally:
                client.close()
        validate_wire(wire, "local")
        returncode = process.wait(timeout=TIMEOUT_SECONDS)
        if returncode != 0:
            stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
            raise AssertionError(f"local RPC server exited {returncode}: {stderr}")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if os.name != "nt":
            try:
                os.unlink(endpoint)
            except FileNotFoundError:
                pass


def main() -> int:
    exe = executable_path()
    with tempfile.TemporaryDirectory(prefix="zim-rpc-config-") as config_root:
        env = isolated_environment(config_root)
        run_stdio_smoke(exe, env)
        run_local_smoke(exe, env)
    print("RPC process-boundary smoke passed (stdio + local IPC)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"rpc-smoke: {exc}", file=sys.stderr)
        raise
