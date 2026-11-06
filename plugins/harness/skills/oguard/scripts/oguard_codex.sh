#!/usr/bin/env bash
# hook 가드 수정 매뉴얼을 codex 에 넘겨 실행하고, 대상 파일 범위·백업·원복을 관리하는 스크립트
#
# 사용법:
#   oguard_codex.sh precheck <매뉴얼.md> <작업디렉터리>   # 매뉴얼 형식·대상 파일·git 상태 확인
#   oguard_codex.sh start    <매뉴얼.md> <작업디렉터리>   # 백업 후 codex task --background --write 기동 → RUN_DIR·JOB 출력
#   oguard_codex.sh status   <RUN_DIR>                    # codex 작업 상태(json)
#   oguard_codex.sh result   <RUN_DIR>                    # codex 작업 결과(json)
#   oguard_codex.sh wait     <RUN_DIR> [--timeout 초] [--stall 초]  # completed·failed·cancelled 어느 쪽이든 끝날 때까지 폴링
#   oguard_codex.sh check    <RUN_DIR>                    # 바뀐 파일이 대상 파일 안에만 있는지 판정
#   oguard_codex.sh restore  <RUN_DIR>                    # 백업본으로 대상 파일 원복(원복 직전 내용은 before_restore/ 에 남긴다)
#   oguard_codex.sh snapshot <RUN_DIR>                    # 실행 전 dirty 파일의 내용 해시 기록(start 가 호출)
#
# 종료 코드: 0=정상, 1=판정 실패(범위 이탈·NO_CHANGE 등), 2=사용법·환경 오류
#   wait 전용: 0=completed, 1=failed·cancelled, 124=시간 초과, 3=STALLED(시작 단계 정체)
set -u

die() { echo "OGUARD_ERROR: $*" >&2; exit 2; }

find_companion() {
  local d
  for d in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/openai-codex/codex/*/ \
           "$HOME"/.claude/plugins/cache/openai-codex/codex/*/; do
    [ -f "${d}scripts/codex-companion.mjs" ] && echo "${d}scripts/codex-companion.mjs"
  done | sort -V | tail -1
}

# 변경 목록. 새 폴더를 "?? 폴더/" 한 줄로 접지 않고 파일 단위로 펼친다(L-1456 — 폴더 단위 판정은 하지 않는다)
git_status() {
  git -C "$1" status --porcelain --untracked-files=all 2>/dev/null
}

# 매뉴얼의 "## 대상 파일" 절에서 백틱으로 감싼 절대경로만 뽑는다
target_files() {
  awk '/^## /{insec = ($0 ~ /^## 대상 파일/)} insec' "$1" \
    | grep -o '`/[^`]*`' | tr -d '`' | sort -u
}

