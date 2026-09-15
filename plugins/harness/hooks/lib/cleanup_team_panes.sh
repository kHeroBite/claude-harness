#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# cleanup_team_panes.sh — ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/agents/ 파일 기반 pane 정리
# 사용법: cleanup_team_panes.sh --sid <UUID> [--team-name <팀명>] [--dry-run]
#
# 에이전트 spawn 시 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/{에이전트명} 파일 생성
# 정리 시: 디렉토리 내 파일을 순회하며 pane_id 추출 후 kill escalation

SID=""
TEAM_NAME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sid) SID="$2"; shift 2 ;;
    --team-name) TEAM_NAME="$2"; shift 2 ;;  # optional (미래 용도)
    --dry-run) DRY_RUN=true; shift ;;
    --before-file) echo "⚠️ --before-file 무시됨 (신규 방식: --sid 사용)"; shift 2 ;;
    *) echo "알 수 없는 인수: $1"; exit 1 ;;
  esac
done

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

[ -z "$SID" ] && { echo "❌ --sid 필수"; exit 1; }

AGENTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/agents"

# pane 존재 확인 — list-panes -a 기반
is_pane_alive() {
  local pane_id="$1"
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane_id"
}

# 에이전트 등록 디렉토리 없으면 등록 기반 정리 스킵 → L-280 고아 pane 스캔으로 직행
SKIP_AGENT_CLEANUP=false
if [ ! -d "$AGENTS_DIR" ] || [ -z "$(ls -A "$AGENTS_DIR" 2>/dev/null)" ]; then
  echo "ℹ️ 에이전트 등록 디렉토리 없음 — 등록 기반 정리 스킵, 고아 pane 스캔 진행"
  SKIP_AGENT_CLEANUP=true
fi

# kill escalation 전 tmux status off
tmux set -g status off 2>/dev/null || true

