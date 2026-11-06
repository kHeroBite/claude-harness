#!/bin/bash
# 자기 세션의 session-env 두 경로(HOME·CLAUDE_CONFIG_DIR)를 무손실 심링크로 단일화하는 공용 라이브러리
#
# 사용: source 후 아래 함수를 호출한다. exit 를 쓰지 않으며 set -e 를 가정하지 않는다.
#   spu_classify <상대경로>   → stdout: contract | volatile
#   spu_paths <UUID>          → SPU_CCD_DIR·SPU_HOME_DIR 설정. CCD 미설정·UUID 이상이면 rc=1
#   spu_unify <UUID>          → stdout 1줄: UNIFIED | BLOCKED:<상이 계약 파일 목록> | SKIP | FAILED | BUDGET:<files|elapsed>
#   spu_prune_bak <UUID>      → 단일화된 세션의 .unify-bak.<epoch> 중 지워도 되는 것만 삭제
#   spu_log <메시지>          → 두 경로의 logs/session_path_guard.log 에 1줄 (같은 실체면 1번만)
#
# 호출자 의무: <UUID> 는 자기 세션이어야 한다(CLAUDE.md 세션 격리 §(a)). lib 는 타 세션 여부를 판정할 수 없다.
#
# 예산(선택 환경변수 — F-PATH-1 처럼 시간 예산 안에서 부를 때만 준다):
#   SPU_MAX_FILES  두 경로 파일 수 합의 상한. 넘으면 아무것도 바꾸지 않고 BUDGET:files
#   SPU_MAX_SEC    경과 상한(초, 소수 허용). mv 직전까지 넘으면 BUDGET:elapsed (HOME 에 합집합만 남고 CCD 는 그대로)
#
# ── 분류 원칙 ──────────────────────────────────────────────────────────────
# 기본값은 contract(fail-closed)이고 휘발은 아래 명시 allowlist 뿐이다.
# *_invoked·*_required·ointaug_done·peer_check_done·heartbeat·last_prompt_epoch·pipeline_start_time 은
# 가드가 mtime 으로 판정하는 증표다. 이를 휘발로 다뤄 "최신 우선" 으로 고르면 증표 위조와 같은 효과가 난다.
# 같은 이유로 한쪽에만 있는 파일은 mtime 을 보존하는 cp -a 로만 복사한다.
#
# ── 이 lib 가 못 잡는 것 (정직 기재) ───────────────────────────────────────
#  A. 내용이 같고 mtime 만 다른 증표는 상이로 보지 않는다. HOME 쪽 mtime 이 남는다.
#     CCD 쪽이 더 새로운 증표였다면 더 오래된 값이 남으므로 가드는 더 엄격한 쪽으로 판정한다.
#  B. CCD 에만 있는 심링크 항목은 상이 대조 대상이 아니다(find -type f). 복사는 cp -a 가 그대로 한다.
#  C. 줄바꿈이 든 파일명은 md5sum 이 이스케이프하므로 contract 로 떨어지고 대조가 어긋나면 FAILED 다.

# 분류 — stdout: contract | volatile
spu_classify() {
  local rel="${1#./}"
  # 경로 이탈·이스케이프 이름은 무조건 contract
  case "$rel" in
    ""|/*|..|../*|*/..|*/../*|*\\*) echo contract; return 0 ;;
  esac
  case "$rel" in
    logs/*) echo volatile; return 0 ;;
    */*)    echo contract; return 0 ;;
  esac
  case "$rel" in
    ctx_used_pct|*.lock|peer_targets.json|peer_list|agent_cap_slots.json|teammate_activity.json|hook_debug.log|ctx_notify_stage|observation_checkpoint_count|observation_guard_notified|wt_cache.json|work_title|work_title_seed|main_topic)
      echo volatile ;;
    *) echo contract ;;
  esac
}

