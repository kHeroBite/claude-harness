#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 세션 소속 고아 팀에이전트 프로세스를 탐지하는 공용 라이브러리 (agents/ 무의존)
#
# 배경: 2026-08-17 고아 팀에이전트 5개 사고.
#   - 결함 A: SessionStart.sh boot-stale이 메타파일만 지우고 프로세스는 살려둠
#   - 결함 B: oinit/ofinish의 모든 탐지 경로가 agents/ 디렉토리 단일 의존
#             → agents/ 소멸 시 "정리 대상 없음"으로 오판정
#   - 결함 C: agents/ 삭제 전 "잔존 0건" 검증 게이트 부재
#   증적: .claude/evidence/agent_orphan_cleanup_20260817.md
#
# 설계 원칙:
#   1. agents/ 를 절대 참조하지 않는다 — ps 만으로 대상을 산출한다.
#   2. NUL 함정 회피 — /proc/{pid}/cmdline 직접 grep 금지. ps -eo pid=,args= 단일 방식.
#      (실측: naive grep = 0건 오판정 vs ps = 5건 정상 탐지)
#   3. 메인 프로세스 보호(L-213) — --agent-id 없는 claude 는 절대 대상 아님.
#   4. 세션 격리 — --parent-session-id 가 인자 UUID 와 일치하는 것만 대상.
#   5. 자기 자신($$ 및 조상)은 대상에서 제외한다.
#
# 긴급 정지 스위치 (의도적 설계):
#   이 파일 하나를 삭제/이동하면 이를 source 하는 hook(H-1 write_guard / H-2 SessionStart)이
#   전부 fail-open 되어 아무 것도 차단·회수하지 않는다. 문제 발생 시 즉시 탈출 경로다.
#     mv orphan_scan.sh orphan_scan.sh.disabled   # 무력화
#     mv orphan_scan.sh.disabled orphan_scan.sh   # 복구
#
# 제공 함수:
#   orphan_scan_pids <uuid>    — 고아 PID 목록을 개행 구분으로 stdout 출력 (없으면 무출력)
#   orphan_scan_count <uuid>   — 고아 개수를 정수로 stdout 출력 (실패 시에도 반드시 정수)
#   orphan_scan_detail <uuid>  — "PID<TAB>요약" 형태 진단 출력 (사람이 읽는 용도)
#   orphan_scan_reap <uuid>    — TERM → 대기 → KILL 로 회수. 회수한 개수를 stdout 출력
#
# 반환 규약 (fail-open 계약 — 호출부가 반드시 지켜야 함):
#   함수가 비어 있거나 정수가 아닌 값을 돌려주면 호출부는 "검사 실패"로 간주하고 **통과**시킨다.
#   검사가 성공했고 개수 > 0 일 때만 차단(fail-closed)한다.
#   이유: hook 자체의 오류로 4개 프로젝트 세션이 멈추는 것이 고아 잔존보다 큰 사고다.

