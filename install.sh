#!/usr/bin/env bash
# Claude Code 하네스 배포 패키지 설치 스크립트 — WSL2·일반 Linux 사용자 공간, sudo 없음, 멱등(재실행 안전)
set -uo pipefail

# ── 사용법
#   bash install.sh [--non-interactive] [--link-skills]
#   환경변수 (모두 선택)
#     HARNESS_HOME           하네스 설치 루트 (기본 ~/.harness)
#     HARNESS_PROFILES_ROOT  cc/cas 프로필 루트 (기본 ~/.claude-profiles)
#     HARNESS_PROJECT_ROOTS  oio 파일 I/O 허용 프로젝트 루트 (콤마 구분)
#     CLAUDE_CONFIG_DIR      Claude Code 설정 디렉터리 (기본 ~/.claude)
#   예 (서버):
#     HARNESS_HOME=/data/pd/claude/harness HARNESS_PROFILES_ROOT=/data/pd/claude/profiles \
#       bash install.sh --non-interactive

NON_INTERACTIVE=0
LINK_SKILLS=0
for _arg in "$@"; do
    case "$_arg" in
        --non-interactive) NON_INTERACTIVE=1 ;;
        --link-skills) LINK_SKILLS=1 ;;
        -h|--help)
            sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "알 수 없는 옵션: $_arg (사용 가능: --non-interactive, --link-skills)"
            exit 2
            ;;
    esac
done
# 표준입력이 터미널이 아니면 비대화로 간주한다
[ -t 0 ] || NON_INTERACTIVE=1

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_HOME="${HARNESS_HOME%/}"
PROFILES_ROOT="${HARNESS_PROFILES_ROOT:-$HOME/.claude-profiles}"
PROFILES_ROOT="${PROFILES_ROOT%/}"
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN_SRC="${HARNESS_DIR}/bin"
BIN_DST="${HARNESS_HOME}/bin"
LOCAL_BIN="${HOME}/.local/bin"
VENV_DIR="${HARNESS_HOME}/venv/oio"
REPO_PLUGIN_ROOT="${HARNESS_DIR}/plugins/harness"
OIO_REQ="${REPO_PLUGIN_ROOT}/mcp-servers/oio/requirements.txt"
TS="$(date +%Y%m%d-%H%M%S)"

# 검증 결과 누적 (항목명|상태|비고)
RESULTS=""
FAILED=0

# 결과 기록 헬퍼
record() {
    RESULTS="${RESULTS}${1}|${2}|${3}"$'\n'
    [ "$2" = "실패" ] && FAILED=1
    return 0
}

# 표식 블록 교체 헬퍼 — 파일에서 시작·끝 표식 사이를 지우고 새 블록을 끝에 붙인다(멱등).
# 인자: 대상파일 시작표식 끝표식 블록본문(시작·끝 표식 제외)
replace_block() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import os, sys
path, begin, end, body = sys.argv[1:5]
text = ""
if os.path.exists(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()
out, skip = [], False
for line in text.splitlines(keepends=True):
    s = line.rstrip("\r\n")
    if s == begin:
        skip = True
        continue
    if skip and s == end:
        skip = False
        continue
    if not skip:
        out.append(line)
new = "".join(out).rstrip("\n")
block = begin + "\n" + body.rstrip("\n") + "\n" + end + "\n"
new = (new + "\n\n" if new else "") + block
tmp = path + ".harness_tmp"
with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(new)
os.replace(tmp, path)
PY
}

echo "═══════════════════════════════════════════════"
echo " Claude Code 하네스 설치 (멱등 — 재실행 안전, sudo 사용 안 함)"
echo "═══════════════════════════════════════════════"
echo "  HARNESS_HOME          = ${HARNESS_HOME}"
echo "  HARNESS_PROFILES_ROOT = ${PROFILES_ROOT}"
echo "  CLAUDE_CONFIG_DIR     = ${CFG_DIR}"
echo ""

# ── 0) 플랫폼 판별 (WSL2 / 일반 Linux)
echo "[0/10] 플랫폼 판별"
PLATFORM=""
if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
    echo "  ❌ Linux(WSL2 포함)만 지원합니다. 현재: $(uname -s 2>/dev/null)"
    record "플랫폼" "실패" "Linux 아님"
    echo "설치를 중단합니다."
    exit 1
elif grep -qi microsoft /proc/version 2>/dev/null; then
    PLATFORM="wsl"
    record "플랫폼" "성공" "WSL2"
