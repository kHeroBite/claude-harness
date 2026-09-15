---
name: oinit
description: "강제 초기화/정리 스킬 — 팀에이전트·tmux pane 진단 + 비정상 정리 + 잔류 pane kill + state IDLE 강제 전이. ofinish에서 항상 호출. 수동 호출(/oinit): 강제 초기화/전부 중지/다 멈춰/파이프라인 초기화/긴급 종료/메인 무응답/팀 무응답/pane 고착/compact 후 위치 소실 등 모든 비정상 상황. 항상 강제모드 — 모든 hook 우회 + 진단 skip 가능 + 정리 + IDLE 강제 전이. 완주(재개)는 oresume 별도. (v2.1.178+: TeamCreate/TeamDelete 제거 — Agent 자동 팀 관리, 팀 디렉토리는 세션 종료 시 자동 정리.)"
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [ofinish, 사용자]
  calls: []
---

# oinit — 강제 초기화/정리 스킬

**실행 주체**: 메인 에이전트 전용
**실행 시점**: ofinish Step 1 내 자동 호출 / 또는 `/oinit`으로 수동 독립 실행
**목적**: 팀에이전트·pane 비정상 감지·정리 + 잔류 pane kill + state IDLE 강제 전이

> **v2.1.178+ 변경 (Claude Code 공식)**: TeamCreate/TeamDelete 도구가 제거됨. Agent(name=, team_name=) 호출만으로 팀/pane/config.json이 자동 생성되고 세션 종료 시 자동 정리된다. in-process 캐시 개념이 없으므로 "Already leading team"·"inprocess_stuck" 류 워크어라운드는 더 이상 발생하지 않는다.
> **⚠️ 절대 금지 (실측 교훈)**: 세션 활성 중 `teams/<name>/` 디렉토리를 수동 dir_delete/rm 하면 "team file not found"로 이후 모든 Agent 호출이 전면 차단된다. 팀 디렉토리 물리 삭제는 절대 하지 말고 세션 종료 시 자동 정리에 위임한다. 잔류 팀에이전트 pane 정리가 필요하면 tmux kill-pane(팀에이전트 pane만, 메인 pane 절대 금지 — L-304)만 사용한다.

> **항상 강제모드**: 모든 hook 우회 + 진단 skip 가능 + 정리 강제 + IDLE 강제 전이.
> **완주(재개)는 별도**: 중단된 파이프라인 재개는 `/oresume` 전담 — oinit은 정리·초기화만.

> **팀에이전트 spawn 완전 금지 (L-360)**: DEV 상태에서 팀에이전트 spawn(과거 TeamCreate + Agent 조합)이
> 메인 세션을 100% 팅기게 함. oinit은 항상 메인이 직접 Step 0~10 수행. (v2.1.178+: TeamCreate 제거 — spawn 금지 원칙은 유지.)

## 트리거 키워드

- `/oinit` — 직접 호출
- "강제 초기화", "전부 중지", "다 멈춰", "파이프라인 초기화", "긴급 종료", "모든 작업 중지"
- "그만 종료", "이만 멈춤", "작업 끝낼게", "여기까지" — 사용자 의도적 종료 (구 /oexit 흡수 — 2026-05-11)
  ※ 흡수 후 oinit은 항상 즉시 실행(사용자 확인 없음). 의도적 종료도 oinit이 동일하게 처리한다.
- (v2.1.178+ 해당 없음 — Agent 자동 팀 관리) "TeamCreate already leading" / "Already leading team" / "in-process 캐시 잔존" 류는 TeamCreate/TeamDelete 제거로 더 이상 발생하지 않음. 잔류 pane 고착 시에만 oinit 호출.

## 적용 범위 (자기 세션만 — 세션 격리 불변식 준수)

- ✅ 현재 UUID의 `session-env/${UUID}/` 하위 전부
- ✅ 현재 UUID가 leadSessionId인 `teams/<name>/` + `tasks/<name>/` 디렉토리
- ✅ 현재 PIPELINE_UUID와 매칭되는 tmux pane/window
- ❌ 타 세션의 session-env, teams, tmux 세션은 절대 건드리지 않음 (격리 §a/§b/§c/§d)

## Hook 우회 (강제모드)

이 스킬의 모든 정리 명령은 자기 세션의 `session-env/${UUID}/` 하위 + 자기 소유 `teams/<name>/`에만 작용한다.
`write_guard.sh` 분기 구조상 다음 경로는 활성 상태에서도 통과한다:

```yaml
이미_우회되는_경로:
  - mcp__oio__bash_exec + .claude/ 또는 session-env/ 참조 + /mnt/[c-z]/ 미참조 → exit 0
  - mcp__oio__bash_exec + tmux 읽기/kill 명령 + NTFS 프로젝트 경로 없음 → exit 0
  - mcp__oio__file_delete/dir_delete + session-env/${UUID}/ 하위 → F-OEXIT-1 분기로 exit 0
  - mcp__oio__session_state(force=true) → state_machine 경유 IDLE 전이 합법

차단_가능_경로_회피:
  - state 파일 직접 file_delete 금지 (F1) → session_state(force=true)로 IDLE 기록
  - /mnt/[c-z]/ 경로 직접 쓰기 금지 → 본 스킬 범위 외이므로 시도 자체 안 함
  - run_in_background=true 금지 (F10) → 모든 명령은 foreground 동기 실행
```

