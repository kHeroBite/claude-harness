#!/bin/sh
# peer host 1줄 설치 스크립트 — join 토큰 교환 → peer_mcp 설치 → claude mcp 등록(POSIX sh·dash 호환)
#
# 사용(host 가 GET /v1/bootstrap.sh 로 제공하며 아래 HUB_DEFAULT 자리표시를 host URL 로 치환한다):
#   PEER_JOIN=<join> sh -c 'printf "Authorization: Bearer %s\n" "$PEER_JOIN" | curl -fsSL -H @- http://<host>/v1/bootstrap.sh | sh -s -- [--harness]'
# 토큰은 1순위 환경변수 PEER_JOIN(ps 노출 회피), 대안 `sh -s -- --join <값>`(ps 에 보일 수 있음)으로 받는다.
# 선택 환경변수: PEER_HUB_URL(치환 URL 덮어쓰기) · PEER_INSTALL_DIR(기본 ~/.local/share/claude-peer)
#                PEER_CLIENT_HOME(기본 ~/.config/claude-peer) · PEER_MACHINE_LABEL
# 종료 코드: 0 완료 · 2 사용법 · 3 토큰 없음 · 4 필수 도구 없음 · 5 join 거절 · 6 내려받기·sha 실패
#            7 mcp 등록 실패 · 8 harness 실패 · 9 hub 주소 없음
# 토큰 값은 어떤 출력·로그에도 쓰지 않는다. HTTP 는 python3 urllib 로 하고 토큰은 환경변수로만 넘긴다.

set -u

HUB_DEFAULT='__PEER_HUB_URL__'
MCP_NAME='peer'

_say() { printf '[peer-bootstrap] %s\n' "$*" >&2; }
_die() { _rc=$1; shift; _say "실패: $*"; _cleanup_fail; exit "$_rc"; }

HARNESS=0
ARG_JOIN=''
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS=1 ;;
    --join)
      if [ $# -lt 2 ]; then _say "--join 뒤에 값이 없다"; exit 2; fi
      ARG_JOIN=$2; shift ;;
    --join=*) ARG_JOIN=${1#--join=} ;;
    -h|--help)
      sed -n '2,11p' "$0" 2>/dev/null >&2 || true
      exit 0 ;;
    *) _say "알 수 없는 인자: $1 (허용: --harness, --join <값>)"; exit 2 ;;
  esac
  shift
done

# ── 정리 상태 ────────────────────────────────────────────────────────────
STAGE=''
BACKUP=''
COMMITTED=0
ENV_WRITTEN=0
ENV_EXISTED=0
DIR_CREATED=0

_cleanup_fail() {
  # 커밋 뒤 실패면 이전 상태로 되돌린다(부분 설치 정리).
  if [ "$COMMITTED" = 1 ]; then
    for _f in peer_mcp.py peer_common.py; do
      if [ -n "$BACKUP" ] && [ -f "$BACKUP/$_f" ]; then
        mv -f "$BACKUP/$_f" "$INSTALL_DIR/$_f" 2>/dev/null || true
      else
        rm -f "$INSTALL_DIR/$_f" 2>/dev/null || true
      fi
    done
    if [ "$DIR_CREATED" = 1 ]; then rmdir "$INSTALL_DIR" 2>/dev/null || true; fi
  fi
  if [ "$ENV_WRITTEN" = 1 ]; then
    if [ "$ENV_EXISTED" = 1 ] && [ -n "$BACKUP" ] && [ -f "$BACKUP/env" ]; then
      mv -f "$BACKUP/env" "$ENV_FILE" 2>/dev/null || true
    else
      rm -f "$ENV_FILE" 2>/dev/null || true
    fi
  fi
  _cleanup_tmp
}

_cleanup_tmp() {
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  STAGE=''
  BACKUP=''
}

trap '_cleanup_fail; exit 130' INT TERM HUP

# ── 1. 사전 확인 ─────────────────────────────────────────────────────────
HUB_URL=${PEER_HUB_URL:-$HUB_DEFAULT}
case "$HUB_URL" in
  ''|__PEER_HUB*) _say "hub 주소가 없다 — host 의 /v1/bootstrap.sh 로 받거나 PEER_HUB_URL 을 지정하라"; exit 9 ;;
  http://*|https://*) ;;
  *) _say "hub 주소 형식 오류(http:// 또는 https:// 로 시작해야 한다)"; exit 9 ;;
esac
HUB_URL=${HUB_URL%/}

if ! command -v python3 >/dev/null 2>&1; then
  _say "python3 이 없다 — python3(3.8 이상)을 설치한 뒤 다시 실행하라"
  exit 4
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' </dev/null >/dev/null 2>&1; then
  _say "python3 버전이 낮다 — 3.8 이상이 필요하다"
  exit 4
