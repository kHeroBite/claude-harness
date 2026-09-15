# 에이전트 운영 절차 상세

## TeamCreate 조건부 (L-221)

```yaml
TeamCreate_조건부 (L-221):
  시점: 코드 수정 오케스트레이션 시작 직전
  확인: $HOME/.claude/session-env/${UUID}/team_name 파일 존재 여부
  존재_시: 기존 팀 재사용 (TeamCreate 스킵)
  미존재_시: TeamCreate 호출
  역라우팅: 기존 팀에 새 에이전트 spawn (새 팀 생성 금지)

  에이전트_등록_디렉토리 (L-235):
    생성: mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/agents')
    시점: TeamCreate 직후

  TeamCreate_실패_재시도:
    오류: "Already leading team"
    처리: TeamDelete → 재시도 → 실패 시 "-v2" 접미사
    팀명_기록: team_name 파일 업데이트 필수
```

## 에이전트 등록 파일 생성 (L-235)

```yaml
시점: Agent 도구 반환 직후 (spawn 완료)
방법: |
  # agent_lifecycle.sh hook이 자동 등록 (5회 retry)
  sleep 1
  AGENT_FILE="$HOME/.claude/session-env/${UUID}/agents/{에이전트명}"
  if [ -f "$AGENT_FILE" ]; then
    PANE_ID=$(grep "^pane_id=" "$AGENT_FILE" | cut -d= -f2)
  fi
  # hook 미등록 시 수동 생성
  if [ ! -f "$AGENT_FILE" ]; then
    _AGENT_TYPE_FALLBACK="${AGENT_NAME%%-*}"  # "odev-1" → "odev", "oplan-1" → "oplan"
    printf 'pane_id=%s\nteam={팀명}\nspawned_at=%s\nagent_type=%s\n' "$PANE_ID" "$(date +%s)" "$_AGENT_TYPE_FALLBACK" > "$AGENT_FILE"
  fi
적용: oplan/odev/otest/odone 모든 에이전트 spawn 직후
```

## shutdown_sent 플래그 (L-241)

```yaml
시점: shutdown_request 발송 직후
방법: echo "shutdown_sent=true" >> agents/{에이전트명}
검증: checkpoint_verify.sh가 플래그 확인
```
