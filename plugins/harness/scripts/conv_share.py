#!/usr/bin/env python3
# 다른 머신과 Claude 대화 기록(transcript)을 마스킹한 사본으로 주고받아 재개 목록에 넣는 도구
"""conv_share — 머신 간 대화 공유.

사용법:
  conv_share.py export --sid <S> [--cwd <작업폴더>] [--project <이름>] [--role <값>]
  conv_share.py send   --sid <S> (<ssh별칭> | --outbox) [--project <이름>]
  conv_share.py push   --sid <S> (<ssh별칭> | --outbox) [--cwd ..] [--project ..] [--role ..]   export 후 send
                       [--place [--peer-cwd <상대 작업폴더>]]   ssh 일 때 상대 쪽 재개 위치까지 배치(recv-import)
  conv_share.py pull   <ssh별칭> --project <이름> [--timeout 10]     상대 outbox 를 가져와 수신함에 넣기
  conv_share.py import --project <이름> --cwd <작업폴더>              수신함 항목을 로컬 재개 위치에 넣기
  conv_share.py is-imported --sid <S> --project <이름>                가져온 대화면 rc 0(재개 때 --fork-session)
  conv_share.py recv <프로젝트>                                       (내부) 원격 수신부, stdin = 묶음
  conv_share.py recv-import <프로젝트> [<작업폴더>]                   (내부) recv 후 그 머신에서 import(상대 세션 불필요)
  conv_share.py outbox-take <프로젝트> | outbox-ack <프로젝트> <sid:sha>...   (내부) pull 이 쓰는 원격 부분

위치(머신당 한 곳 — peer_ssh_notify.sh 와 같은 루트 판정, 정본은 그 스크립트의 home 하위명령):
  루트      ① PEER_NOTIFY_HOME ② CLAUDE_CONFIG_DIR(cas 임시 폴더 /tmp/cc-<uuid> 가 아니고 $HOME/.claude 와 실경로가 다를 때)
            ③ $HOME/.claude  — cas 세션·평범한 실행은 머신 공용 $HOME/.claude, 시험·격리 실행만 그 폴더
  준비본    <루트>/conv_stage/<sid>.jsonl.gz · <sid>.meta.json
  수신함    <루트>/conv_inbox/<프로젝트 소문자>/<sid>.jsonl.gz · .meta.json · .imported · .conflict
  송신함    <루트>/conv_outbox/<프로젝트 소문자>/  (역방향 ssh 가 없을 때)
  로그      <루트>/logs/conv_share.log  (경로·sid·건수만, 본문 미기록)
  재개 위치 ${ROLE_HOME_BASE:-$HOME/.claude}/projects/<enc(cwd)>/<sid>.jsonl  (enc = 영숫자 외 '-')

E0 실측(docs/prd/conv-share-e0-2026-11-06.md)으로 정한 규칙:
  - 수신 측 작업폴더의 enc 폴더에 넣어야 재개된다. 다른 프로젝트 폴더에 두면 찾지 못한다.
  - 최상위 cwd 가 원본 cwd 이거나 그 하위인 줄만 수신 측 cwd 로 바꾼다(원본이 /mnt/<드라이브>/ 아래면 대소문자 무시).
    동반 파일은 보내지 않는다.
  - 수신 머신은 --fork-session 으로 재개한다. 원본 sid 파일은 그대로라 다음 수신의 접두 판정이 유지된다.

보안: 가져온 기록은 데이터로만 저장한다(실행·source 금지). 원격 명령은 고정 리터럴 + 검증된 토큰만 쓴다.
크기 상한(기본 1GB, CONV_SHARE_MAX_BYTES): export 는 상한을 넘는 대화를 거부하지 않고 최신 쪽 연속 줄만 상한만큼 보낸다.
  출력 둘째 줄 `TRUNCATED orig_bytes=.. sent_bytes=.. dropped_lines=..`, meta.truncated=true, rc 0.
  수신 import 는 잘린 판의 앞부분이 로컬 기록 꼬리와 겹치면 새 판으로 교체한다(kind replace).
종료 코드: 0 성공 · 1 실행 실패 · 2 사용법·검증 실패 · 3 원격(ssh) 실패 · 4 일부 거부(conflict·sha 불일치)
          · 5 크기 상한 초과(수신 묶음·해제 크기, 또는 export 에서 최신 줄 하나가 상한보다 클 때)
"""

import argparse
import array
import datetime
import fcntl
import gzip
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

MAX_BYTES = int(os.environ.get("CONV_SHARE_MAX_BYTES", str(1024 * 1024 * 1024)))
SID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# TOK_RE·HARNESS_RE 는 fullmatch 로만 쓴다. re.match + '$' 는 끝 개행 1개를 통과시켜 ssh 원격 명령에 줄바꿈이 섞일 수 있다(TODO-054).
TOK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
HARNESS_RE = re.compile(r"^/[A-Za-z0-9._/-]{1,255}$")
ROLE_RE = re.compile(r"^[^\s\t\n]{0,80}$")
MAGIC = b"CSV1"