## 팀 관리 — v2.1.178+ 해당 없음 (Agent 자동 팀 관리)

**v2.1.178+ 변경**: TeamCreate/TeamDelete 도구가 제거되었고 in-process 캐시 개념도 사라졌다. 따라서 옛 "Already leading team" / "already exists" 차단 증상은 더 이상 발생하지 않으며, 그 워크어라운드(TeamDelete 1차/2차/3차 호출, rm -rf teams/, inprocess_stuck 마커)는 모두 불필요하다.

**현재 모델**:
- Agent(name=, team_name=) 호출만으로 팀/pane/config.json이 자동 생성된다.
- 팀 디렉토리(`teams/<name>/`, `tasks/<name>/`)는 세션 종료 시 Claude Code가 자동 정리한다.
- ⚠️ **세션 활성 중 `teams/<name>/`를 수동 dir_delete/rm 하면 "team file not found"로 이후 모든 Agent 호출이 전면 차단된다.** 팀 디렉토리는 절대 물리 삭제하지 말 것.

**잔류 정리가 필요한 경우**: 고착된 팀에이전트 pane만 tmux kill-pane으로 정리한다 (메인 pane 절대 금지 — L-304). session-env/${UUID}/ 하위 파일(team_name, state 등) 정리는 무방하다 (teams/ 디렉토리가 아님).

---

## 독립 실행 vs ofinish 내 호출 차이

```yaml
ofinish_내_호출 (자동):
  - pipeline_state가 이미 FINISH로 전환된 상태에서 호출됨
  - Step 9(파이프라인 재개)는 스킵 — ofinish가 이후 단계 담당

독립_실행 (/oinit 수동):
  - pipeline_state 변경 없음 (현재 상태 유지)
  - Step 9(파이프라인 재개 판단) 실행 — 비정상 상황 복구 목적
```

---

## 실행 주체 결정 원칙 (L-360)

```yaml
실행_주체: 메인 에이전트가 항상 직접 Step 0~10 수행 (파이프라인 상태 무관)
Agent_호출_절대_금지: DEV 상태에서 팀에이전트 spawn(과거 TeamCreate + Agent 조합) → 메인 세션 팅김. (v2.1.178+: TeamCreate 제거 — Agent spawn 자체 금지 원칙 유지.)

비IDLE 상태에서 oio 허용 범위 (write_guard.sh 기준):
  - mcp__oio__bash_exec: .claude/ 경로 참조 명령 → 허용
  - mcp__oio__bash_exec: tmux 읽기 전용 명령 → 허용
  - mcp__oio__bash_exec: team-report.sh, team-cleanup.sh → 허용
  - mcp__oio__file_edit: .claude/ 하위 파일 → 허용
```

---

## session-env 범위 이해 (오진 방지 필수)

```yaml
session-env_구조:
  위치: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/
  범위: 모든 tmux 세션이 공유하는 글로벌 디렉토리
  의미: UUID 하나 = Claude Code 세션(대화) 하나

  ⚠️ 흔한 오진 패턴:
    team-report.sh에 "타세션 활성 에이전트" 표시됨
    → 다른 프로젝트에서 정상 실행 중인 에이전트 — 정리 대상 아님 (L-213 보호)

  이_세션_관련_파이프라인_식별:
    방법: MY_SESSION=$(tmux display-message -p '#{session_name}')
          에이전트 pane의 session_name == MY_SESSION인 것만 이 세션 소속
```

---

## 실행 절차 (번호순 엄수 — 스킵 절대 금지)

```
/oinit 호출 (또는 ofinish 내 Skill('oinit'))
  ↓
Step 0:   스크립트 존재 확인 (team-report.sh, team-cleanup.sh)
  ↓
Step 1:   pane 목록 확인 + capture-pane 내용 수집 (마지막 3줄)
  ↓
Step 1.5: SendMessage probe 발송 (응답 대기 없이) + capture-pane 재확인
  ↓
Step 2:   ★ team-report.sh 실행 — 물리적 현황 리포팅
  ↓
Step 3:   ★ team-cleanup.sh --dry-run — 정리 대상 미리보기
  ↓
Step 4:   리포트 분석 + CASE별 복구 판단
  ↓
Step 5:   ★ team-cleanup.sh --force + pane 잔류 재확인
  ↓
Step 6:   잔류 팀에이전트 pane kill (v2.1.178+: TeamDelete/rm-rf 우회 제거 — 팀 디렉토리 자동 정리)
  ↓
Step 7:   잔류 파일 정리 (agents/, evidence/, panes/, compact/)
  ↓
Step 8:   표 형태 통합 리포팅 + ofinish_cleanup_done 마커 생성
  ↓
Step 9:   파이프라인 재개 판단 (독립 실행 시만) + ofinish_done까지 자동 완주
  ↓
Step 10:  재발방지 — 원인 분석 + oinit SKILL.md 자체 수정 (CASE 0건이어도 필수)
```