precheck() {
  local manual="$1" wd="$2" sec missing=0 f
  [ -f "$manual" ] || die "매뉴얼 없음: $manual"
  [ -d "$wd" ] || die "작업디렉터리 없음: $wd"
  for sec in "## 목적" "## 대상 파일" "## 변경 내용" "## 검증" "## 되돌리기" "## 금지"; do
    grep -q "^${sec}" "$manual" || { echo "MISSING_SECTION $sec"; missing=1; }
  done
  local targets; targets=$(target_files "$manual")
  [ -n "$targets" ] || { echo "NO_TARGETS (## 대상 파일 절에 \`/절대경로\` 가 없음)"; missing=1; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in "$wd"/*) ;; *) echo "OUTSIDE_WORKDIR $f"; missing=1 ;; esac
    if [ -e "$f" ] && [ -n "$(git -C "$wd" status --porcelain -- "$f" 2>/dev/null)" ]; then
      echo "DIRTY $f"; missing=1
    fi
  done <<< "$targets"
  [ -n "$(find_companion)" ] || { echo "NO_COMPANION"; missing=1; }
  command -v codex >/dev/null 2>&1 || { echo "NO_CODEX_CLI"; missing=1; }
  [ "$missing" -eq 0 ] && echo "PRECHECK_OK" && return 0
  return 1
}

start() {
  local manual wd
  manual=$(readlink -f "$1"); wd=$(readlink -f "$2")
  precheck "$manual" "$wd" || die "precheck 실패 — 위 항목을 고친 뒤 다시 실행"
  local comp; comp=$(find_companion)
  local run="${OGUARD_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs/oguard}/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$run/backup" || die "RUN_DIR 생성 실패: $run"
  printf '%s\n' "$manual" > "$run/manual"
  printf '%s\n' "$wd" > "$run/workdir"
  target_files "$manual" > "$run/targets"
  git_status "$wd" > "$run/git_before"
  snapshot "$run"
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -e "$f" ]; then
      mkdir -p "$run/backup$(dirname "$f")" && cp -p "$f" "$run/backup$f"
    else
      printf '%s\n' "$f" >> "$run/created"
    fi
  done < "$run/targets"
  local prompt
  prompt="다음 매뉴얼을 처음부터 끝까지 그대로 실행하라: ${manual}
규칙:
1. 수정해도 되는 파일은 매뉴얼 '## 대상 파일' 절에 적힌 파일뿐이다. 그 밖의 파일은 만들거나 고치지 마라.
2. git commit·push·reset·checkout 을 하지 마라. 커밋은 호출자가 검증 후 직접 한다.
3. 매뉴얼의 '## 검증' 명령을 모두 실행하고, 각 명령의 실제 출력을 요약해 보고하라.
4. 매뉴얼의 예상과 실제가 다르면 임의로 우회하지 말고 그 지점에서 멈춰 차이를 보고하라.
5. oio 등 필요한 도구가 안 보이면 도구 검색으로 찾은 뒤 판단하라. 검색에도 없으면 MCP 서버가 아직 기동 중일 수 있으니 20~30초 기다린 뒤 도구 검색을 한 번 더 하라(재검색). 그래도 없으면 멈춰 보고하라. 검색 없이 도구가 없다고 결론 내리지 마라.
6. 작업 디렉터리: ${wd}"
  ( cd "$wd" && node "$comp" task --background --write "$prompt" ) > "$run/start.log" 2>&1
  local rc=$?
  cat "$run/start.log"
  local job; job=$(grep -oE '(task|job)-[A-Za-z0-9_-]+' "$run/start.log" | head -1)
  printf '%s\n' "$job" > "$run/job"
  echo "RUN_DIR=$run"
  echo "JOB=${job:-unknown}"
  [ "$rc" -eq 0 ] || die "codex 기동 실패(rc=$rc) — $run/start.log"
}

companion_cmd() {
  local run="$1" sub="$2" comp wd job
  [ -d "$run" ] || die "RUN_DIR 없음: $run"
  comp=$(find_companion); wd=$(cat "$run/workdir"); job=$(cat "$run/job" 2>/dev/null)
  ( cd "$wd" && node "$comp" "$sub" ${job:+"$job"} --json )
}

# status json 에서 첫 "status" 값을 뽑는다
job_status() {
  companion_cmd "$1" status 2>/dev/null | grep -oE '"status"[[:space:]]*:[[:space:]]*"[A-Za-z_]+"' | head -1 | sed -E 's/.*"([A-Za-z_]+)"$/\1/'
}

wait_job() {
  local run="$1"; shift
  local timeout=1800 stall=180 poll="${OGUARD_POLL:-5}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      --stall) stall="${2:-}"; shift 2 ;;
      *) die "wait: 알 수 없는 인자 $1" ;;
    esac
  done
  case "$timeout$stall" in *[!0-9]*|"") die "wait: --timeout·--stall 은 숫자(초)" ;; esac
  [ -d "$run" ] || die "RUN_DIR 없음: $run"
  local t0 now st last="" last_t
  t0=$(date +%s); last_t=$t0
  while :; do
    st=$(job_status "$run")
    now=$(date +%s)
    case "$st" in
      completed) echo "WAIT_DONE completed"; return 0 ;;
      failed|cancelled) echo "WAIT_DONE $st"; return 1 ;;
    esac
    if [ "$st" != "$last" ]; then last="$st"; last_t=$now; fi
    # starting·queued 등 시작 단계에서 status 가 진전 없이 머무르면 중계 프로세스 사망을 의심한다
    if [ "$stall" -gt 0 ] && [ $((now - last_t)) -ge "$stall" ]; then
      case "$st" in
        running) ;;
        *) echo "STALLED status=${st:-unknown} ${stall}초 진전 없음 — SKILL.md '실패 유형 1' 참조(브로커 자식 프로세스 확인)"; return 3 ;;
      esac
    fi
    if [ $((now - t0)) -ge "$timeout" ]; then echo "WAIT_TIMEOUT status=${st:-unknown}"; return 124; fi
    sleep "$poll"
  done
}

# 실행 전 dirty 파일의 내용 해시. status 줄이 그대로여도 내용이 바뀌면 새 변경으로 잡는다
snapshot() {
  local run="$1" wd line f
  [ -d "$run" ] || die "RUN_DIR 없음: $run"
  wd=$(cat "$run/workdir")
  : > "$run/hash_before"
  while IFS= read -r line; do
    f="$wd/${line:3}"
    [ -f "$f" ] && printf '%s %s\n' "$(git hash-object -- "$f" 2>/dev/null)" "$line" >> "$run/hash_before"
  done < <(git_status "$wd")
  return 0
}

check() {
  local run="$1" wd f bad=0 inscope=0 outscope=0
  [ -d "$run" ] || die "RUN_DIR 없음: $run"
  wd=$(cat "$run/workdir")
  git_status "$wd" > "$run/git_after"
  # 실행 전에 이미 바뀌어 있던 줄은 제외하고, 새로 바뀐 경로만 본다
  while IFS= read -r line; do
    f="$wd/${line:3}"
    if grep -qxF "$line" "$run/git_before"; then
      if [ -f "$run/hash_before" ] && [ -f "$f" ] && ! grep -qxF "$(git hash-object -- "$f" 2>/dev/null) $line" "$run/hash_before"; then
        :  # status 줄은 같지만 내용이 바뀌었다
      else
        continue
      fi
    fi
    if grep -qxF "$f" "$run/targets"; then echo "IN_SCOPE $f"; inscope=$((inscope+1)); else echo "OUT_OF_SCOPE $f"; bad=1; outscope=1; fi
  done < "$run/git_after"
  [ "$outscope" -eq 0 ] || echo "OUT_OF_SCOPE_NOTE 되돌리지 말 것 — 같은 폴더의 다른 작업자 변경일 수 있다. git diff 로 내용을 확인해 보고한다"
  # codex 가 completed 인데 대상 변경이 0 이면 실패다(승인 거부·oio 미발견으로 아무것도 못 한 경우)
  if [ "$inscope" -eq 0 ] && [ "$(job_status "$run")" = "completed" ]; then
    echo "NO_CHANGE (codex completed 인데 대상 파일 변경 0 — SKILL.md '실패 유형 2·3' 참조)"
    companion_cmd "$run" result 2>/dev/null | grep -qi 'approval policy is' && echo "APPROVAL_DENIED"
    bad=1
  fi
  [ "$bad" -eq 0 ] && echo "CHECK_OK" && return 0
  echo "CHECK_FAIL"; return 1
}

restore() {
  local run="$1" f
  [ -d "$run" ] || die "RUN_DIR 없음: $run"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -e "$run/backup$f" ]; then
      if [ -e "$f" ]; then mkdir -p "$run/before_restore$(dirname "$f")" && cp -p "$f" "$run/before_restore$f"; fi
      cp -p "$run/backup$f" "$f" && echo "RESTORED $f"
    fi
  done < "$run/targets"
  if [ -f "$run/created" ]; then
    while IFS= read -r f; do
      if [ -e "$f" ]; then
        mkdir -p "$run/before_restore$(dirname "$f")" && cp -p "$f" "$run/before_restore$f" && rm -f -- "$f" && echo "REMOVED_CREATED $f"
      fi
    done < "$run/created"
  fi
  echo "RESTORE_DONE"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  precheck) [ $# -eq 2 ] || die "precheck <매뉴얼> <작업디렉터리>"; precheck "$(readlink -f "$1")" "$(readlink -f "$2")" ;;
  start)    [ $# -eq 2 ] || die "start <매뉴얼> <작업디렉터리>"; start "$1" "$2" ;;
  status)   [ $# -eq 1 ] || die "status <RUN_DIR>"; companion_cmd "$1" status ;;
  result)   [ $# -eq 1 ] || die "result <RUN_DIR>"; companion_cmd "$1" result ;;
  wait)     [ $# -ge 1 ] || die "wait <RUN_DIR> [--timeout 초] [--stall 초]"; wait_job "$@" ;;
  check)    [ $# -eq 1 ] || die "check <RUN_DIR>"; check "$1" ;;
  restore)  [ $# -eq 1 ] || die "restore <RUN_DIR>"; restore "$1" ;;
  snapshot) [ $# -eq 1 ] || die "snapshot <RUN_DIR>"; snapshot "$1" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