# 원격에서 수신부를 찾아 실행하는 고정 리터럴(peer_ssh_notify.sh REMOTE_LAUNCH 와 같은 방식). 검증된 토큰만 뒤에 붙는다.
REMOTE_LAUNCH = ('h=$1; shift; if [ "$h" != - ]; then s=$h/current/scripts/conv_share.py; '
                 'else s=$(command -v conv_share.py 2>/dev/null) || s=${HARNESS_HOME:-$HOME/.harness}/current/scripts/conv_share.py; '
                 'fi; exec python3 -B "$s" "$@"')

# 마스킹하지 않는 구조 필드. 재개 때 Claude Code 가 쓰는 값이다.
STRUCT_KEYS = {"cwd", "sessionId", "parentUuid", "uuid", "type", "timestamp", "requestId", "id", "tool_use_id",
               "leafUuid", "logicalParentUuid", "version", "gitBranch", "userType", "isSidechain", "role",
               "model", "stop_reason", "media_type", "signature", "name", "agentId", "slug"}

MASKS = [
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
     "[masked:private-key]"),
    ("anthropic_key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{10,}"), "[masked:api-key]"),
    ("bearer", re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=\-]{16,}"), r"\1 [masked]"),
    ("assign", re.compile(r"(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)"
                          r"(\"?\s*[:=]\s*)([\"']?)[^\s\"',;]{4,}"), r"\1\2\3[masked]"),
    ("email", re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"), "[email]"),
    ("hex", re.compile(r"\b[0-9a-fA-F]{48,}\b"), "[masked:hex]"),
    ("b64", re.compile(r"(?<![A-Za-z0-9+/])(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])"
                       r"[A-Za-z0-9+/]{80,}={0,2}"), "[masked:b64]"),
]


class Fail(Exception):
    def __init__(self, msg, rc=1):
        super().__init__(msg)
        self.rc = rc


# ---------------------------------------------------------------- 경로·공통

_CAS_CFG_RE = re.compile(r"/tmp/cc-[0-9a-fA-F-]{36}/?")
_ROOT_CACHE = {}


def _root_fallback():
    # peer_ssh_notify.sh cfg_dir 와 같은 규칙(스크립트를 못 찾을 때만 쓴다 — 두 곳을 같게 유지한다)
    c, d = os.environ.get("CLAUDE_CONFIG_DIR", ""), os.path.join(os.path.expanduser("~"), ".claude")
    if c and not _CAS_CFG_RE.fullmatch(c) and os.path.realpath(c) != os.path.realpath(d):
        return c if c == "/" else c.rstrip("/")
    return d