# 경로 계산 — rc=1 이면 대상 아님
spu_paths() {
  local uuid="${1:-}"
  SPU_CCD_DIR=""
  SPU_HOME_DIR=""
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] || return 1
  case "$uuid" in
    ""|.|..|*/*) return 1 ;;
  esac
  SPU_CCD_DIR="${CLAUDE_CONFIG_DIR}/session-env/${uuid}"
  SPU_HOME_DIR="$HOME/.claude/session-env/${uuid}"
  return 0
}

# 로그 — 이미 단일화됐으면 같은 실체에 두 번 쓰지 않는다
spu_log() {
  local _d _rp _seen="" _ts
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  for _d in "$SPU_CCD_DIR" "$SPU_HOME_DIR"; do
    [ -d "$_d" ] || continue
    _rp=$(readlink -f "$_d" 2>/dev/null)
    [ "$_rp" = "$_seen" ] && continue
    _seen="$_rp"
    mkdir -p "${_d}/logs" 2>/dev/null
    echo "${_ts} $*" >> "${_d}/logs/session_path_guard.log" 2>/dev/null || true
  done
}

_spu_is_unified() {
  [ -e "$SPU_CCD_DIR" ] && [ "$(readlink -f "$SPU_CCD_DIR" 2>/dev/null)" = "$(readlink -f "$SPU_HOME_DIR" 2>/dev/null)" ]
}

# 스냅샷 — "상대경로<TAB>md5" 를 상대경로 기준 정렬. xargs -r: 입력 0건이면 md5sum 미실행(가짜 "-" 항목 방지)
_spu_snap() {
  ( cd "$1" 2>/dev/null && find . -type f -print0 2>/dev/null | xargs -0 -r md5sum 2>/dev/null ) \
    | LC_ALL=C awk '{h=$1; sub(/^\\/,"",h); r=substr($0,length($1)+3); sub(/^\.\//,"",r); print r "\t" h}' \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1 > "$2" 2>/dev/null || : > "$2"
}

# 두 스냅샷 모두에 있고 해시가 다른 상대경로 (1줄 1개)
_spu_diverged() {
  LC_ALL=C join -t "$(printf '\t')" -j 1 -o 0,1.2,2.2 "$1" "$2" 2>/dev/null \
    | LC_ALL=C awk -F '\t' '$2!=$3 {print $1}'
}

# 첫 스냅샷에만 있는 상대경로 (1줄 1개)
_spu_only_in_first() {
  LC_ALL=C join -t "$(printf '\t')" -v1 -j 1 -o 0 "$1" "$2" 2>/dev/null
}

_spu_is_small_text() {
  [ -f "$1" ] || return 1
  [ "$(stat -c %s "$1" 2>/dev/null || echo 9999999)" -le 1048576 ] || return 1
  [ ! -s "$1" ] || LC_ALL=C grep -qI '' "$1" 2>/dev/null
}

# 휘발 파일 상이 해소 — logs/*.log(1MB 이하 텍스트)는 HOME 에 없는 줄만 덧붙이고, 그 외는 mtime 최신을 남긴다.
# 덧붙이기(O_APPEND)라 형제 hook 이 같은 로그에 쓰는 중이어도 그 줄을 잃지 않는다. 진 쪽 원본은 bak 에 남는다.
_spu_merge_volatile() {
  local _src="$1/$2" _dst="${SPU_HOME_DIR}/$2"
  case "$2" in
    logs/*.log)
      if _spu_is_small_text "$_src" && _spu_is_small_text "$_dst"; then
        LC_ALL=C awk 'NR==FNR {seen[$0]=1; next} !seen[$0]++' "$_dst" "$_src" >> "$_dst" 2>/dev/null
        return 0
      fi
      ;;
  esac
  if [ "$_src" -nt "$_dst" ]; then
    cp -a -- "$_src" "$_dst" 2>/dev/null
  fi
  return 0
}

_spu_over_budget() {
  [ -n "${SPU_MAX_SEC:-}" ] || return 1
  local _now _max
  _now=$(date +%s%3N)
  _max=$(awk -v s="$SPU_MAX_SEC" 'BEGIN{printf "%d", s*1000}')
  [ $((_now - _SPU_T0)) -ge "$_max" ]
}

_spu_ccd_has_files() {
  [ -n "$(find "$SPU_CCD_DIR" -mindepth 1 -not -type d -print -quit 2>/dev/null)" ]
}

# 빈 CCD 단축 경로. 같은 matcher 의 다른 hook 이 사이에 CCD 를 다시 만들면 ln -sT 가 실패하므로 재시도한다.
# 재귀 삭제 금지: 빈 디렉토리만 지운다. 파일이 생기면 그 디렉토리는 지워지지 않아 보존된다.
# rc: 0=링크 완료, 1=파일이 생겼으니 합집합 경로로, 2=실패, 3=예산 초과
_spu_try_empty_link() {
  local uuid="$1" _a=1
  while [ "$_a" -le 3 ]; do
    _spu_ccd_has_files && return 1
    find "$SPU_CCD_DIR" -depth -type d -empty -delete 2>/dev/null
    if [ ! -e "$SPU_CCD_DIR" ] && [ ! -L "$SPU_CCD_DIR" ] \
       && ln -sT "$SPU_HOME_DIR" "$SPU_CCD_DIR" 2>/dev/null \
       && _spu_is_unified; then
      spu_log "PATH_UNIFIED uuid=${uuid} mode=empty_ccd_link attempt=${_a}"
      return 0
    fi
    _spu_over_budget && return 3
    [ "$_a" -lt 3 ] && sleep 0.3
    _a=$((_a + 1))
  done
  _spu_ccd_has_files && return 1
  spu_log "PATH_UNIFY_FAILED uuid=${uuid} mode=empty_ccd_link attempts=3 (CCD 잔존 — 삭제 안 함)"
  return 2
}

# 양쪽 실디렉토리 — md5 전수 대조 후 계약 파일 상이만 fail-closed. stdout: 결과 1줄
_spu_merge() {
  local uuid="$1" _tmp="$2" _rel _blocked="" _miss _bak _epoch
  local _c="$SPU_CCD_DIR" _h="$SPU_HOME_DIR"

  if [ -n "${SPU_MAX_FILES:-}" ]; then
    local _n
    _n=$(find "$_c" "$_h" -type f 2>/dev/null | wc -l)
    if [ "$_n" -gt "$SPU_MAX_FILES" ]; then
      echo "BUDGET:files"
      return 0
    fi
  fi

  _spu_snap "$_c" "$_tmp/c"
  _spu_snap "$_h" "$_tmp/h"
  _spu_diverged "$_tmp/c" "$_tmp/h" > "$_tmp/div"

  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    [ "$(spu_classify "$_rel")" = "volatile" ] || _blocked="${_blocked:+$_blocked }$_rel"
  done < "$_tmp/div"

  if [ -n "$_blocked" ]; then
    spu_log "PATH_UNIFY_BLOCKED uuid=${uuid} 내용상이=[${_blocked}]"
    echo "BLOCKED:${_blocked}"
    return 0
  fi

  if _spu_over_budget; then
    echo "BUDGET:elapsed"
    return 0
  fi

  # 상이가 휘발뿐 — 해소하고, HOME 에 없는 것만 mtime 보존 복사한다(no-clobber, 중단돼도 손실 0)
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    _spu_merge_volatile "$_c" "$_rel"
  done < "$_tmp/div"
  cp -a -n "$_c/." "$_h/" 2>/dev/null

  _spu_snap "$_h" "$_tmp/n"
  _miss=$(_spu_only_in_first "$_tmp/c" "$_tmp/n" | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$_miss" ]; then
    spu_log "PATH_UNIFY_ABORT uuid=${uuid} 합집합_누락=[${_miss}]"
    echo "FAILED"
    return 0
  fi

  if _spu_over_budget; then
    echo "BUDGET:elapsed"
    return 0
  fi

  # 합집합이 실렸으므로 CCD 를 심링크로 교체한다. 원본은 지우지 않고 .unify-bak.<epoch> 로 보존한다.
  # mv -T: 같은 이름이 있어도 그 안으로 들어가지 않는다. 형제 hook 이 bak 자리에 쓴 파일을 잃지 않도록 삭제는 spu_prune_bak 만 한다.
  _epoch=$(date +%s)
  _bak="${_c}.unify-bak.${_epoch}"
  while [ -e "$_bak" ]; do
    _epoch=$((_epoch + 1))
    _bak="${_c}.unify-bak.${_epoch}"
  done
  if ! mv -T "$_c" "$_bak" 2>/dev/null; then
    spu_log "PATH_UNIFY_FAILED uuid=${uuid} reason=mv_ccd_failed"
    echo "FAILED"
    return 0
  fi
  # 재스캔 전에 표식을 찍는다. 이 시각보다 새 파일이 bak 에 있으면 spu_prune_bak 이 지우지 않는다.
  : > "${_bak}.rescanned" 2>/dev/null

  # 2차 재스캔 — mv 직전까지 병렬 기록된 파일을 다시 대조한다
  cp -a -n "$_bak/." "$_h/" 2>/dev/null
  _spu_snap "$_bak" "$_tmp/c"
  _spu_snap "$_h" "$_tmp/n"
  _spu_diverged "$_tmp/c" "$_tmp/n" > "$_tmp/div2"
  _blocked=""
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    if [ "$(spu_classify "$_rel")" = "volatile" ]; then
      _spu_merge_volatile "$_bak" "$_rel"
    else
      _blocked="${_blocked:+$_blocked }$_rel"
    fi
  done < "$_tmp/div2"
  _miss=$(_spu_only_in_first "$_tmp/c" "$_tmp/n" | tr '\n' ' ' | sed 's/ $//')

  if [ -n "$_blocked" ] || [ -n "$_miss" ]; then
    # bak 보존(삭제 금지) — CCD 자리가 비었으면 원복, 아니면 bak 만 남기고 보고
    if [ ! -e "$_c" ] && [ ! -L "$_c" ]; then
      mv -T "$_bak" "$_c" 2>/dev/null
      rm -f "${_bak}.rescanned" 2>/dev/null
      spu_log "PATH_UNIFY_ROLLBACK uuid=${uuid} reason=recheck 상이=[${_blocked}] 누락=[${_miss}]"
    else
      spu_log "PATH_UNIFY_BAK_KEPT uuid=${uuid} bak=${_bak} 상이=[${_blocked}] 누락=[${_miss}]"
    fi
    echo "FAILED"
    return 0
  fi

  if ln -sT "$_h" "$_c" 2>/dev/null && _spu_is_unified; then
    spu_log "PATH_UNIFIED uuid=${uuid} mode=merge_union ccd파일=$(wc -l < "$_tmp/c" 2>/dev/null) bak=${_bak}"
    echo "UNIFIED"
    return 0
  fi

  # 링크 생성 실패 — CCD 자리가 비었으면 원복, 새 실디렉토리가 생겼으면 bak 보존(HOME 에도 합집합 있음)
  [ -L "$_c" ] && rm -f "$_c" 2>/dev/null
  if [ ! -e "$_c" ]; then
    mv -T "$_bak" "$_c" 2>/dev/null
    rm -f "${_bak}.rescanned" 2>/dev/null
    spu_log "PATH_UNIFY_ROLLBACK uuid=${uuid} reason=symlink_verify_failed"
  else
    spu_log "PATH_UNIFY_BAK_KEPT uuid=${uuid} bak=${_bak} reason=ccd_recreated"
  fi
  echo "FAILED"
  return 0
}

# 단일화 — stdout 1줄. 어떤 결과든 rc=0
spu_unify() {
  local uuid="${1:-}" _rc _tmp
  spu_paths "$uuid" || { echo "SKIP"; return 0; }

  # 이미 단일화됐거나 둘 다 없으면(신규 세션 — 런타임이 곧 만든다) 할 일이 없다
  if _spu_is_unified; then echo "SKIP"; return 0; fi
  if [ ! -d "$SPU_CCD_DIR" ] && [ ! -d "$SPU_HOME_DIR" ]; then echo "SKIP"; return 0; fi

  _SPU_T0=$(date +%s%3N)

  # 한쪽만 존재 — 정본 판정 불필요. HOME 이 실체, CCD 가 심링크(방향 근거는 hook 주석)
  if [ ! -d "$SPU_HOME_DIR" ]; then
    mkdir -p "$(dirname "$SPU_HOME_DIR")" 2>/dev/null
    if mv -T "$SPU_CCD_DIR" "$SPU_HOME_DIR" 2>/dev/null && ln -sT "$SPU_HOME_DIR" "$SPU_CCD_DIR" 2>/dev/null; then
      spu_log "PATH_UNIFIED uuid=${uuid} mode=move_ccd_to_home"
      echo "UNIFIED"
    else
      spu_log "PATH_UNIFY_FAILED uuid=${uuid} mode=move_ccd_to_home"
      echo "FAILED"
    fi
    return 0
  fi

  if [ ! -d "$SPU_CCD_DIR" ]; then
    mkdir -p "$(dirname "$SPU_CCD_DIR")" 2>/dev/null
    if ln -sT "$SPU_HOME_DIR" "$SPU_CCD_DIR" 2>/dev/null; then
      spu_log "PATH_UNIFIED uuid=${uuid} mode=link_only"
      echo "UNIFIED"
    else
      spu_log "PATH_UNIFY_FAILED uuid=${uuid} mode=link_only"
      echo "FAILED"
    fi
    return 0
  fi

  _spu_try_empty_link "$uuid"
  _rc=$?
  case "$_rc" in
    0) echo "UNIFIED"; return 0 ;;
    2) echo "FAILED"; return 0 ;;
    3) echo "BUDGET:elapsed"; return 0 ;;
  esac

  _tmp=$(mktemp -d 2>/dev/null) || { echo "FAILED"; return 0; }
  _spu_merge "$uuid" "$_tmp"
  rm -rf "$_tmp" 2>/dev/null
  return 0
}

# bak 정리 — 단일화된 세션에서만, 재스캔 뒤 새 파일이 없고 모든 항목이 HOME 에 있을 때만 지운다.
# 표식(.rescanned)이 없는 bak 은 판정 근거가 없으므로 그대로 둔다.
spu_prune_bak() {
  local uuid="${1:-}" _b _m _f _miss
  spu_paths "$uuid" || return 0
  [ -L "$SPU_CCD_DIR" ] || return 0
  _spu_is_unified || return 0
  for _b in "${SPU_CCD_DIR}".unify-bak.*; do
    [ -d "$_b" ] && [ ! -L "$_b" ] || continue
    _m="${_b}.rescanned"
    [ -f "$_m" ] || continue
    if [ -n "$(find "$_b" -newer "$_m" -not -type d -print -quit 2>/dev/null)" ]; then
      spu_log "PATH_UNIFY_BAK_KEPT uuid=${uuid} bak=${_b} reason=newer_than_rescan"
      continue
    fi
    _miss=""
    while IFS= read -r _f; do
      if [ ! -e "${SPU_HOME_DIR}/${_f}" ] && [ ! -L "${SPU_HOME_DIR}/${_f}" ]; then
        _miss="$_f"
        break
      fi
    done <<EOF
$(cd "$_b" 2>/dev/null && find . -not -type d -print 2>/dev/null)
EOF
    if [ -n "$_miss" ]; then
      spu_log "PATH_UNIFY_BAK_KEPT uuid=${uuid} bak=${_b} reason=missing_in_home first=${_miss}"
      continue
    fi
    rm -rf "$_b" 2>/dev/null
    rm -f "$_m" 2>/dev/null
    spu_log "PATH_UNIFY_BAK_PRUNED uuid=${uuid} bak=${_b}"
  done
  return 0
}
