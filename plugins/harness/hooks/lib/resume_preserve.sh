# 재기동 복원용 보존 사본(rp_save)과 재주입 요약(rp_reinject)을 제공하는 공용 함수 라이브러리
#
# 10D (conv_179163042411, 2026-10-11) — 계획서 plans/oplan_conv_179163042411_s10D.md §3-5·§3-6
# 배경: 재부팅/WSL 종료 뒤 SessionStart.sh(boot-stale·heartbeat-stale·R3)와
#       UserPromptSubmit.sh(자기 세션 고착 정리·_reset_idle)가 state 를 IDLE 로 되돌리고
#       classification·team_name·conv_id 등을 지운다. 그 결과 oresume 이 재개할 근거를 잃는다.
# 접근법 A2: 기존 삭제는 그대로 둔다. 삭제 ★직전★ 에 자기 세션 디렉토리 안에 보존 사본을 남기고,
#           복원은 oresume(resume_restore.py)이 단일 진입점으로 수행한다.
#
# 규칙
#   - POSIX sh 호환 문법만 쓴다([[ ]]·배열·${PIPESTATUS} 금지). bash·dash 어느 쪽에서 source 해도 동작한다.
#   - 쓰기는 $HOME/.claude/session-env/<자기 UUID>/ 하위만 한다(세션 격리 §(a)). 다른 세션은 읽지도 않는다.
#   - 보존 실패가 호출자의 기존 동작을 바꾸지 않는다 — rp_save 는 언제나 rc=0, 출력 없음.
#   - 시험 주입: RP_BOOT_ID(boot_id 대체), RP_NOW(현재 epoch 대체).

# 보존 대상 — 다섯 정리 지점이 지우거나 덮어쓰는 메타 파일 전부
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): oroof_active 와 구 oralph_active 를 모두 보존한다
RP_FILES="state classification entry_tier status team_name conv_id goal.json auto oroof_active oroof_active.json oralph_active oralph_active.json route_decision pipeline_uuid rollback_hash"
RP_KEEP=5

# JSON 문자열 이스케이프(역슬래시·따옴표·제어문자 제거)
_rp_js() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_rp_now() {
  if [ -n "${RP_NOW:-}" ]; then printf '%s' "$RP_NOW"; else date +%s; fi
}

_rp_boot_id() {
  if [ -n "${RP_BOOT_ID:-}" ]; then printf '%s' "$RP_BOOT_ID"; return 0; fi
  cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\n'
}

# 세션 디렉토리 → UUID(마지막 경로 성분)
_rp_uuid() {
  _rp_u=${1%/}
  printf '%s' "${_rp_u##*/}"
}

# 보존본을 쓸 정본 디렉토리 — 항상 $HOME/.claude/session-env/<UUID>
_rp_home_dir() {
  printf '%s' "$HOME/.claude/session-env/$(_rp_uuid "$1")"
}

# state 첫 토큰
_rp_state() {
  _rp_st=""
  if [ -r "$1/state" ]; then
    read -r _rp_st _rp_rest < "$1/state" 2>/dev/null
  fi
  printf '%s' "$_rp_st"
}

# checkpoint.jsonl 의 마지막 유효 이벤트(STATE_TRANSITION 은 건너뛴다)
_rp_last_event() {
  [ -f "$1/checkpoint.jsonl" ] || return 0
  grep -v '"event": *"STATE_TRANSITION"' "$1/checkpoint.jsonl" 2>/dev/null | tail -n 1 \
    | sed -n 's/.*"event": *"\([A-Za-z0-9_]*\)".*/\1/p'
}

# 파이프라인이 열려 있는가(완료 기록 없음) — 0=열림
#   - checkpoint.jsonl 필요
#   - 마지막 유효 이벤트가 FINISH_DONE 이면 닫힘
#   - evidence/ofinish_done 이 checkpoint.jsonl 보다 새것(또는 같은 시각)이면 닫힘
#     (옛 사이클의 ofinish_done 잔류물이 새 파이프라인을 닫힌 것으로 오판하지 않도록 mtime 을 비교한다)
_rp_ckpt_open() {
  [ -f "$1/checkpoint.jsonl" ] || return 1
  [ "$(_rp_last_event "$1")" = "FINISH_DONE" ] && return 1
  if [ -f "$1/evidence/ofinish_done" ]; then
    [ "$1/checkpoint.jsonl" -nt "$1/evidence/ofinish_done" ] || return 1
  fi
  return 0
}

