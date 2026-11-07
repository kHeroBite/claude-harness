#!/bin/sh
# 새 머신에 하네스를 한 번에 설치하는 온라인 설치 스크립트 — 필수 도구 사다리(system→user→sudo)·clone·oUpdate·install.sh·플러그인 연결
#
# 1줄 설치(파이프로 실행해도 질문은 /dev/tty 에서 읽는다. tty 가 없으면 비대화로 본다):
#   curl -fsSL https://raw.githubusercontent.com/kHeroBite/claude-harness/master/install-online.sh | sh
#   wget -qO- https://raw.githubusercontent.com/kHeroBite/claude-harness/master/install-online.sh | sh
#   git clone https://github.com/kHeroBite/claude-harness.git /tmp/ch && sh /tmp/ch/install-online.sh
#
# 이 파일은 정적 파일이다. 버전·sha 를 박지 않는다. clone 뒤 최신 v* 태그(없으면 기본 브랜치)를 쓴다.
# POSIX sh(dash) 로 동작해야 한다 — bash 전용 문법 금지.
set -u

# ── 상수 ────────────────────────────────────────────────────────────────
DIST_URL_DEFAULT="https://github.com/kHeroBite/claude-harness.git"
# Claude Code 공식 네이티브 설치(출처: https://code.claude.com/docs/en/setup, sudo 불필요, ~/.local/bin/claude)
CLAUDE_NATIVE_URL="https://claude.ai/install.sh"
CLAUDE_NPM_PKG="@anthropic-ai/claude-code"
# Codex CLI 공식 standalone 설치(출처: https://github.com/openai/codex README, sudo 불필요, ~/.local/bin/codex)
#   설치 스크립트의 CODEX_NON_INTERACTIVE 는 의미를 확인하지 못해 쓰지 않는다.
CODEX_NATIVE_URL="https://chatgpt.com/codex/install.sh"
CODEX_NPM_PKG="@openai/codex"
# codex 플러그인(출처: https://github.com/openai/codex-plugin-cc README — Node.js 18.18 이상 필요)
CODEX_PLUGIN_RERUN="claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex"
NODE_DIST="https://nodejs.org/dist"

# 부트스트랩 최소 목록(clone 전) — requires.txt 와 같은 형식
BOOTSTRAP_REQS="git|2.0|required|apt=git|dnf=git|yum=git|zypper=git|pacman=git|apk=git|brew=git
python3|3.10|required|apt=python3|dnf=python3|yum=python3|zypper=python3|pacman=python|apk=python3|brew=python@3"

usage() {
    cat <<'EOF'
사용법: sh install-online.sh [옵션]

옵션:
  --home <폴더>          프로젝트 홈(묻지 않음). 설치 위치는 <폴더>/AI 다
  --non-interactive      묻지 않는다. sudo 를 시도하지 않고 외부 설치 스크립트도 실행하지 않는다
  --yes                  동의가 필요한 설치를 자동 진행한다(비대화에서 sudo 는 sudo -n 으로만)
  --no-sudo              어떤 단계에서도 sudo 를 쓰지 않는다(--yes --no-sudo = 사용자 공간 설치만 자동)
  --no-plugin            Claude Code 플러그인(harness·codex) 연결을 건너뛴다(재실행 명령만 안내)
  --no-rc                셸 rc 파일을 고치지 않는다(install.sh 에 전달)
  --repo-url <URL>       배포 저장소 주소(기본: 상단 DIST_URL_DEFAULT)
  --deps-only            필수 도구 점검·설치만 한다(oUpdate 가 재사용하는 진입점)
  --requires <파일>      도구 목록 파일(기본: 이 스크립트 옆 requires.txt)
  --only <도구>          그 도구만 점검·설치한다(--deps-only 와 같은 동작).
                         --deps-only 없이 --only codex 를 주면 codex 플러그인 연결까지 한다
  -h, --help             이 도움말

--deps-only 출력(줄 단위):
  DEP <이름> <system|user|sudo|missing> <버전 또는 메모>
  CMD <이름> <수동 설치 명령>
  끝 줄: DEPS OK | DEPS MISSING <이름…> | DEPS PYTHON_TOO_OLD <버전>
종료코드: 0 정상 / 2 인자 오류 / 3 필수 도구 누락 / 4 python3 가 3.10 미만 / 그 밖은 oUpdate 의 종료코드
EOF
}

# ── 인자 ────────────────────────────────────────────────────────────────
HOME_P=""
NONINT=0
YES=0
NOSUDO=0
NOPLUGIN=0
NORC=0
DIST_URL="$DIST_URL_DEFAULT"
DEPS_ONLY=0
REQ_FILE=""
ONLY=""