fi
if ! command -v claude >/dev/null 2>&1; then
  _say "claude(Claude Code CLI)가 없다 — Claude Code 를 설치한 뒤 다시 실행하라"
  exit 4
fi

if [ -z "${PEER_JOIN:-}" ] && [ -n "$ARG_JOIN" ]; then PEER_JOIN=$ARG_JOIN; fi
ARG_JOIN=''
if [ -z "${PEER_JOIN:-}" ]; then
  _say "join 토큰이 없다 — PEER_JOIN 환경변수(권장) 또는 sh -s -- --join <값> 으로 넘겨라"
  exit 3
fi

if [ -z "${HOME:-}" ]; then
  _say "HOME 이 비어 있다"
  exit 2
fi
INSTALL_DIR=${PEER_INSTALL_DIR:-$HOME/.local/share/claude-peer}
CLIENT_HOME=${PEER_CLIENT_HOME:-$HOME/.config/claude-peer}
ENV_FILE=$CLIENT_HOME/env

umask 077
_parent=$(dirname "$INSTALL_DIR")
mkdir -p "$_parent" || _die 6 "설치 상위 폴더를 만들 수 없다"
STAGE=$(mktemp -d "$_parent/.claude-peer-stage.XXXXXX") || _die 6 "임시 폴더를 만들 수 없다"
BACKUP=$STAGE/backup
mkdir -p "$BACKUP" "$STAGE/new" || _die 6 "임시 폴더를 만들 수 없다"

# ── HTTP 도우미(python3 urllib — 토큰은 환경변수 PB_TOKEN 으로만) ─────────
# 사용: _http <join|get> <url> <출력파일> <토큰>  → stdout 에 상태 코드, 파일에 결과
_http() {
  PB_MODE=$1 PB_URL=$2 PB_OUT=$3 PB_TOKEN=$4 python3 - <<'PY'
import hashlib, json, os, socket, sys
try:
    import urllib.request as u
    import urllib.error as ue
except Exception:
    print("0"); sys.exit(0)

class NoRedirect(u.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None

mode = os.environ["PB_MODE"]; url = os.environ["PB_URL"]; out = os.environ["PB_OUT"]
tok = os.environ.get("PB_TOKEN", "")
hdr = {"Authorization": "Bearer " + tok, "User-Agent": "claude-peer-bootstrap/1"}
data = None
method = "GET"
def machine_id():
    # peer_common.machine_id 와 같은 규칙(원문 비노출 sha256 앞 16자)
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

if mode == "join":
    method = "POST"
    hdr["Content-Type"] = "application/json"
    mid = machine_id()
    label = os.environ.get("PEER_MACHINE_LABEL", "").strip() or ("m-" + mid[:6])
    data = json.dumps({"join_token": tok, "machine_id": mid, "machine_label": label, "label": label}).encode("utf-8")
req = u.Request(url, data=data, headers=hdr, method=method)
op = u.build_opener(NoRedirect)
try:
    r = op.open(req, timeout=30)
    code = r.status
    body = r.read(64 << 20)
    sha_hdr = r.headers.get("X-Sha256", "")
except ue.HTTPError as e:
    print(str(e.code)); sys.exit(0)
except Exception:
    print("0"); sys.exit(0)
if mode == "join":
    try:
        tokv = json.loads(body.decode("utf-8")).get("machine_token") or ""
    except Exception:
        tokv = ""
    if code != 200 or not tokv:
        print(str(code if code != 200 else 502)); sys.exit(0)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(tokv)
    print("200"); sys.exit(0)
# get: sha256 대조
if code != 200:
    print(str(code)); sys.exit(0)
got = hashlib.sha256(body).hexdigest()
if not sha_hdr or sha_hdr.strip().lower() != got:
    print("SHA"); sys.exit(0)
with open(out, "wb") as f:
    f.write(body)
print("200")
PY
}

# ── 2. join 토큰 교환 ───────────────────────────────────────────────────
_st=$(_http join "$HUB_URL/v1/join" "$STAGE/mtok" "$PEER_JOIN")
unset PEER_JOIN
case "$_st" in
  200) ;;
  0) _die 5 "hub 에 접속할 수 없다($HUB_URL)" ;;
  *) _die 5 "join 토큰이 거절됐다(HTTP $_st — 이미 사용했거나 만료·잘못된 토큰). host 에서 새 join 토큰을 받아라" ;;
esac
MTOK=$(cat "$STAGE/mtok")
rm -f "$STAGE/mtok"
_say "join 교환 완료"