# rp_resumable <session_dir> — 재개 가능한 파이프라인이면 0
#   [c199 건6 2026-10-24] state 가 PLAN|DEV|TEST|DONE 인데 checkpoint 가 완료 기록(FINISH_DONE·ofinish_done)으로
#   닫혀 있으면 state·checkpoint 불일치다. 이때도 0(보존)을 돌려준다 — 판정은 resume_restore.py(rc=5)가 한다.
#   (Mars c197: 새 사이클이 DEV 진입 이벤트를 남기지 않아 보존본이 만들어지지 않았다 — L-1365)
#   checkpoint.jsonl 부재는 종전대로 1 이다.
rp_resumable() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 1
  _rr_st=$(_rp_state "$1")
  case "$_rr_st" in
    ""|IDLE|UNKNOWN|__LOCK_FAIL__|EARLY_TERM) return 1 ;;
  esac
  _rp_ckpt_open "$1" && return 0
  [ -f "$1/checkpoint.jsonl" ] || return 1
  case "$_rr_st" in
    PLAN|DEV|TEST|DONE) return 0 ;;
  esac
  return 1
}

_rp_log() {  # $1=정본 디렉토리 $2=내용
  [ -d "$1/logs" ] || mkdir -p "$1/logs" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -Iseconds 2>/dev/null)" "$2" >> "$1/logs/resume_preserve.log" 2>/dev/null
  return 0
}

_rp_save_impl() {
  _rs_src=${1%/}
  _rs_reason=$(printf '%s' "${2:-unknown}" | tr -c 'A-Za-z0-9_' '_' | cut -c1-24)
  [ -n "$_rs_src" ] || return 0
  rp_resumable "$_rs_src" || return 0
  _rs_dst=$(_rp_home_dir "$_rs_src")
  _rs_root="$_rs_dst/resume_preserve"
  _rs_ts=$(_rp_now)
  _rs_dir="$_rs_root/${_rs_ts}_${_rs_reason}"
  [ -e "$_rs_dir" ] && _rs_dir="${_rs_dir}_$$"
  if ! mkdir -p "$_rs_dir" 2>/dev/null; then
    _rp_log "$_rs_dst" "rp_save FAIL mkdir reason=$_rs_reason"
    return 0
  fi
  for _rs_f in $RP_FILES; do
    [ -f "$_rs_src/$_rs_f" ] && cp -p "$_rs_src/$_rs_f" "$_rs_dir/$_rs_f" 2>/dev/null
  done
  _rs_state_line=""
  [ -r "$_rs_src/state" ] && IFS= read -r _rs_state_line < "$_rs_src/state" 2>/dev/null
  _rs_one() { _rs_v=""; [ -r "$_rs_src/$1" ] && IFS= read -r _rs_v < "$_rs_src/$1" 2>/dev/null; printf '%s' "$_rs_v"; }
  _rs_prev=""
  if [ -f "$_rs_dst/agent_state/_main.json" ]; then
    _rs_prev=$(sed -n 's/.*"boot_id": *"\([^"]*\)".*/\1/p' "$_rs_dst/agent_state/_main.json" 2>/dev/null | head -n 1)
  fi
  _rs_json=$(printf '{"saved_at":%s,"reason":"%s","boot_id":"%s","prev_boot_id":"%s","state_line":"%s","conv_id":"%s","classification":"%s","entry_tier":"%s","team_name":"%s","last_event":"%s","dir":"%s"}' \
    "$_rs_ts" "$(_rp_js "$_rs_reason")" "$(_rp_js "$(_rp_boot_id)")" "$(_rp_js "$_rs_prev")" \
    "$(_rp_js "$_rs_state_line")" "$(_rp_js "$(_rs_one conv_id)")" "$(_rp_js "$(_rs_one classification)")" \
    "$(_rp_js "$(_rs_one entry_tier)")" "$(_rp_js "$(_rs_one team_name)")" \
    "$(_rp_js "$(_rp_last_event "$_rs_src")")" "$(_rp_js "$_rs_dir")")
  printf '%s\n' "$_rs_json" > "$_rs_dir/meta.json" 2>/dev/null
  if printf '%s\n' "$_rs_json" > "$_rs_root/.latest.json.$$" 2>/dev/null \
     && mv -f "$_rs_root/.latest.json.$$" "$_rs_root/latest.json" 2>/dev/null; then
    :
  else
    rm -f "$_rs_root/.latest.json.$$" 2>/dev/null
    _rp_log "$_rs_dst" "rp_save FAIL latest.json reason=$_rs_reason dir=$_rs_dir"
    return 0
  fi
  # 최근 RP_KEEP 개만 남긴다 — 자기 resume_preserve/ 안의 <epoch>_<reason> 디렉토리만 대상
  ls -1d "$_rs_root"/[0-9]*_* 2>/dev/null | sort | head -n "-$RP_KEEP" | while IFS= read -r _rs_old; do
    case "$_rs_old" in
      "$_rs_root"/[0-9]*_*) [ -d "$_rs_old" ] && rm -rf "$_rs_old" 2>/dev/null ;;
    esac
  done
  _rp_log "$_rs_dst" "rp_save OK reason=$_rs_reason dir=$_rs_dir"
  return 0
}

# rp_save <session_dir> <reason> — 재개 가능할 때만 삭제 직전 사본을 남긴다. 언제나 rc=0·무출력.
rp_save() {
  ( _rp_save_impl "$@" ) >/dev/null 2>&1
  return 0
}