> **★ = 필수 셸 스크립트 실행 (AI가 tmux 명령을 직접 실행하여 진단하는 것 금지)**

---

### Step 0: 스크립트 존재 확인

```yaml
명령: |
  [ -f ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/team-report.sh ] || echo "⚠️ team-report.sh 미존재 — fallback 모드"
  [ -f ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/team-cleanup.sh ] || echo "⚠️ team-cleanup.sh 미존재 — fallback 모드"

Fallback_동작:
  team-report.sh 미존재 시:
    - tmux list-panes -a -F '#{pane_id} #{pane_title}' 로 직접 pane 상태 출력
    - [P2-isolation §(c)] 자기 세션만 확인 (타 세션 session-env/*/ 순회 금지):
        st=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state" 2>/dev/null | awk '{print $1}' || echo "?")
        echo "UUID=${UUID} STATE=$st"
  team-cleanup.sh 미존재 시:
    - tmux kill-pane -t {pane_id} 로 직접 정리
    - agents/ 디렉토리 수동 삭제
```

### Step 1: pane 목록 확인 + capture-pane 내용 수집

```yaml
목적: 현재 세션의 모든 pane을 직접 열거하고 마지막 3줄 내용을 수집
도구: mcp__oio__bash_exec

1-A. pane 목록 수집:
  명령: |
    MY_SESSION=$(tmux display-message -p '#{session_name}')
    MY_PANE=$(tmux display-message -p '#{pane_id}')
    tmux list-panes -t "$MY_SESSION" -F \
      '#{pane_id} #{pane_pid} #{pane_current_command} #{pane_width}x#{pane_height} #{pane_dead}'
  출력: pane_id, PID, 실행중 CMD, 크기, 생존여부 목록

1-B. capture-pane 내용 수집 (MY_PANE 제외):
  명령: |
    MY_PANE=$(tmux display-message -p '#{pane_id}')
    for PANE_ID in $(tmux list-panes -t "$MY_SESSION" -F '#{pane_id}'); do
      [ "$PANE_ID" = "$MY_PANE" ] && continue  # 메인 pane 스킵
      LAST3=$(tmux capture-pane -p -t "$PANE_ID" 2>/dev/null | grep -v '^$' | tail -3)
      echo "=== PANE $PANE_ID ==="
      echo "$LAST3"
    done
  ⚠️ pane_id 명시 필수 (L-350): tmux capture-pane -t "$PANE_ID" 형식 엄수
  ⚠️ MY_PANE 자신은 절대 캡처 금지 (oio bash_exec 서브쉘 오탐 위험)

1-C. agents/ 등록 목록과 교차:
  명령: ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/" 2>/dev/null
  목적: 등록된 에이전트 이름 목록 수집 → Step 1.5 SendMessage probe 대상 결정
```

### Step 1.5: SendMessage probe 발송 + capture-pane 재확인

```yaml
목적: 살아있는 팀에이전트에게 상태 질의 메시지를 보내고 pane 응답으로 현황 파악
원칙 (L-331): SendMessage 응답 대기 금지 — 발송 후 즉시 capture-pane으로 확인

절차:
  1. agents/ 목록의 각 에이전트에게 SendMessage 발송:
       SendMessage({
         to: "{agent-id}",
         message: "[oinit] 현재 상태를 한 줄로 보고하라. (진행중 작업명, 완료여부)"
       })
     발송 후 즉시 다음 에이전트로 진행 — 응답 대기 절대 금지

  2. 10초 대기 (응답 수신 시간 허용):
       mcp__oio__bash_exec: sleep 10

  3. 각 에이전트 pane capture-pane 재수집:
       for PANE_ID in {Step 1에서 수집한 에이전트 pane 목록}; do
         LAST3=$(tmux capture-pane -p -t "$PANE_ID" 2>/dev/null | grep -v '^$' | tail -3)
         echo "=== PANE $PANE_ID (probe 후) ==="
         echo "$LAST3"
       done

  4. 응답 유무 판정:
     응답_있음: pane 내용이 "[oinit]" 질의 이후 변화 있음 → 정상 활동 중
     응답_없음: pane 내용 변화 없음 → 비정상 후보 (Step 4에서 CASE 분류)
     pane_없음:  에이전트 등록 but pane 소멸 → CASE-4 (bash 빠짐 or 종료)

에이전트_없음_처리:
  agents/ 비어있음 → SendMessage 발송 대상 없음 → Step 1.5 스킵 → Step 2 진행
```

### Step 2: ★ team-report.sh 실행 (현황 스냅샷)

```yaml
도구: mcp__oio__bash_exec
명령: bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/team-report.sh
목적: 정리 전 현재 팀에이전트/pane 현황 스냅샷 기록

⚠️ oio EXEC_ERROR (UTF-8 디코딩 실패) 시 즉시 fallback (L-361):
  원인: team-report.sh 출력에 이모지(📊 등) 포함 → oio bash_exec stdout 디코딩 실패
  fallback: 자기 세션 상태만 확인 (§(c) 준수 — 타 세션 정보 stdout 출력 금지)
    ```bash
    # [P2-isolation] Fix 31: 전체 session-env/*/ 순회 → 자기 세션만 확인으로 교체
    # ★bash -c 래핑 필수 — bash_exec 셸은 /bin/sh(dash) 이고 dash 에는 source 가 없다.★
    #   미래핑 시 state_read 가 rc=127 로 죽어 빈 문자열이 되고 상태 판정이 통째로 어긋난다 (2026-08-26 실측).
    st=$(bash -c 'source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh" 2>/dev/null; state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/'"${UUID}"'/state"' 2>/dev/null | awk '{print $1}' || echo "?")
    st="${st:-?}"
    echo "UUID=${UUID} STATE=$st"
    ```
  이후: tmux list-panes + ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/ 직접 확인으로 진단 계속
```