need_arg() {
    if [ "$2" -lt 2 ]; then
        printf '오류: %s 에 값이 필요하다\n' "$1" >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --home) need_arg "$1" $#; HOME_P="$2"; shift ;;
        --home=*) HOME_P="${1#*=}" ;;
        --non-interactive) NONINT=1 ;;
        --yes|-y) YES=1 ;;
        --no-sudo) NOSUDO=1 ;;
        --no-plugin) NOPLUGIN=1 ;;
        --no-rc) NORC=1 ;;
        --repo-url) need_arg "$1" $#; DIST_URL="$2"; shift ;;
        --repo-url=*) DIST_URL="${1#*=}" ;;
        --deps-only) DEPS_ONLY=1 ;;
        --requires) need_arg "$1" $#; REQ_FILE="$2"; shift ;;
        --requires=*) REQ_FILE="${1#*=}" ;;
        --only) need_arg "$1" $#; ONLY="$2"; shift ;;
        --only=*) ONLY="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf '오류: 알 수 없는 옵션 %s (--help 참고)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# 시험용 덮어쓰기 — INSTALL_ONLINE_TEST=1 일 때만 읽는다(실설치에서 환경변수로 임의 명령이 실행되는 경로 차단)
T_CLAUDE=""
T_CODEX=""
T_NODE=""
T_TTY=""
if [ "${INSTALL_ONLINE_TEST:-}" = "1" ]; then
    T_CLAUDE="${CLAUDE_INSTALL_CMD:-}"
    T_CODEX="${CODEX_INSTALL_CMD:-}"
    T_NODE="${NODE_INSTALL_CMD:-}"
    T_TTY="${INSTALL_ONLINE_TTY:-}"
fi

# 사용자 공간 도구를 먼저 찾는다(비대화 ssh 의 PATH 에 ~/.local/bin 이 빠지는 경우 대비). 원래 PATH 는 따로 둔다.
ORIG_PATH="${PATH:-/usr/bin:/bin}"
case ":$ORIG_PATH:" in
    *":$HOME/.local/bin:"*) PATH="$ORIG_PATH" ;;
    *) PATH="$HOME/.local/bin:$ORIG_PATH" ;;
esac
export PATH

# ── 대화 여부 ────────────────────────────────────────────────────────────
INTERACTIVE=0
if [ "$NONINT" -eq 0 ]; then
    if [ -n "$T_TTY" ]; then
        if [ -r "$T_TTY" ]; then
            exec 3<"$T_TTY"
            INTERACTIVE=1
        fi
    elif (exec 3</dev/tty) 2>/dev/null; then
        exec 3</dev/tty
        INTERACTIVE=1
    fi
fi

# ── 공용 함수 ────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; }
warn() { printf '경고: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
rehash() { hash -r 2>/dev/null || true; }
redact_url() { printf '%s\n' "$1" | sed 's#://[^/@]*@#://#'; }

ask_yn() {
    printf '%s [y/N]: ' "$1" >&2
    _ans=""
    read -r _ans <&3 || _ans=""
    case "$_ans" in
        y|Y|yes|YES|Yes) return 0 ;;
    esac
    return 1
}

ask_line() {
    printf '%s' "$1" >&2
    _ans=""
    read -r _ans <&3 || _ans=""
    printf '%s\n' "$_ans"
}

# 동의: --yes 면 진행, 대화면 y/N(기본 N), 그 밖은 거부
consent() {
    _what="$1"
    _cmd="$2"
    if [ "$YES" -eq 1 ]; then
        return 0
    fi
    if [ "$INTERACTIVE" -eq 1 ]; then
        printf '%s 이(가) 필요하다. 실행할 명령: %s\n' "$_what" "$_cmd" >&2
        ask_yn "지금 실행할까?"
        return $?
    fi
    return 1
}

ver_of() {
    printf '%s\n' "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*$/\1/p' | head -n 1
}

# $1 >= $2 (빈 하한은 항상 참)
ver_ge() {
    [ -z "$2" ] && return 0
    [ -z "$1" ] && return 1
    awk -v a="$1" -v b="$2" 'BEGIN{n=split(a,x,".");m=split(b,y,".");k=(n>m?n:m);
        for(i=1;i<=k;i++){p=(i<=n?x[i]+0:0);q=(i<=m?y[i]+0:0);if(p>q)exit 0;if(p<q)exit 1}exit 0}'
}

run_to() {
    if have timeout; then
        timeout 90 "$@"
    else
        "$@"
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

fetch_to() {
    if have curl; then
        curl -fsSL "$1" -o "$2"
    elif have wget; then
        wget -qO "$2" "$1"
    else
        return 1
    fi
}

# 도구 버전 탐지 — 찾으면 rc=0 + 버전(없으면 ok) 출력
tool_version() {
    case "$1" in
        python3)
            have python3 || return 1
            python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo ""
            ;;
        venv)
            have python3 || return 1
            if python3 -c 'import ensurepip, venv' >/dev/null 2>&1; then
                echo ok
                return 0
            fi
            # import 판정 실패 → 임시 venv 를 실제로 만들어 재확인
            _vd="$(mktemp -d 2>/dev/null)" || return 1
            if python3 -m venv "$_vd/v" >/dev/null 2>&1; then _vr=0; else _vr=1; fi
            rm -rf "$_vd"
            [ "$_vr" -eq 0 ] || return 1
            echo ok
            ;;
        curl/wget)
            if have curl; then
                echo "curl $(ver_of "$(curl --version 2>/dev/null | head -n 1)")"
            elif have wget; then
                echo "wget $(ver_of "$(wget --version 2>/dev/null | head -n 1)")"
            else
                return 1
            fi
            ;;
        tmux)
            have tmux || return 1
            ver_of "$(tmux -V 2>/dev/null)"
            ;;
        *)
            have "$1" || return 1
            ver_of "$("$1" --version 2>/dev/null | head -n 1)"
            ;;
    esac
}