# ── 3. 파일 내려받기 + sha256 대조 ───────────────────────────────────────
for _f in peer_mcp.py peer_common.py; do
  _st=$(_http get "$HUB_URL/v1/files/$_f" "$STAGE/new/$_f" "$MTOK")
  case "$_st" in
    200) ;;
    SHA) _die 6 "$_f sha256 불일치 — 설치를 중단한다" ;;
    0) _die 6 "$_f 내려받기 실패(접속 오류)" ;;
    *) _die 6 "$_f 내려받기 실패(HTTP $_st)" ;;
  esac
done
_say "파일 2개 내려받기·sha256 확인 완료"

# ── 4. 설치(백업 후 교체) ────────────────────────────────────────────────
if [ ! -d "$INSTALL_DIR" ]; then
  mkdir -p "$INSTALL_DIR" || _die 6 "설치 폴더를 만들 수 없다"
  DIR_CREATED=1
fi
chmod 700 "$INSTALL_DIR" 2>/dev/null || true
COMMITTED=1
for _f in peer_mcp.py peer_common.py; do
  if [ -f "$INSTALL_DIR/$_f" ]; then cp -p "$INSTALL_DIR/$_f" "$BACKUP/$_f" || _die 6 "기존 파일 백업 실패"; fi
  chmod 600 "$STAGE/new/$_f"
  mv -f "$STAGE/new/$_f" "$INSTALL_DIR/$_f" || _die 6 "$_f 설치 실패"
done
_say "설치 경로: $INSTALL_DIR"

# ── 5. client env(0600) ─────────────────────────────────────────────────
mkdir -p "$CLIENT_HOME" || _die 6 "client 폴더를 만들 수 없다"
chmod 700 "$CLIENT_HOME" 2>/dev/null || true
if [ -f "$ENV_FILE" ]; then ENV_EXISTED=1; cp -p "$ENV_FILE" "$BACKUP/env" || _die 6 "기존 env 백업 실패"; fi
ENV_WRITTEN=1
PB_URL=$HUB_URL PB_TOKEN=$MTOK PB_OUT=$ENV_FILE python3 - <<'PY' || _die 6 "env 기록 실패"
import os
p = os.environ["PB_OUT"]; tmp = p + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("PEER_HUB_URL=%s\nPEER_TOKEN=%s\n" % (os.environ["PB_URL"], os.environ["PB_TOKEN"]))
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
_say "client env 기록(0600): $ENV_FILE"

# ── 6. claude mcp 등록(멱등 — 있으면 지우고 같은 값으로 다시 등록) ───────
if claude mcp get "$MCP_NAME" </dev/null >/dev/null 2>&1; then
  claude mcp remove --scope user "$MCP_NAME" </dev/null >/dev/null 2>&1 || true
  _mode='갱신'
else
  _mode='등록'
fi
if [ -n "${PEER_CLIENT_HOME:-}" ]; then
  claude mcp add --scope user -e "PEER_CLIENT_HOME=$PEER_CLIENT_HOME" "$MCP_NAME" -- python3 "$INSTALL_DIR/peer_mcp.py" </dev/null >/dev/null 2>&1 \
    || _die 7 "claude mcp add 실패"
else
  claude mcp add --scope user "$MCP_NAME" -- python3 "$INSTALL_DIR/peer_mcp.py" </dev/null >/dev/null 2>&1 \
    || _die 7 "claude mcp add 실패"
fi
_say "claude mcp $_mode 완료(이름 $MCP_NAME, scope user)"

# ── 7. --harness: host 의 install_harness.sh 내려받아 실행 ───────────────
if [ "$HARNESS" = 1 ]; then
  _st=$(_http get "$HUB_URL/v1/files/install_harness.sh" "$STAGE/install_harness.sh" "$MTOK")
  case "$_st" in
    200) ;;
    SHA) _say "install_harness.sh sha256 불일치 — 하네스 설치를 건너뛴다(peer 설치는 유지)"; _cleanup_tmp; exit 8 ;;
    *) _say "install_harness.sh 내려받기 실패(HTTP $_st) — peer 설치는 유지"; _cleanup_tmp; exit 8 ;;
  esac
  if command -v bash >/dev/null 2>&1; then _sh=bash; else _sh=sh; fi
  if ! "$_sh" "$STAGE/install_harness.sh" </dev/null; then
    _say "install_harness.sh 실행 실패 — peer 설치는 유지"
    _cleanup_tmp
    exit 8
  fi
  _say "하네스 설치 완료"
fi

MTOK=''
_cleanup_tmp
trap - INT TERM HUP
_say "완료 — 새 Claude Code 세션부터 peer MCP 가 붙는다"
exit 0
