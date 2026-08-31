#!/usr/bin/env python3
"""macOS SZU SRun guardian. Credentials are read only from the login Keychain."""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import requests


ROOT = Path.home() / "Library" / "Application Support" / "SZUNetworkGuardian"
CONFIG_PATH = ROOT / "config.json"
LOG_DIR = ROOT / "logs"
LOCK_PATH = ROOT / "guardian.lock"
PID_PATH = ROOT / "guardian.pid"
KEYCHAIN = ROOT / "keychain"
USERNAME_SERVICE = "com.wenjun.szu-network-guardian.username"
PASSWORD_SERVICE = "com.wenjun.szu-network-guardian.password"
SRUN_BASE_URL = "https://net.szu.edu.cn"
DORMITORY_LOGIN_URL = "http://172.30.255.42:801/eportal/portal/login/"
VALID_ZONES = {"teaching_office", "dormitory", "auto"}
PROBE_EXPECTED_TEXT = "Success"
BACKUP_CONNECTIVITY_PROBE = "https://www.baidu.com/favicon.ico"
SRUN_ALPHA = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"
STANDARD_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
UINT32_MASK = 0xFFFFFFFF
STOP = False
WAKE = threading.Event()


class SafeLog:
    def __init__(self) -> None:
        LOG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(LOG_DIR, 0o700)

    def write(self, level: str, event: str) -> None:
        # event strings are defined locally; never pass exceptions, URLs or server bodies here.
        path = LOG_DIR / f"guardian-{date.today():%Y-%m-%d}.log"
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, f"{datetime.now():%Y-%m-%d %H:%M:%S} [{level}] {event}\n".encode())
        finally:
            os.close(fd)
        cutoff = date.today() - timedelta(days=7)
        for old in LOG_DIR.glob("guardian-*.log"):
            try:
                if date.fromisoformat(old.stem.removeprefix("guardian-")) < cutoff:
                    old.unlink()
            except (OSError, ValueError):
                pass


LOG = SafeLog()


