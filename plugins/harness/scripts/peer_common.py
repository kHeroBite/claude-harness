# peer host MCP 공통 모듈 — 경로·토큰·HTTP 클라이언트·JSON-RPC·원자 기록·프로세스 판정(표준 라이브러리만, Python 3.8 호환)
"""peer_hub.py(host)·peer_mcp.py(세션 클라이언트)·peer_takeover.py 가 함께 쓰는 공통 함수.

경로
  hub_home()      ${PEER_HUB_HOME:-$HOME/.claude/peer_hub}   host 상태(hub.json·tokens.json·state.json·blobs/)
  client_home()   ${PEER_CLIENT_HOME:-$HOME/.config/claude-peer}  클라이언트 env(0600)
  inbox_root()    peer_ssh_notify.sh home 판정 결과(ADR-034) — 실패 시 같은 규칙을 파이썬으로 재현
보안
  토큰 값은 어디에도 출력·기록하지 않는다. 로그는 redact() 를 거친다. 비교는 hmac.compare_digest.
"""
from __future__ import print_function

import errno
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time

try:  # Python 3 표준
    import urllib.request as _ureq
    import urllib.error as _uerr
except ImportError:  # pragma: no cover
    _ureq = None
    _uerr = None

# ── 상수 ────────────────────────────────────────────────────────────────
PROTO = 1
VERSION = "1.0.0"
TTL = 90                    # 세션 heartbeat 만료(초, host 시계 기준)
HEARTBEAT_SEC = 30
PORT_MIN = 47800
PORT_MAX = 47899
PORT_RANGE = (PORT_MIN, PORT_MAX)
BODY_MAX = 1 << 20          # JSON 본문 상한 1MiB
MSG_MAX = 4096              # 메시지 본문 상한(바이트)
TAG_MAX = 16                # 메시지 태그 상한(문자)
EVENT_RING = 1000
LONGPOLL_MAX = 30           # long-poll 최대 대기(초)
AUTH_FAIL_LIMIT = 20        # 분당 인증 실패 허용 횟수(초과 시 429)
AUTH_FAIL_WINDOW = 60
GRACE_DEFAULT = 600
JOIN_TTL_DEFAULT = 1800
BLOB_MAX_DEFAULT = 1 << 30  # 1GiB
MCP_PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
MCP_PROTOCOL_DEFAULT = "2025-06-18"

KEY_RE = re.compile(r"[A-Za-z0-9_-]{8,64}")
TOKEN_SHAPE_RE = re.compile(r"[A-Za-z0-9_-]{20,128}")
BLOB_ID_RE = re.compile(r"[0-9a-f]{32}")
NAME_RE = re.compile(r"[A-Za-z0-9가-힣._:#-]{0,64}")

# 종료·오류 코드(문자열 코드는 HTTP 응답 {"error": 코드} 와 클라이언트 반환값에 공통)
E_HOST_ABSENT = "HOST_ABSENT"          # hub 정보 없음(hub.json·env 모두 없음) — 조용한 폴백 대상
E_HOST_UNREACHABLE = "HOST_UNREACHABLE"  # 주소는 있으나 접속 실패
E_UNAUTHORIZED = "UNAUTHORIZED"


# ── 시간·문자열 ─────────────────────────────────────────────────────────
def now():
    return time.time()


def iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts if ts is not None else time.time()))


_REDACT_BEARER = re.compile(r"(?i)(bearer\s+)[^\s\"']+")
_REDACT_LONG = re.compile(r"[A-Za-z0-9_-]{32,}")


def redact(text):
    """로그용 마스킹 — Bearer 뒤 값과 32자 이상 토큰 모양 문자열을 가린다."""
    s = str(text)
    s = _REDACT_BEARER.sub(r"\1***", s)
    return _REDACT_LONG.sub("***", s)


def log(msg, stream=None):
    """stderr 로그(토큰 마스킹). stdio MCP 의 stdout 을 오염시키지 않는다."""
    try:
        (stream or sys.stderr).write("[peer %s] %s\n" % (time.strftime("%H:%M:%S"), redact(msg)))
        (stream or sys.stderr).flush()
    except Exception:
        pass