def root():
    # peer 루트 판정(TODO-052): ① PEER_NOTIFY_HOME ② cas 임시 폴더가 아니고 $HOME/.claude 와 다른 CLAUDE_CONFIG_DIR
    # ③ $HOME/.claude. 판정 정본은 같은 폴더의 peer_ssh_notify.sh home 이다(inbox·대화 공유 루트를 한 판정으로 맞춘다).
    pn = os.environ.get("PEER_NOTIFY_HOME", "").strip()
    if pn:
        return pn
    key = (os.environ.get("CLAUDE_CONFIG_DIR", ""), os.path.expanduser("~"))
    if key not in _ROOT_CACHE:
        got = ""
        psn = os.path.join(os.path.dirname(os.path.abspath(__file__)), "peer_ssh_notify.sh")
        if os.path.isfile(psn):
            try:
                p = subprocess.run(["bash", psn, "home"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, timeout=10)
                out = p.stdout.decode("utf-8", "replace").strip()
                if p.returncode == 0 and out and "\n" not in out:
                    got = out
            except (OSError, subprocess.TimeoutExpired):
                got = ""
        _ROOT_CACHE[key] = got or _root_fallback()  # 구판 스크립트(home 없음 rc=2)·부재 시 같은 규칙의 대체 판정
    return _ROOT_CACHE[key]


def home_base():
    return os.environ.get("ROLE_HOME_BASE", "").strip() or os.path.join(os.path.expanduser("~"), ".claude")


def enc(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def proj_key(project):
    if not TOK_RE.fullmatch(project or ""):
        raise Fail("프로젝트 형식이 올바르지 않다: 영문·숫자·._- 1~64자", 2)
    return project.lower()


def need_sid(sid):
    if not SID_RE.fullmatch(sid or ""):
        raise Fail("sid 는 UUID 형식이어야 한다", 2)
    return sid


def box(kind, project):
    return os.path.join(root(), kind, proj_key(project))


def stage_dir():
    return os.path.join(root(), "conv_stage")


def self_host():
    h = socket.gethostname().split(".")[0]
    return h if TOK_RE.fullmatch(h) else "unknown"


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg):
    try:
        d = os.path.join(root(), "logs")
        os.makedirs(d, mode=0o700, exist_ok=True)
        with open(os.path.join(d, "conv_share.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (now_iso(), msg))
    except OSError:
        pass


def mkdir700(d):
    os.makedirs(d, mode=0o700, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass


def atomic_write(path, data):
    """임시파일에 쓴 뒤 rename 한다. 권한 600. 중간에 끊기면 임시파일을 지운다."""
    d = os.path.dirname(path)
    mkdir700(d)
    fd, tmp = tempfile.mkstemp(prefix=".cs-", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def role_lib():
    """role_lib 을 선택적으로 불러온다(소스 .claude/hooks/lib, 배포본 hooks/lib, 홈 순). 없으면 None."""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [os.environ.get("CONV_SHARE_ROLE_LIB", ""), os.path.join(here, "..", "hooks", "lib"),
             os.path.join(os.path.expanduser("~"), ".claude", "hooks", "lib")]
    for d in cands:
        if d and os.path.isfile(os.path.join(d, "role_lib.py")):
            if d not in sys.path:
                sys.path.insert(0, d)
            try:
                import role_lib as rl  # noqa: E402
                return rl
            except Exception:  # role_lib 오류는 공유를 막지 않는다
                return None
    return None


# ---------------------------------------------------------------- 마스킹

def mask_str(s, counts):
    for name, rx, rep in MASKS:
        s, n = rx.subn(rep, s)
        if n:
            counts[name] = counts.get(name, 0) + n
    return s


def mask_obj(o, counts, key=None):
    """json 값 안의 문자열만 바꾼다. 구조 필드·서명된 thinking 블록·base64 이미지 본문은 건드리지 않는다."""
    if isinstance(o, str):
        return o if key in STRUCT_KEYS else mask_str(o, counts)
    if isinstance(o, list):
        return [mask_obj(v, counts, None) for v in o]
    if isinstance(o, dict):
        if o.get("type") in ("thinking", "redacted_thinking"):
            return o  # 서명 검증 대상이라 바꾸면 재개가 깨진다(한계: thinking 본문은 마스킹하지 않음)
        if o.get("type") == "base64" and "data" in o:
            return o
        return {k: mask_obj(v, counts, k) for k, v in o.items()}
    return o


# ---------------------------------------------------------------- export

def find_transcript(sid, cwd):
    pdir = os.path.join(home_base(), "projects")
    if cwd:
        p = os.path.join(pdir, enc(cwd), sid + ".jsonl")
        if os.path.isfile(p):
            return p
    try:
        for d in sorted(os.listdir(pdir)):
            p = os.path.join(pdir, d, sid + ".jsonl")
            if os.path.isfile(p):
                return p
    except OSError:
        pass
    return ""


def first_cwd(lines):
    for o in lines:
        if isinstance(o, dict) and isinstance(o.get("cwd"), str) and o["cwd"]:
            return o["cwd"]
    return ""


def do_export(sid, cwd, project, role):
    need_sid(sid)
    src = find_transcript(sid, cwd)
    if not src:
        raise Fail("transcript 를 찾지 못했다: sid=%s" % sid, 1)
    size = os.path.getsize(src)
    sd = stage_dir()
    mkdir700(sd)
    counts, lens, dropped = {}, array.array("q"), 0
    # 원본 전체를 메모리에 올리지 않는다. 상한을 넘으면 최신 쪽 MAX_BYTES 만 줄 단위로 마스킹해 임시 파일에 쓰고,
    # 메모리에는 줄 길이만 둔다.
    tmp = tempfile.TemporaryFile(prefix=".cs-", dir=sd)
    try:
        with open(src, "rb") as f:
            start = max(0, size - MAX_BYTES)
            if start > 0:
                left = start - 1
                while left > 0:  # 시작점 앞 영역의 줄 수(1MB 조각)
                    chunk = f.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    dropped += chunk.count(b"\n")
                    left -= len(chunk)
                f.seek(start - 1)
                if f.read(1) == b"\n":
                    dropped += 1  # 시작점이 줄 머리다
                else:
                    f.readline()  # 시작점에 걸친 줄은 끝까지 버린다(줄 중간에서 시작하지 않음)
                    dropped += 1
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    ln = json.dumps(mask_obj(json.loads(raw.decode("utf-8")), counts), ensure_ascii=False,
                                    separators=(",", ":"))
                    json.loads(ln)  # 재검증
                except (ValueError, UnicodeDecodeError):
                    counts["dropped_line"] = counts.get("dropped_line", 0) + 1
                    continue
                b = (ln + "\n").encode("utf-8")
                tmp.write(b)
                lens.append(len(b))
        # 마스킹으로 늘어 상한을 넘으면 오래된 줄부터 더 버린다(연속 꼬리만 보낸다. 중간 줄 건너뛰기 없음).
        total, skip = sum(lens), 0
        while total > MAX_BYTES and skip < len(lens):
            total -= lens[skip]
            skip += 1
        truncated = start > 0 or skip > 0
        kept = len(lens) - skip
        if truncated and kept == 0:
            log("export fail sid=%s size=%d max=%d reason=last-line-too-big" % (sid, size, MAX_BYTES))
            raise Fail("최신 줄 하나가 상한보다 크다 — 보낼 줄이 없다(%d 바이트 상한, CONV_SHARE_MAX_BYTES 로 조정)"
                       % MAX_BYTES, 5)
        dropped += skip
        off = sum(lens[:skip])
        src_cwd = ""
        tmp.seek(off)
        for ln in tmp:  # 남은 첫 cwd 줄만 찾고 멈춘다
            try:
                o = json.loads(ln.decode("utf-8"))
            except ValueError:
                continue
            src_cwd = first_cwd([o])
            if src_cwd:
                break
        src_cwd = src_cwd or (cwd or "")
        rl = role_lib()
        if not project:
            project = rl.project_slug(None, src_cwd) if (rl and src_cwd) else os.path.basename(src_cwd.rstrip("/")) or "root"
        proj_key(project)
        if role is None:
            role = ""
            if rl:
                try:
                    role = rl.current_role(sid) or ""
                except Exception:
                    role = ""
        # 본문 산출: 임시 파일 꼬리를 sha256·gzip 에 함께 흘린다. 같은 폴더 임시 파일 → rename.
        h = hashlib.sha256()
        gz_path = os.path.join(sd, sid + ".jsonl.gz")
        fd, gtmp = tempfile.mkstemp(prefix=".cs-", dir=sd)
        try:
            with os.fdopen(fd, "wb") as gf:
                with gzip.GzipFile(fileobj=gf, mode="wb", mtime=0) as g:
                    tmp.seek(off)
                    while True:
                        chunk = tmp.read(1 << 20)
                        if not chunk:
                            break
                        h.update(chunk)
                        g.write(chunk)
                gf.flush()
                os.fsync(gf.fileno())
            os.chmod(gtmp, 0o600)
            os.replace(gtmp, gz_path)
        except BaseException:
            try:
                os.unlink(gtmp)
            except OSError:
                pass
            raise
    finally:
        tmp.close()
    meta = {"v": 1, "sid": sid, "project": project.lower(), "role": role, "host": self_host(), "cwd": src_cwd,
            "lines": kept, "bytes": total, "sha256": h.hexdigest(),
            "created": now_iso(), "masked": counts, "truncated": truncated, "orig_bytes": size,
            "dropped_lines": dropped}
    atomic_write(os.path.join(sd, sid + ".meta.json"), json.dumps(meta, ensure_ascii=False).encode("utf-8"))
    total_masked = sum(v for k, v in counts.items() if k != "dropped_line")
    print("EXPORT sid=%s lines=%d bytes=%d masked=%d %s" % (sid, meta["lines"], meta["bytes"], total_masked,
                                                            json.dumps(counts, ensure_ascii=False)))
    if truncated:
        print("TRUNCATED orig_bytes=%d sent_bytes=%d dropped_lines=%d" % (size, total, dropped))
        log("export truncate sid=%s orig=%d kept=%d dropped=%d" % (sid, size, total, dropped))
    log("export sid=%s project=%s lines=%d bytes=%d masked=%d" % (sid, meta["project"], meta["lines"],
                                                                    meta["bytes"], total_masked))
    return meta


# ---------------------------------------------------------------- 묶음(envelope)

def pack(meta, gz):
    m = json.dumps(meta, ensure_ascii=False).encode("utf-8")
    return MAGIC + b" %d %d\n" % (len(m), len(gz)) + m + gz


def unpack_stream(data):
    """CSV1 <meta길이> <gz길이>\\n<meta><gz> 의 반복. 형식이 깨지면 그 지점에서 멈춘다."""
    items, pos = [], 0
    while pos < len(data):
        nl = data.find(b"\n", pos, pos + 64)
        if nl < 0:
            raise Fail("묶음 머리가 깨졌다", 2)
        head = data[pos:nl].split()
        if len(head) != 3 or head[0] != MAGIC or not head[1].isdigit() or not head[2].isdigit():
            raise Fail("묶음 머리가 깨졌다", 2)
        ml, gl = int(head[1]), int(head[2])
        if ml > 65536 or gl > MAX_BYTES:
            raise Fail("묶음 크기 상한 초과", 5)
        s = nl + 1
        if s + ml + gl > len(data):
            raise Fail("묶음이 중간에 끊겼다", 2)
        items.append((data[s:s + ml], data[s + ml:s + ml + gl]))
        pos = s + ml + gl
    return items


def verify_item(mraw, gz, project):
    """meta·본문을 검증해 (meta, body) 를 돌려준다. 실패 시 Fail."""
    try:
        meta = json.loads(mraw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise Fail("meta 가 json 이 아니다", 2)
    if not isinstance(meta, dict):
        raise Fail("meta 형식 오류", 2)
    need_sid(meta.get("sid", ""))
    if str(meta.get("project", "")).lower() != proj_key(project):
        raise Fail("프로젝트 불일치", 2)
    if not TOK_RE.fullmatch(str(meta.get("host", ""))):
        raise Fail("호스트 형식 오류", 2)
    if not ROLE_RE.fullmatch(str(meta.get("role", ""))):
        raise Fail("롤 형식 오류", 2)
    if not isinstance(meta.get("cwd", ""), str) or not str(meta.get("cwd", "")).startswith("/"):
        raise Fail("원본 cwd 형식 오류", 2)
    try:
        with gzip.GzipFile(fileobj=__import__("io").BytesIO(gz)) as g:
            body = g.read(MAX_BYTES + 1)
    except (OSError, EOFError):
        raise Fail("gzip 해제 실패", 2)
    if len(body) > MAX_BYTES:
        raise Fail("해제 크기 상한 초과", 5)
    if hashlib.sha256(body).hexdigest() != meta.get("sha256"):
        raise Fail("sha256 불일치", 4)
    for ln in body.splitlines():
        if ln.strip():
            try:
                json.loads(ln.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise Fail("본문 줄이 json 이 아니다", 2)
    return meta, body


def store(kind, project, meta, gz):
    d = box(kind, project)
    sid = meta["sid"]
    with open_lock(d):
        atomic_write(os.path.join(d, sid + ".jsonl.gz"), gz)
        atomic_write(os.path.join(d, sid + ".meta.json"), json.dumps(meta, ensure_ascii=False).encode("utf-8"))


class open_lock:
    def __init__(self, d):
        self.d = d

    def __enter__(self):
        mkdir700(self.d)
        self.f = open(os.path.join(self.d, ".lock"), "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        try:
            fcntl.flock(self.f, fcntl.LOCK_UN)
        finally:
            self.f.close()


def ingest(data, project):
    """묶음 스트림을 검증해 수신함에 넣는다. (받은 [(sid, sha)], 거부 건수)."""
    got, bad = [], 0
    for mraw, gz in unpack_stream(data):
        try:
            meta, _body = verify_item(mraw, gz, project)
        except Fail as e:
            bad += 1
            log("recv reject project=%s reason=%s" % (project, e))
            continue
        store("conv_inbox", project, meta, gz)
        got.append((meta["sid"], meta["sha256"]))
        log("recv sid=%s project=%s from=%s lines=%s" % (meta["sid"], project, meta.get("host"), meta.get("lines")))
    return got, bad


# ---------------------------------------------------------------- send / recv / outbox / pull

def ssh_base(alias, timeout):
    if not TOK_RE.fullmatch(alias or ""):
        raise Fail("ssh 별칭 형식이 올바르지 않다", 2)
    if subprocess.run(["ssh", "-G", "--", alias], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise Fail("ssh -G 로 해석되지 않는 별칭이다: %s" % alias, 2)
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % timeout, "--", alias]


def remote_harness():
    h = os.environ.get("CONV_SHARE_REMOTE_HARNESS", "") or os.environ.get("PEER_NOTIFY_REMOTE_HARNESS", "")
    if not h:
        return "-"
    if not HARNESS_RE.fullmatch(h):
        raise Fail("원격 HARNESS 경로 형식 오류", 2)
    return h


def ssh_call(alias, args, stdin=b"", timeout=5, total=60):
    for a in args:
        if not TOK_RE.fullmatch(a) and not re.fullmatch(r"[0-9a-f-]{36}:[0-9a-f]{64}", a) and not HARNESS_RE.fullmatch(a):
            raise Fail("원격 인자 검증 실패", 2)
    cmd = ssh_base(alias, timeout) + ["bash -c '%s' _ %s %s" % (REMOTE_LAUNCH, remote_harness(), " ".join(args))]
    try:
        p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=total)
    except subprocess.TimeoutExpired:
        raise Fail("ssh 시간 초과(%ds)" % total, 3)
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        raise Fail("ssh 실패 rc=%d %s" % (p.returncode, err[-1] if err else ""), 3 if p.returncode == 255 else 1)
    return p.stdout


def staged(sid):
    sd = stage_dir()
    meta = read_json(os.path.join(sd, sid + ".meta.json"))
    try:
        with open(os.path.join(sd, sid + ".jsonl.gz"), "rb") as f:
            gz = f.read()
    except OSError:
        gz = None
    if not meta or gz is None:
        raise Fail("준비본이 없다 — 먼저 export 하라: sid=%s" % sid, 1)
    return meta, gz


def do_send(sid, target, project=None, place=False, peer_cwd=""):
    need_sid(sid)
    meta, gz = staged(sid)
    project = project or meta["project"]
    if target == "--outbox":
        verify_item(json.dumps(meta).encode("utf-8"), gz, project)
        store("conv_outbox", project, meta, gz)
        print("SENT outbox sid=%s" % sid)
        log("send outbox sid=%s project=%s" % (sid, proj_key(project)))
        return
    if peer_cwd and not HARNESS_RE.fullmatch(peer_cwd):
        raise Fail("--peer-cwd 형식 오류(절대경로, 영문·숫자·._/- 만)", 2)
    if place:
        # 상대 머신에 세션이 없어도 재개 목록에 보이도록 수신 직후 상대 쪽에서 import 까지 한다.
        # 상대 배포본이 구판이라 recv-import 를 모르면(rc≠0, ssh 단절 제외) 수신함 저장(recv)으로 물러난다.
        args = ["recv-import", proj_key(project)] + ([peer_cwd] if peer_cwd else [])
        try:
            out = ssh_call(target, args, stdin=pack(meta, gz), timeout=5, total=120)
            print("SENT %s sid=%s %s" % (target, sid, out.decode("utf-8", "replace").strip()))
            log("send ssh=%s sid=%s project=%s place=1" % (target, sid, proj_key(project)))
            return
        except Fail as e:
            if e.rc == 3:
                raise
            print("PLACE fallback reason=remote-old")
            log("send place fallback ssh=%s sid=%s err=%s" % (target, sid, e))
    out = ssh_call(target, ["recv", proj_key(project)], stdin=pack(meta, gz), timeout=5, total=120)
    print("SENT %s sid=%s %s" % (target, sid, out.decode("utf-8", "replace").strip()))
    log("send ssh=%s sid=%s project=%s" % (target, sid, proj_key(project)))


def cmd_recv(a):
    data = sys.stdin.buffer.read(MAX_BYTES * 2 + 1)
    got, bad = ingest(data, a.project)
    print("RECV %d rejected %d" % (len(got), bad))
    return 4 if bad else 0


def local_project_dir(project):
    """수신 머신에서 프로젝트 이름 → 작업폴더(role_lib project-dir 과 같은 규칙, 출력 없음). 없거나 모호하면 ''."""
    rl = role_lib()
    if not rl or not hasattr(rl, "project_roots"):
        return ""
    low = project.lower()
    for r in rl.project_roots():
        try:
            ents = sorted(os.listdir(r))
        except OSError:
            continue
        if project in ents and os.path.isdir(os.path.join(r, project)):
            return os.path.join(r, project)
        hits = [e for e in ents if e.lower() == low and os.path.isdir(os.path.join(r, e))]
        if len(hits) == 1:
            return os.path.join(r, hits[0])
        if len(hits) > 1:
            return ""
    return ""


def cmd_recv_import(a):
    """(내부) 원격 수신부 + 재개 위치 배치. 상대 머신에 세션이 없어도 다음 cc·ccc·claude --resume 에 보이게 한다.

    배치하지 못해도 수신함 저장은 성공으로 본다(rc 0, PLACE none). 나중에 ccc 가 import 한다.
    재개 위치(<홈>/projects)가 아직 없으면 만들지 않는다(그 머신에서 Claude 를 한 번도 실행하지 않은 상태).
    """
    data = sys.stdin.buffer.read(MAX_BYTES * 2 + 1)
    got, bad = ingest(data, a.project)
    print("RECV %d rejected %d" % (len(got), bad))
    if not got:
        return 4 if bad else 0
    cwd = a.cwd or local_project_dir(a.project)
    if not cwd or not cwd.startswith("/") or not os.path.isdir(cwd):
        print("PLACE none reason=no-cwd project=%s" % proj_key(a.project))
        log("recv-import no-cwd project=%s" % proj_key(a.project))
        return 4 if bad else 0
    if not os.path.isdir(os.path.join(home_base(), "projects")):
        print("PLACE none reason=no-home home=%s" % home_base())
        log("recv-import no-home project=%s" % proj_key(a.project))
        return 4 if bad else 0
    rc = cmd_import(argparse.Namespace(project=a.project, cwd=cwd))
    print("PLACE ok cwd=%s dir=%s" % (cwd, os.path.join(home_base(), "projects", enc(os.path.abspath(cwd)))))
    log("recv-import place project=%s rc=%d" % (proj_key(a.project), rc))
    return 4 if (bad or rc) else 0


def cmd_outbox_take(a):
    d = box("conv_outbox", a.project)
    if not os.path.isdir(d):
        return 0
    with open_lock(d):
        for n in sorted(os.listdir(d)):
            if not n.endswith(".meta.json"):
                continue
            sid = n[:-len(".meta.json")]
            if not SID_RE.fullmatch(sid):
                continue
            meta = read_json(os.path.join(d, n))
            try:
                with open(os.path.join(d, sid + ".jsonl.gz"), "rb") as f:
                    gz = f.read()
            except OSError:
                continue
            if meta:
                sys.stdout.buffer.write(pack(meta, gz))
    sys.stdout.buffer.flush()
    return 0


def cmd_outbox_ack(a):
    d = box("conv_outbox", a.project)
    n = 0
    with open_lock(d):
        for pair in a.pairs:
            sid, _, sha = pair.partition(":")
            if not SID_RE.fullmatch(sid):
                continue
            meta = read_json(os.path.join(d, sid + ".meta.json"))
            if meta and meta.get("sha256") == sha:  # 그 사이 새 판이 들어왔으면 지우지 않는다
                for ext in (".jsonl.gz", ".meta.json"):
                    try:
                        os.unlink(os.path.join(d, sid + ext))
                    except OSError:
                        pass
                n += 1
    print("ACK %d" % n)
    return 0


def cmd_pull(a):
    deadline = time.time() + a.timeout
    data = ssh_call(a.alias, ["outbox-take", proj_key(a.project)], timeout=3, total=max(1, int(a.timeout)))
    if not data:
        print("PULLED 0")
        return 0
    got, bad = ingest(data, a.project)
    if got:
        left = max(1, int(deadline - time.time()))
        ssh_call(a.alias, ["outbox-ack", proj_key(a.project)] + ["%s:%s" % g for g in got], timeout=3, total=left)
    print("PULLED %d" % len(got) + (" rejected %d" % bad if bad else ""))
    log("pull ssh=%s project=%s got=%d bad=%d" % (a.alias, proj_key(a.project), len(got), bad))
    return 4 if bad else 0


# ---------------------------------------------------------------- import

NTFS_RE = re.compile(r"^/mnt/[A-Za-z]/")


def map_cwd(cwd, src_cwd, dst_cwd):
    """원본 cwd 와 같거나 그 하위 경로면 수신 측 경로로 바꾼다. 아니면 None.

    원본이 /mnt/<드라이브>/ 아래(NTFS)면 대소문자를 무시한다. 같은 폴더가 Pd·pd 로 섞여 기록되기 때문이다.
    ext4 경로는 정확 일치만 본다. 하위 경로의 나머지 부분은 원문 그대로 붙인다.
    """
    if not isinstance(cwd, str) or not src_cwd:
        return None
    src = src_cwd.rstrip("/") or "/"
    fold = bool(NTFS_RE.match(src + "/"))
    a, b = (cwd.lower(), src.lower()) if fold else (cwd, src)
    if a == b:
        return dst_cwd
    if a.startswith(b + "/"):
        return dst_cwd.rstrip("/") + cwd[len(src):]
    return None


def substitute_cwd(body, src_cwd, dst_cwd):
    out = []
    for ln in body.splitlines():
        if not ln.strip():
            continue
        o = json.loads(ln.decode("utf-8"))
        if isinstance(o, dict):
            m = map_cwd(o.get("cwd"), src_cwd, dst_cwd)
            if m is not None:
                o["cwd"] = m
        out.append(json.dumps(o, ensure_ascii=False, separators=(",", ":")))
    return out


def norm_lines(path):
    with open(path, "rb") as f:
        res = []
        for ln in f:
            if ln.strip():
                try:
                    res.append(json.dumps(json.loads(ln.decode("utf-8")), ensure_ascii=False, separators=(",", ":")))
                except (ValueError, UnicodeDecodeError):
                    res.append(ln.decode("utf-8", "replace").rstrip("\n"))
        return res


def register_resume(project, meta, cwd):
    rl = role_lib()
    if not rl:
        return
    try:
        value = meta.get("role") or ""
        rid, area = rl.split_value(value) if value else ("", "")
        rl.resume_upsert(project.lower(), {"sid": meta["sid"], "role": rid, "area": area,
                                           "name": rl.name_of(value) if value else "", "value": value,
                                           "profile": "", "topic": "📥%s" % meta.get("host", ""), "cwd": cwd,
                                           "imported_from": meta.get("host", "")})
    except Exception as e:  # 재개 색인 실패는 가져오기를 막지 않는다
        log("import resume_index fail sid=%s err=%s" % (meta["sid"], type(e).__name__))


def tail_overlap(local, new_lines):
    """잘린 판(창이 앞으로 밀림)이 로컬 기록의 꼬리를 이어받는지 본다.

    새 판 첫 줄이 로컬 k 번째 줄과 같고 local[k:] 가 새 판의 접두이면 로컬 최신 부분이 새 판에 그대로 들어 있다.
    새 줄이 있으면 "replace", 새 판이 로컬 꼬리와 똑같으면(새 줄 없음) 로컬을 줄이지 않도록 "same",
    겹치지 않으면 "conflict"(로컬에서 이어 쓴 기록 보호).
    """
    first, k = new_lines[0], -1
    while True:
        try:
            k = local.index(first, k + 1)
        except ValueError:
            return "conflict"
        rest = len(local) - k
        if rest <= len(new_lines) and local[k:] == new_lines[:rest]:
            return "replace" if len(new_lines) > rest else "same"


def cmd_import(a):
    pk = proj_key(a.project)
    cwd = os.path.abspath(a.cwd)
    if not a.cwd.startswith("/"):
        raise Fail("--cwd 는 절대경로여야 한다", 2)
    d = box("conv_inbox", pk)
    pdir = os.path.realpath(os.path.join(home_base(), "projects"))
    rows, bad = [], 0
    if os.path.isdir(d):
        with open_lock(d):
            for n in sorted(os.listdir(d)):
                if not n.endswith(".meta.json"):
                    continue
                sid = n[:-len(".meta.json")]
                if not SID_RE.fullmatch(sid):
                    continue
                mp = os.path.join(d, n)
                meta = read_json(mp)
                imp = os.path.join(d, sid + ".imported")
                try:
                    with open(os.path.join(d, sid + ".jsonl.gz"), "rb") as f:
                        gz = f.read()
                    meta, body = verify_item(json.dumps(meta or {}).encode("utf-8"), gz, pk)
                except (OSError, Fail) as e:
                    bad += 1
                    rows.append((sid, "reject", "", ""))
                    log("import reject sid=%s reason=%s" % (sid, e))
                    continue
                try:
                    with open(imp, encoding="ascii") as f:
                        if f.read().strip() == meta["sha256"]:
                            continue  # 이미 가져온 판
                except OSError:
                    pass
                new_lines = substitute_cwd(body, meta["cwd"], cwd)
                tdir = os.path.join(pdir, enc(cwd))
                target = os.path.join(tdir, sid + ".jsonl")
                if os.path.dirname(os.path.realpath(target)) != os.path.realpath(tdir) or \
                        not os.path.realpath(tdir).startswith(pdir + os.sep):
                    bad += 1
                    rows.append((sid, "reject", "", ""))
                    log("import reject sid=%s reason=path" % sid)
                    continue
                kind = "new"
                if os.path.exists(target):
                    local = norm_lines(target)
                    if local == new_lines[:len(local)]:
                        kind = "extend" if len(new_lines) > len(local) else "same"
                    elif meta.get("truncated") is True and new_lines:
                        kind = tail_overlap(local, new_lines)
                    else:
                        kind = "conflict"
                if kind == "conflict":
                    atomic_write(os.path.join(d, sid + ".conflict"),
                                 ("%s 로컬 기록이 수신본의 접두가 아니다 — 로컬 보존, 수신본은 수신함에 남김\n"
                                  % now_iso()).encode("utf-8"))
                    bad += 1
                    rows.append((sid, "conflict", meta.get("role") or "-", meta.get("host", "")))
                    log("import conflict sid=%s" % sid)
                    continue
                if kind != "same":
                    atomic_write(target, ("\n".join(new_lines) + "\n").encode("utf-8"))
                register_resume(pk, meta, cwd)
                atomic_write(imp, meta["sha256"].encode("ascii"))
                try:
                    os.unlink(os.path.join(d, sid + ".conflict"))
                except OSError:
                    pass
                rows.append((sid, kind, meta.get("role") or "-", meta.get("host", "")))
                log("import sid=%s kind=%s lines=%d" % (sid, kind, len(new_lines)))
    done = [r for r in rows if r[1] in ("new", "extend", "replace")]
    print("IMPORTED %d" % len(done))
    for r in rows:
        print("ITEM\t%s\t%s\t%s\t%s" % r)
    return 4 if bad else 0


def cmd_is_imported(a):
    need_sid(a.sid)
    p = os.path.join(box("conv_inbox", a.project), a.sid + ".imported")
    return 0 if os.path.isfile(p) else 1


# ---------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(prog="conv_share.py", description="머신 간 대화 공유")
    sp = ap.add_subparsers(dest="cmd", required=True)
    for name in ("export", "push"):
        q = sp.add_parser(name)
        q.add_argument("--sid", required=True)
        q.add_argument("--cwd", default="")
        q.add_argument("--project", default="")
        q.add_argument("--role", default=None)
        if name == "push":
            q.add_argument("target")
            q.add_argument("--place", action="store_true")
            q.add_argument("--peer-cwd", default="")
    q = sp.add_parser("send")
    q.add_argument("--sid", required=True)
    q.add_argument("--project", default="")
    q.add_argument("target")
    q = sp.add_parser("pull")
    q.add_argument("alias")
    q.add_argument("--project", required=True)
    q.add_argument("--timeout", type=float, default=10)
    q = sp.add_parser("import")
    q.add_argument("--project", required=True)
    q.add_argument("--cwd", required=True)
    q = sp.add_parser("is-imported")
    q.add_argument("--sid", required=True)
    q.add_argument("--project", required=True)
    q = sp.add_parser("recv")
    q.add_argument("project")
    q = sp.add_parser("recv-import")
    q.add_argument("project")
    q.add_argument("cwd", nargs="?", default="")
    q = sp.add_parser("outbox-take")
    q.add_argument("project")
    q = sp.add_parser("outbox-ack")
    q.add_argument("project")
    q.add_argument("pairs", nargs="*")
    # "--outbox" 를 위치 인자로 받기 위해 앞에 "--" 를 끼워 넣는다
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in ("send", "push") and "--outbox" in argv:
        argv.remove("--outbox")
        argv += ["--", "--outbox"]
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        if a.cmd == "export":
            do_export(a.sid, a.cwd, a.project, a.role)
            return 0
        if a.cmd == "push":
            meta = do_export(a.sid, a.cwd, a.project, a.role)
            do_send(a.sid, a.target, meta["project"], a.place, a.peer_cwd)
            return 0
        if a.cmd == "send":
            do_send(a.sid, a.target, a.project or None)
            return 0
        return {"pull": cmd_pull, "import": cmd_import, "is-imported": cmd_is_imported, "recv": cmd_recv,
                "recv-import": cmd_recv_import,
                "outbox-take": cmd_outbox_take, "outbox-ack": cmd_outbox_ack}[a.cmd](a)
    except Fail as e:
        sys.stderr.write("conv_share: %s\n" % e)
        log("fail cmd=%s rc=%d %s" % (a.cmd, e.rc, e))
        return e.rc


if __name__ == "__main__":
    sys.exit(main())