opt_get() {
    printf '%s\n' "$1" | tr '|' '\n' | sed -n "s/^$2=//p" | head -n 1
}

pm_detect() {
    for _p in apt-get dnf yum zypper pacman apk brew; do
        if have "$_p"; then
            echo "$_p"
            return 0
        fi
    done
    return 1
}

pm_cmd() {
    case "$1" in
        apt-get) echo "apt-get install -y $2" ;;
        dnf) echo "dnf install -y $2" ;;
        yum) echo "yum install -y $2" ;;
        zypper) echo "zypper --non-interactive install $2" ;;
        pacman) echo "pacman -S --noconfirm $2" ;;
        apk) echo "apk add $2" ;;
        brew) echo "brew install $2" ;;
    esac
}

npm_prefix_writable() {
    have npm || return 1
    _np="$(npm config get prefix 2>/dev/null)"
    [ -n "$_np" ] && [ -d "$_np" ] && [ -w "$_np" ] || return 1
    [ ! -e "$_np/lib/node_modules" ] || [ -w "$_np/lib/node_modules" ]
}

# ── 결과 기록 ────────────────────────────────────────────────────────────
TABLE=""
MISSING=""
PY_OLD=""
DONE_NAMES=" "
SEEN_CLAUDE=0
SEEN_CODEX=0

dep() {
    say "DEP $1 $2 $3"
    TABLE="${TABLE}$(printf '  %-10s %-8s %s' "$1" "$2" "$3")
"
    if [ "$2" = "missing" ]; then
        MISSING="${MISSING:+$MISSING }$1"
    fi
}

cmd_hint() { say "CMD $1 $2"; }

recheck() {
    rehash
    _rv="$(tool_version "$1")" || return 1
    ver_ge "$_rv" "$2" || return 1
    printf '%s\n' "${_rv:-ok}"
}

# ── 전용 사다리: Claude Code ─────────────────────────────────────────────
ladder_claude() {
    _native=""
    if have curl; then
        _native="curl -fsSL $CLAUDE_NATIVE_URL | bash"
    elif have wget; then
        # 공식 문서에 wget 형은 없다 — 같은 스크립트를 받는 동등 명령이라는 것은 추정
        _native="wget -qO- $CLAUDE_NATIVE_URL | bash"
    fi
    _npm=""
    _nv="$(tool_version node 2>/dev/null)" || _nv=""
    # npm 대안은 Node 22 이상 + 전역 prefix 가 사용자 쓰기 가능할 때만(관리자 권한으로 돌리지 않는다)
    if npm_prefix_writable && ver_ge "$_nv" "22"; then
        _npm="npm install -g $CLAUDE_NPM_PKG"
    fi
    _run="$_native"
    if [ -n "$T_CLAUDE" ]; then
        _run="$T_CLAUDE"
    fi
    if [ -n "$_run$_npm" ] && consent "Claude Code(공식 네이티브 설치, sudo 없음)" "${_native:-$_npm}"; then
        if [ -n "$_run" ]; then
            say "실행: $_native"
            sh -c "$_run" || warn "Claude Code 공식 설치 실패"
            if _got="$(recheck claude "")"; then
                dep claude user "$_got"
                return 0
            fi
        fi
        if [ -n "$_npm" ]; then
            say "실행: $_npm"
            sh -c "$_npm" || warn "npm 설치 실패"
            if _got="$(recheck claude "")"; then
                dep claude user "$_got (npm)"
                return 0
            fi
        fi
    fi
    if [ -n "$_native" ]; then
        cmd_hint claude "$_native"
    else
        cmd_hint claude "curl 또는 wget 이 필요하다 — https://code.claude.com/docs/en/setup"
    fi
    if [ -n "$_npm" ]; then
        cmd_hint claude "$_npm"
    fi
    return 1
}

# ── 전용 사다리: Codex CLI ───────────────────────────────────────────────
ladder_codex() {
    _native=""
    if have curl; then
        _native="curl -fsSL $CODEX_NATIVE_URL | sh"
    elif have wget; then
        # README 에 wget 형은 없다 — 동등 명령이라는 것은 추정
        _native="wget -qO- $CODEX_NATIVE_URL | sh"
    fi
    _npm=""
    if npm_prefix_writable; then
        _npm="npm install -g $CODEX_NPM_PKG"
    fi
    _brew=""
    if have brew; then
        _brew="brew install --cask codex"
    fi
    _run="$_native"
    if [ -n "$T_CODEX" ]; then
        _run="$T_CODEX"
    fi
    if [ -n "$_run$_npm$_brew" ] && consent "Codex CLI(공식 standalone 설치, sudo 없음)" "${_native:-${_npm:-$_brew}}"; then
        if [ -n "$_run" ]; then
            say "실행: $_native"
            # PATH 에 ~/.local/bin 이 이미 들어 있으므로 설치 스크립트가 셸 프로필을 따로 고치지 않는다
            env PATH="$PATH" sh -c "$_run" || warn "Codex 공식 설치 실패"
            if _got="$(recheck codex "")"; then
                dep codex user "$_got"
                return 0
            fi
        fi
        for _alt in "$_npm" "$_brew"; do
            [ -n "$_alt" ] || continue
            say "실행: $_alt"
            sh -c "$_alt" || warn "실패: $_alt"
            if _got="$(recheck codex "")"; then
                dep codex user "$_got"
                return 0
            fi
        done
    fi
    if [ -n "$_native" ]; then
        cmd_hint codex "$_native"
    else
        cmd_hint codex "curl 또는 wget 이 필요하다 — https://github.com/openai/codex"
    fi
    [ -n "$_npm" ] && cmd_hint codex "$_npm"
    [ -n "$_brew" ] && cmd_hint codex "$_brew"
    return 1
}