### Step 3: ★ team-cleanup.sh --dry-run (정리 대상 미리보기)

```yaml
도구: mcp__oio__bash_exec
명령: bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/team-cleanup.sh --dry-run

⚠️ --force 실행 전 필수 확인 (L-339):
  dry-run 출력에서 현재 세션의 2.1.x pane이 "고아 pane으로 kill 예정"으로 표시될 수 있음.
  이는 cleanup.sh가 --agent-id 없는 2.1.x pane을 고아로 오판정하는 패턴.

  확인 절차:
    1. MY_PANE=$(tmux display-message -p '#{pane_id}') → kill 예정 pane_id와 비교
    2. kill 예정 pane이 MY_PANE과 다르면 → --agent-id 플래그 확인:
         for P in {kill 예정 pane들}; do
           PID=$(tmux display-message -t "$P" -p '#{pane_pid}')
           CHILD=$(pgrep -P "$PID" | head -1)
           ps -p "${CHILD:-$PID}" -o args= | grep -o '\-\-agent-id [^ ]*'
         done
    3. --agent-id 없음 → 메인 Claude pane → --force 금지
       --agent-id 있음 (e.g. oplan-1@team) → 팀에이전트 잔류 → --force 안전

  현재 세션의 메인 Claude pane(2.1.x, --agent-id 없음)이 포함되어 있으면 --force 금지.
  대안: 고착 파이프라인 리셋은 state IDLE 강제 전이(Step 9)로 처리. (v2.1.178+: 팀 디렉토리 dir_delete 절대 금지 — "team file not found"로 Agent 전면 차단. 세션 종료 시 자동 정리에 위임.)
```

### Step 4: 리포트 분석 + CASE별 복구 판단

```yaml
판정_기준:
  pane 소멸: 정상 종료 (agents/ 파일 정리 대상)
  CMD=bash: CASE-4 bash 빠짐 → kill 대상
  CMD=2.1.x + --agent-id 없음: 메인 Claude → L-213 보호 (절대 kill 금지)
  CMD=2.1.x + --agent-id 있음 + state=IDLE: CASE-8 종료 후 pane 잔류 → kill 대상
  CMD=2.1.x + --agent-id 있음 + state 비IDLE + evidence 없음: 정상 실행 중
  CMD=2.1.x + --agent-id 있음 + evidence 있음: 완료 → 다음 단계
```

### Step 5: ★ team-cleanup.sh --force + pane 잔류 재확인

```yaml
도구: mcp__oio__bash_exec
명령: bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/team-cleanup.sh --force

⚠️ --force 후 pane 잔류 재확인 필수 (L-362):
  원인: cleanup.sh가 활성 파이프라인 소속 pane을 L-328로 skip → kill 0건이어도 exit 0
  절차: |
    for PANE_ID in {dry-run에서 kill 대상으로 표시된 pane_id 목록}; do
      PANE_EXISTS=$(tmux display-message -t "$PANE_ID" -p '#{pane_id}' 2>/dev/null)
      [ -z "$PANE_EXISTS" ] && echo "✅ $PANE_ID 소멸 확인" && continue
      echo "⚠️ $PANE_ID 잔류 — 수동 kill escalation 즉시 실행"
      BASH_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null)
      CHILD_PID=$(pgrep -P "$BASH_PID" 2>/dev/null | head -1)
      kill "${CHILD_PID:-$BASH_PID}" 2>/dev/null; sleep 1
      kill -9 "${CHILD_PID:-$BASH_PID}" 2>/dev/null; kill -9 "$BASH_PID" 2>/dev/null; sleep 1
      tmux set -g status off 2>/dev/null
      tmux kill-pane -t "$PANE_ID" 2>/dev/null
      tmux set -g status on 2>/dev/null
      echo "✅ $PANE_ID kill 완료"
    done
  핵심: cleanup.sh --force 결과(exit code)를 믿지 말고 pane 실존 여부로 직접 확인

⚠️ [CASE-8 확장형] team-cleanup.sh IDLE pane 오판정:
  증상: --agent-id 보유 pane이 🧍IDLE 배너 상태인데 "활성 출력 감지"로 보호됨
  원인: capture-pane의 IDLE statusline timer(↓ N tokens 등)가 _active=true 오판정 유발
  대응: |
    해당 pane의 --agent-id 확인 후 현재 세션 UUID 일치 시 수동 kill escalation:
      BASH_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null)
      CHILD_PID=$(pgrep -P "$BASH_PID" 2>/dev/null | head -1)
      kill "${CHILD_PID:-$BASH_PID}" 2>/dev/null; sleep 1
      kill -9 "${CHILD_PID:-$BASH_PID}" 2>/dev/null
      tmux kill-pane -t "$PANE_ID" 2>/dev/null
    메인 pane(--agent-id 없음)은 절대 kill 금지 (L-213)
    근본 수정: team-cleanup.sh에 🧍IDLE 배너 직접 감지 조건 추가 (L-394)

⚠️ [CRITICAL — L-350] oio bash_exec 경유 시 MY_PANE 오탐 위험:
  team-cleanup.sh가 oio bash_exec 경유로 실행되면 tmux display-message가
  bash_exec 서브쉘의 임시 pane을 MY_PANE으로 반환할 수 있음.
  → 실제 메인 Claude pane이 고아로 오판정 → 메인 kill 사고 발생 (실제 사고: 2026-04-09)
  수정: team-cleanup.sh에 3차 방어선: claude/2.1.x CMD + --agent-id 없으면 무조건 kill 금지
  확인: dry-run 결과에 claude/2.1.x CMD pane이 포함되어 있으면 → --force 절대 금지
```