else
    PLATFORM="linux"
    record "플랫폼" "성공" "일반 Linux — WSL 전용 기능(oss 스크린샷·Windows 알림·clip.exe 클립보드)은 비활성"
    echo "  ℹ️  일반 Linux 입니다. WSL 전용 기능(oss·Windows 알림·clip.exe)은 동작하지 않습니다."
fi

# ── 1) python3 확인 (venv·settings 병합 전제)
echo "[1/10] python3 확인"
if command -v python3 >/dev/null 2>&1; then
    record "python3" "성공" "$(python3 --version 2>&1)"
else
    echo "  ❌ python3 가 없습니다. 시스템 관리자에게 설치를 요청하거나 사용자 공간(pyenv 등)에 설치한 뒤 재실행하세요."
    record "python3" "실패" "미설치"
    exit 1
fi

# ── 2) 디렉터리 + current 링크 (설치된 플러그인 루트를 가리킨다)
echo "[2/10] HARNESS_HOME 구성"
mkdir -p "$HARNESS_HOME" "$BIN_DST" "$PROFILES_ROOT" "$CFG_DIR"
# Claude Code 가 설치한 플러그인 캐시를 우선하고, 없으면 이 저장소의 plugins/harness 를 쓴다.
# 이후 갱신은 SessionStart hook 이 맡는다.
PLUGIN_ROOT=""
_cache_base="${CFG_DIR}/plugins/cache/harness-marketplace/harness"
if [ -d "$_cache_base" ]; then
    PLUGIN_ROOT="$(ls -1d "$_cache_base"/*/ 2>/dev/null | sort -V | tail -n 1)"
    PLUGIN_ROOT="${PLUGIN_ROOT%/}"
