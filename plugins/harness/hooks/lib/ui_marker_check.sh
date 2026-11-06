#!/bin/bash
# UI 테스트 완료 마커(v2)의 요구 여부·유효성을 판정하고 차단 사유 문장을 만드는 공용 lib
#
# 사용처: PreToolUse_SendMessage_otest.sh, ui_test_done_guard.sh, PreToolUse_done_gate.sh
# source 전용이다. exit 를 쓰지 않고 모든 함수는 return 코드로만 결과를 알린다.
#
# v2 마커 형식 (ui_test_done · winforms_test_done · web_test_done 공통):
#   1줄  : PASS|PARTIAL|FAIL <ISO8601>      예) PASS 2026-09-29T22:30:00+09:00
#   2줄~ : evidence: <절대경로>             1줄 이상, 각 경로 실존, mtime ≥ pipeline_start_time
#   빈 파일(touch)은 무효다. ui_test_not_required 도 사유 1줄이 없으면 면제로 인정하지 않는다.
#
# 공개 함수:
#   ui_markers_required SESSION_DIR          → 0 필요 / 1 불필요 / 2 판정 오류(ui_touched.json 판독 실패 — 차단 권장)
#                                              (UMC_REQ_REASON 에 판정 근거)
#   ui_markers_valid    SESSION_DIR          → 0 유효 / 1 무효 (UMC_FAIL_* 에 첫 실패)
#   ui_marker_valid     FILE [PIPELINE_START]→ 0 유효 / 1 무효
#   otest_done_valid    FILE [PIPELINE_START]→ 0 유효 / 1 무효 (비어 있지 않음 + START 주면 mtime)
#   ui_project_type     SESSION_DIR          → stdout csharp|web|""
#   ui_pipeline_start   SESSION_DIR          → stdout epoch (없으면 빈값, rc 1)
#   ui_marker_block_reason SESSION_DIR [머리말] → stdout 차단 사유 전문(①실패 사유 ②v2 형식 ③실행 예시)
#   ui_block_json       TEXT                 → stdout {"decision":"block","reason":TEXT}

UMC_FAIL_FILE=""
UMC_FAIL_CODE=""
UMC_FAIL_REASON=""
UMC_FAIL_KIND=""
UMC_REQ_REASON=""
UMC_NOTE=""

# SESSION_DIR 과 같은 UUID 의 $HOME 쪽 경로 (cc-prefix 분리 대응)
_umc_home_dir() {
  printf '%s' "$HOME/.claude/session-env/$(basename "$1")"
}

# SESSION_DIR 우선, 없으면 HOME 쪽. 둘 다 없으면 SESSION_DIR 쪽 경로를 출력하고 rc 1
_umc_find() {
  local sd="$1" rel="$2" hd
  if [ -e "$sd/$rel" ]; then printf '%s' "$sd/$rel"; return 0; fi
  hd=$(_umc_home_dir "$sd")
  if [ "$hd" != "$sd" ] && [ -e "$hd/$rel" ]; then printf '%s' "$hd/$rel"; return 0; fi
  printf '%s' "$sd/$rel"
  return 1
}

# 공백이 아닌 글자가 하나라도 있으면 0
_umc_nonempty() {
  [ -f "$1" ] && grep -q '[^[:space:]]' "$1" 2>/dev/null
}

_umc_fail() {
  UMC_FAIL_CODE="$1"
  UMC_FAIL_REASON="$2"
  return 1
}

ui_pipeline_start() {
  local f v
  f=$(_umc_find "$1" pipeline_start_time) || return 1
  v=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  case "$v" in
    '') return 1 ;;
    *[!0-9]*) v=$(date -d "$v" +%s 2>/dev/null) || return 1 ;;
  esac
  printf '%s' "$v"
}

# evidence 경로 정규화: 앞뒤 공백·따옴표 제거, Windows 경로 → WSL, ~ 확장, 상대경로 → 마커 디렉터리 기준
_umc_norm_path() {
  local p="$1" dir="$2"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  case "$p" in
    \"*\") p="${p#\"}"; p="${p%\"}" ;;
    \'*\') p="${p#\'}"; p="${p%\'}" ;;
  esac
  if printf '%s' "$p" | grep -qE '^[A-Za-z]:[\\/]'; then
    if command -v wslpath >/dev/null 2>&1; then
      p=$(wslpath -u "$p" 2>/dev/null || printf '%s' "$p")
    fi
  fi
  case "$p" in
    '~/'*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*|'') ;;
    *) p="$dir/$p" ;;
  esac
  printf '%s' "$p"
}

