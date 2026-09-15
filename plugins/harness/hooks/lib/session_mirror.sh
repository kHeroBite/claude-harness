# session-env 쓰기를 CLAUDE_CONFIG_DIR / HOME 반대편 base 에도 반영하는 공용 미러 함수.
#
# 배경 (사이클46 축②):
#   hook 스크립트들이 세션 상태를 쓸 때 base 가 두 갈래로 갈린다.
#     A) "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<UUID>/..."
#     B) "$HOME/.claude/session-env/<UUID>/..."          ← ${HOME} 하드코딩
#   CLAUDE_CONFIG_DIR 이 설정된 세션에서는 A 와 B 가 서로 다른 파일을 가리키므로
#   "쓴 쪽"과 "읽는 쪽"이 어긋나 상태가 유실된다.
#   본 파일은 원 쓰기 성공 후 반대편 base 에 같은 내용을 복제해 양쪽을 정합시킨다.
#
# ★설계 안전 불변식 5 (전부 지킨다)★
#   1. fail-soft   — 미러 실패가 원 쓰기를 실패시키지 않는다. ★원 쓰기가 정본★
#   2. UUID 경계   — 경로에서 추출한 UUID 하위에만 쓴다. 반대편도 반드시 같은 UUID.
#                    (실측 2026-08-27: HOME 591개 · CFG 17개 UUID 실존 —
#                     경계 이탈 시 타 세션 오염 = 세션격리 §(a) 위반)
#   3. flock 미획득 — 미러는 원본의 .lock 을 절대 잡지 않는다. 호출자는 lock 밖에서 부른다.
#   4. 멱등        — tmp→mv 원자 교체. 같은 내용 2회 써도 안전.
#   5. .lock/.tmp 미러 금지 — 락 파일·임시 파일은 복제하지 않는다.
#
# ★dash 호환★ — hook 이 /bin/sh 로 실행되는 경우가 있어 POSIX sh 문법만 사용한다.
#   금지: [[ ]] · 배열 · ${PIPESTATUS} · ${BASH_SOURCE} · local -a · =~
#   (`local` 은 POSIX 표준은 아니나 dash/bash/ash 전부 지원하므로 사용한다)
#
# 계약:
#   _mirror_peer_path <절대경로>   stdout=반대편 경로, rc=0 / 미러 대상 아니면 stdout 공백, rc=1
#   _mirror_file      <절대경로>   원본을 반대편에 복제. ★항상 rc=0 (fail-soft)★
#   _mirror_file_strict <절대경로> 위와 동일하나 실패 시 rc≠0. ★검증 전용 — hook 에서 쓰지 말 것★
#
# ★자기 사각지대 (사이클40 A2 교훈 — 숨기지 않고 적는다)★
#   S-1. 본 함수는 "단일 파일 복제"만 한다. 디렉토리 트리·삭제(rm)·rename 은 미러하지 않는다.
#        ⇒ 원본이 삭제되어도 반대편에는 남는다. 정리(cleanup) 경로는 별도 대응이 필요하다.
#   S-2. 경합 시 최종 승자를 보장하지 않는다. 원본 쓰기와 미러 사이에 다른 쓰기가 끼면
#        반대편이 한 세대 뒤쳐질 수 있다. 정본은 언제나 원본 쪽이다.
#   S-3. UUID 형식은 36자 hex-hyphen 정규형만 인정한다. 비정규 UUID 디렉토리는 미러되지 않는다.
#   S-4. 반대편 base 가 존재하지 않으면 mkdir 로 생성한다. 즉 미러는 새 UUID 디렉토리를
#        반대편에 만들 수 있다. 이는 의도된 동작이나, 디스크 사용이 양쪽으로 늘어난다.
#   S-5. 심볼릭 링크를 따라가지 않고 일반 파일로만 복제한다.