fi
[ -n "$PLUGIN_ROOT" ] && [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="$REPO_PLUGIN_ROOT"
if [ -e "${HARNESS_HOME}/current" ] && [ ! -L "${HARNESS_HOME}/current" ]; then
    record "current 링크" "실패" "${HARNESS_HOME}/current 가 링크가 아닌 실제 경로 — 손대지 않음"
else
    ln -sfn "$PLUGIN_ROOT" "${HARNESS_HOME}/current" \
        && record "current 링크" "성공" "${HARNESS_HOME}/current → ${PLUGIN_ROOT}" \
        || record "current 링크" "실패" "ln 실패"
fi

# ── 3) bin 링크 (cc/ccc/claude-as/cas) — HARNESS_HOME/bin + ~/.local/bin
echo "[3/10] bin 링크 생성"
mkdir -p "$LOCAL_BIN"
_link_ok=1
for _b in cc ccc claude-as; do
    if [ -f "${BIN_SRC}/${_b}" ]; then
        chmod +x "${BIN_SRC}/${_b}" 2>/dev/null
        ln -sfn "${BIN_SRC}/${_b}" "${BIN_DST}/${_b}" || _link_ok=0
        ln -sfn "${BIN_SRC}/${_b}" "${LOCAL_BIN}/${_b}" || _link_ok=0
    else
        echo "  ⚠ ${BIN_SRC}/${_b} 없음"
        _link_ok=0
    fi
done
# cas 는 claude-as 의 별칭 (원본 구조와 동일)
ln -sfn "${BIN_SRC}/claude-as" "${BIN_DST}/cas" || _link_ok=0
ln -sfn "${BIN_SRC}/claude-as" "${LOCAL_BIN}/cas" || _link_ok=0
if [ "$_link_ok" = "1" ]; then
    record "bin 링크(cc/ccc/claude-as/cas)" "성공" "${BIN_DST}, ${LOCAL_BIN}"
else
    record "bin 링크(cc/ccc/claude-as/cas)" "실패" "일부 링크 실패"
fi

# ── 4) 셸 환경 표식 블록 (PATH + HARNESS_HOME + CLAUDE_PROFILES_ROOT)
#    ~/.bashrc 는 비대화 셸에서 앞부분 가드로 끝나는 배포판이 많아 로그인 셸 파일에도 같은 블록을 둔다.
echo "[4/10] 셸 환경 등록"
_env_body="export HARNESS_HOME=\"${HARNESS_HOME}\"
export CLAUDE_PROFILES_ROOT=\"${PROFILES_ROOT}\"
case \":\$PATH:\" in *\":${BIN_DST}:\"*) ;; *) export PATH=\"${BIN_DST}:\$PATH\" ;; esac
case \":\$PATH:\" in *\":\$HOME/.local/bin:\"*) ;; *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;; esac"
_bashrc="${HOME}/.bashrc"
if [ -f "${HOME}/.bash_profile" ]; then
    _login_rc="${HOME}/.bash_profile"
elif [ -f "${HOME}/.bash_login" ]; then
    _login_rc="${HOME}/.bash_login"
else
    _login_rc="${HOME}/.profile"
fi
_env_ok=1
for _rc in "$_bashrc" "$_login_rc"; do
    [ -f "$_rc" ] && cp -p "$_rc" "${_rc}.bak.${TS}" 2>/dev/null
    replace_block "$_rc" '# >>> harness PATH' '# <<< harness PATH' "$_env_body" || _env_ok=0
done
if [ "$_env_ok" = "1" ]; then
    record "셸 환경 등록" "성공" "${_bashrc}, ${_login_rc} (표식 블록 갱신)"
else
    record "셸 환경 등록" "실패" "표식 블록 기록 실패"
fi
export HARNESS_HOME CLAUDE_PROFILES_ROOT="$PROFILES_ROOT"

# ── 5) tmux 확인 + 설정 연결 (설치 시도는 하지 않는다)
echo "[5/10] tmux 확인"
if command -v tmux >/dev/null 2>&1; then
    record "tmux" "성공" "$(tmux -V 2>&1)"
    _tconf="${HARNESS_HOME}/current/tmux/tmux.conf"
    if [ -f "$_tconf" ]; then
        [ -f "${HOME}/.tmux.conf" ] && cp -p "${HOME}/.tmux.conf" "${HOME}/.tmux.conf.bak.${TS}" 2>/dev/null
        if replace_block "${HOME}/.tmux.conf" '# >>> harness tmux' '# <<< harness tmux' "source-file \"${_tconf}\""; then
            record "tmux 설정 연결" "성공" "~/.tmux.conf → source-file ${_tconf}"
        else
            record "tmux 설정 연결" "실패" "~/.tmux.conf 기록 실패"
        fi
    else
        record "tmux 설정 연결" "성공" "배포본에 tmux.conf 없음 — 건너뜀"
    fi
else
    echo ""
    echo "  ⚠️  tmux 가 없습니다. 하네스 hook 다수가 tmux 에 의존하므로 팀에이전트 파이프라인이 정상 동작하지 않습니다."
    echo "     이 스크립트는 패키지를 설치하지 않습니다. 시스템 관리자에게 설치를 요청하거나 사용자 공간에 설치한 뒤 재실행하세요."
    record "tmux" "실패" "미설치 — 팀에이전트 동작 불가 (설치는 직접)"
fi

# ── 6) 프로필 디렉터리 확인 (cc 는 프로필 0개면 exit 1 한다)
echo "[6/10] 프로필 디렉터리 확인"
# .credentials.json 을 가진 디렉터리만 유효 프로필로 인정 (cc 의 판정 기준과 동일)
_profile_count=$(find "$PROFILES_ROOT" -maxdepth 2 -name '.credentials.json' 2>/dev/null | wc -l)
if [ "$_profile_count" -gt 0 ]; then
    record "프로필" "성공" "${_profile_count}개 존재 (${PROFILES_ROOT})"
else
    echo "  ℹ️  등록된 프로필이 0개입니다. 설치 후 'cas create default' 로 1개 만들고 1회 로그인하세요."
    record "프로필" "성공" "0개 — 'cas create default' 안내함"
fi

# ── 7) oio MCP 서버 venv + fastmcp 설치
#    venv 는 플러그인 바깥 고정 경로에 두어 플러그인 갱신에도 살아남게 한다.
echo "[7/10] oio MCP venv 구성"
if [ ! -x "${VENV_DIR}/bin/python" ]; then
    mkdir -p "$(dirname "$VENV_DIR")"
    if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
        # python3-venv 가 없는 배포판: 사용자 공간 virtualenv 로 대체한다(sudo 불필요)
        rm -rf "$VENV_DIR"
        python3 -m virtualenv "$VENV_DIR" >/dev/null 2>&1 \
            || { python3 -m pip install --user -q virtualenv >/dev/null 2>&1 && python3 -m virtualenv "$VENV_DIR" >/dev/null 2>&1; }
    fi
fi
if [ -x "${VENV_DIR}/bin/python" ]; then
    if [ -f "$OIO_REQ" ]; then
        "${VENV_DIR}/bin/python" -m pip install -q --upgrade pip >/dev/null 2>&1
        if "${VENV_DIR}/bin/python" -m pip install -q -r "$OIO_REQ"; then
            record "oio venv + fastmcp" "성공" "$VENV_DIR"
        else
            record "oio venv + fastmcp" "실패" "pip install 실패"
        fi
    else
        record "oio venv + fastmcp" "실패" "requirements.txt 없음: $OIO_REQ"
    fi
else
    record "oio venv + fastmcp" "실패" "venv 생성 실패 (python3-venv 또는 virtualenv 필요)"
fi
# .mcp.json 은 venv 를 ${HOME}/.harness/venv/oio 로 가리킨다.
# HARNESS_HOME 이 기본값이 아니면 ~/.harness/venv → $HARNESS_HOME/venv 호환 링크를 만든다.
if [ "$HARNESS_HOME" != "${HOME}/.harness" ]; then
    _compat="${HOME}/.harness/venv"
    mkdir -p "${HOME}/.harness"
    if [ -L "$_compat" ] || [ ! -e "$_compat" ]; then
        ln -sfn "${HARNESS_HOME}/venv" "$_compat" \
            && record "venv 호환 링크" "성공" "${_compat} → ${HARNESS_HOME}/venv" \
            || record "venv 호환 링크" "실패" "ln 실패"
    else
        record "venv 호환 링크" "실패" "${_compat} 가 실제 디렉터리 — 손대지 않음(.mcp.json 경로 확인 필요)"
    fi
fi

# ── 8) Claude Code settings 병합 (없는 키만 추가, 원본 백업)
echo "[8/10] settings 병합"
_targets="${CFG_DIR}"
if [ -d "$PROFILES_ROOT" ]; then
    for _p in "$PROFILES_ROOT"/*/; do
        [ -d "$_p" ] && _targets="${_targets}
${_p%/}"
    done
fi
_statusline="${HARNESS_HOME}/current/statusline.py"
_merge_ok=1
_merge_n=0
while IFS= read -r _d; do
    [ -z "$_d" ] && continue
    _out=$(python3 - "${_d}/settings.json" "$_statusline" "$TS" <<'PY'
import json, os, shutil, sys
path, statusline, ts = sys.argv[1:4]
data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"ERR 파싱 실패: {e}")
        sys.exit(1)
    if not isinstance(data, dict):
        print("ERR 최상위가 객체 아님")
        sys.exit(1)
added = []
if "statusLine" not in data and os.path.exists(statusline):
    data["statusLine"] = {"type": "command", "command": f'python3 "{statusline}"'}
    added.append("statusLine")
if "skipDangerousModePermissionPrompt" not in data:
    data["skipDangerousModePermissionPrompt"] = True
    added.append("skipDangerousModePermissionPrompt")
ep = data.get("enabledPlugins")
if ep is None:
    data["enabledPlugins"] = {"harness@harness-marketplace": True}
    added.append("enabledPlugins")
elif isinstance(ep, dict) and "harness@harness-marketplace" not in ep:
    ep["harness@harness-marketplace"] = True
    added.append("enabledPlugins.harness")
if added:
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.bak.{ts}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".harness_tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)
print("OK " + (",".join(added) if added else "변경 없음"))
PY
)
    _rc=$?
    echo "  ${_d}/settings.json: ${_out}"
    [ "$_rc" -eq 0 ] || _merge_ok=0
    _merge_n=$((_merge_n + 1))
done <<EOF
${_targets}
EOF
if [ "$_merge_ok" = "1" ]; then
    record "settings 병합" "성공" "${_merge_n}개 파일 (기존 키 유지)"
else
    record "settings 병합" "실패" "일부 settings.json 파싱 실패 — 원본 유지"
fi

# ── 9) 프로젝트 루트 선언 (선택)
#    oio 의 파일 I/O 허용 루트다. 미선언이면 CLAUDE_PROJECT_DIR / cwd 로 자동 판별한다.
echo "[9/10] 프로젝트 루트 선언 (선택)"
_marker='# >>> harness project roots'
if grep -q "$_marker" "$_bashrc" 2>/dev/null; then
    record "프로젝트 루트 선언" "성공" "이미 선언됨 (중복 추가 안 함)"
elif [ -n "${HARNESS_PROJECT_ROOTS:-}" ]; then
    replace_block "$_bashrc" "$_marker" '# <<< harness project roots' "export HARNESS_PROJECT_ROOTS=\"${HARNESS_PROJECT_ROOTS}\""
    replace_block "$_login_rc" "$_marker" '# <<< harness project roots' "export HARNESS_PROJECT_ROOTS=\"${HARNESS_PROJECT_ROOTS}\""
    record "프로젝트 루트 선언" "성공" "${HARNESS_PROJECT_ROOTS}"
elif [ "$NON_INTERACTIVE" = "0" ]; then
    echo ""
    echo "  프로젝트를 여러 위치에 두셨다면 그 상위 경로들을 콤마로 구분해 입력하세요."
    echo "  예: /mnt/d/work,/data/me/Project"
    echo "  그냥 Enter 를 누르면 자동 판별을 씁니다 (대부분의 경우 이걸로 충분합니다)."
    echo ""
    printf "     프로젝트 루트 [자동 판별] "
    read -r _roots
    _roots="$(printf '%s' "$_roots" | tr -d '[:space:]')"
    if [ -z "$_roots" ]; then
        record "프로젝트 루트 선언" "성공" "자동 판별 사용"
    elif printf '%s' "$_roots" | grep -qE '(^|,)/(mnt)?(/[a-z])?(,|$)'; then
        # "/" · "/mnt" · "/mnt/c" 같은 광역 경로는 거부한다 (보안 하한선).
        echo "     ⚠ '/' · '/mnt' · '/mnt/c' 같은 광역 경로는 허용하지 않습니다. 자동 판별로 진행합니다."
        record "프로젝트 루트 선언" "성공" "광역 경로 거부 — 자동 판별 사용"
    else
        replace_block "$_bashrc" "$_marker" '# <<< harness project roots' "export HARNESS_PROJECT_ROOTS=\"${_roots}\""
        replace_block "$_login_rc" "$_marker" '# <<< harness project roots' "export HARNESS_PROJECT_ROOTS=\"${_roots}\""
        record "프로젝트 루트 선언" "성공" "$_roots"
    fi
else
    record "프로젝트 루트 선언" "성공" "비대화 설치 — 자동 판별 사용"
fi

# ── 10) rules 디렉터리 + (선택) 스킬 무접두 링크
echo "[10/10] rules 디렉터리 / 스킬 링크"
mkdir -p "${CFG_DIR}/rules"
if [ -d "${CFG_DIR}/rules" ]; then
    record "rules 디렉터리" "성공" "${CFG_DIR}/rules"
else
    record "rules 디렉터리" "실패" "생성 실패"
fi
if [ "$LINK_SKILLS" = "1" ]; then
    _sk_src="${HARNESS_HOME}/current/skills"
    _sk_n=0
    _sk_skip=0
    mkdir -p "${CFG_DIR}/skills"
    for _s in "$_sk_src"/*/; do
        [ -d "$_s" ] || continue
        _name="$(basename "$_s")"
        _dst="${CFG_DIR}/skills/${_name}"
        if [ -e "$_dst" ] && [ ! -L "$_dst" ]; then
            _sk_skip=$((_sk_skip + 1))
            continue
        fi
        ln -sfn "${_s%/}" "$_dst" && _sk_n=$((_sk_n + 1))
    done
    record "스킬 무접두 링크" "성공" "${_sk_n}개 링크, 기존 실제 디렉터리 ${_sk_skip}개 유지"
fi

# ── 설치 결과 출력
echo ""
echo "═══════════════════════════════════════════════"
echo " 설치 결과"
echo "═══════════════════════════════════════════════"
printf '%s' "$RESULTS" | while IFS='|' read -r _item _status _note; do
    [ -z "$_item" ] && continue
    if [ "$_status" = "성공" ]; then
        printf "  ✅ %-34s %s\n" "$_item" "$_note"
    else
        printf "  ❌ %-34s %s\n" "$_item" "$_note"
    fi
done
echo "═══════════════════════════════════════════════"
echo ""

if [ "$FAILED" = "1" ]; then
    echo "⚠️  일부 항목이 실패했습니다. 위 목록을 확인하세요."
else
    echo "✅ 설치 완료."
fi

echo ""
echo "다음 단계:"
echo "  1) source ${_bashrc}       (또는 새 로그인 셸)"
echo "  2) cas create default        (프로필이 없다면 — 로그인은 직접 진행)"
echo "  3) cc                        (하네스 진입)"
echo ""
echo "ℹ️  oio MCP 가 연결되지 않는 경우:"
echo "   .mcp.json 의 \${HOME} 전개는 공식 보장 대상이 아닙니다."
echo "   oio 도구가 보이지 않으면 설치된 플러그인의 .mcp.json command 를"
echo "   ${HOME}/.harness/venv/oio/bin/python 절대경로로 바꾸세요."
echo ""
echo "⚠️  보안 고지: cc/ccc/cas 는 --dangerously-skip-permissions 모드로 실행됩니다."
echo "   비활성화하려면: export HARNESS_SAFE_MODE=1"
echo ""

exit $FAILED