# --- 중복 source 방지 ---
if [[ -n "${_ORPHAN_SCAN_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_ORPHAN_SCAN_LOADED=1

# UUID 형식 검증 — 오탐으로 무관 프로세스를 잡는 사고 방지.
# 빈 문자열이나 짧은 문자열이 인자로 들어와 ps 전체가 매칭되는 것을 막는다.
_orphan_uuid_valid() {
  local u="$1"
  [[ -n "$u" ]] || return 1
  [[ ${#u} -ge 8 ]] || return 1
  # 허용 문자: 영숫자와 하이픈만 (grep -F 를 쓰지만 방어적으로 한 번 더 제한)
  case "$u" in
    *[!0-9A-Za-z-]*) return 1 ;;
  esac
  return 0
}

# 자기 자신과 조상 PID 집합을 산출 — 스스로를 죽이거나 카운트하지 않기 위함.
_orphan_self_chain() {
  local p="$$" i=0
  while [[ -n "$p" && "$p" != "0" && "$p" != "1" && $i -lt 32 ]]; do
    echo "$p"
    # /proc/<pid>/stat 의 4번째 필드가 PPID. 단, 2번째 필드(comm)에 공백이 들어가면
    # 필드가 밀리므로 comm 을 통째로 제거한 뒤 파싱한다(예: "(sh -c foo)").
    p=$(sed 's/^[0-9]* (.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $2}')
    # 숫자가 아니면 체인 추적 중단 (오염된 값으로 계속 진행하지 않는다)
    case "$p" in
      ''|*[!0-9]*) break ;;
    esac
    i=$((i + 1))
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# 대상 판정 (3차 보강 2026-08-17) — hook·oio 양쪽이 공유하는 단일 판정 로직
#
# 배경: 1차 구현은 hook(bash 정규식)과 oio(python 정규식)에 판정 로직을 각각 두었다.
#       그 결과 **동일한 결함을 양쪽이 공유**해 이중 방어가 성립하지 않았다(otest-1 실측).
#       B1(상위 디렉토리) / B2(./) / B4(../) 가 두 계층을 동시에 통과했다.
#       → 판정 로직을 이 파일 한 곳에만 두고 양쪽이 호출하도록 통일한다.
#
# orphan_target_uuid <경로>
#   보호 대상이면 해당 세션 UUID 를 출력하고 rc=0.
#   대상이 아니면 아무것도 출력하지 않고 rc=1.
#
# 보호 대상 정의:
#   ① session-env/<uuid>/agents            (하위 경로 포함)
#   ② session-env/<uuid>/panes             (하위 경로 포함)
#   ③ session-env/<uuid>                   ★ 상위 디렉토리 — 부모를 지우면 자식도 소멸(B1)
# 정규화: realpath -m 으로 ./ 와 ../ 를 먼저 해소한다(B2/B4). 파일이 없어도 동작한다.
orphan_target_uuid() {
  local raw="$1" norm
  [[ -n "$raw" ]] || return 1

  # ★ B2/B4 해소 — 검사 **전에** 경로를 정규화한다.
  #   realpath -m 은 존재하지 않는 경로도 순수 문자열 연산으로 정규화한다.
  norm=$(realpath -m -- "$raw" 2>/dev/null) || norm="$raw"
  [[ -n "$norm" ]] || norm="$raw"

  # ── 4차 보강: 최상위 보호 (무조건 차단 — 고아 유무 무관) ────────────────
  # 배경: 보호 정의가 session-env/<uuid> 깊이에서 멈춰 그 위 2단계가 무방비였다.
  #   session-env 통째 / ~/.claude 통째 삭제 = 전 세션 추적근거 일괄 소멸(현재 80개 세션).
  # 판단 근거 (실측 조사):
  #   - 스킬·hook 전수 grep 결과 "session-env 자체" 삭제 정상 경로 **0건**
  #   - "~/.claude 통째" 삭제 정상 경로 **0건**
  #   - 반면 session-env/<uuid> 는 ofinish 가 실제로 사용 → 조건부 유지
  #   → 정상 사용처가 없으므로 고아 카운트에 의존하지 않고 **무조건 차단**한다.
  #     (고아 0건이라고 통과시키면 오탐·정상상태에서 80개 세션이 소멸할 수 있다.)
  # 특별 UUID "__ALWAYS__" 를 반환해 호출부가 잔존수 조회 없이 즉시 차단하게 한다.
  local _home_claude="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  case "$norm" in
    "$_home_claude"|"$_home_claude/session-env"|*/.claude|*/.claude/session-env)
      echo "__ALWAYS__"
      return 0
      ;;
  esac

  # session-env/ 이후 구간을 잘라낸다. 없으면 대상 아님.
  case "$norm" in
    */session-env/*) ;;
    *) return 1 ;;
  esac
  local rest u sub
  rest="${norm##*/session-env/}"     # "<uuid>" 또는 "<uuid>/agents/..." 형태
  u="${rest%%/*}"                    # 첫 세그먼트 = UUID
  [[ -n "$u" ]] || return 1

  if [[ "$rest" == "$u" ]]; then
    # ③ B1 — session-env/<uuid> 자체 (부모 삭제 = 자식 소멸)
    echo "$u"
    return 0
  fi

  # ①② agents / panes (하위 경로 포함)
  sub="${rest#*/}"                   # UUID 뒤 나머지
  case "$sub" in
    agents|agents/*|panes|panes/*)
      echo "$u"
      return 0
      ;;
  esac

  return 1
}

# 삭제성 명령인지 판정 (bash_exec 전용 — B5/B7/B8/B10 해소).
# ★ 과잉 차단 방지: 호출부가 "보호 경로가 인자에 포함될 때"만 이 함수를 부른다.
#   따라서 일상 bash 명령은 애초에 여기까지 오지 않는다.
orphan_is_destructive_cmd() {
  local cmd="$1"
  [[ -n "$cmd" ]] || return 1
  # 경로 접두(/bin/, /usr/bin/ 등)를 허용하려면 앞경계에 / 를 포함해야 한다(B10).
  # 삭제·내용소거 수단을 폭넓게 인정한다(B5 find -delete / B8 rsync --delete / B7 cp /dev/null).
  if echo "$cmd" | grep -qE '(^|[[:space:];&|(`]|/)(rm|rmdir|unlink|shred|srm)([[:space:]]|$)'; then return 0; fi
  if echo "$cmd" | grep -qE '(^|[[:space:];&|(`]|/)mv([[:space:]]|$)'; then return 0; fi
  if echo "$cmd" | grep -qE '(^|[[:space:];&|(`]|/)find([[:space:]]|$)' \
     && echo "$cmd" | grep -qE '\-delete|\-exec[[:space:]]+.*(rm|unlink)'; then return 0; fi
  if echo "$cmd" | grep -qE '\-\-delete(\-before|\-after|\-during|\-excluded)?([[:space:]]|$)'; then return 0; fi
  if echo "$cmd" | grep -qE '(^|[[:space:];&|(`]|/)(truncate|shred)([[:space:]]|$)'; then return 0; fi
  # 언어 런타임 경유 삭제 (4차 보강) — python shutil.rmtree / os.remove / pathlib unlink 등
  if echo "$cmd" | grep -qE 'shutil\.rmtree|os\.(remove|unlink|rmdir)|Path\([^)]*\)\.unlink|\.unlink\(\)'; then return 0; fi
  if echo "$cmd" | grep -qE '(^|[[:space:];&|(`]|/)(perl|python[0-9.]*|ruby|node)([[:space:]])' \
     && echo "$cmd" | grep -qE 'unlink|rmtree|rmdir|remove'; then return 0; fi
  # cp /dev/null X (내용 소거) 탐지.
  # ★리다이렉션(2>/dev/null, >/dev/null 등)은 먼저 제거하고 본다★ — 사이클42 T3.
  #   종전 '/dev/null[[:space:]]' 는 /dev/null 뒤에 공백만 있으면 무조건 삭제성으로 봤다.
  #   그래서 `foo 2>/dev/null | head` 처럼 ★삭제 의도가 0인 순수 읽기 명령★ 이
  #   파이프·&&·|| 를 붙이는 것만으로 전부 차단됐다(오탐).
  #   실측: `ls SE 2>/dev/null | wc -l` · `grep -r x SE/ 2>/dev/null | head` 등 전부 BLOCK.
  #   이는 "보수적 차단"이 아니라 문자열 우연 일치이며 ★얻는 안전이 0★ 이라 정밀화했다.
  #   cp /dev/null X 는 /dev/null 이 ★인자 위치★ 라 정규화 후에도 남아 그대로 잡힌다.
  #   ★못 잡는 것★: 변수 치환(`R=2>/dev/null`)·이스케이프·서브셸로 문자열을 감추면
  #   이 정규화도 우회된다. 본 함수는 ★문자열 판정★ 이며 그 한계는 종전과 동일하다.
  _cmd_norm=$(echo "$cmd" | sed -E 's/[0-9]*>[[:space:]]*\/dev\/null//g')
  if echo "$_cmd_norm" | grep -qE '/dev/null[[:space:]]'; then return 0; fi
  if echo "$cmd" | grep -qE '(^|[[:space:];&|(`])>[[:space:]]*[^[:space:]]*session-env'; then return 0; fi
  return 1
}

# 고아 PID 목록 산출.
#   조건 ① claude 프로세스   ② --agent-id 보유 (= 팀에이전트, 메인 아님 / L-213)
#   조건 ③ --parent-session-id <uuid> 일치   ④ 자기 자신/조상 아님
orphan_scan_pids() {
  local uuid="$1"
  _orphan_uuid_valid "$uuid" || return 1

  local selfchain
  selfchain=$(_orphan_self_chain 2>/dev/null) || selfchain=""

  # ★ NUL 함정 회피 — /proc/{pid}/cmdline 는 인자 구분이 NUL 이라 "--parent-session-id <uuid>"
  #   같은 공백 포함 문자열이 grep 으로 절대 매칭되지 않는다(실측 확인: 5건 전부 skip).
  #   ps -eo args= 는 공백으로 구분해 출력하므로 이 문제가 없다. 반드시 ps 를 쓴다.
  ps -eo pid=,args= 2>/dev/null | while read -r pid args; do
    [[ -n "$pid" ]] || continue
    case "$args" in
      *claude*) ;;
      *) continue ;;
    esac
    # 메인 프로세스 보호 (L-213) — --agent-id 없으면 메인. 절대 대상 아님.
    case "$args" in
      *--agent-id*) ;;
      *) continue ;;
    esac
    # 세션 격리 — 자기 UUID 소속만.
    case "$args" in
      *"--parent-session-id $uuid"*) ;;
      *) continue ;;
    esac
    # 자기 자신/조상 제외
    if echo "$selfchain" | grep -qx -- "$pid"; then
      continue
    fi
    echo "$pid"
  done
}

# 고아 개수. 실패해도 반드시 정수를 출력한다(호출부 파싱 안전).
# 단, 검사 자체가 불가능하면 비정상 종료코드(1)로 알려 호출부가 fail-open 하도록 한다.
orphan_scan_count() {
  local uuid="$1" out
  if ! _orphan_uuid_valid "$uuid"; then
    return 1
  fi
  out=$(orphan_scan_pids "$uuid" 2>/dev/null) || return 1
  if [[ -z "$out" ]]; then
    echo 0
  else
    echo "$out" | grep -c . 2>/dev/null || echo 0
  fi
  return 0
}

# 진단용 상세 출력 — 차단 메시지/로그에 쓴다.
orphan_scan_detail() {
  local uuid="$1" pid args
  _orphan_uuid_valid "$uuid" || return 1
  orphan_scan_pids "$uuid" 2>/dev/null | while read -r pid; do
    [[ -n "$pid" ]] || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null | head -c 160)
    printf '%s\t%s\n' "$pid" "$args"
  done
}

# 고아 회수 — TERM 발송 → 최대 5초 대기 → 잔존분 KILL. 회수한 개수를 출력한다.
# 안전: orphan_scan_pids 가 이미 메인 보호/세션 격리/자기 제외를 적용한 목록만 돌려준다.
orphan_scan_reap() {
  local uuid="$1" pids pid n=0 waited=0
  _orphan_uuid_valid "$uuid" || return 1
  pids=$(orphan_scan_pids "$uuid" 2>/dev/null) || return 1
  [[ -n "$pids" ]] || { echo 0; return 0; }

  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null && n=$((n + 1))
  done

  # 최대 5초 동안 0.5초 간격으로 종료 확인
  while [[ $waited -lt 10 ]]; do
    local remain
    remain=$(orphan_scan_pids "$uuid" 2>/dev/null)
    [[ -z "$remain" ]] && break
    sleep 0.5
    waited=$((waited + 1))
  done

  # 그래도 남으면 KILL
  for pid in $(orphan_scan_pids "$uuid" 2>/dev/null); do
    kill -KILL "$pid" 2>/dev/null
  done

  echo "$n"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI 진입점 (3차 보강) — oio(Python) 가 판정 로직을 복제하지 않고 이 파일을 그대로 쓰게 한다.
#
#   bash orphan_scan.sh check-path <경로> [<bash명령>]
#     → 차단해야 하면  "BLOCK <uuid> <잔존수>" 출력 + rc=0
#     → 통과해야 하면  "PASS" 출력 + rc=0
#     → 판정 불가면    "UNKNOWN" 출력 + rc=0   (호출부는 반드시 통과시킬 것 — fail-open)
#
#   3번째 인자가 주어지면 bash 명령으로 간주해 삭제성 여부까지 함께 본다.
#   판정 로직이 이 파일 한 곳에만 존재하므로 hook·oio 가 어긋날 수 없다.
if [[ "${1:-}" == "check-path" ]]; then
  _cp_path="${2:-}"
  _cp_cmd="${3:-}"

  _cp_uuid=$(orphan_target_uuid "$_cp_path" 2>/dev/null) || _cp_uuid=""
  if [[ -z "$_cp_uuid" ]]; then
    echo "PASS"; exit 0            # 보호 대상 경로 아님 → 검사 자체 불필요
  fi
  if [[ -n "$_cp_cmd" ]] && ! orphan_is_destructive_cmd "$_cp_cmd"; then
    echo "PASS"; exit 0            # 보호 경로를 건드리지만 삭제성 명령이 아님
  fi

  # 4차 보강 — 최상위 경로는 고아 유무와 무관하게 무조건 차단.
  # 정상 삭제 경로가 존재하지 않음을 실측 확인했으므로 잔존수를 보지 않는다.
  if [[ "$_cp_uuid" == "__ALWAYS__" ]]; then
    echo "BLOCK __ALWAYS__ 0"; exit 0
  fi

  _cp_cnt=$(orphan_scan_count "$_cp_uuid" 2>/dev/null)
  if [[ $? -ne 0 || ! "$_cp_cnt" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN"; exit 0         # 판정 불가 → fail-open
  fi
  if [[ "$_cp_cnt" -gt 0 ]]; then
    echo "BLOCK $_cp_uuid $_cp_cnt"; exit 0
  fi
  echo "PASS"; exit 0              # ★ 잔존 0건 → 통과 (정상 정리 흐름 보장)
fi

# ═════════════════════════════════════════════════════════════════════════════
# [H-2 확장 2026-08-17] shutdown 발신 후 미응답 조기 감지
#
# 배경: 2026-08-17 verify-1 / diag-1 / odev-2 3건이 작업 완료 후 SendMessage 미호출로
#       보고를 유실했다. 본인들은 "보고 완료"로 오인했고, 메인은 유휴 알림만 보고
#       추측할 수밖에 없었다. shutdown_request 2회에도 응답이 없었다.
#       증적: .claude/evidence/verify1_hang_diag_20260817.md
#
# 역할 분담:
#   H-1 (SubagentStop_report_guard) = 발생 자체를 물리 차단한다.
#   H-2 (이 블록)                   = 이미 발생한 상태를 빨리 알아채게 한다. **경고만.**
#
# ★ 절대 원칙 — 이 블록은 어떤 경우에도 차단하지 않는다.
#   호출부(write_guard)는 stale 목록이 비면 침묵하고, 있어도 경고만 출력한 뒤 통과한다.
#   모든 함수는 실패 시 무출력 + rc 0 (fail-open). 위 기존 함수는 한 줄도 건드리지 않았다.
#
# 세션 격리 (CLAUDE.md §(a)): 마커는 인자로 받은 자기 UUID 하위에만 쓴다.
#   경로: session-env/<uuid>/evidence/shutdown_sent/<agent>
#
# 긴급 정지: 이 파일 자체를 지우거나 이름을 바꾸면 H-1(고아 차단)과 함께
#            H-2 경고도 동시에 무력화된다 (기존 탈출구가 그대로 유효).
#
# 제공 함수:
#   shutdown_marker_write <uuid> <agent>        — 발신 시각(epoch) 기록
#   shutdown_marker_clear <uuid> <agent>        — 응답 수신 시 마커 제거
#   shutdown_stale_list   <uuid> [초=90]        — 초과 미응답 "<agent> <경과초>" 목록
# ═════════════════════════════════════════════════════════════════════════════

# 에이전트 이름 정규화 — path traversal 차단.
# [A-Za-z0-9_-] 외 문자를 전부 제거한다. 빈 결과면 rc 1 (호출부는 그냥 통과).
_shutdown_agent_sanitize() {
  local raw="${1:-}"
  local clean
  clean=$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9_-' 2>/dev/null)
  # 길이 상한 — 비정상적으로 긴 이름으로 파일시스템을 오염시키지 않는다.
  clean="${clean:0:64}"
  [[ -n "$clean" ]] || return 1
  printf '%s' "$clean"
  return 0
}

# 마커 디렉토리 경로 산출. UUID 형식 검증은 기존 _orphan_uuid_valid 를 재사용한다(L-457 단일 출처).
_shutdown_marker_dir() {
  local uuid="${1:-}"
  _orphan_uuid_valid "$uuid" || return 1
  printf '%s/session-env/%s/evidence/shutdown_sent' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$uuid"
  return 0
}

# shutdown_request 발신 시각을 기록한다. 실패해도 조용히 rc 0.
shutdown_marker_write() {
  local uuid="${1:-}" agent="${2:-}"
  local dir name
  dir=$(_shutdown_marker_dir "$uuid" 2>/dev/null) || return 0
  name=$(_shutdown_agent_sanitize "$agent" 2>/dev/null) || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  # 이미 마커가 있으면 덮어쓰지 않는다 — 최초 발신 시각을 보존해야 경과초가 정확하다.
  [[ -f "$dir/$name" ]] && return 0
  printf '%s' "$(date +%s 2>/dev/null)" > "$dir/$name" 2>/dev/null || true
  return 0
}

# 응답 수신 등으로 마커를 해제한다. 실패해도 조용히 rc 0.
shutdown_marker_clear() {
  local uuid="${1:-}" agent="${2:-}"
  local dir name
  dir=$(_shutdown_marker_dir "$uuid" 2>/dev/null) || return 0
  name=$(_shutdown_agent_sanitize "$agent" 2>/dev/null) || return 0
  [[ -f "$dir/$name" ]] || return 0
  rm -f "$dir/$name" 2>/dev/null || true
  return 0
}

# 임계초(기본 90초)를 초과해 미응답인 에이전트를 "<agent> <경과초>" 형태로 출력.
# 해당 없음 / 판정 불가 = 무출력 + rc 0 (호출부는 무출력이면 침묵한다).
shutdown_stale_list() {
  local uuid="${1:-}" threshold="${2:-90}"
  local dir now f name ts age
  dir=$(_shutdown_marker_dir "$uuid" 2>/dev/null) || return 0
  [[ -d "$dir" ]] || return 0
  # 임계값이 정수가 아니면 기본값으로 되돌린다(오염된 인자로 오작동 방지).
  case "$threshold" in
    ''|*[!0-9]*) threshold=90 ;;
  esac
  now=$(date +%s 2>/dev/null)
  case "$now" in
    ''|*[!0-9]*) return 0 ;;   # 시각 취득 실패 → 판정 포기(fail-open)
  esac
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" 2>/dev/null)
    [[ -n "$name" ]] || continue
    ts=$(cat "$f" 2>/dev/null | tr -cd '0-9' 2>/dev/null)
    case "$ts" in
      ''|*[!0-9]*) continue ;;  # 파손된 마커는 조용히 건너뛴다
    esac
    age=$(( now - ts ))
    [[ "$age" -lt 0 ]] && continue          # 시계 역행 방어
    [[ "$age" -gt 86400 ]] && continue      # 1일 초과분은 잔재로 보고 무시
    if [[ "$age" -ge "$threshold" ]]; then
      printf '%s %s\n' "$name" "$age"
    fi
  done
  return 0
}