if [ "$SKIP_AGENT_CLEANUP" = false ]; then
for AGENT_FILE in "$AGENTS_DIR"/*; do
  [ -f "$AGENT_FILE" ] || continue

  AGENT_NAME=$(basename "$AGENT_FILE")
  PANE_ID=$(grep "^pane_id=" "$AGENT_FILE" 2>/dev/null | cut -d= -f2)

  if [ -z "$PANE_ID" ]; then
    echo "⚠️ $AGENT_NAME: pane_id 없음 — BEFORE diff fallback 시도"
    BEFORE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/pre_spawn_${AGENT_NAME}.txt"
    if [ -f "$BEFORE_FILE" ]; then
      CURRENT_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | sort)
      NEW_PANES=$(comm -13 <(sort "$BEFORE_FILE") <(echo "$CURRENT_PANES"))
      FALLBACK_CLEANED=false
      for NP in $NEW_PANES; do
        NP_CMD=$(tmux display-message -t "$NP" -p '#{pane_current_command}' 2>/dev/null || echo "unknown")
        # bash/claude/node 프로세스만 정리 대상
        case "$NP_CMD" in
          bash|claude|node) ;;
          *) continue ;;
        esac
        # L-213: 다른 팀 소속 pane 보호 — agents/ 파일에 등록된 pane은 제외 (이미 다른 에이전트가 관리)
        ALREADY_REGISTERED=false
        for af in "$AGENTS_DIR"/*; do
          [ -f "$af" ] || continue
          AF_PID=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
          if [ "$AF_PID" = "$NP" ]; then
            ALREADY_REGISTERED=true
            break
          fi
        done
        [ "$ALREADY_REGISTERED" = true ] && continue
        echo "🔍 $AGENT_NAME: BEFORE diff fallback — 새 pane $NP (CMD=$NP_CMD) 정리 시도"
        NP_PID=$(tmux display-message -t "$NP" -p '#{pane_pid}' 2>/dev/null || true)
        for NP_RETRY in 1 2 3; do
          if [ -n "$NP_PID" ]; then
            kill "$NP_PID" 2>/dev/null || true
            sleep 2
            if ! is_pane_alive "$NP"; then
              echo "✅ $AGENT_NAME: fallback pane $NP 소멸 (SIGTERM, retry $NP_RETRY)"
              FALLBACK_CLEANED=true; break
            fi
            kill -9 "$NP_PID" 2>/dev/null || true
            sleep 1
            if ! is_pane_alive "$NP"; then
              echo "✅ $AGENT_NAME: fallback pane $NP 소멸 (SIGKILL, retry $NP_RETRY)"
              FALLBACK_CLEANED=true; break
            fi
          fi
          tmux kill-pane -t "$NP" 2>/dev/null || true
          sleep 1
          if ! is_pane_alive "$NP"; then
            echo "✅ $AGENT_NAME: fallback pane $NP 소멸 (kill-pane, retry $NP_RETRY)"
            FALLBACK_CLEANED=true; break
          fi
          echo "⚠️ $AGENT_NAME: fallback pane $NP 재시도 $NP_RETRY/3 실패"
        done
        if [ "$FALLBACK_CLEANED" = false ] && is_pane_alive "$NP"; then
          echo "❌ $AGENT_NAME: fallback pane $NP 3회 재시도 실패 → orphan 기록"
          mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes"
          echo "$(date +%s) $NP" >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
          _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
        fi
      done
    else
      echo "⚠️ $AGENT_NAME: pre_spawn 파일 없음 — fallback 불가, 파일만 삭제"
    fi
    rm -f "$AGENT_FILE"
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    CMD=$(tmux display-message -t "$PANE_ID" -p '#{pane_current_command}' 2>/dev/null || echo "unknown")
    echo "[dry-run] 정리 대상: $AGENT_NAME / pane=$PANE_ID (CMD=$CMD)"
    continue
  fi

  # pane 이미 소멸 확인
  if ! is_pane_alive "$PANE_ID"; then
    echo "✅ $AGENT_NAME ($PANE_ID) 이미 소멸"
    rm -f "$AGENT_FILE"
    continue
  fi

  PANE_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null || true)
  CLEANED=false

  # 팀에이전트 프로세스 종료 확인 — node/claude 자식이 아직 실행 중이면 grace 대기
  if [ -n "$PANE_PID" ]; then
    CLAUDE_CHILD=$(pgrep -P "$PANE_PID" 2>/dev/null | xargs -I{} ps -p {} -o comm= 2>/dev/null | grep -E "^node$|^claude" | head -1 || true)
    if [ -n "$CLAUDE_CHILD" ]; then
      echo "⏳ $AGENT_NAME ($PANE_ID): $CLAUDE_CHILD 실행 중 — grace 3초 대기"
      sleep 3
      # grace 후 재확인: 종료됐으면 pane도 소멸됐을 가능성 체크
      if ! is_pane_alive "$PANE_ID"; then
        echo "✅ $AGENT_NAME ($PANE_ID) grace 후 자연 소멸"
        rm -f "$AGENT_FILE"
        continue
      fi
    fi
  fi

  for RETRY in 1 2 3; do
    if [ -n "$PANE_PID" ]; then
      # 1단계: SIGTERM
      kill "$PANE_PID" 2>/dev/null || true
      sleep 2
      if ! is_pane_alive "$PANE_ID"; then
        CLEANED=true; echo "✅ $AGENT_NAME ($PANE_ID) 소멸 (SIGTERM, retry $RETRY)"; break
      fi
      # 2단계: SIGKILL
      kill -9 "$PANE_PID" 2>/dev/null || true
      sleep 1
      if ! is_pane_alive "$PANE_ID"; then
        CLEANED=true; echo "✅ $AGENT_NAME ($PANE_ID) 소멸 (SIGKILL, retry $RETRY)"; break
      fi
    fi
    # 3단계: tmux kill-pane (PID 없는 좀비 포함, status off 상태)
    tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
    sleep 1
    if ! is_pane_alive "$PANE_ID"; then
      CLEANED=true; echo "✅ $AGENT_NAME ($PANE_ID) 소멸 (kill-pane, retry $RETRY)"; break
    fi
    echo "⚠️ $AGENT_NAME ($PANE_ID) 재시도 $RETRY/3 실패"
  done

  if [ "$CLEANED" = true ]; then
    rm -f "$AGENT_FILE"
  else
    echo "❌ $AGENT_NAME ($PANE_ID) 3회 재시도 실패 → orphan 기록"
    mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes"
    echo "$(date +%s) $PANE_ID" >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
    _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
    rm -f "$AGENT_FILE"
  fi
done

tmux set -g status on 2>/dev/null || true

# 디렉토리 비어있으면 삭제
if [ "$DRY_RUN" = false ] && [ -d "$AGENTS_DIR" ]; then
  REMAINING=$(ls "$AGENTS_DIR" 2>/dev/null | wc -l)
  if [ "$REMAINING" -eq 0 ]; then
    rmdir "$AGENTS_DIR" 2>/dev/null || true
    echo "🗑️ 에이전트 등록 디렉토리 삭제: $AGENTS_DIR"
  fi
fi
fi  # SKIP_AGENT_CLEANUP

# bash 고아 pane 전수 정리 (L-280)
# agents/ 미등록 + 현재 세션 + bash 상태 pane → 즉시 정리 대상
if [ "$DRY_RUN" = false ]; then
  MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
  MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
  if [ -z "$MY_PANE" ]; then
    echo "⚠️ MY_PANE 빈값 — 고아 pane 정리 스킵 (메인 pane 보호)"
  elif [ -n "$MY_SESSION" ]; then
    # [L-394] self-kill 절대 방어: 메인 pane bash의 자식 PID(=메인 Claude Code 프로세스) 식별
    # 다른 pane을 정리할 때 SPID/자식 PID가 메인 Claude Code와 일치하면 즉시 skip
    MY_PANE_PID=$(tmux display-message -p -t "$MY_PANE" '#{pane_pid}' 2>/dev/null || true)
    MY_CLAUDE_PIDS=""
    if [ -n "$MY_PANE_PID" ]; then
      MY_CLAUDE_PIDS=$(pgrep -P "$MY_PANE_PID" 2>/dev/null | tr '\n' ' ')
    fi
    while IFS=' ' read -r SPANE SCMD SPID; do
      [ -z "$SPANE" ] && continue
      [ "$SPANE" = "$MY_PANE" ] && continue    # 메인 pane 제외
      # [L-394] SPID 또는 그 자식 PID가 메인 Claude Code 프로세스와 일치하면 절대 kill 금지
      if [ -n "$SPID" ] && [ -n "$MY_CLAUDE_PIDS" ]; then
        _SELF_HIT=false
        for _MCP in $MY_CLAUDE_PIDS; do
          if [ "$SPID" = "$_MCP" ]; then
            echo "🛡️ [L-394] self-kill 차단: $SPANE SPID=$SPID = 메인 Claude Code"
            _SELF_HIT=true; break
          fi
        done
        if [ "$_SELF_HIT" = false ]; then
          SPID_CHILDREN=$(pgrep -P "$SPID" 2>/dev/null | tr '\n' ' ')
          for _SC in $SPID_CHILDREN; do
            for _MCP in $MY_CLAUDE_PIDS; do
              if [ "$_SC" = "$_MCP" ]; then
                echo "🛡️ [L-394] self-kill 차단: $SPANE 자식 $_SC = 메인 Claude Code"
                _SELF_HIT=true; break 2
              fi
            done
          done
        fi
        [ "$_SELF_HIT" = true ] && continue
      fi
      # bash 또는 현재 세션 소속 고아 에이전트(2.1.x/claude/node) 모두 대상
      case "$SCMD" in
        bash) ;; # bash 고아 → 정리
        *)
          # bash 아닌 pane: 자식 프로세스 CMD에 --parent-session-id $SID 포함 여부로 자기 팀 소속 판별
          CHILD_CMD=""
          if [ -n "$SPID" ]; then
            CHILD_PID=$(pgrep -P "$SPID" 2>/dev/null | head -1)
            [ -n "$CHILD_PID" ] && CHILD_CMD=$(ps -p "$CHILD_PID" -o cmd= 2>/dev/null || true)
          fi
          if [ -n "$CHILD_CMD" ] && echo "$CHILD_CMD" | grep -qF -- "--parent-session-id $SID"; then
            echo "🔍 고아 에이전트 pane 감지: $SPANE (CMD=$SCMD, 자식=$CHILD_CMD)"
          else
            continue  # 자기 팀 소속 아님 → 스킵 (L-213 보호)
          fi
          ;;
      esac

      # L-213: 다른 세션 agents/에 등록된 pane이면 절대 kill 금지
      # 현재 세션(SID) agents/는 제외 — 현재 세션 bash 고아는 정리 허용
      # [P2-isolation] pane_index 파일 기반 O(1) 조회 — agents/* 전체 grep 제거
      REGISTERED=false
      for _idx_file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"/*/panes/pane_index; do
        [ -f "$_idx_file" ] || continue
        _af_uuid=$(basename "$(dirname "$(dirname "$_idx_file")")")
        [ "$_af_uuid" = "$SID" ] && continue  # 현재 세션 스킵
        if grep -qF "${SPANE}=" "$_idx_file" 2>/dev/null; then
          REGISTERED=true; break
        fi
      done
      # [§(a)(c) FIX-06] fallback 타 세션 agents/* 스캔 제거 — pane_index 없는 구세대 세션은 fail-closed
      # REGISTERED=false 유지 → 해당 pane은 kill하지 않음 (오탐 방지 우선)
      [ "$REGISTERED" = true ] && continue

      # 미등록 고아 pane → kill escalation (bash + 고아 에이전트 모두)
      echo "🔍 고아 pane 감지: $SPANE (CMD=$SCMD, PID=$SPID) — 정리 시작"
      ORPHAN_CLEANED=false
      # 자식 프로세스(claude/2.1.x) 먼저 종료
      if [ -n "$SPID" ] && [ "$SCMD" != "bash" ]; then
        pgrep -P "$SPID" 2>/dev/null | xargs -r kill 2>/dev/null || true
        sleep 1
      fi
      for ORETRY in 1 2 3; do
        if [ -n "$SPID" ]; then
          kill "$SPID" 2>/dev/null || true
          sleep 1
          if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SPANE"; then
            echo "✅ 고아 pane $SPANE 소멸 (SIGTERM, retry $ORETRY)"
            ORPHAN_CLEANED=true; break
          fi
          kill -9 "$SPID" 2>/dev/null || true
          sleep 1
          if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SPANE"; then
            echo "✅ 고아 pane $SPANE 소멸 (SIGKILL, retry $ORETRY)"
            ORPHAN_CLEANED=true; break
          fi
        fi
        tmux kill-pane -t "$SPANE" 2>/dev/null || true
        sleep 1
        if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SPANE"; then
          echo "✅ 고아 pane $SPANE 소멸 (kill-pane, retry $ORETRY)"
          ORPHAN_CLEANED=true; break
        fi
        echo "⚠️ 고아 pane $SPANE 재시도 $ORETRY/3 실패"
      done
      if [ "$ORPHAN_CLEANED" = false ]; then
        echo "❌ 고아 pane $SPANE 3회 재시도 실패 → orphan 기록"
        mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes"
        echo "$(date +%s) $SPANE" >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
        _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
      fi
    done < <(tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null)
  fi