# ── 전용 사다리: node(nodejs.org 공식 바이너리 → ~/.local/share/node) ─────
node_user_install() {
    case "$(uname -s)" in
        Linux) _os=linux ;;
        Darwin) _os=darwin ;;
        *) warn "node: 지원하지 않는 OS"; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) _ar=x64 ;;
        aarch64|arm64) _ar=arm64 ;;
        *) warn "node: 지원하지 않는 CPU"; return 1 ;;
    esac
    have python3 || { warn "node: index.json 해석에 python3 가 필요하다"; return 1; }
    _nt="$(mktemp -d)" || return 1
    if ! fetch_to "$NODE_DIST/index.json" "$_nt/index.json"; then
        warn "node: index.json 을 받지 못했다"
        rm -rf "$_nt"
        return 1
    fi
    _v="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(next(x["version"] for x in d if x.get("lts")))' "$_nt/index.json" 2>/dev/null)"
    if [ -z "$_v" ]; then
        warn "node: LTS 판을 찾지 못했다"
        rm -rf "$_nt"
        return 1
    fi
    _f="node-$_v-$_os-$_ar.tar.gz"
    if ! fetch_to "$NODE_DIST/$_v/$_f" "$_nt/$_f" || ! fetch_to "$NODE_DIST/$_v/SHASUMS256.txt" "$_nt/SHASUMS256.txt"; then
        warn "node: $_f 또는 SHASUMS256.txt 를 받지 못했다"
        rm -rf "$_nt"
        return 1
    fi
    _exp="$(awk -v f="$_f" '$2==f{print $1}' "$_nt/SHASUMS256.txt")"
    _act="$(sha256_of "$_nt/$_f")" || _act=""
    if [ -z "$_exp" ] || [ "$_exp" != "$_act" ]; then
        warn "node: SHASUMS256 대조 실패 — 설치하지 않는다"
        rm -rf "$_nt"
        return 1
    fi
    _dest="$HOME/.local/share/node/$_v"
    mkdir -p "$_dest" "$HOME/.local/bin" || { rm -rf "$_nt"; return 1; }
    if ! tar -xzf "$_nt/$_f" -C "$_dest" --strip-components=1; then
        warn "node: 압축 해제 실패"
        rm -rf "$_nt"
        return 1
    fi
    rm -rf "$_nt"
    for _b in node npm npx; do
        _l="$HOME/.local/bin/$_b"
        if [ -e "$_l" ] && [ ! -L "$_l" ]; then
            warn "node: $_l 이 링크가 아닌 파일이라 덮어쓰지 않는다"
            continue
        fi
        ln -sfn "$_dest/bin/$_b" "$_l"
    done
    say "node $_v 를 $_dest 에 설치했다(SHASUMS256 일치)"
    return 0
}

ladder_node_user() {
    _desc="nodejs.org 공식 바이너리(최신 LTS)를 ~/.local/share/node 에 풀고 ~/.local/bin 에 링크"
    if consent "node 18.18 이상(sudo 없음)" "$_desc"; then
        if [ -n "$T_NODE" ]; then
            sh -c "$T_NODE" || warn "node 설치 실패"
        else
            node_user_install || warn "node 사용자 공간 설치 실패"
        fi
        if _got="$(recheck node "$1")"; then
            dep node user "$_got"
            return 0
        fi
    fi
    cmd_hint node "$_desc (이 스크립트를 --yes 로 다시 실행하면 자동)"
    return 1
}