# ── 경로 ────────────────────────────────────────────────────────────────
def _home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def hub_home():
    return os.environ.get("PEER_HUB_HOME") or os.path.join(_home(), ".claude", "peer_hub")


def client_home():
    return os.environ.get("PEER_CLIENT_HOME") or os.path.join(_home(), ".config", "claude-peer")


def client_env_path():
    return os.path.join(client_home(), "env")


def scripts_dir():
    return os.path.dirname(os.path.abspath(__file__))


_CAS_TMP_RE = re.compile(r"/tmp/cc-[0-9a-fA-F-]{36}/?")


def _inbox_root_py():
    v = os.environ.get("PEER_NOTIFY_HOME")
    if v:
        return v
    c = os.environ.get("CLAUDE_CONFIG_DIR") or ""
    d = os.path.join(_home(), ".claude")
    if c and not _CAS_TMP_RE.fullmatch(c):
        if os.path.realpath(c) != os.path.realpath(d):
            return c.rstrip("/") or "/"
    return d


def inbox_root():
    """peer_ssh_notify.sh home 판정(ADR-034). 스크립트가 없거나 실패하면 같은 규칙을 파이썬으로 재현."""
    sh = os.path.join(scripts_dir(), "peer_ssh_notify.sh")
    if os.path.isfile(sh):
        try:
            r = subprocess.run(["bash", sh, "home"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=5, universal_newlines=True)
            out = (r.stdout or "").strip()
            if r.returncode == 0 and out.startswith("/"):
                return out
        except (OSError, subprocess.SubprocessError):
            pass
    return _inbox_root_py()


def inbox_path(project):
    return os.path.join(inbox_root(), "peer_inbox", "%s.jsonl" % str(project).lower())


# ── 파일 ────────────────────────────────────────────────────────────────
def ensure_dir(path, mode=0o700):
    try:
        os.makedirs(path, mode)
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise
    return path


def atomic_write(path, data, mode=None):
    """tmp → fsync → rename. data 는 str 또는 bytes. mode(예: 0o600)를 주면 rename 전에 적용."""
    d = os.path.dirname(os.path.abspath(path))
    ensure_dir(d)
    if isinstance(data, str):
        data = data.encode("utf-8")
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def atomic_write_json(path, obj, mode=None):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True) + "\n", mode)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


class FileLock(object):
    """flock 컨텍스트. blocking=False 면 획득 실패 시 acquired=False(예외 없음). timeout 초 동안 재시도 가능."""

    def __init__(self, path, blocking=True, timeout=None):
        self.path = path
        self.blocking = blocking
        self.timeout = timeout
        self.fd = None
        self.acquired = False

    def acquire(self):
        ensure_dir(os.path.dirname(os.path.abspath(self.path)))
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        if self.blocking and self.timeout is None:
            fcntl.flock(self.fd, fcntl.LOCK_EX)
            self.acquired = True
            return True
        end = time.time() + (self.timeout or 0)
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.acquired = True
                return True
            except (OSError, IOError):
                if not self.blocking or time.time() >= end:
                    return False
                time.sleep(0.05)

    def release(self):
        if self.fd is not None:
            try:
                if self.acquired:
                    fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None
                self.acquired = False

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *a):
        self.release()
        return False


def try_flock(path):
    """비차단 배타 잠금. 성공 시 열린 fd(프로세스가 살아 있는 동안 유지), 실패 시 None."""
    ensure_dir(os.path.dirname(os.path.abspath(path)))
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (OSError, IOError):
        os.close(fd)
        return None


# ── 토큰 ────────────────────────────────────────────────────────────────
def gen_token():
    return secrets.token_urlsafe(32)


def gen_hex(n=16):
    return secrets.token_hex(n)


def gen_session_key():
    return "s" + secrets.token_hex(12)


