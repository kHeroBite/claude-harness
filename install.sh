#!/usr/bin/env bash
# Claude Code 하네스 배포 패키지 설치 스크립트 — 멱등 (몇 번 재실행해도 안전)
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="${HARNESS_DIR}/bin"
BIN_DST="${HOME}/.local/bin"
VENV_DIR="${HOME}/.harness/venv/oio"
PROFILES_ROOT="${HOME}/.claude-profiles"
OIO_REQ="${HARNESS_DIR}/plugins/harness/mcp-servers/oio/requirements.txt"

# 검증 결과 누적 (항목명|상태|비고)
RESULTS=""
FAILED=0

# 결과 기록 헬퍼
record() {
    RESULTS="${RESULTS}${1}|${2}|${3}"$'\n'
    [ "$2" = "실패" ] && FAILED=1
    return 0
}

echo "═══════════════════════════════════════════════"
echo " Claude Code 하네스 설치 (멱등 — 재실행 안전)"
echo "═══════════════════════════════════════════════"
echo ""

# ── 0) 환경 확인 (WSL2 전용)
echo "[0/7] 환경 확인"
if grep -qi microsoft /proc/version 2>/dev/null; then
    record "WSL2 환경" "성공" "확인됨"
else
    echo "  ❌ 이 하네스는 WSL2 전용입니다. macOS/네이티브 Linux 는 지원하지 않습니다."
    record "WSL2 환경" "실패" "WSL2 가 아님"
    echo ""
    echo "설치를 중단합니다."
    exit 1
fi

# ── 1) python3 / pip 존재 검사 (venv 생성 전제)
echo "[1/7] python3 확인"
if command -v python3 >/dev/null 2>&1; then
    record "python3" "성공" "$(python3 --version 2>&1)"
else
    echo "  ❌ python3 가 없습니다. 'sudo apt install -y python3 python3-venv' 후 재실행하세요."
    record "python3" "실패" "미설치"
    exit 1
fi

# ── 2) bin 3종 심볼릭링크 (멱등: ln -sfn 은 기존 링크를 갱신)
echo "[2/7] bin 심볼릭링크 생성"
mkdir -p "$BIN_DST"
_link_ok=1
for _b in cc ccc claude-as; do
    if [ -f "${BIN_SRC}/${_b}" ]; then
        chmod +x "${BIN_SRC}/${_b}" 2>/dev/null
        ln -sfn "${BIN_SRC}/${_b}" "${BIN_DST}/${_b}" || _link_ok=0
    else
        echo "  ⚠ ${BIN_SRC}/${_b} 없음"
        _link_ok=0
    fi
done
# cas 는 claude-as 의 별칭 (원본 구조와 동일)
ln -sfn "${BIN_SRC}/claude-as" "${BIN_DST}/cas" || _link_ok=0
if [ "$_link_ok" = "1" ]; then
    record "bin 심볼릭(cc/ccc/claude-as/cas)" "성공" "$BIN_DST"
else
    record "bin 심볼릭(cc/ccc/claude-as/cas)" "실패" "일부 링크 실패"
fi

# ── 3) PATH 추가 (멱등: 마커 주석 존재 여부로 중복 방지)
echo "[3/7] PATH 등록"
_bashrc="${HOME}/.bashrc"
if grep -q '# >>> harness PATH' "$_bashrc" 2>/dev/null; then
    record "PATH 등록" "성공" "이미 등록됨 (중복 추가 안 함)"
else
    {
        echo ''
        echo '# >>> harness PATH'
        echo 'export PATH="$HOME/.local/bin:$PATH"'
        echo '# <<< harness PATH'
    } >> "$_bashrc"
    record "PATH 등록" "성공" "~/.bashrc 에 추가됨"
fi

# ── 4) tmux 확인 (hook 12개가 의존 — 부재 시 파이프라인이 오작동한다)
echo "[4/7] tmux 확인"
if command -v tmux >/dev/null 2>&1; then
    record "tmux" "성공" "$(tmux -V 2>&1)"
else
    echo ""
    echo "  ⚠️  tmux 가 설치되어 있지 않습니다."
    echo "     하네스 hook 12개가 tmux 에 의존하므로 tmux 없이는"
    echo "     팀에이전트 파이프라인이 정상 동작하지 않습니다."
    echo ""
    if [ -t 0 ]; then
        printf "     지금 설치하시겠습니까? (sudo 권한 필요) [y/N] "
        read -r _ans
    else
        _ans="n"
    fi
    case "$_ans" in
        [yY]*)
            sudo apt-get update && sudo apt-get install -y tmux
            if command -v tmux >/dev/null 2>&1; then
                record "tmux" "성공" "설치 완료"
            else
                record "tmux" "실패" "설치 시도했으나 실패"
            fi
            ;;
        *)
            echo "     건너뜁니다. 나중에 직접 설치하세요: sudo apt install -y tmux"
            record "tmux" "실패" "미설치 — 팀에이전트 동작 불가"
            ;;
    esac
fi

# ── 5) 프로파일 디렉토리 초기화 (cc 는 프로파일 0개면 exit 1 한다)
echo "[5/7] 프로파일 디렉토리 초기화"
mkdir -p "$PROFILES_ROOT"
# .credentials.json 을 가진 디렉토리만 유효 프로파일로 인정 (cc 의 판정 기준과 동일)
_profile_count=$(find "$PROFILES_ROOT" -maxdepth 2 -name '.credentials.json' 2>/dev/null | wc -l)
if [ "$_profile_count" -gt 0 ]; then
    record "프로파일" "성공" "${_profile_count}개 존재"