# ── 패키지 관리자 단계 ──────────────────────────────────────────────────
ladder_pm() {
    _name="$1"
    _min="$2"
    _opts="$3"
    _pm="$(pm_detect)" || return 1
    _key="$_pm"
    [ "$_pm" = "apt-get" ] && _key=apt
    _pkg="$(opt_get "$_opts" "$_key")"
    [ -n "$_pkg" ] || return 1
    _pc="$(pm_cmd "$_pm" "$_pkg")"
    _stage=sudo
    _ran=0
    if [ "$_pm" = "brew" ]; then
        _stage=user
        if consent "$_name(brew 사용자 설치)" "$_pc"; then
            sh -c "$_pc" && _ran=1
        else
            cmd_hint "$_name" "$_pc"
            return 1
        fi
    elif [ "$(id -u)" = "0" ]; then
        sh -c "$_pc" && _ran=1
    elif [ "$NOSUDO" -eq 1 ]; then
        cmd_hint "$_name" "sudo $_pc"
        return 1
    elif ! have sudo; then
        cmd_hint "$_name" "$_pc (root 권한 필요 — sudo 없음)"
        return 1
    elif [ "$INTERACTIVE" -eq 1 ]; then
        printf '%s 을(를) 시스템 패키지로 설치하려면 관리자 권한이 필요하다. 명령: sudo %s\n' "$_name" "$_pc" >&2
        if [ "$YES" -eq 1 ] || ask_yn "sudo 로 실행할까?"; then
            sudo $_pc && _ran=1
        else
            cmd_hint "$_name" "sudo $_pc"
            return 1
        fi
    elif [ "$YES" -eq 1 ]; then
        sudo -n $_pc && _ran=1
        if [ "$_ran" -eq 0 ]; then
            cmd_hint "$_name" "sudo $_pc"
            return 1
        fi
    else
        cmd_hint "$_name" "sudo $_pc"
        return 1
    fi
    if [ "$_ran" -eq 1 ] && _got="$(recheck "$_name" "$_min")"; then
        dep "$_name" "$_stage" "$_got"
        return 0
    fi
    if [ "$_ran" -eq 1 ]; then
        _now="$(tool_version "$_name" 2>/dev/null)" || _now=""
        if [ -n "$_now" ]; then
            warn "$_name: 패키지 관리자 판 $_now 이(가) 하한 $_min 미만이다"
        fi
    fi
    cmd_hint "$_name" "sudo $_pc"
    return 1
}

# ── 한 도구 처리 ────────────────────────────────────────────────────────
process_line() {
    _line="$1"
    _name="${_line%%|*}"
    _rest="${_line#*|}"
    _min="${_rest%%|*}"
    _rest="${_rest#*|}"
    _need="${_rest%%|*}"
    _opts="${_rest#*|}"
    [ "$_opts" = "$_rest" ] && _opts=""
    [ -n "$_name" ] || return 0
    if [ -n "$ONLY" ] && [ "$ONLY" != "$_name" ]; then
        return 0
    fi
    case "$DONE_NAMES" in
        *" $_name "*) return 0 ;;
    esac
    DONE_NAMES="$DONE_NAMES$_name "
    [ "$_name" = "claude" ] && SEEN_CLAUDE=1
    [ "$_name" = "codex" ] && SEEN_CODEX=1

    _found=0
    _v=""
    if _v="$(tool_version "$_name")"; then
        _found=1
        if ver_ge "$_v" "$_min"; then
            dep "$_name" system "${_v:-ok}"
            return 0
        fi
    fi
    if [ "$_name" = "python3" ] && [ "$_found" -eq 1 ]; then
        PY_OLD="${_v:-unknown}"
        dep python3 missing "$PY_OLD < $_min"
        return 0
    fi
    if [ "$_found" -eq 1 ]; then
        _why="${_v:-?} < $_min"
    else
        _why="없음"
    fi

    # ② 사용자 공간
    _user="$(opt_get "$_opts" user)"
    case "$_name" in
        claude) ladder_claude && return 0 ;;
        codex) ladder_codex && return 0 ;;
        node) ladder_node_user "$_min" && return 0 ;;
        *)
            if [ -n "$_user" ] && [ "$_user" != "builtin" ]; then
                # 원격 판 requires.txt 의 명령이므로 claude·codex 와 같은 동의 규칙(대화 y/N, 비대화는 --yes 때만)
                if consent "$_name(사용자 공간 설치, sudo 없음)" "$_user"; then
                    say "사용자 공간 설치: $_user"
                    sh -c "$_user" || warn "$_name: 사용자 공간 설치 실패"
                    if _got="$(recheck "$_name" "$_min")"; then
                        dep "$_name" user "$_got"
                        return 0
                    fi
                else
                    cmd_hint "$_name" "$_user"
                fi
            fi
            ;;
    esac

    # ③ 패키지 관리자(+ sudo)
    ladder_pm "$_name" "$_min" "$_opts" && return 0

    if [ "$_need" = "optional" ]; then
        say "DEP $_name missing $_why (선택)"
        TABLE="${TABLE}$(printf '  %-10s %-8s %s' "$_name" missing "$_why (선택)")
"
        return 0
    fi
    dep "$_name" missing "$_why"
    return 0
}

# requires 목록(문자열) 처리 — rc: 0 / 3 누락 / 4 python 구판
run_reqs() {
    _tmp_list="$(mktemp)" || return 2
    printf '%s\n' "$1" | sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' > "$_tmp_list"
    while IFS= read -r _l; do
        process_line "$_l"
    done < "$_tmp_list"
    rm -f "$_tmp_list"
    if [ -n "$PY_OLD" ]; then
        return 4
    fi
    if [ -n "$MISSING" ]; then
        return 3
    fi
    return 0
}

deps_tail() {
    case "$1" in
        0) say "DEPS OK" ;;
        4) say "DEPS PYTHON_TOO_OLD $PY_OLD" ;;
        *) say "DEPS MISSING $MISSING" ;;
    esac
}

print_table() {
    say "결과표 (system=이미 있음 | user=사용자 공간 설치 | sudo=패키지 관리자 | missing=누락)"
    printf '%s' "$TABLE"
}

login_notes() {
    if [ "$SEEN_CLAUDE" -eq 1 ]; then
        say "처음이면 claude 를 실행한 뒤 /login 으로 로그인하라"
    fi
    if [ "$SEEN_CODEX" -eq 1 ]; then
        say "codex 는 codex login 으로 로그인하라(ChatGPT 계정 또는 API 키 — 자동화하지 않음), 그 뒤 Claude Code 안에서 /codex:setup 으로 준비 상태를 확인하라"
    fi
}