def token_eq(a, b):
    if not a or not b:
        return False
    return hmac.compare_digest(str(a).encode("utf-8"), str(b).encode("utf-8"))


def token_hash(tok):
    return hashlib.sha256(str(tok or "").encode("utf-8")).hexdigest()


def token_prefix(tok):
    """429 계수 키·로그용 식별자(sha256 앞 12자). 원문은 노출하지 않는다."""
    return token_hash(tok)[:12] if tok else "none"


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


# ── 머신·프로세스 ────────────────────────────────────────────────────────
def machine_id():
    """머신 식별자 sha256(machine-id 또는 hostname)[:16]. 원문은 노출하지 않는다. PEER_MACHINE_ID 로 덮어쓰기(시험)."""
    v = os.environ.get("PEER_MACHINE_ID")
    if v:
        return v
    raw = ""
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            with open(p) as f:
                raw = f.read().strip()
            if raw:
                break
        except OSError:
            pass
    if not raw:
        raw = socket.gethostname()
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def machine_label():
    """사람이 보는 머신 이름. PEER_MACHINE_LABEL 이 없으면 'm-<machine_id 앞 6자>'(호스트명 비노출)."""
    v = os.environ.get("PEER_MACHINE_LABEL", "").strip()
    if v and NAME_RE.fullmatch(v):
        return v
    return "m-" + machine_id()[:6]


def pid_start(pid):
    """/proc/<pid>/stat 22번째 필드(starttime). 없으면 None."""
    try:
        with open("/proc/%d/stat" % int(pid), encoding="utf-8", errors="replace") as f:
            s = f.read()
    except (OSError, ValueError, TypeError):
        return None
    rest = s[s.rfind(")") + 2:].split()
    try:
        return rest[19]
    except IndexError:
        return None


def pid_alive(pid, start=None):
    """pid 가 살아 있고(start 가 주어지면 starttime 까지 일치) 좀비가 아니면 True."""
    if not pid:
        return False
    try:
        with open("/proc/%d/stat" % int(pid), encoding="utf-8", errors="replace") as f:
            s = f.read()
    except (OSError, ValueError, TypeError):
        return False
    rest = s[s.rfind(")") + 2:].split()
    if not rest or rest[0] == "Z":
        return False
    if start is None:
        return True
    try:
        return str(rest[19]) == str(start)
    except IndexError:
        return False


def parse_owner(text):
    """'pid:start' → (pid:int, start:str) 또는 None."""
    if not text:
        return None
    m = re.fullmatch(r"(\d+):(\d+)", str(text).strip())
    if not m:
        return None
    return int(m.group(1)), m.group(2)


def is_loopback(host):
    h = (host or "").strip().strip("[]")
    if h in ("localhost", "::1"):
        return True
    return h.startswith("127.")


# ── hub 탐색·클라이언트 설정 ─────────────────────────────────────────────
def hub_json_path(home=None):
    return os.path.join(home or hub_home(), "hub.json")


def tokens_path(home=None):
    return os.path.join(home or hub_home(), "tokens.json")


def read_hub_json(home=None, check_alive=True):
    """hub.json 을 읽어 dict 반환. check_alive 면 pid+start 가 살아 있을 때만(아니면 None)."""
    d = read_json(hub_json_path(home), None)
    if not isinstance(d, dict) or not d.get("url"):
        return None
    if check_alive and not pid_alive(d.get("pid"), d.get("pid_start")):
        return None
    return d


