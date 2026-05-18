#!/usr/bin/env python3
import argparse
import base64
import contextlib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

TOKEN_URL = os.environ.get("CODEX_USAGE_TOKEN_URL", "https://auth.openai.com/oauth/token")
USAGE_URLS = [
    url.strip()
    for url in os.environ.get(
        "CODEX_USAGE_URLS",
        "https://chatgpt.com/backend-api/wham/usage;https://chatgpt.com/backend-api/codex/usage",
    ).split(";")
    if url.strip()
]
CLIENT_ID = os.environ.get("CODEX_USAGE_CLIENT_ID", "app_EMoamEEZ73f0CkXaXp7hrann")
AUTH_CANDIDATES = [
    Path.home() / ".hermes" / "auth.json",
    Path.home() / ".codex" / "auth.json",
]


def _app_data_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
    if base:
        root = Path(base)
    else:
        root = Path.home() / ".codex-usage-widget"
    path = root / "CodexUsageWidget"
    path.mkdir(parents=True, exist_ok=True)
    return path


_cache_override = os.environ.get("CODEX_USAGE_CACHE_PATH")
CACHE_PATH = Path(_cache_override) if _cache_override else (_app_data_dir() / "last_usage.json")


class UsageError(RuntimeError):
    def __init__(self, message: str, kind: str = "unknown"):
        super().__init__(message)
        self.kind = kind


def _b64url_decode(seg: str) -> bytes:
    seg += "=" * ((4 - len(seg) % 4) % 4)
    return base64.urlsafe_b64decode(seg.encode())


def _account_id_from_token(token: str | None) -> str | None:
    if not isinstance(token, str) or "." not in token:
        return None
    try:
        payload = json.loads(_b64url_decode(token.split(".")[1]))
        return (payload.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id")
    except Exception:
        return None


def _load_auth():
    # 新版 Hermes auth.json: credential_pool.openai-codex[0]
    hermes_auth = Path.home() / ".hermes" / "auth.json"
    if hermes_auth.exists():
        try:
            data = json.loads(hermes_auth.read_text(encoding="utf-8"))
            pool = (data.get("credential_pool") or {}).get("openai-codex") or []
            if isinstance(pool, list) and pool:
                cred = pool[0] if isinstance(pool[0], dict) else {}
                access = cred.get("access_token")
                refresh = cred.get("refresh_token")
                account_id = cred.get("account_id") or _account_id_from_token(access)
                if access and refresh:
                    return hermes_auth, data, cred, access, refresh, account_id
        except Exception:
            pass

    last_err = None
    for auth_path in AUTH_CANDIDATES:
        if not auth_path.exists():
            continue
        try:
            data = json.loads(auth_path.read_text(encoding="utf-8"))
            tokens = data.get("tokens") or {}
            access = tokens.get("access_token")
            refresh = tokens.get("refresh_token")
            id_token = tokens.get("id_token")
            account_id = tokens.get("account_id") or _account_id_from_token(id_token)
            if access and refresh:
                return auth_path, data, tokens, access, refresh, account_id
            last_err = f"{auth_path} 缺少 access_token 或 refresh_token"
        except Exception as e:
            last_err = f"{auth_path} 读取失败: {e}"

    if last_err:
        raise UsageError(last_err, "auth")
    raise UsageError("未找到 auth.json（已检查 ~/.hermes/auth.json 与 ~/.codex/auth.json）", "auth")


@contextlib.contextmanager
def _file_lock(lock_path: Path, timeout: float = 8.0):
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+b") as fh:
        start = time.monotonic()
        if os.name == "nt":
            import msvcrt

            while True:
                try:
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() - start > timeout:
                        raise UsageError(f"认证文件锁等待超时: {lock_path}", "auth")
                    time.sleep(0.1)
            try:
                yield
            finally:
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            while True:
                try:
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() - start > timeout:
                        raise UsageError(f"认证文件锁等待超时: {lock_path}", "auth")
                    time.sleep(0.1)
            try:
                yield
            finally:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def _atomic_json_write(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def _http_json(url: str, method: str = "GET", headers=None, body=None, timeout=20):
    req = Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urlopen(req, timeout=timeout) as r:
        raw = r.read().decode("utf-8", errors="replace")
        return r.getcode(), json.loads(raw)


def _refresh(refresh_token: str):
    payload = urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLIENT_ID,
    }).encode("utf-8")
    code, data = _http_json(
        TOKEN_URL,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
        body=payload,
        timeout=20,
    )
    if code != 200:
        raise UsageError(f"refresh失败: HTTP {code}", "auth")
    if not data.get("access_token"):
        raise UsageError("refresh成功但无access_token", "auth")
    return data