# --- 미러 대상 여부 판정 + 반대편 경로 산출 ---------------------------------
# 입력: 원본 절대경로
# 출력(stdout): 반대편 절대경로
# rc: 0=미러 대상 / 1=미러 대상 아님(정상 · 조용히 skip)
_mirror_peer_path() {
    _mp_src="$1"

    # (a) 인자 검증 — 절대경로만 허용
    case "$_mp_src" in
        /*) ;;
        *) return 1 ;;
    esac

    # (b) 불변식 5 — .lock / .tmp 계열은 미러 금지
    case "$_mp_src" in
        *.lock|*.lock.*|*.tmp|*.tmp.*|*.mig.*) return 1 ;;
    esac

    # (c) 두 base 산출. 미설정이거나 동일하면 미러 불필요 (멱등 — 불변식 4)
    _mp_cfg="${CLAUDE_CONFIG_DIR:-}"
    _mp_home="${HOME:-}/.claude"
    [ -z "$_mp_cfg" ] && return 1
    [ -z "${HOME:-}" ] && return 1
    [ "$_mp_cfg" = "$_mp_home" ] && return 1

    _mp_cfg_root="${_mp_cfg}/session-env/"
    _mp_home_root="${_mp_home}/session-env/"

    # (d) 어느 base 에 속하는지 판정하고 나머지(<UUID>/<rel>)를 잘라낸다
    _mp_rest=""
    _mp_dstroot=""
    case "$_mp_src" in
        "${_mp_cfg_root}"*)
            _mp_rest="${_mp_src#"$_mp_cfg_root"}"
            _mp_dstroot="$_mp_home_root"
            ;;
        "${_mp_home_root}"*)
            _mp_rest="${_mp_src#"$_mp_home_root"}"
            _mp_dstroot="$_mp_cfg_root"
            ;;
        *)
            return 1
            ;;
    esac
    [ -z "$_mp_rest" ] && return 1

    # (e) ★불변식 2 — UUID 경계 엄수★
    #     <rest> 의 첫 세그먼트를 UUID 로 보고 36자 정규형인지 검사한다.
    #     ⇒ 반대편 경로는 반드시 같은 UUID 하위가 된다 (문자열 재조립이 아니라
    #        검증된 UUID + 검증된 상대경로로만 만들기 때문).
    _mp_uuid="${_mp_rest%%/*}"
    _mp_rel="${_mp_rest#*/}"
    # UUID 하위에 파일이 없으면(=rest 가 UUID 뿐) 미러 대상 아님
    [ "$_mp_rel" = "$_mp_rest" ] && return 1
    [ -z "$_mp_rel" ] && return 1

    # 36자 hex-hyphen 정규형 검증 (dash 호환 — case 글롭만 사용, =~ 금지)
    case "$_mp_uuid" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac

    # (f) ★경로 이탈 방어★ — 상대경로에 .. 세그먼트가 있으면 UUID 경계를 벗어날 수 있다.
    #     예: <UUID>/../<타UUID>/state → 정규화되면 타 세션. 즉시 거부한다.
    case "/$_mp_rel/" in
        */../*) return 1 ;;
    esac
    # 절대경로 재진입·중복 슬래시도 거부 (방어적)
    case "$_mp_rel" in
        /*|*//*) return 1 ;;
    esac

    printf '%s%s/%s\n' "$_mp_dstroot" "$_mp_uuid" "$_mp_rel"
    return 0
}

# --- 실제 복제 (내부 구현 · rc 를 그대로 돌려준다) ---------------------------
# 이 함수는 검증용이며, hook 은 아래 _mirror_file (fail-soft) 을 쓴다.
_mirror_file_strict() {
    _mf_src="$1"
    [ -n "$_mf_src" ] || return 2

    # 원본이 없거나 일반 파일이 아니면 복제할 게 없다 (불변식 5 · S-5)
    [ -f "$_mf_src" ] || return 3
    [ -L "$_mf_src" ] && return 3

    _mf_dst=$(_mirror_peer_path "$_mf_src") || return 1
    [ -n "$_mf_dst" ] || return 1

    _mf_dstdir=$(dirname "$_mf_dst")
    mkdir -p "$_mf_dstdir" 2>/dev/null || return 4

    # ★불변식 4 — tmp→mv 원자 교체 (멱등)★
    # ★불변식 3 — 원본의 .lock 을 잡지 않는다. 여기서 flock 을 쓰지 않는다.★
    _mf_tmp="${_mf_dst}.mirror.$$"
    if cat "$_mf_src" > "$_mf_tmp" 2>/dev/null; then
        if mv -f "$_mf_tmp" "$_mf_dst" 2>/dev/null; then
            return 0
        fi
    fi
    rm -f "$_mf_tmp" 2>/dev/null
    return 5
}

# --- 공개 진입점 (★불변식 1 — 항상 rc=0★) ----------------------------------
# hook 에서는 반드시 이 함수를 호출한다. 어떤 실패도 원 쓰기를 되돌리지 않는다.
_mirror_file() {
    _mirror_file_strict "$1" 2>/dev/null
    return 0
}

# --- 삭제 미러 (사이클46 odev-3 — S-1 해소) ---------------------------------
# 배경:
#   `_mirror_file` 은 복제 전용이라 ★원본이 삭제되면 반대편에 잔존한다★ (S-1).
#   `classification` 잔류는 statusline/게이트 오판을 부르므로 실질 위험이다.
#   본 함수는 원본 삭제 직후 반대편의 같은 파일을 지워 양쪽을 정합시킨다.
#
# ★불변식 5 동일 적용★
#   1. fail-soft   — `_mirror_delete` 는 항상 rc=0. 삭제 미러 실패가 원 삭제를 되돌리지 않는다.
#   2. UUID 경계   — `_mirror_peer_path` 를 그대로 재사용한다. 경로 산출 로직을 복제하지 않으므로
#                    `..` 탈출·비정규 UUID·session-env 밖 경로 거부가 자동으로 동일하게 적용된다.
#                    ★삭제는 복제보다 위험하다 — 잘못 지우면 복구가 없다.★ 그래서 경계 판정을
#                    새로 짜지 않고 이미 변이 테스트로 생존이 확인된 함수에 위임한다.
#   3. flock 미획득 — flock 을 잡지 않는다. 호출자는 lock 밖에서 부른다.
#   4. 멱등        — ★이미 없는 파일 삭제는 성공(rc=0)으로 처리한다.★ 2회 호출해도 안전하다.
#   5. .lock/.tmp 제외 — `_mirror_peer_path` 가 rc=1 로 거부하므로 삭제되지 않는다.
#
# ★추가 안전 — 디렉토리는 절대 지우지 않는다★
#   `rm -f` 만 쓰고 `-r` 을 쓰지 않는다. 반대편 경로가 디렉토리면 명시적으로 거부한다.
#   ⇒ 인자를 잘못 줘도 트리 삭제로 번지지 않는다.
#
# 계약:
#   _mirror_delete_strict <절대경로>  반대편 삭제. rc=0 성공/이미없음 · rc≠0 실패
#   _mirror_delete        <절대경로>  위와 동일하나 ★항상 rc=0 (fail-soft)★ — hook 은 이것만 호출
#
# ⚠️ 사용법: ★원본을 삭제한 "직후"에 호출한다.★ 원본 경로를 인자로 준다(반대편 경로가 아니다).
#    원본 존재 여부는 검사하지 않는다 — 이미 지워진 뒤에 불리는 것이 정상이기 때문이다.
_mirror_delete_strict() {
    _md_src="$1"
    [ -n "$_md_src" ] || return 2

    # 반대편 경로 산출 — 경계 검증 전량 위임 (불변식 2/5)
    _md_dst=$(_mirror_peer_path "$_md_src") || return 1
    [ -n "$_md_dst" ] || return 1

    # ★디렉토리 거부★ — 트리 삭제로 번지는 것을 물리적으로 막는다
    [ -d "$_md_dst" ] && return 6

    # ★불변식 4 — 멱등★ 이미 없으면 지울 것이 없으므로 성공
    [ -e "$_md_dst" ] || return 0

    # ★불변식 3 — flock 미획득★
    rm -f "$_md_dst" 2>/dev/null || return 5
    # 실제로 사라졌는지 확인 (silent 실패 방지)
    [ -e "$_md_dst" ] && return 5
    return 0
}

_mirror_delete() {
    _mirror_delete_strict "$1" 2>/dev/null
    return 0
}