def load_env_file(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                out[k.strip()] = v
    except OSError:
        pass
    return out


def write_client_env(url, token, path=None):
    """클라이언트 env(PEER_HUB_URL·PEER_TOKEN)를 0600 으로 원자 기록."""
    p = path or client_env_path()
    ensure_dir(os.path.dirname(p))
    atomic_write(p, "PEER_HUB_URL=%s\nPEER_TOKEN=%s\n" % (url, token), mode=0o600)
    return p


def discover_hub():
    """(url, token, source) 반환. 우선순위: 환경변수 → 클라이언트 env 파일 → 같은 머신 hub.json+tokens.json(admin).
    없으면 (None, None, None) — 호출자는 HOST_ABSENT 로 조용히 폴백한다."""
    url = os.environ.get("PEER_HUB_URL", "").strip()
    tok = os.environ.get("PEER_TOKEN", "").strip()
    if url and tok:
        return url.rstrip("/"), tok, "env"
    env = load_env_file(client_env_path())
    if env.get("PEER_HUB_URL") and env.get("PEER_TOKEN"):
        return env["PEER_HUB_URL"].rstrip("/"), env["PEER_TOKEN"], "client_env"
    hj = read_hub_json()
    if hj:
        tj = read_json(tokens_path(), {}) or {}
        if tj.get("admin"):
            return str(hj["url"]).rstrip("/"), tj["admin"], "local_hub"
    return None, None, None


# ── HTTP 클라이언트(urllib) ──────────────────────────────────────────────
class _NoRedirect(_ureq.HTTPRedirectHandler if _ureq else object):
    def redirect_request(self, *a, **k):  # 토큰이 다른 곳으로 새지 않게 리다이렉트 금지
        return None


def _opener():
    return _ureq.build_opener(_NoRedirect, _ureq.ProxyHandler({}))


def http_json(url, method="GET", body=None, token=None, timeout=10, headers=None):
    """JSON 요청. 반환 (status:int, obj:dict). 접속 실패는 (0, {"error": "HOST_UNREACHABLE"}).
    응답이 JSON 이 아니면 {"error": "BAD_RESPONSE", "raw": 앞 200자}."""
    data = None
    h = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = "Bearer " + token
    if headers:
        h.update(headers)
    req = _ureq.Request(url, data=data, method=method, headers=h)
    try:
        resp = _opener().open(req, timeout=timeout)
        status, raw = resp.status, resp.read()
    except _uerr.HTTPError as e:
        status, raw = e.code, e.read() if hasattr(e, "read") else b""
    except (_uerr.URLError, OSError, socket.timeout, ValueError):
        return 0, {"error": E_HOST_UNREACHABLE}
    if not raw:
        return status, {}
    try:
        obj = json.loads(raw.decode("utf-8"))
        if not isinstance(obj, dict):
            obj = {"value": obj}
        return status, obj
    except ValueError:
        return status, {"error": "BAD_RESPONSE", "raw": raw[:200].decode("utf-8", "replace")}


def http_put_file(url, path, token, timeout=120, sha=None):
    """파일을 PUT 으로 스트리밍 업로드(X-Sha256 헤더). 반환 (status, obj)."""
    size = os.path.getsize(path)
    sha = sha or sha256_file(path)
    f = open(path, "rb")
    try:
        req = _ureq.Request(url, data=f, method="PUT", headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/octet-stream",
            "Content-Length": str(size), "X-Sha256": sha, "Accept": "application/json"})
        try:
            resp = _opener().open(req, timeout=timeout)
            status, raw = resp.status, resp.read()
        except _uerr.HTTPError as e:
            status, raw = e.code, e.read()
        except (_uerr.URLError, OSError, socket.timeout):
            return 0, {"error": E_HOST_UNREACHABLE}
    finally:
        f.close()
    try:
        return status, json.loads(raw.decode("utf-8")) if raw else {}
    except ValueError:
        return status, {"error": "BAD_RESPONSE"}