# ── 플러그인 연결 ───────────────────────────────────────────────────────
codex_plugin_connect() {
    if [ "$NOPLUGIN" -eq 1 ] || ! have claude; then
        if [ "$NOPLUGIN" -eq 1 ]; then
            warn "codex 플러그인 연결을 건너뛴다(--no-plugin)"
        else
            warn "claude 가 없어 codex 플러그인 연결을 건너뛴다"
        fi
        say "codex 플러그인 재실행 명령: $CODEX_PLUGIN_RERUN"
        return 0
    fi
    _ok=1
    if run_to claude plugin marketplace list 2>/dev/null | grep -q 'openai-codex'; then
        say "codex 마켓플레이스(openai-codex) 있음 — 추가 생략"
    else
        run_to claude plugin marketplace add openai/codex-plugin-cc || _ok=0
    fi
    if [ "$_ok" -eq 1 ]; then
        if run_to claude plugin list 2>/dev/null | grep -q 'codex@openai-codex'; then
            say "codex 플러그인(codex@openai-codex) 있음 — 설치 생략"
        else
            run_to claude plugin install codex@openai-codex || _ok=0
        fi
    fi
    if [ "$_ok" -eq 1 ]; then
        say "codex 플러그인 연결 완료"
    else
        warn "codex 플러그인 연결 실패(로그인 전이면 실패할 수 있다) — 로그인 뒤 아래 명령을 다시 실행하라"
        say "codex 플러그인 재실행 명령: $CODEX_PLUGIN_RERUN"
    fi
    return 0
}

harness_plugin_connect() {
    _hrerun="claude plugin marketplace add $1/src && claude plugin install harness@harness-marketplace"
    if [ "$NOPLUGIN" -eq 1 ] || ! have claude; then
        warn "harness 플러그인 연결을 건너뛴다"
        say "harness 플러그인 재실행 명령: $_hrerun"
        return 0
    fi
    if run_to claude plugin marketplace add "$1/src" && run_to claude plugin install harness@harness-marketplace; then
        HPLUG_OK=1
        say "harness 플러그인 연결 완료"
    else
        warn "harness 플러그인 연결 실패(로그인 전이면 실패할 수 있다) — 로그인 뒤 다시 실행하라"
        say "harness 플러그인 재실행 명령: $_hrerun"
    fi
}

# 대화 모드에서 갱신 전에 대상 판 requires.txt 로 도구를 대화형으로 갖춘다(엔진은 비대화로 다시 점검만 한다)
pre_deps_interactive() {
    [ "$INTERACTIVE" -eq 1 ] || return 0
    [ -d "$1/.git" ] || return 0
    git -C "$1" fetch -q origin --tags 2>/dev/null || return 0
    _pref="$(git -C "$1" tag -l 'v*' --sort=-v:refname | head -n 1)"
    [ -n "$_pref" ] || _pref="origin/HEAD"
    _preq="$(git -C "$1" show "$_pref:requires.txt" 2>/dev/null)" || return 0
    [ -n "$_preq" ] || return 0
    run_reqs "$_preq"
    return 0
}

# oUpdate apply 실행 + 큰 변경(breaking, rc=7) 처리
#   대화: 엔진이 낸 요약을 보인 뒤 y/N 동의 → --accept-breaking 으로 다시 실행
#   비대화 + --yes: 무인 설치를 명시한 것으로 보고 처음부터 --accept-breaking 전달
#   비대화(--yes 없음): 넘기지 않는다 — rc=7 그대로 멈추고 재실행 명령 안내
# 사용: apply_update <HARNESS_HOME> <harness_update.py>
apply_update() {
    _ah="$1"
    _as="$2"
    _af="--non-interactive"
    [ "$YES" -eq 1 ] && _af="$_af --yes --accept-breaking"
    [ "$NOSUDO" -eq 1 ] && _af="$_af --no-sudo"
    # shellcheck disable=SC2086
    HARNESS_HOME="$_ah" HARNESS_AI_ROOT="$AI" python3 -B "$_as" apply --ai-root "$AI" $_af
    _aurc=$?
    [ "$_aurc" -eq 7 ] || return "$_aurc"
    if [ "$INTERACTIVE" -eq 1 ]; then
        if ask_yn "위 큰 변경(breaking) 요약을 확인했다. 이대로 갱신할까?"; then
            # shellcheck disable=SC2086
            HARNESS_HOME="$_ah" HARNESS_AI_ROOT="$AI" python3 -B "$_as" apply --ai-root "$AI" $_af --accept-breaking
            return $?
        fi
        say "큰 변경 갱신을 거부해 멈췄다(현행 유지)."
        return 7
    fi
    say "큰 변경(breaking)이 있어 멈췄다(rc=7, 현행 유지). 요약을 확인한 뒤 --yes 를 붙여 다시 실행하거나 대화 모드로 실행하라:"
    say "  sh install-online.sh --home '$HOME_P' --yes"
    return 7
}