def _save_auth(auth_path: Path, full_auth: dict, old_tokens: dict, refreshed: dict):
    new_tokens = dict(old_tokens)
    new_tokens["access_token"] = refreshed.get("access_token", old_tokens.get("access_token"))
    if refreshed.get("refresh_token"):
        new_tokens["refresh_token"] = refreshed["refresh_token"]
    if refreshed.get("id_token"):
        new_tokens["id_token"] = refreshed["id_token"]

    with _file_lock(auth_path.with_suffix(auth_path.suffix + ".lock")):
        if auth_path.exists():
            backup_path = auth_path.with_suffix(auth_path.suffix + ".bak")
            shutil.copy2(auth_path, backup_path)

        if isinstance(full_auth.get("credential_pool"), dict):
            pool = full_auth["credential_pool"].get("openai-codex")
            if isinstance(pool, list) and pool:
                cred0 = pool[0]
                if isinstance(cred0, dict):
                    cred0["access_token"] = new_tokens.get("access_token")
                    if new_tokens.get("refresh_token"):
                        cred0["refresh_token"] = new_tokens.get("refresh_token")
                    full_auth["credential_pool"]["openai-codex"][0] = cred0
                    _atomic_json_write(auth_path, full_auth)
                    return cred0

        full_auth["tokens"] = new_tokens
        _atomic_json_write(auth_path, full_auth)
        return new_tokens


def _build_cloudflare_friendly_headers(access_token: str, account_id: str | None):
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Origin": "https://chatgpt.com",
        "Referer": "https://chatgpt.com/codex",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "Sec-Fetch-Site": "same-origin",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Dest": "empty",
    }
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id
    return headers


def _fetch_usage(access_token: str, account_id: str | None):
    headers = _build_cloudflare_friendly_headers(access_token, account_id)
    last_err = None
    for url in USAGE_URLS:
        try:
            code, data = _http_json(url, headers=headers, timeout=20)
            if code == 200:
                return data
            last_err = UsageError(f"usage失败: HTTP {code} ({url})", "api")
        except HTTPError:
            raise
        except Exception as e:
            last_err = e
    if last_err:
        raise last_err
    raise UsageError("usage失败: 未知错误", "api")


def _clamp_percent(value) -> int:
    try:
        return min(100, max(0, int(value or 0)))
    except (TypeError, ValueError):
        return 0


def _build_result(usage: dict):
    rl = usage.get("rate_limit") or {}
    p = rl.get("primary_window") or {}
    s = rl.get("secondary_window") or {}

    p_used = _clamp_percent(p.get("used_percent", 0))
    s_used = _clamp_percent(s.get("used_percent", 0))
    p_reset = max(0, int(p.get("reset_after_seconds", 0) or 0))
    s_reset = max(0, int(s.get("reset_after_seconds", 0) or 0))

    return {
        "ok": True,
        "from_cache": False,
        "error_kind": "",
        "ts": int(time.time()),
        "plan": usage.get("plan_type", "unknown"),
        "allowed": bool((rl.get("allowed") if isinstance(rl, dict) else False)),
        "limit_reached": bool((rl.get("limit_reached") if isinstance(rl, dict) else False)),
        "primary": {"used": p_used, "left": max(0, 100 - p_used), "reset_seconds": p_reset},
        "secondary": {"used": s_used, "left": max(0, 100 - s_used), "reset_seconds": s_reset},
    }


def _load_cache():
    if CACHE_PATH.exists():
        try:
            return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
        except Exception:
            return None
    return None


def _save_cache(result: dict):
    _atomic_json_write(CACHE_PATH, result)


def _error_kind(error: Exception) -> str:
    if isinstance(error, UsageError):
        return error.kind
    if isinstance(error, HTTPError):
        return "auth" if getattr(error, "code", None) in (401, 403) else "api"
    if isinstance(error, (URLError, TimeoutError)):
        return "network"
    if isinstance(error, json.JSONDecodeError):
        return "parse"
    if isinstance(error, OSError):
        return "filesystem"
    return "unknown"


def fetch_usage_result(refresh_on_401: bool = True):
    auth_path, auth, tokens, access, refresh, account_id = _load_auth()
    account_id = account_id or _account_id_from_token(access)

    try:
        usage = _fetch_usage(access, account_id)
    except HTTPError as e:
        if not refresh_on_401 or getattr(e, "code", None) != 401:
            raise
        refreshed = _refresh(refresh)
        tokens = _save_auth(auth_path, auth, tokens, refreshed)
        access = tokens.get("access_token")
        account_id = account_id or _account_id_from_token(access)
        usage = _fetch_usage(access, account_id)

    result = _build_result(usage)
    _save_cache(result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description="Fetch Codex usage and print JSON.")
    parser.add_argument("--no-refresh", action="store_true", help="Do not refresh auth tokens on HTTP 401.")
    args = parser.parse_args(argv)

    try:
        result = fetch_usage_result(refresh_on_401=not args.no_refresh)
        print(json.dumps(result, ensure_ascii=False))
    except (HTTPError, URLError, TimeoutError, UsageError, OSError, json.JSONDecodeError) as e:
        kind = _error_kind(e)
        cache = _load_cache()
        if cache:
            cache["ok"] = False
            cache["error"] = str(e)
            cache["error_kind"] = kind
            cache["from_cache"] = True
            print(json.dumps(cache, ensure_ascii=False))
            return 0
        print(json.dumps({"ok": False, "error": str(e), "error_kind": kind, "from_cache": False}, ensure_ascii=False))
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