_umc_fmt_epoch() {
  date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '%s' "$1"
}

ui_marker_valid() {
  local f="$1" start="${2:-}" first line p m dir n=0
  UMC_FAIL_FILE="$f"; UMC_FAIL_CODE=""; UMC_FAIL_REASON=""; UMC_FAIL_KIND="ui"
  if [ ! -e "$f" ]; then
    _umc_fail missing "마커 파일이 없다"; return 1
  fi
  if ! _umc_nonempty "$f"; then
    _umc_fail empty "빈 파일이다(0바이트 또는 공백뿐). touch 로 만든 마커는 무효다"; return 1
  fi
  first=$(head -n 1 "$f" 2>/dev/null | tr -d '\r')
  if ! printf '%s\n' "$first" | grep -qE '^(PASS|PARTIAL|FAIL) [0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    _umc_fail first_line "첫 줄 형식이 틀렸다(현재 첫 줄: '${first:0:80}'). 'PASS|PARTIAL|FAIL <ISO8601>' 이어야 한다"; return 1
  fi
  dir=$(dirname "$f")
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      evidence:*) ;;
      *) continue ;;
    esac
    n=$((n + 1))
    p=$(_umc_norm_path "${line#evidence:}" "$dir")
    if [ -z "$p" ] || [ ! -e "$p" ]; then
      _umc_fail path_missing "evidence 경로가 존재하지 않는다: '${p}'"; return 1
    fi
    # 디렉터리는 파일 생성 때마다 mtime 이 갱신되므로 증거로 인정하지 않는다(정규 파일만)
    if [ ! -f "$p" ]; then
      _umc_fail path_missing "evidence 경로가 정규 파일이 아니다(디렉터리 등): '${p}'"; return 1
    fi
    # 마커 자기 자신·다른 완료 마커를 증거로 가리키는 것은 무효
    if [ "$(readlink -f "$p" 2>/dev/null)" = "$(readlink -f "$f" 2>/dev/null)" ]; then
      _umc_fail path_missing "evidence 가 마커 자기 자신을 가리킨다: '${p}'. 실제 스크린샷·UI 테스트 로그 경로를 적어라"; return 1
    fi
    case "$(basename "$p")" in
      ui_test_done|winforms_test_done|web_test_done|otest_done|ui_test_not_required|ui_touched.json)
        _umc_fail path_missing "evidence 가 다른 완료 마커를 가리킨다: '${p}'. 실제 스크린샷·UI 테스트 로그 경로를 적어라"; return 1 ;;
    esac
    if [ -n "$start" ]; then
      m=$(stat -c %Y "$p" 2>/dev/null || echo 0)
      if [ "$m" -lt "$start" ]; then
        _umc_fail stale "evidence 가 이번 파이프라인보다 오래됐다: '${p}' mtime=$(_umc_fmt_epoch "$m") < pipeline_start_time=$(_umc_fmt_epoch "$start")"; return 1
      fi
    fi
  done < "$f"
  if [ "$n" -eq 0 ]; then
    _umc_fail no_evidence "'evidence: <절대경로>' 줄이 하나도 없다"; return 1
  fi
  return 0
}

otest_done_valid() {
  local f="$1" start="${2:-}" m
  UMC_FAIL_FILE="$f"; UMC_FAIL_CODE=""; UMC_FAIL_REASON=""; UMC_FAIL_KIND="otest"
  if [ ! -e "$f" ]; then
    _umc_fail missing "otest_done 마커 파일이 없다"; return 1
  fi
  if ! _umc_nonempty "$f"; then
    _umc_fail empty "otest_done 이 빈 파일이다(0바이트 또는 공백뿐). touch 로 만든 마커는 무효다"; return 1
  fi
  if [ -n "$start" ]; then
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ "$m" -lt "$start" ]; then
      _umc_fail stale "otest_done 이 이번 파이프라인보다 오래됐다: mtime=$(_umc_fmt_epoch "$m") < pipeline_start_time=$(_umc_fmt_epoch "$start")"; return 1
    fi
  fi
  return 0
}