def read_keychain(service: str) -> str:
    result = subprocess.run(
        [str(KEYCHAIN), "get", service],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0 or not result.stdout:
        raise RuntimeError("keychain credential unavailable")
    return result.stdout.decode("utf-8")


def read_config() -> dict[str, Any]:
    with CONFIG_PATH.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("network_zone") not in VALID_ZONES:
        raise RuntimeError("unsupported network zone")
    interval = data.get("check_interval_seconds")
    if not isinstance(interval, int) or not 60 <= interval <= 86400:
        raise RuntimeError("invalid check interval")
    if data.get("connectivity_probe") != "https://captive.apple.com/hotspot-detect.html":
        raise RuntimeError("unexpected connectivity probe")
    return data


def direct_session() -> requests.Session:
    session = requests.Session()
    session.trust_env = False  # do not treat local proxy reachability as direct Internet access
    session.headers.update({"User-Agent": "SZUNetworkGuardian-macOS/1.2"})
    return session


def is_online(session: requests.Session, probe: str) -> bool:
    checks = ((probe, "apple"), (BACKUP_CONNECTIVITY_PROBE, "baidu"))
    for url, kind in checks:
        try:
            response = session.get(url, timeout=(4, 8), allow_redirects=True, verify=True)
            if kind == "apple":
                valid = response.status_code == 200 and PROBE_EXPECTED_TEXT in response.text
            else:
                final_host = urlparse(response.url).hostname or ""
                valid = response.status_code == 200 and final_host.endswith("baidu.com")
            if valid:
                return True
        except requests.RequestException:
            continue
    return False


def words(content: bytes, include_length: bool) -> list[int]:
    values = [
        sum((content[i + off] if i + off < len(content) else 0) << (off * 8) for off in range(4))
        for i in range(0, len(content), 4)
    ]
    if include_length:
        values.append(len(content))
    return values


def xencode(content: str, key: str) -> bytes:
    values = words(content.encode("utf-8"), True)
    keys = words(key.encode("utf-8"), False)
    keys.extend([0] * (4 - len(keys)))
    n = len(values) - 1
    z, total, rounds = values[n], 0, 6 + 52 // (n + 1)
    while rounds:
        total = (total + 0x9E3779B9) & UINT32_MASK
        e = (total >> 2) & 3
        for p in range(n):
            y = values[p + 1]
            mix = ((z >> 5) ^ ((y << 2) & UINT32_MASK)) + (((y >> 3) ^ ((z << 4) & UINT32_MASK)) ^ (total ^ y))
            values[p] = (values[p] + mix + (keys[(p & 3) ^ e] ^ z)) & UINT32_MASK
            z = values[p]
        y = values[0]
        mix = ((z >> 5) ^ ((y << 2) & UINT32_MASK)) + (((y >> 3) ^ ((z << 4) & UINT32_MASK)) ^ (total ^ y))
        values[n] = (values[n] + mix + (keys[(n & 3) ^ e] ^ z)) & UINT32_MASK
        z = values[n]
        rounds -= 1
    out = bytearray()
    for value in values:
        out.extend((value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF))
    return bytes(out)


def srun_b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii").translate(str.maketrans(STANDARD_ALPHA, SRUN_ALPHA))


def parse_jsonp(text: str) -> dict[str, Any]:
    match = re.search(r"^[^(]*\((.*)\)\s*;?\s*$", text.strip(), re.DOTALL)
    if not match:
        raise RuntimeError("invalid srun response")
    payload = json.loads(match.group(1))
    if not isinstance(payload, dict):
        raise RuntimeError("invalid srun payload")
    return payload


def jsonp_get(session: requests.Session, path: str, params: dict[str, str]) -> dict[str, Any]:
    try:
        response = session.get(SRUN_BASE_URL + path, params=params, timeout=(4, 10), verify=True)
        response.raise_for_status()
        return parse_jsonp(response.text)
    except (requests.RequestException, ValueError):
        # Never include exception text: requests may contain a full query string.
        raise RuntimeError("srun request failed") from None


def discover_ac_id(session: requests.Session) -> str:
    try:
        response = session.get(SRUN_BASE_URL + "/", timeout=(4, 8), allow_redirects=True, verify=True)
        match = re.search(r"ac_id=(\d+)", response.text)
        if match:
            return match.group(1)
    except requests.RequestException:
        pass
    return "1"


def login_srun(session: requests.Session, username: str, password: str) -> bool:
    ac_id = discover_ac_id(session)
    challenge_data = jsonp_get(session, "/cgi-bin/get_challenge", {"callback": "_", "username": username, "ip": ""})
    challenge, client_ip = str(challenge_data.get("challenge", "")), str(challenge_data.get("client_ip", ""))
    if challenge_data.get("error") not in ("ok", None, "") or not challenge or not client_ip:
        return False
    password_md5 = hmac.new(challenge.encode(), password.encode(), hashlib.md5).hexdigest()
    info_json = json.dumps({"username": username, "password": password, "ip": client_ip, "acid": ac_id, "enc_ver": "srun_bx1"}, ensure_ascii=False, separators=(",", ":"))
    info = "{SRBX1}" + srun_b64(xencode(info_json, challenge))
    checksum = hashlib.sha1("".join(challenge + field for field in (username, password_md5, ac_id, client_ip, "200", "1", info)).encode()).hexdigest()
    portal = jsonp_get(session, "/cgi-bin/srun_portal", {
        "callback": "_", "action": "login", "username": username, "password": "{MD5}" + password_md5,
        "os": "macOS", "name": "macOS", "double_stack": "0", "info": info, "chksum": checksum,
        "ac_id": ac_id, "ip": client_ip, "n": "200", "type": "1",
    })
    return portal.get("error") == "ok" or portal.get("res") == "ok" or portal.get("st") == 1


def parse_dormitory_response(text: str) -> dict[str, Any]:
    stripped = text.strip()
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError:
        match = re.search(r"^[^(]*\((.*)\)\s*;?\s*$", stripped, re.DOTALL)
        if not match:
            raise RuntimeError("invalid dormitory response") from None
        try:
            payload = json.loads(match.group(1))
        except json.JSONDecodeError:
            raise RuntimeError("invalid dormitory response") from None
    if not isinstance(payload, dict):
        raise RuntimeError("invalid dormitory payload")
    return payload


def dormitory_portal_reachable(session: requests.Session) -> bool:
    """Probe only the private portal endpoint; never include account parameters."""
    try:
        response = session.get(
            DORMITORY_LOGIN_URL,
            timeout=(2, 4),
            allow_redirects=False,
        )
        return response.status_code < 500
    except requests.RequestException:
        return False


def login_dormitory(session: requests.Session, username: str, password: str) -> bool:
    """Authenticate to the legacy ePortal without ever logging its credential-bearing URL."""
    try:
        response = session.get(
            DORMITORY_LOGIN_URL,
            params={"user_account": username, "user_password": password},
            headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
            timeout=(4, 10),
            allow_redirects=False,
        )
        if 300 <= response.status_code < 400:
            return False
        response.raise_for_status()
        payload = parse_dormitory_response(response.text)
    except (requests.RequestException, RuntimeError, ValueError):
        # requests exception text may contain the complete URL and plaintext password.
        raise RuntimeError("dormitory request failed") from None
    result = payload.get("result")
    message = str(payload.get("msg", ""))
    return result in (1, "1", True) or "success" in message.lower() or "成功" in message


def authenticate_zone(
    session: requests.Session,
    zone: str,
    username: str,
    password: str,
) -> tuple[bool, str]:
    if zone == "teaching_office":
        LOG.write("WARN", "connectivity unavailable; attempting teaching-office SRun authentication")
        return login_srun(session, username, password), "teaching-office"
    if zone == "dormitory":
        LOG.write("WARN", "connectivity unavailable; attempting dormitory ePortal HTTP authentication")
        return login_dormitory(session, username, password), "dormitory"

    LOG.write("WARN", "connectivity unavailable; auto mode trying teaching-office SRun authentication")
    try:
        if login_srun(session, username, password):
            return True, "teaching-office"
    except RuntimeError:
        pass
    if not dormitory_portal_reachable(session):
        LOG.write("WARN", "auto mode found no reachable dormitory portal; dormitory credentials not sent")
        return False, "none"
    LOG.write("WARN", "auto mode detected dormitory portal; attempting ePortal HTTP authentication")
    return login_dormitory(session, username, password), "dormitory"


def run_check() -> bool:
    config = read_config()
    session = direct_session()
    if is_online(session, config["connectivity_probe"]):
        LOG.write("INFO", "connectivity verified; authentication not attempted")
        return True
    try:
        username, password = read_keychain(USERNAME_SERVICE), read_keychain(PASSWORD_SERVICE)
        success, method = authenticate_zone(session, config["network_zone"], username, password)
    except RuntimeError:
        LOG.write("ERROR", "authentication request failed or Keychain credential unavailable")
        return False
    finally:
        username = password = ""
    if not success:
        LOG.write("WARN", "authentication rejected or no usable response")
        return False
    for delay in (2, 4, 8):
        time.sleep(delay)
        if is_online(session, config["connectivity_probe"]):
            LOG.write("INFO", f"{method} authentication succeeded and connectivity recovered")
            return True
    LOG.write("WARN", "authentication acknowledged but connectivity did not recover")
    return False


def on_signal(signum: int, frame: object) -> None:
    global STOP
    STOP = True


def on_wake(signum: int, frame: object) -> None:
    WAKE.set()


def one_shot() -> int:
    with LOCK_PATH.open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 75
        return 0 if run_check() else 2


def daemon() -> int:
    global STOP
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGUSR1, on_wake)
    with LOCK_PATH.open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        PID_PATH.write_text(str(os.getpid()) + "\n", encoding="ascii")
        os.chmod(PID_PATH, 0o600)
        LOG.write("INFO", "guardian started")
        try:
            while not STOP:
                run_check()
                interval = read_config()["check_interval_seconds"]
                WAKE.wait(interval)
                WAKE.clear()
        finally:
            PID_PATH.unlink(missing_ok=True)
            LOG.write("INFO", "guardian stopped")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--daemon", action="store_true")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--open-logs", action="store_true")
    args = parser.parse_args()
    if args.open_logs:
        subprocess.run(["/usr/bin/open", str(LOG_DIR)], check=False)
        return 0
    if args.once:
        return one_shot()
    if args.daemon:
        return daemon()
    parser.error("choose --daemon, --once, or --open-logs")
    return 64


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        # Avoid traceback output because HTTP libraries can embed sensitive URLs in it.
        LOG.write("ERROR", "fatal internal error")
        raise SystemExit(70)