### Step 6: 잔류 팀에이전트 pane kill (v2.1.178+ — TeamDelete/rm-rf 우회 제거)

```yaml
# ⚠️ v2.1.178+ 변경: TeamCreate/TeamDelete 도구 제거. 팀 디렉토리는 세션 종료 시 자동 정리.
# 따라서 옛 "TeamDelete 1차/2차/3차 + rm -rf teams/ + inprocess_stuck 마커" 절차는 전부 제거됨.
# 이 단계에서는 잔류 팀에이전트 pane만 정리한다 (Step 5에서 이미 처리되지 않은 잔류분).

절대_금지 (실측 교훈):
  - teams/<name>/ 디렉토리 수동 dir_delete/rm 절대 금지.
    세션 활성 중 삭제하면 "team file not found"로 이후 모든 Agent 호출이 전면 차단됨.
  - 팀 디렉토리 정리는 세션 종료 시 Claude Code 자동 정리에 위임한다.
  - 메인 pane kill 절대 금지 (--agent-id 없는 pane — L-304/L-213).

★ kill 전 pane 캡처 의무 (2026-08-17 신규 — 생략 금지):
  근거: 2026-08-17 verify-1 무응답 원인 규명이 pane 캡처 하나로 확정됐다.
        캡처 없이 kill했으면 "NTFS git 블로킹"(가설 A)으로 오종결됐을 것이다.
        kill은 증거를 영구 소멸시킨다. 캡처는 되돌릴 수 없는 조치 이전에만 가능하다.
  규칙: 어떤 팀에이전트 pane이든 kill 하기 **전에** 반드시 전체 스크롤백을 캡처해 파일로 남긴다.
  명령:
    CAP_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/pane_capture"
    mkdir -p "$CAP_DIR"
    tmux capture-pane -p -S -3000 -t "$PANE_ID" > "$CAP_DIR/${PANE_ID//%/}_$(date +%Y%m%d_%H%M%S).txt" 2>/dev/null || true
  주의:
    - `-S -3000` 필수 — 기본 캡처는 현재 화면만 담아 원인 구간이 잘린다.
    - pane_id 명시 필수 (L-350).
    - 캡처 실패는 kill을 막지 않는다 (fail-open). 단 실패 사실을 출력에 남긴다.
    - 특히 "무응답" 판정으로 kill하는 경우 캡처는 **필수 중의 필수** — 그 pane의 마지막 화면이
      원인 규명의 유일한 증거다 (SendMessage 미호출 여부는 캡처로만 확인된다).

절차:
  1. Step 5에서 kill 대상으로 식별된 팀에이전트 pane 중 잔류분이 있으면 tmux kill-pane으로 정리:
       ★ 1-A. kill 직전 위 "kill 전 pane 캡처 의무" 절차를 먼저 수행한다 (캡처 → 그 다음 kill).
       (kill escalation 절차는 Step 5와 동일 — BASH_PID/CHILD_PID kill 후 tmux kill-pane)
     팀에이전트 pane은 --agent-id 보유 pane만 대상으로 한다.
  2. session-env/${UUID}/ 하위 파일(team_name 등) 정리는 Step 7에서 수행 (teams/ 디렉토리가 아니므로 무방).
  3. 잔류 pane 0건이면 "정리 대상 없음" 출력 후 Step 7로 진행.
```

### Step 7: 잔류 파일 정리