fi

# M-09: orphans 자동 정리 — 24시간 이상 된 항목 제거
ORPHANS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/panes/orphans"
if [ -f "$ORPHANS_FILE" ]; then
  NOW=$(date +%s)
  CUTOFF=$((NOW - 86400))
  TMP_ORPHANS="${ORPHANS_FILE}.tmp.$$"
  while IFS=' ' read -r TS PANE_ID REST; do
    if [ -n "$TS" ] && [ "$TS" -gt "$CUTOFF" ] 2>/dev/null; then
      echo "$TS $PANE_ID $REST" >> "$TMP_ORPHANS"
    fi
  done < "$ORPHANS_FILE"
  if [ -f "$TMP_ORPHANS" ]; then
    mv "$TMP_ORPHANS" "$ORPHANS_FILE"
  else
    rm -f "$ORPHANS_FILE"
  fi
fi

# ━━━ 전수 스캔: agents/ 화이트리스트 기반 잔류 pane 정리 (L-287) ━━━
# agents/*.json 등록 pane만 cleanup 대상 — 미등록 pane은 오탐 방지를 위해 skip
MY_PANE="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)}"
MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)

# teams 화이트리스트: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{TEAM_NAME}/agents/*.json에서 pane_id 추출
# TEAM_NAME이 없으면 session-env/${SID}/team_name 파일에서 로딩 시도
_EFFECTIVE_TEAM="${TEAM_NAME}"
if [ -z "$_EFFECTIVE_TEAM" ] && [ -n "$SID" ]; then
  _EFFECTIVE_TEAM=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}/team_name" 2>/dev/null || true)