else
    echo ""
    echo "  ℹ️  등록된 프로파일이 0개입니다."
    echo "     설치 후 아래 명령으로 프로파일을 1개 만들어야 cc 가 동작합니다."
    echo ""
    echo "         cas create default"
    echo ""
    echo "     생성 후 1회 로그인하면 .credentials.json 이 만들어집니다."
    record "프로파일" "성공" "0개 — 'cas create default' 안내함"
fi

# ── 6) oio MCP 서버 venv + fastmcp 설치
#    venv 를 플러그인 바깥 고정 경로에 두어 플러그인 갱신에도 살아남게 한다.
echo "[6/7] oio MCP venv 구성"
if [ ! -d "$VENV_DIR" ]; then
    mkdir -p "$(dirname "$VENV_DIR")"
    python3 -m venv "$VENV_DIR"
fi
if [ -x "${VENV_DIR}/bin/python" ]; then
    if [ -f "$OIO_REQ" ]; then
        "${VENV_DIR}/bin/pip" install -q --upgrade pip >/dev/null 2>&1
        if "${VENV_DIR}/bin/pip" install -q -r "$OIO_REQ"; then
            record "oio venv + fastmcp" "성공" "$VENV_DIR"
        else
            record "oio venv + fastmcp" "실패" "pip install 실패"
        fi
    else
        record "oio venv + fastmcp" "실패" "requirements.txt 없음: $OIO_REQ"
    fi
else
    record "oio venv + fastmcp" "실패" "venv 생성 실패"
fi

# ── 6.5) .mcp.json 의 ${HOME} 전개 불확실성 대응
#    공식 문서상 전개가 보장된 변수는 ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA}/${CLAUDE_PROJECT_DIR} 뿐이다.
#    ${HOME} 이 전개되지 않아 oio 서버가 붙지 않으면 아래 명령으로 절대경로 치환하라는 안내를 남긴다.
echo "[6.5/7] oio MCP 경로 안내"
_mcp_json="${HARNESS_DIR}/plugins/harness/.mcp.json"
if [ -f "$_mcp_json" ] && grep -q '\${HOME}' "$_mcp_json" 2>/dev/null; then
    record "oio MCP command 경로" "성공" "\${HOME} 사용 — 미전개 시 아래 안내 참조"
    MCP_HINT=1
else
    record "oio MCP command 경로" "성공" "절대경로로 치환됨"
    MCP_HINT=0
fi

# ── 6.7) 프로젝트 루트 선언 (선택)
#    oio 의 파일 I/O 허용 루트다. 미선언이면 CLAUDE_PROJECT_DIR / cwd 로 자동 판별하므로
#    단일 프로젝트 사용자는 아무것도 하지 않아도 된다. 여러 위치의 프로젝트를
#    함께 쓰는 경우에만 선언하면 된다.
#    멱등: 마커 주석 존재 여부로 중복 추가를 막는다.
echo "[6.7/7] 프로젝트 루트 선언 (선택)"
_marker='# >>> harness project roots'
if grep -q "$_marker" "$_bashrc" 2>/dev/null; then
    record "프로젝트 루트 선언" "성공" "이미 선언됨 (중복 추가 안 함)"
elif [ -n "${HARNESS_PROJECT_ROOTS:-}" ]; then
    # 환경변수로 이미 주어졌으면 그대로 고정한다 (무인 설치 경로).
    {
        echo ''
        echo "$_marker"
        echo "export HARNESS_PROJECT_ROOTS=\"${HARNESS_PROJECT_ROOTS}\""
        echo '# <<< harness project roots'
    } >> "$_bashrc"
    record "프로젝트 루트 선언" "성공" "${HARNESS_PROJECT_ROOTS}"
elif [ -t 0 ]; then
    echo ""
    echo "  프로젝트를 여러 위치에 두셨다면 그 상위 경로들을 콤마로 구분해 입력하세요."
    echo "  예: /mnt/d/work,/mnt/c/src"
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
        {
            echo ''
            echo "$_marker"
            echo "export HARNESS_PROJECT_ROOTS=\"${_roots}\""
            echo '# <<< harness project roots'
        } >> "$_bashrc"
        record "프로젝트 루트 선언" "성공" "$_roots"
    fi
else
    record "프로젝트 루트 선언" "성공" "비대화 설치 — 자동 판별 사용"
fi

# ── 7) rules 디렉토리 (SessionStart hook 이 harness.md 를 동기화하는 고정 경로)
echo "[7/7] rules 디렉토리 생성"
mkdir -p "${HOME}/.claude/rules"
if [ -d "${HOME}/.claude/rules" ]; then
    record "rules 디렉토리" "성공" "${HOME}/.claude/rules"
else
    record "rules 디렉토리" "실패" "생성 실패"
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
echo "  1) source ~/.bashrc"
echo "  2) cas create default        (프로파일이 없다면)"
echo "  3) cc                        (하네스 진입)"
if [ "${MCP_HINT:-0}" = "1" ]; then
    echo ""
    echo "ℹ️  oio MCP 가 연결되지 않는 경우:"
    echo "   .mcp.json 의 \${HOME} 전개는 공식 보장 대상이 아닙니다."
    echo "   Claude Code 기동 후 oio 도구가 보이지 않으면 아래 명령으로 절대경로 치환하세요."
    echo ""
    echo "       sed -i \"s|\\\${HOME}|\$HOME|g\" \\"
    echo "         \"${HARNESS_DIR}/plugins/harness/.mcp.json\""
    echo ""
fi

echo ""
echo "⚠️  보안 고지: cc/ccc/cas 는 --dangerously-skip-permissions 모드로 실행됩니다."
echo "   비활성화하려면: export HARNESS_SAFE_MODE=1"
echo ""

exit $FAILED