```yaml
# UUID 디렉토리는 ofinish Step 4에서 일괄 삭제 (여기서 삭제 금지)
# Step 4/5에서 정리되지 않은 팀별 잔류 파일만 정리
대상: agents/, evidence/, panes/, compact/ (팀별 개별 파일)

★7-A. agents/ + inboxes 양쪽 base 정리 (F-ROSTER-1 — 2026-09-13 신설, 생략 금지)★
  명령: bash -c 'source ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/agent_roster_cleanup.sh; cleanup_agent_roster "${UUID}" "${TEAM_NAME}"'

  배경 (사이클123 진단의 절반이 틀렸다):
    사이클123 은 "roster 는 Claude Code in-memory 라 우리가 못 지운다"(Issue #27639)로
    결론내고 spawn 총량 감축만 조치했다. 사이클125 실측에서 드러난 것은 이렇다.
      · pane 0건 / 프로세스 0건 (정상 종료 확인)
      · teams/<팀>/config.json 의 members[].isActive = ★전부 false★ (종료가 정상 기록됨)
      · 그런데 ★$HOME 쪽 session-env/<UUID>/agents/ 에 21건 잔존★
        (사이클123 것까지 섞여 있었다 — 파일이라 세션 재시작으로도 안 지워진다)
    ⇒ "in-memory 라 못 지운다" 는 ★roster 표시★ 에만 해당한다. 디스크 잔존물은 우리 소관이다.
    ⇒ 진짜 원인은 ★경로 이중화★ — 정리 코드가 ${CLAUDE_CONFIG_DIR} 쪽만 비우고 $HOME 쪽을 빠뜨렸다.
      두 base 가 동시 실존하는 세션에서 한쪽만 지우면 나머지가 영구 누적된다.

  판정 기준:
    ★프로세스 실존으로만 판정한다★ — agents/ 파일 존재는 생존의 증거가 아니다(10시간 잔존 실측).
    `ps -eo args | grep -- "--agent-id <name>@" | grep -v "grep "` 가 0건이면 죽은 것이다.
    ⚠️ `grep -v "grep "` 누락 시 자기 명령줄을 세어 "살아 있다"로 오판한다(실측 오카운트 사례).

  절대 금지:
    · teams/<name>/ ★디렉토리 삭제★ — 세션 활성 중 삭제하면 "team file not found" 로
      이후 모든 Agent 호출이 전면 차단된다(실측). 디렉토리와 config.json 은 보존한다.
    · team-lead 메일함(inboxes/team-lead.json) 삭제 — 메인 수신 경로다.
    · 타 세션 소유 정리 — 자기 UUID 하위 + 자기 소유 팀만 대상이다(세션 격리 §a/§b).

  한계 (숨기지 않는다):
    FleetView 목록 표시 자체는 도구 in-memory 영역이라 이 조치로 사라지지 않는다.
    isActive=false 멤버를 목록에서 빼는 것은 Claude Code 구현 소관이다(Issue #27639).
    이 조치가 보장하는 것은 ★디스크가 진실을 반영하는 것★ 이며,
    다음 세션이 잔존 파일을 "살아 있는 에이전트"로 오판하는 일을 막는다.
```

### Step 8: 표 형태 통합 리포팅 + 완료 마커 생성

```yaml
8-1. 표 형태 리포팅 (핵심 출력):
  목적: Step 1~8에서 수집한 모든 데이터를 Markdown 표로 출력
  형식: |
    ## 🔍 oinit 진단 리포트
    
    | 에이전트명 | pane ID | 상태 | probe 응답 | 마지막 메시지 (3줄) | 처리 결과 |
    |-----------|---------|------|-----------|-------------------|-----------|
    | odev-1    | %1      | 정상 | 응답      | line1 / line2 / line3 | 유지 |
    | oplan-1   | %2      | 비정상 | 무응답  | (빈 pane)         | kill 완료 |
    | (미등록)  | %3      | 고아  | N/A       | bash $ ...        | kill 완료 |
    
    **요약**: 총 pane {N}개 | 정상 {N}개 | 비정상 {N}개 → {N}개 정리
    **완료 마커**: ofinish_cleanup_done {생성됨/실패}

  데이터_소스:
    에이전트명: agents/ 등록 파일명 (미등록 시 "(미등록)")
    pane_ID: tmux pane_id (%N 형식)
    상태: 정상/비정상/고아 (판정 매트릭스 기준)
    probe_응답: Step 1.5 SendMessage 응답 유무 (에이전트 없으면 "N/A")
    마지막_메시지_3줄: Step 1-B capture-pane 결과 → 줄바꿈은 " / "로 연결
    처리_결과: 유지/kill완료/pane정리완료/재spawn 등

  에이전트_없음_처리:
    agents/ 비어있고 메인 pane만 존재 → 표 생략, "정리 대상 없음" 한 줄만 출력

8-2. 완료 마커 생성:
  시점: Step 7(잔류 파일 정리) 완료 직후
  명령: mcp__oio__file_write(
    path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/ofinish_cleanup_done",
    content="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  )
  목적: ofinish_cleanup_done 마커로 정리 완료 여부 확인
  주의: 마커 생성 실패 시에도 Step 10 진행 (마커는 검증용, 차단 목적 아님)

8-3. 수량 불일치 추가 조치:
  agents > pane: pane 소멸 에이전트 → evidence 확인 → 완료면 다음, 미완료면 재spawn
  pane > agents: 미등록 bash 고아 pane → Step 5 kill escalation 즉시 실행
  팀멤버 > 0 && pane == 0: Agent tool 방식 → 정상 (pane 없음이 맞음)
  agents == 0 && 팀멤버 == 0 && pane > 0: 완전 고아 pane → 즉시 kill
```

### Step 9: state IDLE 강제 전이 (강제모드 — 항상 실행)

