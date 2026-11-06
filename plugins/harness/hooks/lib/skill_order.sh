# 스킬 호출 순서(ointaug -> oi) 남은 단계 판정과 안내 문구를 만드는 공용 라이브러리
# source 해서 쓴다. 출력 함수는 항상 return 0 이며 실패 시 빈 출력이다.

# 나노초 mtime 을 정수로 출력한다(없거나 실패하면 rc 1).
_so_mt() {
  local v
  v=$(stat -c %.9Y "$1" 2>/dev/null) || return 1
  v="${v/./}"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

# 단계 하나(required 대 invoked)가 남았는지 판정한다. rc 0=남음 1=충족/요구없음 2=판정 불가.
_so_step_pending() {
  local sdir="$1" req_n="$2" prf_n="$3" req prf
  [[ -e "${sdir}/${req_n}" ]] || return 1
  req=$(_so_mt "${sdir}/${req_n}") || return 2
  prf=$(_so_mt "${sdir}/${prf_n}") || prf=0
  (( prf < req )) && return 0
  return 1
}

# 남은 단계를 순서대로 공백 구분 출력한다("ointaug oi" | "ointaug" | "oi" | "").
skill_order_pending() {
  local sdir="$1" out=""
  [[ -n "$sdir" && -d "$sdir" ]] || return 0
  _so_step_pending "$sdir" ointaug_required ointaug_invoked && out="ointaug"
  if _so_step_pending "$sdir" oi_required oi_invoked; then
    out="${out:+${out} }oi"
  fi
  [[ -n "$out" ]] && printf '%s' "$out"
  return 0
}

# 남은 순서 안내 1줄을 출력한다. 남은 단계가 없으면 빈 출력.
skill_order_hint() {
  local sdir="$1" target="$2" pend first chain="" s
  pend=$(skill_order_pending "$sdir")
  [[ -n "$pend" ]] || return 0
  first="${pend%% *}"
  for s in $pend; do
    chain="${chain}Skill('${s}') -> "
  done
  printf "지금 할 일: Skill('%s') 호출. 남은 순서: %s%s" "$first" "$chain" "$target"
  return 0
}

# oi 호출이 필요한가. rc 0=필요 1=불필요 2=판정 불가.
skill_order_oi_needed() {
  local sdir="$1"
  [[ -n "$sdir" && -d "$sdir" ]] || return 2
  _so_step_pending "$sdir" oi_required oi_invoked
  return $?
}