# rp_reinject <session_dir> <boot_time> — SessionStart(resume/startup) 재주입 요약(호출자가 29줄로 자르고 안내 1줄을 덧붙인다)
#   live : state 가 비IDLE 이고 부팅 이전에 기록됐으며 재개 가능 → 지금 파일로 요약(보존은 백그라운드가 수행 중)
#   saved: state 가 IDLE(또는 부재)이고 latest.json 이 24시간 이내이며 파이프라인 완료 기록이 없음 → 보존본으로 요약
#   그 밖에는 무출력
rp_reinject() {
  _ri_sd=${1%/}
  _ri_bt=${2:-0}
  [ -n "$_ri_sd" ] || return 0
  _ri_dst=$(_rp_home_dir "$_ri_sd")
  _ri_now=$(_rp_now)
  _ri_st=$(_rp_state "$_ri_sd")
  _ri_mode=""
  _ri_src=""
  _ri_reason=""
  case "$_ri_st" in
    ""|IDLE)
      _ri_latest="$_ri_dst/resume_preserve/latest.json"
      [ -f "$_ri_latest" ] || return 0
      _ri_saved=$(sed -n 's/.*"saved_at": *\([0-9]*\).*/\1/p' "$_ri_latest" 2>/dev/null | head -n 1)
      [ -n "$_ri_saved" ] || return 0
      [ $((_ri_now - _ri_saved)) -le 86400 ] || return 0
      _rp_ckpt_open "$_ri_sd" || return 0
      _ri_src=$(sed -n 's/.*"dir": *"\([^"]*\)".*/\1/p' "$_ri_latest" 2>/dev/null | head -n 1)
      [ -n "$_ri_src" ] && [ -d "$_ri_src" ] || return 0
      _ri_reason=$(sed -n 's/.*"reason": *"\([^"]*\)".*/\1/p' "$_ri_latest" 2>/dev/null | head -n 1)
      _ri_mode=saved
      ;;
    UNKNOWN|__LOCK_FAIL__|EARLY_TERM)
      return 0
      ;;
    *)
      _ri_mt=$(stat -c %Y "$_ri_sd/state" 2>/dev/null || echo 0)
      [ "$_ri_mt" -lt "$_ri_bt" ] || return 0
      rp_resumable "$_ri_sd" || return 0
      _ri_src=$_ri_sd
      _ri_reason=boot
      _ri_mode=live
      ;;
  esac
  _ri_get() { _ri_v=""; [ -r "$_ri_src/$1" ] && IFS= read -r _ri_v < "$_ri_src/$1" 2>/dev/null; printf '%s' "$_ri_v"; }
  _ri_conv=$(_ri_get conv_id)
  _ri_stage=$(_ri_get state); _ri_stage=${_ri_stage%% *}
  echo "🔁 [재기동 복원 가능] 이전 파이프라인이 재기동 전에 진행 중이었습니다 (보존=${_ri_mode}, 사유=${_ri_reason})."
  echo "   conv_id=${_ri_conv:-?} stage=${_ri_stage:-?} classification=$(_ri_get classification) entry_tier=$(_ri_get entry_tier) team=$(_ri_get team_name)"
  if [ -f "$_ri_sd/checkpoint.jsonl" ]; then
    echo "   최근 이벤트:"
    grep -v '"event": *"STATE_TRANSITION"' "$_ri_sd/checkpoint.jsonl" 2>/dev/null | tail -n 3 \
      | sed -n 's/.*"ts": *"\([^"]*\)".*"event": *"\([A-Za-z0-9_]*\)".*"detail": *"\([^"]*\)".*/     \1 \2 \3/p' | cut -c1-200
  fi
  # 팀원 상태 집계 — agent_state 스냅샷 우선, 없으면 work/*_result.json(conv_id 일치분만)
  _ri_cnt=""
  if command -v jq >/dev/null 2>&1; then
    if ls "$_ri_dst/agent_state/"*.json >/dev/null 2>&1; then
      _ri_cnt=$(jq -rs '[.[] | select((.kind // "") == "teammate") | (.result.status // "absent")]
                 | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$_ri_dst/agent_state/"*.json 2>/dev/null)
    fi
    if [ -z "$_ri_cnt" ] && ls "$_ri_sd/work/"*_result.json >/dev/null 2>&1; then
      _ri_cnt=$(jq -rs --arg c "$_ri_conv" '[.[] | select((.conv_id // "") == $c) | (.status // "absent")]
                 | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$_ri_sd/work/"*_result.json 2>/dev/null)
    fi
  fi
  echo "   팀원 상태: ${_ri_cnt:-기록 없음}"
  if [ -f "$_ri_dst/agent_state/user_directives.log" ]; then
    echo "   최근 사용자 지시:"
    tail -n 5 "$_ri_dst/agent_state/user_directives.log" 2>/dev/null | cut -c1-200 | sed 's/^/     /'
  fi
  # oresume 호출 안내 1줄은 호출자(SessionStart.sh _ss_resume_reinject)가 덧붙인다.
  return 0
}
