#!/usr/bin/env python3
"""上海创智学院 SRun 有线网自动重连工具（仅使用 Python 标准库）。"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import logging
import os
import plistlib
import re
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


DEFAULT_BASE_URL = "https://auth.sii.edu.cn"
ALLOWED_PORTAL_HOST = "auth.sii.edu.cn"
DEFAULT_AC_ID = "1"
DEFAULT_THEME = "pro"
KEYCHAIN_SERVICE = "cn.edu.sii.srun-autologin"
LAUNCH_AGENT_LABEL = "cn.edu.sii.srun-autologin"

APP_DIR = Path.home() / "Library" / "Application Support" / "SII-SRun"
CONFIG_PATH = APP_DIR / "config.json"
INSTALLED_SCRIPT = APP_DIR / "sii_srun_autologin.py"
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"
LOG_DIR = Path.home() / "Library" / "Logs" / "SII-SRun"

STANDARD_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
SRUN_B64 = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"


class SRunError(RuntimeError):
    """可向用户显示的认证错误。"""


class HTTPStatusError(SRunError):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class CaptchaRequired(SRunError):
    """门户要求图形验证码，守护进程不能无交互处理。"""


def validate_base_url(value: str) -> str:
    """仅允许向学校官方 HTTPS 门户发送认证数据。"""
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise SRunError("认证服务器地址无效") from exc
    if (
        parsed.scheme != "https"
        or parsed.hostname != ALLOWED_PORTAL_HOST
        or port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise SRunError(f"认证服务器必须是 https://{ALLOWED_PORTAL_HOST}")
    return DEFAULT_BASE_URL


def safe_response_code(result: dict[str, Any], fallback: str) -> str:
    """只返回不含个人数据的短服务器代码，避免把任意响应写入日志。"""
    for key in ("error", "ecode", "suc_msg", "code"):
        value = str(result.get(key, ""))
        if re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", value):
            return value
    return fallback


class PortalRedirectHandler(urllib.request.HTTPRedirectHandler):
    """阻止含认证参数的请求被重定向到其他来源。"""

    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> Optional[urllib.request.Request]:
        target = urllib.parse.urlsplit(urllib.parse.urljoin(request.full_url, new_url))
        try:
            port = target.port
        except ValueError as exc:
            raise SRunError("认证服务器返回了无效重定向") from exc
        if target.scheme != "https" or target.hostname != ALLOWED_PORTAL_HOST or port not in (None, 443):
            raise SRunError("认证服务器尝试重定向到其他站点，已拒绝")
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


@dataclass(frozen=True)
class Settings:
    username: str
    base_url: str = DEFAULT_BASE_URL
    ac_id: str = DEFAULT_AC_ID
    theme: str = DEFAULT_THEME


@dataclass(frozen=True)
class OnlineState:
    online: bool
    username: str = ""
    ip: str = ""


@dataclass(frozen=True)
class WiredLinkState:
    connected: bool
    interface: str = ""
    ip: str = ""
    reason: str = ""


def _u32(value: int) -> int:
    return value & 0xFFFFFFFF


def _js_code_units(text: str) -> list[int]:
    """返回与 JavaScript charCodeAt 一致的 UTF-16 code units。"""
    raw = text.encode("utf-16le")
    return [raw[i] | (raw[i + 1] << 8) for i in range(0, len(raw), 2)]


def _sencode(text: str, include_length: bool) -> list[int]:
    units = _js_code_units(text)
    values: list[int] = []
    for i in range(0, len(units), 4):
        value = units[i]
        if i + 1 < len(units):
            value |= units[i + 1] << 8
        if i + 2 < len(units):
            value |= units[i + 2] << 16
        if i + 3 < len(units):
            value |= units[i + 3] << 24
        values.append(_u32(value))
    if include_length:
        values.append(len(units))
    return values


def _lencode(values: list[int]) -> bytes:
    output = bytearray()
    for value in values:
        output.extend(
            (
                value & 0xFF,
                (value >> 8) & 0xFF,
                (value >> 16) & 0xFF,
                (value >> 24) & 0xFF,
            )
        )
    return bytes(output)


def xencode(text: str, key: str) -> bytes:
    """实现该门户前端使用的 XXTEA 变体。"""
    if not text:
        return b""

    values = _sencode(text, True)
    key_values = _sencode(key, False)
    key_values.extend([0] * (4 - len(key_values)))

    n = len(values) - 1
    z = values[n]
    constant = 0x86014019 | 0x183639A0
    total = 0
    rounds = 6 + 52 // (n + 1)

    while rounds > 0:
        total = _u32(total + constant)
        e = (total >> 2) & 3

        for p in range(n):
            y = values[p + 1]
            mixed = (
                ((z >> 5) ^ (y << 2))
                + (((y >> 3) ^ (z << 4)) ^ (total ^ y))
                + (key_values[(p & 3) ^ e] ^ z)
            )
            values[p] = _u32(values[p] + mixed)
            z = values[p]

        y = values[0]
        mixed = (
            ((z >> 5) ^ (y << 2))
            + (((y >> 3) ^ (z << 4)) ^ (total ^ y))
            + (key_values[(n & 3) ^ e] ^ z)
        )
        values[n] = _u32(values[n] + mixed)
        z = values[n]
        rounds -= 1

    return _lencode(values)


def srun_info(username: str, password: str, ip: str, ac_id: str, token: str) -> str:
    payload = json.dumps(
        {
            "username": username,
            "password": password,
            "ip": ip,
            "acid": ac_id,
            "enc_ver": "srun_bx1",
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
    encoded = base64.b64encode(xencode(payload, token)).decode("ascii")
    encoded = encoded.translate(str.maketrans(STANDARD_B64, SRUN_B64))
    return "{SRBX1}" + encoded


def _parse_json_or_jsonp(text: str) -> dict[str, Any]:
    payload = text.strip()
    if not payload:
        raise SRunError("认证服务器返回了空响应")

    if not payload.startswith("{"):
        match = re.match(r"^[^(]+\((.*)\)\s*;?\s*$", payload, flags=re.DOTALL)
        if not match:
            raise SRunError("无法解析认证服务器响应")
        payload = match.group(1)

    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise SRunError("认证服务器返回的 JSON 无效") from exc
    if not isinstance(parsed, dict):
        raise SRunError("认证服务器返回了意外的数据格式")
    return parsed


def _hardware_port_map(text: str) -> dict[str, str]:
    ports: dict[str, str] = {}
    current_port = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("Hardware Port:"):
            current_port = line.split(":", 1)[1].strip()
        elif line.startswith("Device:") and current_port:
            device = line.split(":", 1)[1].strip()
            if device:
                ports[device] = current_port
    return ports


def _is_wired_hardware_port(name: str) -> bool:
    normalized = name.casefold()
    if "wi-fi" in normalized or "airport" in normalized or "bridge" in normalized:
        return False
    return bool(
        "ethernet" in normalized
        or re.search(r"\busb\b.*\blan\b", normalized)
        or "10/100" in normalized
        or "gigabit" in normalized
    )


def _run_network_probe(command: list[str]) -> str:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=4.0,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SRunError(f"无法执行网络接口检查：{command[0]}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise SRunError(detail or f"网络接口检查失败：{command[0]}")
    return result.stdout


def detect_wired_link(base_url: str) -> WiredLinkState:
    """仅当认证站点路由实际经过已激活的有线接口时返回 connected。"""
    hostname = urllib.parse.urlsplit(base_url).hostname
    if not hostname:
        return WiredLinkState(False, reason="认证服务器地址无效")

    try:
        hardware_text = _run_network_probe(["/usr/sbin/networksetup", "-listallhardwareports"])
        hardware_ports = _hardware_port_map(hardware_text)
        route_text = _run_network_probe(["/sbin/route", "-n", "get", hostname])
    except SRunError as exc:
        return WiredLinkState(False, reason=str(exc))

    route_match = re.search(r"^\s*interface:\s*(\S+)", route_text, flags=re.MULTILINE)
    if not route_match:
        return WiredLinkState(False, reason="认证服务器当前没有可用路由")

    interface = route_match.group(1)
    port_name = hardware_ports.get(interface, "")
    if not port_name:
        return WiredLinkState(False, interface=interface, reason="无法确认当前路由接口是有线网卡")
    if not _is_wired_hardware_port(port_name):
        return WiredLinkState(False, interface=interface, reason="认证服务器当前未走有线网卡")

    try:
        interface_text = _run_network_probe(["/sbin/ifconfig", interface])
    except SRunError as exc:
        return WiredLinkState(False, interface=interface, reason=str(exc))

    if not re.search(r"^\s*status:\s*active\s*$", interface_text, flags=re.MULTILINE):
        return WiredLinkState(False, interface=interface, reason="有线网口未检测到物理链路")

    ipv4_match = re.search(r"^\s*inet\s+(\d+(?:\.\d+){3})\b", interface_text, flags=re.MULTILINE)
    if not ipv4_match:
        return WiredLinkState(False, interface=interface, reason="有线网卡尚未取得 IPv4 地址")
    ip = ipv4_match.group(1)
    if ip.startswith("169.254."):
        return WiredLinkState(False, interface=interface, ip=ip, reason="有线网卡只有自分配地址，尚未取得校园网地址")

    return WiredLinkState(True, interface=interface, ip=ip, reason=f"{port_name} 已连接")


class PortalClient:
    def __init__(self, settings: Settings, timeout: float = 8.0):
        self.settings = Settings(
            username=settings.username,
            base_url=validate_base_url(settings.base_url),
            ac_id=settings.ac_id,
            theme=settings.theme,
        )
        self.timeout = timeout

        context = ssl.create_default_context()
        # 校园门户应直连；忽略系统中的 HTTP(S) 代理环境变量。
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            PortalRedirectHandler(),
            urllib.request.HTTPSHandler(context=context),
        )

    def _request_text(self, path: str, params: Optional[dict[str, Any]] = None) -> str:
        base = self.settings.base_url.rstrip("/")
        url = base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)

        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/json,text/javascript,*/*;q=0.8",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) SII-SRun-Autologin/1.0",
            },
        )
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                return response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            raise HTTPStatusError(exc.code, f"认证服务器返回 HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise SRunError(f"无法连接认证服务器：{reason}") from exc

    def _request_object(
        self,
        path: str,
        params: Optional[dict[str, Any]] = None,
        jsonp: bool = False,
    ) -> dict[str, Any]:
        query = dict(params or {})
        if jsonp:
            query.setdefault("callback", f"_srun_{int(time.time() * 1000)}")
            query.setdefault("_", str(int(time.time() * 1000)))
        return _parse_json_or_jsonp(self._request_text(path, query))

    def status(self) -> OnlineState:
        result = self._request_object("/cgi-bin/rad_user_info", jsonp=True)
        if result.get("error") == "ok":
            return OnlineState(
                online=True,
                username=str(result.get("user_name", "")),
                ip=str(result.get("online_ip", "")),
            )
        if result.get("error") in {"not_online_error", "no_response_data_error"}:
            return OnlineState(online=False)
        raise SRunError(f"查询在线状态失败（服务器代码：{safe_response_code(result, 'unknown')}）")

    def discover_ip(self) -> str:
        page = self._request_text(
            "/srun_portal_pc",
            {"ac_id": self.settings.ac_id, "theme": self.settings.theme},
        )
        match = re.search(r'\bip\s*:\s*"([^"]+)"', page)
        if not match or not match.group(1):
            raise SRunError("认证页没有返回客户端 IP；请确认有线网已连接")
        return match.group(1)

    def _check_captcha(self, ip: str) -> None:
        try:
            result = self._request_object(
                "/v2/srun_portal_captcha_image_info",
                {"user_name": self.settings.username, "ip": ip},
            )
        except HTTPStatusError as exc:
            if exc.status == 404:
                return
            raise
        if result.get("code") == 0 and str(result.get("data")) == "1":
            raise CaptchaRequired("本次登录需要图形验证码，请先在网页上手动登录一次")

    def login(self, password: str) -> dict[str, Any]:
        username = self.settings.username
        ip = self.discover_ip()
        self._check_captcha(ip)

        challenge = self._request_object(
            "/cgi-bin/get_challenge",
            {"username": username, "ip": ip},
            jsonp=True,
        )
        token = str(challenge.get("challenge", ""))
        if not token:
            raise SRunError(
                f"获取登录 challenge 失败（服务器代码：{safe_response_code(challenge, 'missing_challenge')}）"
            )

        hmd5 = hmac.new(token.encode("utf-8"), password.encode("utf-8"), hashlib.md5).hexdigest()
        info = srun_info(username, password, ip, self.settings.ac_id, token)
        n = "200"
        login_type = "1"
        checksum_source = "".join(
            (
                token,
                username,
                token,
                hmd5,
                token,
                self.settings.ac_id,
                token,
                ip,
                token,
                n,
                token,
                login_type,
                token,
                info,
            )
        )
        checksum = hashlib.sha1(checksum_source.encode("utf-8")).hexdigest()

        result = self._request_object(
            "/cgi-bin/srun_portal",
            {
                "action": "login",
                "username": username,
                "password": "{MD5}" + hmd5,
                "os": "Mac OS",
                "name": "Macintosh",
                "nas_ip": "",
                "double_stack": "0",
                "chksum": checksum,
                "info": info,
                "ac_id": self.settings.ac_id,
                "ip": ip,
                "n": n,
                "type": login_type,
                "captchaId": "",
                "captchaVal": "",
            },
            jsonp=True,
        )

        if result.get("error") == "ok" or result.get("suc_msg") in {
            "login_ok",
            "ip_already_online_error",
        }:
            return result

        raise SRunError(f"登录失败（服务器代码：{safe_response_code(result, 'unknown')}）")


def load_settings() -> Settings:
    try:
        metadata = CONFIG_PATH.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077
        ):
            raise SRunError("配置文件必须由当前用户拥有，且权限不得开放给组或其他用户")
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SRunError(f"尚未配置账号，请先运行：{Path(sys.argv[0]).name} setup") from exc
    except (json.JSONDecodeError, OSError) as exc:
        raise SRunError(f"无法读取配置文件：{CONFIG_PATH}") from exc

    username = str(data.get("username", "")).strip()
    if not username:
        raise SRunError("配置文件中缺少 username")
    return Settings(
        username=username,
        base_url=validate_base_url(str(data.get("base_url", DEFAULT_BASE_URL)).rstrip("/")),
        ac_id=str(data.get("ac_id", DEFAULT_AC_ID)),
        theme=str(data.get("theme", DEFAULT_THEME)),
    )


def save_settings(settings: Settings) -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    APP_DIR.chmod(0o700)
    content = (
        json.dumps(
            {
                "username": settings.username,
                "base_url": settings.base_url,
                "ac_id": settings.ac_id,
                "theme": settings.theme,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )
    descriptor, temporary_name = tempfile.mkstemp(prefix=".config.", dir=APP_DIR)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, CONFIG_PATH)
        CONFIG_PATH.chmod(0o600)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            Path(temporary_name).unlink()
        except FileNotFoundError:
            pass


def keychain_store_interactive(username: str) -> None:
    if sys.platform != "darwin":
        raise SRunError("自动保存密码目前只支持 macOS 钥匙串")
    print("请按 macOS 钥匙串工具的提示输入校园网密码；输入内容不会显示。")
    command = [
        "/usr/bin/security",
        "add-generic-password",
        "-U",
        "-a",
        username,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
    ]
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        raise SRunError("无法写入 macOS 钥匙串")


def keychain_read(username: str) -> str:
    if sys.platform != "darwin":
        raise SRunError("自动读取密码目前只支持 macOS 钥匙串")
    command = [
        "/usr/bin/security",
        "find-generic-password",
        "-a",
        username,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SRunError("钥匙串中没有该账号的密码，请重新运行 setup")
    password = result.stdout.rstrip("\n")
    if not password:
        raise SRunError("钥匙串中的密码为空，请重新运行 setup")
    return password


def configured_account_matches(settings: Settings, online_username: str) -> bool:
    configured_base = settings.username.split("@", 1)[0]
    return not online_username or configured_base == online_username


def emit_once_result(args: argparse.Namespace, state: str, message: str, **extra: Any) -> None:
    if getattr(args, "json", False):
        payload: dict[str, Any] = {"state": state, "message": message}
        payload.update(extra)
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    else:
        print(message)


def setup_command(args: argparse.Namespace) -> int:
    username = input("校园网账号：").strip()
    if not username:
        raise SRunError("账号不能为空")

    settings = Settings(
        username=username,
        base_url=DEFAULT_BASE_URL,
        ac_id=str(args.ac_id),
        theme=args.theme,
    )
    keychain_store_interactive(username)
    save_settings(settings)
    print(f"配置已保存；密码位于 macOS 钥匙串，配置文件为 {CONFIG_PATH}")
    return 0


def status_command(args: argparse.Namespace) -> int:
    settings = load_settings()
    link = detect_wired_link(settings.base_url)
    if not link.connected:
        print(f"未连接可用的有线网：{link.reason}")
        return 4
    client = PortalClient(settings, timeout=args.timeout)
    state = client.status()
    if state.online:
        if configured_account_matches(settings, state.username):
            print(f"有线网在线（接口: {link.interface}，IP: {state.ip or link.ip or '未知'}）")
            return 0
        print("在线，但当前在线账号与配置账号不同；不会自动顶替")
        return 3
    print("离线")
    return 1


def once_command(args: argparse.Namespace) -> int:
    settings = load_settings()
    link = detect_wired_link(settings.base_url)
    if not link.connected:
        emit_once_result(
            args,
            "waitingForWired",
            f"未连接可用的有线网，跳过认证：{link.reason}",
            interface=link.interface,
        )
        return 0
    client = PortalClient(settings, timeout=args.timeout)
    state = client.status()
    if state.online:
        if not configured_account_matches(settings, state.username):
            emit_once_result(args, "onlineOtherAccount", "当前在线账号与配置账号不同，已停止以避免顶替登录")
            return 3
        emit_once_result(args, "online", "已经在线，无需重连", interface=link.interface)
        return 0

    password = keychain_read(settings.username)
    try:
        client.login(password)
    finally:
        password = ""
    time.sleep(1.0)
    verified = client.status()
    if not verified.online:
        raise SRunError("服务器返回登录成功，但再次检查仍为离线")
    emit_once_result(args, "reconnected", "重连成功", interface=link.interface)
    return 0


def watch_command(args: argparse.Namespace) -> int:
    settings = load_settings()
    client = PortalClient(settings, timeout=args.timeout)
    interval = max(10.0, float(args.interval))
    failures = 0
    last_state = ""

    logging.info("自动重连守护进程已启动，检查间隔 %.0f 秒", interval)
    while True:
        try:
            link = detect_wired_link(settings.base_url)
            if not link.connected:
                if last_state != "no-wired-link":
                    logging.info("未连接可用的有线网，暂停认证检查：%s", link.reason)
                last_state = "no-wired-link"
                failures = 0
                time.sleep(interval)
                continue

            if last_state == "no-wired-link":
                logging.info("检测到有线网已连接（接口 %s），开始检查认证状态", link.interface)

            state = client.status()
            if state.online:
                if not configured_account_matches(settings, state.username):
                    if last_state != "other-account":
                        logging.warning("检测到其他账号在线；保持现状，不执行登录")
                    last_state = "other-account"
                else:
                    if last_state != "online":
                        logging.info("网络在线")
                    last_state = "online"
                failures = 0
                time.sleep(interval)
                continue

            if last_state != "offline":
                logging.warning("检测到离线，开始重连")
            last_state = "offline"
            password = keychain_read(settings.username)
            try:
                client.login(password)
            finally:
                password = ""
            time.sleep(1.0)
            verified = client.status()
            if not verified.online:
                raise SRunError("登录请求已完成，但在线状态尚未恢复")
            logging.info("重连成功")
            last_state = "online"
            failures = 0
            time.sleep(interval)

        except CaptchaRequired as exc:
            logging.error("%s；5 分钟后再检查", exc)
            failures = 0
            time.sleep(300)
        except KeyboardInterrupt:
            logging.info("自动重连守护进程已停止")
            return 0
        except SRunError as exc:
            failures += 1
            delay = min(300.0, interval * (2 ** min(failures - 1, 4)))
            logging.warning("%s；%.0f 秒后重试", exc, delay)
            time.sleep(delay)


def install_agent_command(args: argparse.Namespace) -> int:
    settings = load_settings()
    keychain_read(settings.username)

    APP_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    APP_DIR.chmod(0o700)
    LOG_DIR.chmod(0o700)

    for log_path in (LOG_DIR / "autologin.log", LOG_DIR / "autologin.error.log"):
        log_path.touch(exist_ok=True)
        log_path.chmod(0o600)

    source = Path(__file__).resolve()
    if source != INSTALLED_SCRIPT:
        shutil.copy2(source, INSTALLED_SCRIPT)
    INSTALLED_SCRIPT.chmod(0o700)

    plist = {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [
            "/usr/bin/python3",
            "-I",
            str(INSTALLED_SCRIPT),
            "watch",
            "--interval",
            str(max(10.0, float(args.interval))),
            "--timeout",
            str(float(args.timeout)),
        ],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Background",
        "ThrottleInterval": 10,
        "Umask": 0o077,
        "StandardOutPath": str(LOG_DIR / "autologin.log"),
        "StandardErrorPath": str(LOG_DIR / "autologin.error.log"),
        "EnvironmentVariables": {"PYTHONUNBUFFERED": "1"},
    }
    descriptor, temporary_name = tempfile.mkstemp(prefix=".srun-agent.", dir=PLIST_PATH.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            plistlib.dump(plist, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, PLIST_PATH)
        PLIST_PATH.chmod(0o600)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            Path(temporary_name).unlink()
        except FileNotFoundError:
            pass

    domain = f"gui/{os.getuid()}"
    subprocess.run(
        ["/bin/launchctl", "bootout", domain, str(PLIST_PATH)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    result = subprocess.run(
        ["/bin/launchctl", "bootstrap", domain, str(PLIST_PATH)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "未知错误"
        raise SRunError(f"LaunchAgent 加载失败：{message}")

    print("开机登录后的自动重连服务已安装并启动")
    print(f"日志：{LOG_DIR / 'autologin.log'}")
    return 0


def configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="上海创智学院 SRun 有线网自动重连")
    parser.add_argument("--verbose", action="store_true", help="输出更多诊断信息")
    subparsers = parser.add_subparsers(dest="command", required=True)

    setup_parser = subparsers.add_parser("setup", help="保存账号和钥匙串密码")
    setup_parser.add_argument("--ac-id", default=DEFAULT_AC_ID)
    setup_parser.add_argument("--theme", default=DEFAULT_THEME)
    setup_parser.set_defaults(handler=setup_command)

    def add_network_options(command_parser: argparse.ArgumentParser) -> None:
        command_parser.add_argument("--timeout", type=float, default=8.0, help="请求超时秒数")

    status_parser = subparsers.add_parser("status", help="查询当前认证状态")
    add_network_options(status_parser)
    status_parser.set_defaults(handler=status_command)

    once_parser = subparsers.add_parser("once", help="离线时执行一次重连")
    once_parser.add_argument("--json", action="store_true", help="输出稳定的 JSON 状态，供其他程序调用")
    add_network_options(once_parser)
    once_parser.set_defaults(handler=once_command)

    watch_parser = subparsers.add_parser("watch", help="持续监测并自动重连")
    watch_parser.add_argument("--interval", type=float, default=15.0, help="在线检查间隔秒数（最小 10）")
    add_network_options(watch_parser)
    watch_parser.set_defaults(handler=watch_command)

    install_parser = subparsers.add_parser("install-agent", help="安装为 macOS 登录自启服务")
    install_parser.add_argument("--interval", type=float, default=15.0, help="在线检查间隔秒数（最小 10）")
    add_network_options(install_parser)
    install_parser.set_defaults(handler=install_agent_command)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    configure_logging(args.verbose)
    try:
        return int(args.handler(args))
    except KeyboardInterrupt:
        return 130
    except SRunError as exc:
        if getattr(args, "json", False):
            state = "captchaRequired" if isinstance(exc, CaptchaRequired) else "error"
            print(json.dumps({"state": state, "message": str(exc)}, ensure_ascii=False, separators=(",", ":")))
            return 2
        print(f"错误：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