fi

WHITELIST_PANES=""
if [ -n "$_EFFECTIVE_TEAM" ]; then
  AGENTS_JSON_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${_EFFECTIVE_TEAM}/agents"
  if [ -d "$AGENTS_JSON_DIR" ]; then
    for _jf in "$AGENTS_JSON_DIR"/*.json; do
      [ -f "$_jf" ] || continue
      _jpane=$(python3 -c "import json,sys; d=json.load(open('$_jf')); print(d.get('pane_id',''))" 2>/dev/null || true)
      [ -n "$_jpane" ] && WHITELIST_PANES="${WHITELIST_PANES} ${_jpane}"
    done
  fi
fi

# agents/ 파일(session-env)에서도 pane_id 보충 (기존 방식과 통합)
if [ -d "$AGENTS_DIR" ]; then
  for _af in "$AGENTS_DIR"/*; do
    [ -f "$_af" ] || continue
    _apane=$(grep "^pane_id=" "$_af" 2>/dev/null | cut -d= -f2)
    [ -n "$_apane" ] && WHITELIST_PANES="${WHITELIST_PANES} ${_apane}"
  done
fi

if [ -n "$MY_PANE" ] && [ -n "$MY_SESSION" ]; then
  ALL_PANES=$(tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null | grep -v "^${MY_PANE} " || true)
  if [ -n "$ALL_PANES" ]; then
    echo "🔍 전수 스캔: agents/ 화이트리스트 기반 잔류 pane 정리"
    echo "$ALL_PANES" | while read SPANE SCMD SPID; do
      [ -z "$SPANE" ] && continue
      SPANE_SESSION=$(tmux display-message -t "$SPANE" -p '#{session_name}' 2>/dev/null || echo "")
      if [ "$SPANE_SESSION" != "$MY_SESSION" ]; then
        echo "  ⚠️ $SPANE (CMD=$SCMD) — 다른 세션 소속: L-213 보호"
        continue
      fi
      # 화이트리스트 체크: agents/*.json에 등록된 pane이 아니면 skip
      if [ -n "$WHITELIST_PANES" ]; then
        _in_whitelist=false
        for _wp in $WHITELIST_PANES; do
          [ "$_wp" = "$SPANE" ] && _in_whitelist=true && break
        done
        if [ "$_in_whitelist" = false ]; then
          echo "  ⏭️ $SPANE (CMD=$SCMD) — agents/ 미등록 pane: skip (오탐 방지)"
          continue
        fi
      fi
      echo "  → 잔류 pane $SPANE (CMD=$SCMD, PID=$SPID) — kill escalation"
      pgrep -P "$SPID" 2>/dev/null | xargs -r kill 2>/dev/null
      sleep 1
      tmux set -g status off 2>/dev/null || true
      [ -n "$SPID" ] && kill "$SPID" 2>/dev/null
      sleep 1
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SPANE"; then
        kill -9 "$SPID" 2>/dev/null
        sleep 1
      fi
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SPANE"; then
        tmux kill-pane -t "$SPANE" 2>/dev/null
        sleep 1
      fi
      tmux set -g status on 2>/dev/null || true
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$SPANE"; then
        echo "  ⚠️ $SPANE 미소멸 — orphan 기록"
      else
        echo "  ✅ $SPANE 소멸 완료"
      fi
    done
  fi
fi

echo "🧹 pane 정리 완료"