ui_project_type() {
  local sd="$1" f t root
  if f=$(_umc_find "$sd" project_type); then
    t=$(tr -d '[:space:]' < "$f" 2>/dev/null)
  fi
  if [ -z "$t" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$root" ]; then
      if find "$root" -maxdepth 3 -name "*.csproj" -print -quit 2>/dev/null | grep -q .; then
        t="csharp"
      elif find "$root" -maxdepth 2 \( -name "package.json" -o -name "*.html" \) -print -quit 2>/dev/null | grep -q .; then
        t="web"
      fi
    fi
  fi
  printf '%s' "$t"
}

ui_markers_required() {
  local sd="$1" cls tj touched ovr nr
  UMC_REQ_REASON=""
  cls=$(tr -d '[:space:]' < "$(_umc_find "$sd" classification)" 2>/dev/null)
  case "$cls" in
    O4|O5) ;;
    *) UMC_REQ_REASON="classification=${cls:-없음}"; return 1 ;;
  esac
  if tj=$(_umc_find "$sd" evidence/ui_touched.json); then
    # 판독 실패는 "불필요"로도 "필요"로도 단정할 수 없다 → rc 2(판정 오류). 호출자는 차단한다.
    if ! touched=$(jq -r 'if has("touched") then .touched|tostring else "absent" end' "$tj" 2>/dev/null) || \
       ! ovr=$(jq -r 'if has("user_override") then .user_override|tostring else "false" end' "$tj" 2>/dev/null); then
      UMC_REQ_REASON="ui_touched.json 판독 실패(${tj}) — JSON 형식을 고치거나 삭제하라"
      return 2
    fi
    if [ "$ovr" != "true" ] && [ "$touched" = "false" ]; then
      UMC_REQ_REASON="ui_touched=false"; return 1
    fi
  fi
  if nr=$(_umc_find "$sd" evidence/ui_test_not_required); then
    if _umc_nonempty "$nr"; then
      UMC_REQ_REASON="ui_test_not_required(사유 있음)"; return 1
    fi
    UMC_REQ_REASON="ui_test_not_required 가 빈 파일이라 면제 불인정"
    return 0
  fi
  UMC_REQ_REASON="classification=${cls}"
  return 0
}

ui_markers_valid() {
  local sd="$1" start f ptype nr tf
  UMC_NOTE=""; UMC_FAIL_KIND="ui"
  start=$(ui_pipeline_start "$sd") || { start=""; UMC_NOTE="pipeline_start_time 부재 — mtime 검사 생략"; }
  f=$(_umc_find "$sd" evidence/ui_test_done)
  if ! ui_marker_valid "$f" "$start"; then
    if nr=$(_umc_find "$sd" evidence/ui_test_not_required) && ! _umc_nonempty "$nr"; then
      UMC_FAIL_REASON="${UMC_FAIL_REASON} / 또한 ui_test_not_required 가 빈 파일이라 면제 사유로 인정되지 않는다(${nr})"
    fi
    return 1
  fi
  ptype=$(ui_project_type "$sd")
  case "$ptype" in
    csharp) tf="winforms_test_done" ;;
    web)    tf="web_test_done" ;;
    *)      return 0 ;;
  esac
  f=$(_umc_find "$sd" "evidence/${tf}")
  if ! ui_marker_valid "$f" "$start"; then
    UMC_FAIL_REASON="${UMC_FAIL_REASON} (프로젝트 유형 ${ptype} → ${tf} 도 v2 로 필요)"
    return 1
  fi
  return 0
}

# 예시에 넣을 실제 증거 파일(이번 파이프라인 이후 생성, 최신 2개)
_umc_example_evidence() {
  local sd="$1" start="${2:-0}" d
  for d in "$sd/evidence" "$(_umc_home_dir "$sd")/evidence"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 2 -type f -printf '%T@\t%p\n' 2>/dev/null
  done | awk -F'\t' -v s="${start:-0}" '
      { n=split($2, a, "/"); b=a[n] }
      b ~ /^(ui_test_done|winforms_test_done|web_test_done|otest_done|ui_test_not_required|ui_touched\.json)$/ { next }
      b ~ /_skipped$/ { next }
      int($1) >= s+0 { print $1 "\t" $2 }' \
    | sort -rn | awk -F'\t' '!seen[$2]++ { print $2 }' | head -n 2
}