```yaml
조건: 항상 실행 (ofinish 내 호출 + 독립 실행 모두)
      ofinish 내 호출 시에는 ofinish의 후속 state 전이(IDLE)가 덮어쓰므로 무해 — 이중 안전.

명령: mcp__oio__session_state(uuid="${UUID}", key="state", value="IDLE", force=true)
⚠️ force=true 필수: 비표준 전이(PLAN/DEV/TEST/DONE → IDLE) 검증 우회
확인: mcp__oio__file_read(path="${SESSION_DIR}/state") → "IDLE ${UUID}" 출력 확인

원칙:
  - oinit은 정리·초기화만. 파이프라인 재개·완주는 oresume이 전담.
  - "다음 단계 spawn" 또는 "ofinish_done까지 자동 완주" 로직은 oinit에서 제외됨 (2026-05-11 분리).
  - 사용자가 마무리를 원하면 별도로 /oresume 또는 /ofinish 호출.

재개_안내 (선택적 출력):
  if [ -e "${SESSION_DIR}/checkpoint.jsonl" ] && ! [ -e "${SESSION_DIR}/evidence/ofinish_done" ]; then
    echo "💡 중단된 파이프라인 재개를 원하면 /oresume 호출"
  fi
```

### Step 10: 재발방지 — 원인 분석 + SKILL.md 자체 수정 (절대 생략 금지)

```yaml
CASE_0건이어도_생략_불가 — 10-1(결과 요약)과 10-5(SKILL.md 갱신 여부)는 항상 실행.
CASE_1건_이상_시: 재발방지 수단 결정 후 /o1 또는 /o2 파이프라인 자동 호출 안내 출력 필수

절차:
  10-1: 이번 oinit 결과 요약 (CASE 수, 정리 항목, 불일치 패턴)
  10-2: 불일치 원인 분류 (A~J — CASE별 복구 조치 섹션 참조)
  10-3: 재발방지 수단 결정 (Hook > Script > Skill > 문서) → /o1 또는 /o2 파이프라인으로 실제 물리 조치 실행 필수
  10-4: 신규 패턴만 LESSONS.md 기록. CASE 0건 시 스킵.
  10-5: SKILL.md 자체 수정 (핵심). 신규 패턴 없으면 "갱신 불필요" 출력.
  10-6: 재발방지 보고 출력:
    ┌──────────────────────────────────────────────┐
    │ 🔒 재발방지 조치 (Step 10)                  │
    ├──────────────────────────────────────────────┤
    │ 발견된 불일치: N건                           │
    │ CASE-N: {원인 한줄} → 물리 조치: {수단}     │
    │ SKILL.md 자체 수정: ✅ {항목} / ⏭️ 불필요   │
    │ LESSONS.md 기록: ✅ L-{번호} / ⏭️ 스킵      │
    │ 다음 조치: /o2 "{이슈 제목}" 자동 호출 권고 │
    └──────────────────────────────────────────────┘

절대_금지:
  - Step 10 생략 ("특수 상황" 핑계 금지)
  - Memory 업데이트만으로 재발방지 완료 선언
  - SKILL.md 수정 없이 Step 10-5를 "완료" 처리
  - CASE 발견 후 SKILL.md/LESSONS.md 수정만으로 재발방지 완료 처리 (파이프라인 호출 없이 종료 금지)
```

---

## 2-way 병렬 진단

```yaml
진단-1: 팀에이전트 상태 판정 (pane 물리 상태 기반 — SendMessage 대기 금지)
  원칙 (L-331): pane 물리 상태로 즉시 판정. SendMessage 응답 대기 금지.
  절차:
    1. ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/ → 등록 에이전트 목록
    2. 각 에이전트 pane 물리 상태로 즉시 판정
    3. evidence/ 파일 기반 완료 판정 (SendMessage 없이)

진단-2: 에이전트 목록 ↔ pane 목록 양방향 교차 검증 (필수 — 항상 실행)
  명령: bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/ostatus-diagnose.sh "$UUID"
  A방향: agents/ 등록 → pane 실존 확인 (소멸/타세션/pane_id 누락 감지)
  B방향: 현재 세션 pane → agents/ 등록 확인 (bash 고아/미등록 에이전트 감지)
```

---

## 판정 매트릭스 (pane 물리 상태 기반 — L-331)

| pane 상태 | evidence 파일 | --agent-id | state | capture-pane | 판정 |
|-----------|--------------|------------|-------|--------------|------|
| 소멸 | - | - | - | - | ✅ 정상 종료 (agents/ 파일 정리) |
| bash | - | - | - | - | ⚠️ CASE-4: bash 빠짐 → 즉시 kill |
| 2.1.x | 있음 | 있음 | IDLE | - | ⚠️ CASE-8: 종료 후 pane 잔류 → kill |
| 2.1.x | 있음 | 있음 | 비IDLE | - | ✅ 완료 (다음 단계 진행) |
| 2.1.x | 없음 | 있음 | 비IDLE | - | ✅ 정상 실행 중 → oinit 종료 |
| 2.1.x | - | 있음 | IDLE | **완료 키워드** | ⚠️ **CASE-11 (L-392)**: kill 대상 |
| 2.1.x | - | 있음 | IDLE | 빈 prompt+IDLE 토큰 표시 | ⚠️ **CASE-11 (L-392)**: kill 대상 |
| 2.1.x | - | 없음 | - | - | ℹ️ 메인 Claude → L-213 보호 (절대 kill 금지) |