rc_block_value() {
    for _rf in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        [ -f "$_rf" ] || continue
        _val="$(sed -n '/^# >>> harness PATH/,/^# <<< harness PATH/p' "$_rf" \
            | sed -n "s/^[[:space:]]*export[[:space:]]*$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" | head -n 1)"
        if [ -n "$_val" ]; then
            printf '%s\n' "$_val"
            return 0
        fi
    done
    return 1
}

# ═══ 진입: --deps-only / --only ═════════════════════════════════════════
if [ "$DEPS_ONLY" -eq 1 ] || [ -n "$ONLY" ]; then
    if [ -z "$REQ_FILE" ]; then
        case "$0" in
            */*) REQ_FILE="$(dirname "$0")/requires.txt" ;;
            *) REQ_FILE="./requires.txt" ;;
        esac
    fi
    if [ ! -f "$REQ_FILE" ]; then
        printf '오류: requires 파일이 없다: %s\n' "$REQ_FILE" >&2
        say "DEPS MISSING requires.txt"
        exit 2
    fi
    run_reqs "$(cat "$REQ_FILE")"
    _drc=$?
    if [ "$DEPS_ONLY" -eq 0 ] && [ "$ONLY" = "codex" ] && [ "$_drc" -eq 0 ]; then
        codex_plugin_connect
    fi
    login_notes
    deps_tail "$_drc"
    exit "$_drc"
fi

# ═══ 진입: 전체 설치 ═══════════════════════════════════════════════════
say "== Claude Code 하네스 온라인 설치 =="

# 1. 프로젝트 홈
if [ -z "$HOME_P" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
        HOME_P="$(ask_line "프로젝트 홈 폴더 [기본 $HOME/Project]: ")"
    fi
    [ -n "$HOME_P" ] || HOME_P="$HOME/Project"
fi
case "$HOME_P" in
    "~") HOME_P="$HOME" ;;
    "~/"*) HOME_P="$HOME/${HOME_P#\~/}" ;;
    /*) ;;
    *) HOME_P="$(pwd)/$HOME_P" ;;
esac
if ! mkdir -p "$HOME_P/AI"; then
    printf '오류: %s/AI 를 만들 수 없다\n' "$HOME_P" >&2
    exit 2
fi
HOME_P="$(cd "$HOME_P" && pwd -P)"
AI="$HOME_P/AI"
H="$AI/.harness"
say "프로젝트 홈: $HOME_P"
say "설치 위치:   $AI"

# 부트스트랩 도구(git·python3)
run_reqs "$BOOTSTRAP_REQS"
_brc=$?
if [ "$_brc" -ne 0 ]; then
    print_table
    deps_tail "$_brc"
    say "필수 도구가 없어 설치를 멈춘다. 위 CMD 를 실행한 뒤 다시 실행하라"
    exit "$_brc"
fi

# 2. 기존 설치 감지 → oUpdate 자동
if [ -f "$H/update_state.json" ]; then
    _up="$H/active/plugins/harness/scripts/harness_update.py"
    [ -f "$_up" ] || _up="$H/src/plugins/harness/scripts/harness_update.py"
    say "기존 설치를 찾았다 → oUpdate 로 갱신한다"
    pre_deps_interactive "$H/src"
    apply_update "$H" "$_up"
    exit $?
fi
_lh="${HARNESS_HOME:-}"
[ -n "$_lh" ] || _lh="$(rc_block_value HARNESS_HOME 2>/dev/null)" || _lh=""
[ -n "$_lh" ] || _lh="$HOME/.harness"
_lh="${_lh%/}"
if [ "$_lh" != "$H" ] && [ -d "$_lh/src/.git" ] && [ -L "$_lh/current" ]; then
    say "레거시 설치를 찾았다($_lh) → oUpdate 로 이전·갱신한다"
    _bt="$(mktemp -d)" || exit 2
    git -C "$_lh/src" fetch -q origin --tags || { warn "원격 fetch 실패"; rm -rf "$_bt"; exit 2; }
    _ref="$(git -C "$_lh/src" tag -l 'v*' --sort=-v:refname | head -n 1)"
    [ -n "$_ref" ] || _ref="origin/HEAD"
    for _f in harness_update.py harness_ai_root.py; do
        if ! git -C "$_lh/src" show "$_ref:plugins/harness/scripts/$_f" > "$_bt/$_f" 2>/dev/null; then
            warn "원격 $_ref 에 $_f 가 없다(1.3.0 이상 필요)"
            rm -rf "$_bt"
            exit 2
        fi
    done
    pre_deps_interactive "$_lh/src"
    apply_update "$_lh" "$_bt/harness_update.py"
    _urc=$?
    rm -rf "$_bt"
    exit "$_urc"
fi

# 3·4. clone → 최신 태그
mkdir -p "$H" || exit 2
_safe_url="$(redact_url "$DIST_URL")"
if [ -d "$H/src/.git" ]; then
    say "기존 clone 을 갱신한다: $_safe_url"
    git -C "$H/src" fetch -q origin --tags || { warn "fetch 실패"; exit 2; }
else
    say "clone: $_safe_url → $H/src"
    git clone -q "$DIST_URL" "$H/src" || { printf '오류: clone 실패(%s)\n' "$_safe_url" >&2; exit 2; }
fi
_tag="$(git -C "$H/src" tag -l 'v*' --sort=-v:refname | head -n 1)"
if [ -n "$_tag" ]; then
    git -C "$H/src" -c advice.detachedHead=false checkout -q "$_tag" || warn "태그 $_tag checkout 실패 — 기본 브랜치로 진행"
    say "판: $_tag"
else
    say "판: 기본 브랜치 HEAD(태그 없음)"
fi

# 3. 전체 도구 점검(requires.txt)
if [ -f "$H/src/requires.txt" ]; then
    run_reqs "$(cat "$H/src/requires.txt")"
    _rrc=$?
else
    warn "배포본에 requires.txt 가 없다 — 부트스트랩 목록만 확인했다"
    _rrc=0
fi
if [ "$_rrc" -ne 0 ]; then
    print_table
    deps_tail "$_rrc"
    login_notes
    say "필수 도구가 없어 설치를 멈춘다. 위 CMD 를 실행하거나 --yes 로 다시 실행하라"
    exit "$_rrc"
fi

# 5. oUpdate apply → releases·active·facade
_up="$H/src/plugins/harness/scripts/harness_update.py"
if [ ! -f "$_up" ]; then
    printf '오류: 배포본에 %s 가 없다(1.3.0 이상 필요)\n' "plugins/harness/scripts/harness_update.py" >&2
    exit 2
fi
say "oUpdate apply 실행"
apply_update "$H" "$_up"
_arc=$?
if [ "$_arc" -ne 0 ] && [ "$_arc" -ne 5 ]; then
    printf '오류: oUpdate apply 실패 rc=%s\n' "$_arc" >&2
    exit "$_arc"
fi

# 6·7. install.sh(링크·rc·oio venv·fastmcp·~/.harness/venv 호환 링크·settings·tmux)
#   venv·pip·호환 링크는 install.sh 가 맡는다(HARNESS_HOME 을 넘기면 <AI>/.harness/venv/oio 에 만든다).
#   원래 PATH 로 실행해 PATH 블록 필요 여부를 정확히 판정하게 한다
_ins="$H/active/install.sh"
[ -f "$_ins" ] || _ins="$H/src/install.sh"
if [ -f "$_ins" ]; then
    _insh=sh
    have bash && _insh=bash
    _rcf=""
    [ "$NORC" -eq 1 ] && _rcf="--no-rc"
    # shellcheck disable=SC2086
    PATH="$ORIG_PATH" HARNESS_HOME="$H" HARNESS_AI_ROOT="$AI" CLAUDE_PROJECT_ROOTS="$HOME_P" "$_insh" "$_ins" --non-interactive $_rcf || warn "install.sh 실패"
else
    warn "install.sh 를 찾지 못했다"
fi

# 8. project_home · install.json
mkdir -p "$HOME/.config/claude-harness"
printf '%s\n' "$HOME_P" > "$HOME/.config/claude-harness/project_home"
_rev="$(git -C "$H/src" rev-parse --short=12 HEAD 2>/dev/null)" || _rev=""
python3 - "$H/install.json" "$HOME_P" "$AI" "$_rev" <<'PYEOF'
import datetime, json, sys
path, home, ai, rev = sys.argv[1:5]
data = {
    "project_home": home,
    "ai_root": ai,
    "installed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "installer_rev": rev,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=1)
    fh.write("\n")
PYEOF

# 9. 플러그인(선택)
HPLUG_OK=0
harness_plugin_connect "$H"
codex_plugin_connect
# 플러그인이 생긴 뒤 facade 재정리(멱등) — apply 때는 플러그인이 없어 .mcp.json·CLAUDE.md 가 플러그인 없는 상태로 만들어졌다
if [ "$HPLUG_OK" -eq 1 ]; then
    _air="$H/active/plugins/harness/scripts/harness_ai_root.py"
    [ -f "$_air" ] || _air="$H/src/plugins/harness/scripts/harness_ai_root.py"
    if [ -f "$_air" ]; then
        say "플러그인 연결 뒤 AI facade 재정리"
        python3 -B "$_air" ensure --harness-home "$H" --ai-root "$AI" || warn "AI facade 재정리 실패 — 나중에 python3 -B '$_air' ensure --harness-home '$H' --ai-root '$AI' 를 실행하라"
    else
        warn "harness_ai_root.py 를 찾지 못해 facade 재정리를 건너뛴다"
    fi
fi

# 10. ~/.claude/{hooks,scripts,agents} 링크(없을 때만)
for _x in hooks scripts agents; do
    [ -e "$AI/.claude/$_x" ] || continue
    if [ -e "$HOME/.claude/$_x" ] || [ -L "$HOME/.claude/$_x" ]; then
        continue
    fi
    mkdir -p "$HOME/.claude" && ln -s "$AI/.claude/$_x" "$HOME/.claude/$_x"
done

print_table
say "설치 완료: $AI (oUpdate rc=$_arc)"
case ":$ORIG_PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) say "PATH 에 ~/.local/bin 이 없었다 — install.sh 가 셸 rc 에 PATH 를 추가했다" ;;
esac
say '새 셸을 열거나 exec $SHELL -l 을 실행하면 cc 를 바로 쓸 수 있다'
SEEN_CLAUDE=1
SEEN_CODEX=1
login_notes
exit 0
