# 세션 시작 때 자기 CLAUDE_CONFIG_DIR 의 settings.json hooks 를 정본과 맞추는 함수 (사이클219)
# 사용: source 후 settings_session_sync <settings_hooks_sync.py 경로>. 항상 rc=0 (세션 시작을 막지 않는다).
# 환경 재지정(시험용): SETTINGS_SYNC_CANON=정본 settings.json, SETTINGS_SYNC_MANIFEST=매니페스트 경로
settings_session_sync() {
  local sync_py="${1:-}" ccd="${CLAUDE_CONFIG_DIR:-}"
  local canon="${SETTINGS_SYNC_CANON:-$HOME/.claude/settings.json}"
  [ -n "$sync_py" ] && [ -f "$sync_py" ] && [ -n "$ccd" ] && [ -f "$canon" ] || return 0
  local target; target=$(readlink -f "$ccd/settings.json" 2>/dev/null) || return 0
  # 세션 격리 §(a): 자기 격리 사본(/tmp/cc-*)만 쓴다. 정본 자체·그 밖의 경로는 무동작.
  case "$target" in /tmp/cc-*/settings.json) ;; *) return 0 ;; esac
  [ -f "$target" ] || return 0
  [ "$target" = "$(readlink -f "$canon" 2>/dev/null)" ] && return 0
  local log="$ccd/settings_session_sync.log" out rc
  # 점검 먼저: 같으면 쓰지 않는다(멱등, 불필요한 백업·mtime 갱신 없음)
  timeout 3 python3 "$sync_py" --check "$canon" "$target" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 1 ]; then
    out=$(timeout 3 python3 "$sync_py" "$canon" "$target" 2>&1); rc=$?
    case "$rc" in
      0) echo "🔄 [settings 동기화] 이 세션 settings.json 의 hooks 를 정본과 맞췄습니다 (hooks 외 키 불변, 백업 .bak-sync-*)"
         echo "    이미 떠 있는 세션의 hook 목록은 시작 때 캐시되므로 새 세션부터 확실히 적용됩니다." ;;
      3) echo "⚠️ [settings 동기화 거부] 이 세션에만 있는 hook 이 있어 덮어쓰지 않았습니다 (L-616)"
         printf '%s\n' "$out" | head -8 | sed 's/^/    /'
         echo "    복구: python3 $sync_py --force \"$canon\" \"$target\"" ;;
      *) echo "⚠️ [settings 동기화 실패] rc=$rc" ;;
    esac
    printf '%s sync rc=%s target=%s\n' "$(date '+%F %T')" "$rc" "$target" >>"$log" 2>/dev/null
  fi
  # 저장소 매니페스트(기준본)와 정본의 드리프트 경고
  local man="${SETTINGS_SYNC_MANIFEST:-$(dirname "$(readlink -f "$sync_py")")/../../settings_hooks_manifest.json}"
  if [ -f "$man" ]; then
    timeout 3 python3 "$sync_py" --check "$canon" "$man" >/dev/null 2>&1; rc=$?
    [ "$rc" = 1 ] && echo "⚠️ [매니페스트 드리프트] 정본 hooks 와 .claude/settings_hooks_manifest.json 이 다릅니다 → 갱신 후 커밋 필요 (tests/test_settings_hooks_manifest.sh)"
  fi
  return 0
}
