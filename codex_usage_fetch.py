#!/usr/bin/env python3
import json
import time
import base64
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

TOKEN_URL = "https://auth.openai.com/oauth/token"
USAGE_URLS = [
    "https://chatgpt.com/backend-api/wham/usage",
    "https://chatgpt.com/backend-api/codex/usage",
]
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
AUTH_CANDIDATES = [
    Path.home() / ".hermes" / "auth.json",
    Path.home() / ".codex" / "auth.json",
]
CACHE_PATH = Path(__file__).resolve().parent / "last_usage.json"


def _b64url_decode(seg: str) -> bytes:
    seg += "=" * ((4 - len(seg) % 4) % 4)
    return base64.urlsafe_b64decode(seg.encode())


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
                account_id = cred.get("account_id")
                if (not account_id) and isinstance(access, str) and "." in access:
                    try:
                        payload = json.loads(_b64url_decode(access.split(".")[1]))
                        account_id = (payload.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id")
                    except Exception:
                        account_id = None
                if access and refresh:
                    return hermes_auth, data, cred, access, refresh, account_id
        except Exception:
            pass

    # 旧版 auth.json 兼容：tokens 结构
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
            account_id = tokens.get("account_id")
            if not account_id and isinstance(id_token, str) and "." in id_token:
                try:
                    payload = json.loads(_b64url_decode(id_token.split(".")[1]))
                    account_id = (payload.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id")
                except Exception:
                    account_id = None
            if access and refresh:
                return auth_path, data, tokens, access, refresh, account_id
            last_err = f"{auth_path} 缺少 access_token 或 refresh_token"
        except Exception as e:
            last_err = f"{auth_path} 读取失败: {e}"

    if last_err:
        raise RuntimeError(last_err)
    raise RuntimeError("未找到 auth.json（已检查 ~/.hermes/auth.json 与 ~/.codex/auth.json）")


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
        raise RuntimeError(f"refresh失败: HTTP {code}")
    if not data.get("access_token"):
        raise RuntimeError("refresh成功但无access_token")
    return data


def _save_auth(auth_path: Path, full_auth: dict, old_tokens: dict, refreshed: dict):
    new_tokens = dict(old_tokens)
    new_tokens["access_token"] = refreshed.get("access_token", old_tokens.get("access_token"))
    if refreshed.get("refresh_token"):
        new_tokens["refresh_token"] = refreshed["refresh_token"]
    if refreshed.get("id_token"):
        new_tokens["id_token"] = refreshed["id_token"]

    # 新版 Hermes credential_pool 结构
    if isinstance(full_auth.get("credential_pool"), dict):
        pool = full_auth["credential_pool"].get("openai-codex")
        if isinstance(pool, list) and pool:
            cred0 = pool[0]
            if isinstance(cred0, dict):
                cred0["access_token"] = new_tokens.get("access_token")
                if new_tokens.get("refresh_token"):
                    cred0["refresh_token"] = new_tokens.get("refresh_token")
                full_auth["credential_pool"]["openai-codex"][0] = cred0
                auth_path.write_text(json.dumps(full_auth, ensure_ascii=False, indent=2), encoding="utf-8")
                return cred0

    # 旧版 tokens 结构
    full_auth["tokens"] = new_tokens
    auth_path.write_text(json.dumps(full_auth, ensure_ascii=False, indent=2), encoding="utf-8")
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
            last_err = RuntimeError(f"usage失败: HTTP {code} ({url})")
        except Exception as e:
            last_err = e
    if last_err:
        raise last_err
    raise RuntimeError("usage失败: 未知错误")


def _build_result(usage: dict):
    rl = usage.get("rate_limit") or {}
    p = rl.get("primary_window") or {}
    s = rl.get("secondary_window") or {}

    p_used = int(p.get("used_percent", 0) or 0)
    s_used = int(s.get("used_percent", 0) or 0)
    p_left = max(0, 100 - p_used)
    s_left = max(0, 100 - s_used)
    p_reset = int(p.get("reset_after_seconds", 0) or 0)
    s_reset = int(s.get("reset_after_seconds", 0) or 0)

    return {
        "ok": True,
        "from_cache": False,
        "ts": int(time.time()),
        "plan": usage.get("plan_type", "unknown"),
        "allowed": bool((rl.get("allowed") if isinstance(rl, dict) else False)),
        "limit_reached": bool((rl.get("limit_reached") if isinstance(rl, dict) else False)),
        "primary": {"used": p_used, "left": p_left, "reset_seconds": p_reset},
        "secondary": {"used": s_used, "left": s_left, "reset_seconds": s_reset},
    }


def _load_cache():
    if CACHE_PATH.exists():
        try:
            return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
        except Exception:
            return None
    return None


def main():
    try:
        auth_path, auth, tokens, access, refresh, account_id = _load_auth()
        if (not account_id) and isinstance(access, str) and "." in access:
            try:
                payload = json.loads(_b64url_decode(access.split(".")[1]))
                account_id = (payload.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id")
            except Exception:
                account_id = None

        # 先用现有 access_token（实测更稳定）；401 再 refresh 重试
        try:
            usage = _fetch_usage(access, account_id)
        except HTTPError as e:
            if getattr(e, "code", None) != 401:
                raise
            refreshed = _refresh(refresh)
            tokens = _save_auth(auth_path, auth, tokens, refreshed)
            access = tokens.get("access_token")
            if (not account_id) and isinstance(access, str) and "." in access:
                try:
                    payload = json.loads(_b64url_decode(access.split(".")[1]))
                    account_id = (payload.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id")
                except Exception:
                    account_id = None
            usage = _fetch_usage(access, account_id)

        result = _build_result(usage)
        CACHE_PATH.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False))
    except (HTTPError, URLError, TimeoutError, RuntimeError, OSError, json.JSONDecodeError) as e:
        cache = _load_cache()
        if cache:
            cache["ok"] = False
            cache["error"] = str(e)
            cache["from_cache"] = True
            print(json.dumps(cache, ensure_ascii=False))
            return
        print(json.dumps({"ok": False, "error": str(e), "from_cache": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