def http_get_to_file(url, dest, token, timeout=120):
    """GET 응답 본문을 dest 에 원자 저장하고 X-Sha256 헤더와 대조. 반환 (status, sha 또는 오류코드)."""
    req = _ureq.Request(url, method="GET", headers={"Authorization": "Bearer " + token})
    try:
        resp = _opener().open(req, timeout=timeout)
    except _uerr.HTTPError as e:
        return e.code, "HTTP_%d" % e.code
    except (_uerr.URLError, OSError, socket.timeout):
        return 0, E_HOST_UNREACHABLE
    want = resp.headers.get("X-Sha256", "")
    d = os.path.dirname(os.path.abspath(dest))
    ensure_dir(d)
    fd, tmp = tempfile.mkstemp(prefix=".dl-", dir=d)
    h = hashlib.sha256()
    try:
        with os.fdopen(fd, "wb") as f:
            while True:
                b = resp.read(1 << 20)
                if not b:
                    break
                h.update(b)
                f.write(b)
        got = h.hexdigest()
        if want and not hmac.compare_digest(want, got):
            os.unlink(tmp)
            return 200, "SHA_MISMATCH"
        os.replace(tmp, dest)
        return resp.status, got
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ── JSON-RPC 2.0 / MCP 유틸 ─────────────────────────────────────────────
RPC_PARSE_ERROR = -32700
RPC_INVALID_REQUEST = -32600
RPC_METHOD_NOT_FOUND = -32601
RPC_INVALID_PARAMS = -32602
RPC_INTERNAL = -32603


def rpc_result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def rpc_error(rid, code, message, data=None):
    e = {"code": code, "message": message}
    if data is not None:
        e["data"] = data
    return {"jsonrpc": "2.0", "id": rid, "error": e}


def rpc_parse(line):
    """한 줄(또는 HTTP 본문)을 파싱. 반환 (msg 또는 None, 오류응답 또는 None)."""
    try:
        msg = json.loads(line)
    except (ValueError, TypeError):
        return None, rpc_error(None, RPC_PARSE_ERROR, "parse error")
    if not isinstance(msg, (dict, list)):
        return None, rpc_error(None, RPC_INVALID_REQUEST, "invalid request")
    return msg, None


def rpc_is_notification(msg):
    return isinstance(msg, dict) and "id" not in msg


def mcp_negotiate_version(requested):
    return requested if requested in MCP_PROTOCOL_VERSIONS else MCP_PROTOCOL_DEFAULT


def mcp_initialize_result(name, version=VERSION, requested=None, instructions=None):
    r = {"protocolVersion": mcp_negotiate_version(requested),
         "capabilities": {"tools": {"listChanged": False}},
         "serverInfo": {"name": name, "version": version}}
    if instructions:
        r["instructions"] = instructions
    return r


def mcp_tool(name, description, properties=None, required=None):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {}, "required": list(required or [])}}


def tool_text(obj, is_error=False):
    """tools/call 결과 형식. obj 가 str 이 아니면 JSON 텍스트로."""
    text = obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False)
    return {"content": [{"type": "text", "text": text}], "isError": bool(is_error)}


def write_jsonl(stream, obj):
    """stdio MCP 응답 1줄 기록(개행 없는 JSON + \\n)."""
    stream.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    stream.flush()


# ── inbox 기록(기존 UserPromptSubmit_peer_inbox.sh 가 읽는 형식) ─────────
def _clean_body(s):
    s = str(s or "")
    s = "".join(ch for ch in s if ch in "\n\t" or ord(ch) >= 32)
    b = s.encode("utf-8")[:MSG_MAX]
    return b.decode("utf-8", "ignore")


def inbox_append(project, tag, body, from_host, via="hub", ts=None):
    """inbox(<루트>/peer_inbox/<프로젝트>.jsonl)에 1건 추가. 배타 잠금 안에서 같은 줄 중복은 건너뛴다.
    반환 True=기록, False=중복 생략. 1줄 = {"ts","from_host","project","tag","body","via"}."""
    proj = str(project or "").lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", proj):
        raise ValueError("bad project")
    tag = str(tag or "")[:TAG_MAX]
    rec = {"ts": ts or iso(), "from_host": str(from_host or "unknown")[:64], "project": proj,
           "tag": tag, "body": _clean_body(body), "via": via}
    line = json.dumps(rec, ensure_ascii=False, separators=(",", ":"))
    path = inbox_path(proj)
    ensure_dir(os.path.dirname(path))
    with FileLock(path + ".lock"):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for old in f:
                    if old.rstrip("\n") == line:
                        return False
        except OSError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (line + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    return True