---

## CASE별 복구 조치

| CASE | 증상 | 원인 | 복구 |
|------|------|------|------|
| CASE-1 | 완료 메시지 미수신 | SendMessage 전달 실패 | evidence 확인 → 완료면 다음 단계, 미완료면 재spawn |
| CASE-2 | pane bash 대기 + shutdown 미수신 | compact/세션 이슈 | shutdown_request 재발송 → 응답 없으면 pane kill |
| CASE-3 | ofinish 후 pane/agents/ 잔류 | ofinish 중단 | 수동 kill + 팀 디렉토리 삭제 |
| CASE-4 | pane bash 빠짐, 에이전트 무응답 | 컨텍스트 초과 or 크래시, 또는 compact/세션 전환 후 `claude --resume {uuid}` 대기 pane 잔류 | evidence 확인 → 미완료면 재spawn. `claude --resume` 대기 pane은 즉시 kill 대상 (에이전트 아님) |
| CASE-5 | compact 후 파이프라인 위치 소실 | 컨텍스트 압축 | state/evidence 확인 후 현재 위치 재전달 |
| CASE-6 | 완료 보고 수신 but evidence 없음 | 거짓 보고 | git diff + evidence 교차 검증 → 재spawn |
| CASE-8 | state=IDLE 후 2.1.x pane 잔류 | 팀에이전트 프로세스 미종료 (세션 종료 시 자동 정리되나 활성 중 잔류) | --agent-id 확인 후 팀에이전트면 kill |
| CASE-10 | pane 빈 화면 + 120초+ 무응답 | pane 초기화 실패 | pane kill → Agent(name=, team_name=)로 재spawn (v2.1.178+: 팀 자동 생성) |
| CASE-12 | agents/ 등록 N개인데 pane 0개 + teams/<팀> 디렉토리 부재 | **Agent() 호출 시 `team_name`/`name` 누락** — 팀에이전트가 아니라 평범한 백그라운드 서브에이전트로 생성됨 (2026-09-06 실사고) | **kill 대상 아니다** (죽일 pane 자체가 없다). agents/ 파일만 정리하고 IDLE 전이. 재발방지는 `PreToolUse_Agent_team_param_guard.sh`(F-AGENT-1)가 담당 — L-968 참조. ⚠️ 이 CASE 는 **조용하다**: 에이전트는 정상 동작하고 결과도 돌아와 겉으로는 성공처럼 보인다. spawn 직후 `tmux list-panes` 로 pane 실존을 확인하는 것이 유일한 조기 발견 수단이다. 팀에이전트가 `SendMessage(to="team-lead")` 실패를 보고하면 이 CASE 를 의심하라 — 팀이 없으니 team-lead 주소도 없다. |
| CASE-11 | shutdown 후 Claude Code IDLE 잔류 + 완료 키워드 | shutdown_approved 받았으나 Claude Code 프로세스 IDLE statusline timer로 활성 false positive | team-cleanup.sh 키워드 매칭(L-392)으로 자동 kill 대상 강등. 수동 확인 시 capture-pane 마지막 30줄에 "완료 보고/team-lead 보고 완료/파일 작성 완료" 등 키워드 확인 |

---

## 진단 보고서 출력 형식

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 oinit 진단 + 정리
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UUID: {UUID}
팀: {팀명}
상태: {PLAN/DEV/TEST/DONE/FINISH}

수량 리포팅:
  팀 멤버 수 (team-lead 제외): N개
  agents/ 등록 수:             N개
  현재 세션 pane 수(메인 제외): N개
  수량 판정: ✅ 일치 / ⚠️ 불일치→CASE 분류

에이전트 ↔ pane 교차 검증:
  A방향(agents→pane) 불일치: N건
  B방향(pane→agents) 불일치: N건
  종합: ✅ 완전 일치 / ⚠️ 불일치 {총N건}

정리 결과:
  고착 파이프라인: N개 → IDLE 리셋
  고아 pane: N개 → kill 정리
  잔류 이상: 없음 / {목록}

재개 조치 (독립 실행 시):
  🔄 {단계} 에이전트 재spawn → 완료 대기 → 다음 단계 진행
  또는
  ⏭️ {단계} 이미 완료 → 다음 단계 자동 진행
  또는
  ⚠️ 자동 재개 불가 — {사유}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 절대 금지

1. **다른 세션 pane kill 금지** — L-213 보호
2. **SendMessage 응답 대기 기반 판정 금지** — L-331 (물리 상태 기반만 허용)
3. **팀에이전트 spawn 금지** — L-360 (메인 세션 팅김 사고)
4. **Step 11 생략 금지** — CASE 0건이어도 결과 요약 + 갱신 여부 판단 필수
5. **ofinish 내 호출 시 Step 9 실행 금지** — ofinish가 이후 단계 담당
6. **kill-window 절대 금지** — segfault 위험 (L-114)
7. **"정리 대상이 없다" 판단으로 Step 0~3 스킵 금지** — L-320