ui_marker_block_reason() {
  local sd="$1" head="${2:-UI 테스트 완료 마커 검사 실패}" start now ex1 ex2 exs content note="" hint=""
  start=$(ui_pipeline_start "$sd") || start=""
  now=$(date '+%Y-%m-%dT%H:%M:%S%:z')
  if [ "$UMC_FAIL_KIND" = "otest" ]; then
    content="PASS ${now}"
    printf '%s\n' "❌ [ui_marker_check] ${head}" \
      "① 실패 마커: ${UMC_FAIL_FILE}" \
      "   사유(${UMC_FAIL_CODE}): ${UMC_FAIL_REASON}" \
      "② 올바른 otest_done 형식: 비어 있지 않은 1줄 'PASS|PARTIAL|FAIL <ISO8601>'${start:+, mtime ≥ pipeline_start_time($(_umc_fmt_epoch "$start"))}. 빈 파일(touch)은 무효다." \
      "③ 작성 예시 (그대로 실행 가능):" \
      "   mcp__oio__file_write(path=\"${UMC_FAIL_FILE}\", content=\"${content}\", overwrite=true)"
    return 0
  fi
  exs=$(_umc_example_evidence "$sd" "$start")
  ex1=$(printf '%s\n' "$exs" | sed -n 1p)
  ex2=$(printf '%s\n' "$exs" | sed -n 2p)
  if [ -z "$ex1" ]; then
    ex1="${sd}/evidence/ui_screenshot_1.png"
    note="   ※ 이번 파이프라인 증거 파일을 찾지 못해 evidence 경로를 예시 이름으로 넣었다. 실제로 존재하는 스크린샷·UI 테스트 로그의 절대경로로 바꿔 실행하라."
  fi
  content="PASS ${now}\\nevidence: ${ex1}"
  [ -n "$ex2" ] && content="${content}\\nevidence: ${ex2}"
  case "$(basename "$UMC_FAIL_FILE")" in
    winforms_test_done) hint="   ※ C# 프로젝트는 otest_winforms_bg(기본) 또는 otest_winforms(포그라운드) 실행 후 ui_test_done 과 winforms_test_done 을 둘 다 v2 로 쓴다." ;;
    web_test_done) hint="   ※ 웹 프로젝트는 otest_ui/otest_playwright 실행 후 ui_test_done 과 web_test_done 을 둘 다 v2 로 쓴다." ;;
  esac
  printf '%s\n' "❌ [ui_marker_check] ${head}" \
    "① 실패 마커: ${UMC_FAIL_FILE}" \
    "   사유(${UMC_FAIL_CODE}): ${UMC_FAIL_REASON}" \
    "② 올바른 v2 마커 형식 (ui_test_done · winforms_test_done · web_test_done 공통):" \
    "   1줄  : PASS|PARTIAL|FAIL <ISO8601>   예) PASS ${now}" \
    "   2줄~ : evidence: <절대경로>   — 1줄 이상, 각 경로가 실제로 존재하고 mtime ≥ pipeline_start_time${start:+($(_umc_fmt_epoch "$start"))}" \
    "   · 빈 파일(touch)은 무효다. PARTIAL/FAIL 이어도 evidence 1줄 이상이 필요하다(UI 미실행이면 사유 문서 경로, 예: evidence/otest_deferred.md)." \
    "   · UI 변경이 없어 UI 테스트가 필요 없으면 대신 evidence/ui_test_not_required 에 사유 1줄을 쓴다(빈 파일 무효)." \
    "③ 작성 예시 (대상 경로 치환 완료, 그대로 실행 가능):" \
    "   mcp__oio__file_write(path=\"${UMC_FAIL_FILE}\", content=\"${content}\", overwrite=true)"
  [ -n "$hint" ] && printf '%s\n' "$hint"
  [ -n "$note" ] && printf '%s\n' "$note"
  return 0
}

ui_block_json() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$1" '{decision:"block",reason:$r}'
  else
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps({"decision":"block","reason":sys.stdin.read()},ensure_ascii=False))'
  fi
}
