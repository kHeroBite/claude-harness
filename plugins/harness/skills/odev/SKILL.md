---
name: odev
description: "코드 구현 메인 라우터. 구현 절차, Lock 획득, 도구 선택. Auto-activates when: implementing code, modifying files."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["ok/ok_pipeline(DEV 단계)"]
  calls: ["odev_lock", "odev_parallel", "odev_impact", "odev_review", "odev_simplify", "odebug"]
---
# odev — 코드 구현 메인

## 절대규칙

```yaml
shutdown_즉답_절대규칙 (L-U5):
  - shutdown_request 수신 즉시 현재 작업 중단 후 shutdown_response 발송
  - 파일 저장/정리 등 후처리 후 응답하는 행위 절대 금지
  - 메인이 3회×5s=15초 내에 응답 없으면 pane 강제 종료 대상
```

## 구현 절차

### 진입 UUID 결정 (첫 번째 mcp__oio__bash_exec 명령 — 필수)
> ⚠️ 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```yaml
UUID_결정:
  UUID=$PIPELINE_UUID
  mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/{logs,evidence,plans,work}')

팀에이전트_UUID_규칙: PIPELINE_UUID 환경변수 값을 그대로 사용. resolve_uuid() 호출 금지.
예: UUID=$PIPELINE_UUID (환경변수에서 직접 읽기)
```

## UUID 규칙 (M-08 통일)

```yaml
팀에이전트_UUID_규칙:
  사용: PIPELINE_UUID 환경변수만 사용 (프롬프트에서 주입)
  금지: resolve_uuid() 호출, $CLAUDE_SESSION_ID 직접 사용
  이유: 팀에이전트는 메인과 다른 세션 ID를 가지므로, 메인이 주입한 PIPELINE_UUID만이 올바른 세션 디렉토리를 가리킴
  적용: odev, otest, obuild, odone 등 모든 팀에이전트 동일
```

### 의도 Lock 획득 (첫 동작 — 필수)

```yaml
절차:
  1. 프로젝트 .claude/locks/ 디렉토리 확인 (없으면 생성)
  2. 대상 파일 목록 확정 (TODO에 명시된 수정 파일)
  3. 기존 의도 Lock JSON 스캔 → 파일 목록 교집합 확인
  4. 충돌 판정:
     충돌_없음: intent_{세션ID}.json 생성 → 정상 진행
     부분_충돌: 비충돌 파일만 등록 → blocked 파일은 odev_lock 절차
     전체_충돌: ntfy 알림 후 대기 → odev_lock 절차
  5. Stale 검사: 충돌 Lock의 PID 사망 / TTL 120분 초과 → 자동 삭제

Lock_유지: odev 이후 파이프라인 완료까지 유지 (해제는 후속 단계에 위임)
otest_실패_복귀: Lock 유지됨 (재획득 불필요)
상세: /odev_lock 참조
```

### 롤백 체크포인트 (odev 진입 시 — 자동)

```yaml
목적: otest 실패 시 안전한 복귀 지점
실행: rollback_checkpoint.sh hook이 odev 스킬 호출 시 자동 실행

Hook_자동_절차:
  1. HEAD hash 기록: $HOME/.claude/session-env/${UUID}/rollback_hash
  2. git tag 생성: odev-checkpoint-YYYYMMDD-HHMMSS
  3. 이전 체크포인트 정리 (최근 5개만 유지)

활용_시나리오:
  otest_경미_실패: 해당 코드만 수정 (체크포인트 불사용)
  otest_3회+_실패: git reset --hard {checkpoint} 고려
    → 사용자 확인 필수 (파괴적 작업)
  TEST→DEV_재진입: 새 체크포인트 생성 (기존 유지)

주의:
  - 체크포인트 = 참조용 (자동 롤백 절대 금지)
  - git reset = 사용자 명시적 승인 후에만
  - uncommitted 변경 있으면 git stash 선행
```

### 기본 준비

- 디버그 모드 OFF 확인
- PROJECT.md/DATABASE.md 참조
- 검증 전략 명시

### 코드 구현

Debug2_로그: 주요 분기점에 Debug2 로그 추가
TODO_업데이트: 각 항목 완료 시 즉시 업데이트

result_json_점진적_업데이트 (재개 지원 — "디스크 먼저, SendMessage 나중"):
  시점: 각 TODO 항목 1개 완료 직후 (SendMessage 전)
  파일: $HOME/.claude/session-env/${UUID}/work/{에이전트명}_result.json
  방법: mcp__oio__file_write (overwrite=true — 매번 전체 덮어쓰기)

  진입_시 (기존 result.json 재사용 판정 — L-670):
    1. ★현재 conv_id 획득 (재사용 판정 기준 — 2번보다 먼저 수행한다):
       mcp__oio__bash_exec(command='cat $HOME/.claude/session-env/${UUID}/conv_id')
       ⚠️ conv_id 파일 자체도 옛 사이클 값이 잔류할 수 있다. 파이프라인이 주입한
          현재 대화ID(프롬프트 명시값)가 있으면 그 값을 우선한다.
    2. 기존 result.json 확인: mcp__oio__file_read(path=".../work/{에이전트명}_result.json")
    3. ★conv_id 대조 게이트 (스킵 판정보다 먼저 통과해야 한다):
       저장된 conv_id == 현재 conv_id  → 같은 작업의 중단분이다. todos_completed 스킵 판정으로 진행한다.
       저장된 conv_id != 현재 conv_id  → ★옛 사이클 잔류물★이다. 파일 내용을 전부 무시하고
                                          전 TODO를 새로 수행한다.
       conv_id 필드 부재 (구 스키마)   → ★잔류물로 간주★한다. 위와 동일하게 전부 새로 수행한다.
       ⚠️ 무시 판정 시 그 사실을 1줄로 출력한다 — 예: "⚠️ [잔류물 무시] {에이전트명}_result.json
          conv_id={저장값|부재} ≠ 현재 {현재값} — 전 TODO를 새로 수행한다."

  내용:
    ★conv_id 필수 필드 — 매 저장마다 현재 대화ID를 반드시 포함한다. 누락하면 다음 사이클이
      이 파일을 자기 것으로 오인해 완료된 것으로 스킵한다 (L-670 재발).
    {
      "agent": "{에이전트명}",
      "conv_id": "{현재 대화ID}",   # ★필수 — 생략 금지
      "status": "partial",  # 전체 완료 시 "completed"로 변경
      "todos_completed": [완료된 TODO id 배열],
      "todos_failed": [],
      "files_modified": [수정 파일 경로 배열],
      "git_sha_after": "",   # 전체 완료 시 git rev-parse --short HEAD
      "summary": "",         # 전체 완료 시 요약
      "substeps": [
        {"todo_id": N, "status": "done", "files": [파일]}
      ]
    }
  갱신_흐름:
    TODO-1 완료 → result.json { conv_id:"{현재}", status:"partial", todos_completed:[1] }
    TODO-2 완료 → result.json { conv_id:"{현재}", status:"partial", todos_completed:[1,2] }
    전체완료   → result.json { conv_id:"{현재}", status:"completed", todos_completed:[1,2,3], git_sha_after:"..." }
  목적: 에이전트 크래시 시에도 디스크에 마지막 완료 TODO까지 보존 → /oresume이 미완료 TODO만 재할당
```

### SQL 위치 검증 (구현 전 체크리스트)

```yaml
규칙: SQL 문자열은 반드시 공유 라이브러리 Queries/*.cs에서만 정의 (경로: {project}/PROJECT.md "코딩 규칙" 섹션 참조)
금지: 폼/컨트롤 파일에 SELECT/INSERT/UPDATE/DELETE 문자열 직접 작성
허용: Queries 클래스의 const string 참조 또는 Build*() 메서드 호출
검증:
  구현_시작_전:
    - 새 SQL 필요 → Queries/ 해당 파일에 먼저 정의
    - 기존 SQL 재사용 가능 여부 확인 (Grep 검색)
  구현_완료_후:
    - 수정 파일에 SELECT/INSERT/UPDATE/DELETE 문자열 잔존 여부 검사
강제: PreToolUse Hook이 위반 자동 차단 (inline_sql_guard.sh)
```

### SQL 주석 꼬리 검사 (구현 완료 후 — 필수, L-686/L-687)

```yaml
배경: |
  SQL 문자열 내부 주석은 `--` 다 (`//` 는 SQL 본문 리터럴이 되어 빌드 통과 + 런타임에만 터진다).
  그런데 `--` 를 verbatim 문자열의 ★마지막 내용물★로 두면, 그 문자열이 다른 조각과
  이어붙는 순간(+ / += / 보간) 뒤 구문이 통째로 주석에 삼켜진다.
  사이클28 실측: 3인이 각자 다른 조립 축을 빠뜨렸고 전부 우연히 무해했다.
  ⇒ 축을 열거하는 검사는 열거하지 않은 축에서 반드시 뚫린다. 열거는 끝나지 않는다.

판정법 (축을 묻지 않는다 — "주석이 꼬리인가"만 묻는다):
  대상: verbatim 문자열(@"..." / $@"...") 내부에서 `--` 를 포함한 모든 줄 (전용·인라인 불문)
  판정: 그 줄에서 `--` 이후를 제거한 뒤, 그 문자열 안에 SQL 내용 줄이 더 남아 있는가
        · 남아 있음 → 안전 (어떤 축으로 이어붙든 주석이 삼킬 게 없다)
        · 없음      → DANGER (문자열 꼬리 = 조립 시 뒤 구문 유실)
  예외: 한 줄 평탄화 코드(Replace("\n"," ") 등)가 있으면 위 배치도 무효 — 별도 grep 필요

성립_근거: |
  `--` 는 줄 끝까지만 삼킨다. 주석 뒤에 SQL 줄이 하나라도 더 있으면 무엇이 어떻게
  이어붙어도 삼켜지는 건 주석 자신의 줄뿐이다.
  ⇒ 위험은 "이어붙임 방식"이 아니라 "주석이 마지막 내용물인가"에서만 발생한다.
    조립 축은 원인이 아니라 발현 경로다.

진양성_확인 (생략 금지):
  DANGER 0건을 근거로 쓰기 전에, 대상 파일 ★사본★에 꼬리 주석을 1건 주입해
  검사가 DANGER 를 실제로 탐지하는지 확인하라.
  ⇒ 0건은 "검사기가 죽은 상태"에서도 나온다. 진양성 확인 없는 0건은 근거가 아니다.

실사례: |
  `baseSql + " DESC LIMIT 1"` (개행 없음) 형태에서 꼬리 주석이 있었다면
  "정렬 역순 1건" → "정렬 없이 전건" 이 된다. 조용한 오답이라 화면으로 알아채기 어렵다.

hook_승격: 보류 — 전 프로젝트 오탐률 실측 후 판단 (사이클28 이월).
           현재 실측 범위는 공유 쿼리 모듈(0/557) + 게이트웨이·모바일 포함 12파일(0/579).
```

### 배치 빌드 검증 (TODO 5개 이상 시)

> 3개 항목마다 중간 빌드, 실패 시 git stash 롤백 절차

> ⚠️ **[L-351 — 2026-04-09] 빌드 hook 차단 대응 — Skill('obuild') 필수**
>
> odev에서 직접 `dotnet build` 또는 `cmd.exe /c dotnet build` 실행 시
> write_guard.sh hook에 의해 차단될 수 있음 (팀에이전트 상태에서 빌드 명령 금지).
>
> **금지 패턴**: `mcp__oio__bash_exec(command="sleep 30 && cat /tmp/oio_bg_*.log")` — blocking 대기로 에이전트 멈춤 유발
>
> **올바른 절차**:
> 1. `Skill('obuild')` 호출 — 빌드 실행 위임 (hook 우회 내장)
> 2. obuild 내에서 결과 반환 — 직접 dotnet 실행 금지
>
> **실제 사고 (2026-04-09)**: odev-1이 `sleep 30 && cat /tmp/oio_bg_*.log` 패턴으로
> 백그라운드 빌드 로그를 blocking 대기 → hook 차단 → 에이전트 완료 불가 → 팀 정리 사고로 이어짐

### 프로그램 실행 중 수정

- .cs 파일은 프로그램 실행 중에도 수정 가능 (파일 잠금 없음)
- **Python MCP 서버 소스 수정 (L-404)**: 실행 중인 uvicorn/FastMCP 프로세스의 .py 파일 수정은 메모리 상태에 즉각 영향 없음 — Python은 import 시점에 모듈을 메모리에 적재하므로, 파일 수정 후 재시작 전까지 실행 중 프로세스는 이전 코드 그대로 동작. **수정 절차**: odev가 .py 파일 수정 → otest 단계에서 서버 재시작 → 변경사항 적용 확인. odev 단계에서 서버 재시작 없이 파일 수정만 해도 안전함.

### ★MCP 서버 소스 수정 시 — 재적재 확인 게이트 (L-404 강화, 사이클43)★

```yaml
배경 (사이클43 실사고 — 2026-08-27 실측):
  사이클41 이 file_ops.py 8~9개 쓰기 경로 전부에 session-env 미러링을 넣었다. ★소스는 옳았다.★
  그런데 사이클42 종료 시 goal_*_completed.json 이 CFG 한쪽에만 생겼다.
  원인은 코드가 아니라 ★적재★ 였다.

      file_ops.py       수정 21:52
      session_mirror.py 수정 22:25
      oio 서버 PID 1581544  기동 ★14:48★  ← 수정 이전 = 구 코드로 계속 동작
      23:48 ofinish file_copy → 1581544 이 처리 → 미러링 코드가 그 메모리에 ★없음★

  ⇒ ★"파일을 고쳤다" ≠ "그 코드가 실행된다".★
  ⇒ 위 L-404 마지막 문장("재시작 없이 수정만 해도 안전")은 ★파일 안전★ 을 말한 것이지
    ★수정이 유효해진다★ 는 뜻이 아니다. 이 문장을 후자로 읽은 것이 사고의 한 축이었다.

왜_검증으로_못_잡았나 (★이 절의 존재 이유★):
  검증 probe 는 항상 ★신규 팀에이전트 = 신규 서버★ 에서 돌아간다.
  ⇒ 언제나 ★신 코드가 적재된 환경만★ 관측한다. 구 서버는 단 한 번도 검사되지 않는다.
  ⇒ ★"지금 되니까 그때도 됐다"★ 는 추론이 성립하지 않는다 — 사이에 프로세스 교체가 끼어 있다.
  ⇒ 런타임 검증은 ★"어느 프로세스가 처리했는가"까지 특정해야★ 성립한다.
    (프로젝트 인프라 스킬(oinfra_{project})의 `/proc/{pid}/exe` MD5 대조와 동형 — 같은 코드베이스라도
     프로세스마다 적재 시점이 다르면 ★서로 다른 프로그램★ 이다.)

필수_절차 (MCP 서버 *.py 수정 시 — 완료 보고 ★전★ 1회):
  1. 수정한 .py 의 mtime 획득:
     mcp__oio__bash_exec(command="stat -c '%y %n' <수정파일>")
  2. 현역 서버 전수의 기동 시각 획득:
     mcp__oio__bash_exec(command="ps -eo pid,lstart,cmd | grep '<서버>/server.py' | grep -v grep")
  3. ★기동 시각 < 수정 시각인 서버가 1개라도 있으면 "미적재 잔존" 을 명시 보고★
     보고 형식: "⚠️ [미적재 잔존] PID {N} 기동 {시각} < 수정 {시각} — 이 프로세스는 구 코드로 동작 중"

금지 (절대):
  - ★구 서버를 kill 하는 것★ — 타 세션·메인 세션 소유일 수 있다.
    죽이면 그 세션의 파이프라인이 통째로 정지한다 (세션 격리 §(b) fail-closed).
    ⇒ ★보고만 하고, 재시작 판단은 사용자/메인에게 넘긴다.★
  - 미적재 잔존을 확인하지 않은 채 "수정 완료 · 검증 통과" 로 보고 (사이클43 재발)
  - 신규 서버 probe 결과만으로 "런타임 유효" 를 단정 (구 서버를 검사하지 않은 것이다)

보강_수단 (2순위 — 본 게이트만으로는 닫히지 않는다):
  session_mirror.stale_module_warning() 이 서버 스스로 구 코드 여부를 진단해
  결과 dict 에 stale_module_warning 필드로 fail-loud 한다 (사이클43 도입).
  ⚠️ 단 ★그 코드 역시 구 서버에는 적재되지 않는다★ — 다음 기동부터 유효.
  ⇒ 그래서 본 게이트(3순위 Skill)와 ★반드시 병행★ 한다. 한쪽만으로는 닫히지 않는다.

Hook_1순위_미적용_사유 (CLAUDE.md 재발방지 정책 요구):
  "서버 프로세스가 구 코드인가" 는 도구 호출의 인자에도 결과에도 나타나지 않는다.
  구 코드는 애초에 진단 필드를 만들지 않으므로 ★부재로만 드러나고, 부재는 정상과 구별되지 않는다★.
  ⇒ hook 이 관측할 신호 자체가 없어 물리 차단 불가.
  ⇒ 2순위(서버 자가 진단) + 3순위(본 게이트) 조합으로 강제한다.
```

### 코드 수정 도구 선택

```yaml
코드_수정_도구_우선순위 (절대 규칙):
  1순위: oio MCP (file_edit/file_write) — 모든 파일 수정의 기본 도구
    - NTFS rsync 자동 처리, Lock 자동, BOM/CRLF 자동 보존
    - team lead approval 우회 (팀에이전트에서도 즉시 실행)
    - 파라미터 정확명 (Pydantic 검증 — 틀리면 즉시 차단):
      | 도구 | 필수 파라미터 | 금지 (틀린 이름) |
      |------|-------------|-----------------|
      | file_edit | path, old_string, new_string | ❌ old_content/new_content |
      | file_write | path, content | ❌ text/body |
      | file_move | source, destination | ❌ path/dest |
      | file_copy | source, destination | ❌ path/dest |
      | file_rename | path, new_name | ❌ name/new_path |
      | file_delete | path | |

  2순위: MCP Serena — C# 심볼 수준 수정 전용 (rename_symbol, replace_symbol_body 등)
    적용 조건: C# 프로젝트 + 심볼 단위 수정(메서드/클래스/속성)이 필요한 경우에만
    - 심볼 수정 (replace_symbol_body)
    - 메서드/클래스 추가 (insert_after_symbol)
    - 변수/함수명 리팩토링 (rename_symbol)
    - 참조 추적 (find_referencing_symbols)

  3순위: Claude Code Edit — oio 불가 시에만 (Fallback)

  주의: Serena는 oio의 대체가 아님. oio가 기본, Serena는 C# 심볼 특화 보조 도구.
  CLAUDE.md 규칙: 모든 파일 I/O는 oio MCP 경유 필수 (Serena는 추가 기능)
```

> 파일 수정은 항상 oio MCP 최우선. 수동 rsync 불필요 (oio 내부 자동 처리).

---

## 규모 판정 + 분류 (메인으로부터 수신)

> 분류 기준(o1~o5)은 ok SKILL.md "분류_판정_알고리즘" 참조

## 에이전트 수 결정

> 에이전트 수: Skill('oplan_parallel') 참조 (단일 출처)

## 파일 할당 매트릭스


```yaml
원칙: 1 파일 = 1 에이전트 (중복 금지) / 의존 관계 → 동일 에이전트 / 작업량 균형
영속화: $HOME/.claude/session-env/${UUID}/file_assignment.json (매트릭스 확정 직후, odev spawn 직전)
용도: 인터럽트 충돌 방지 / git add 대상 목록 / 디버깅 추적
생명주기: 파이프라인 완료 시 ofinish step6에서 삭제
```

---

## 진입 시 필수 절차 (odev 진입 직후 — 코드 작성 전)

```yaml
0_sprint_contract_확인 (코드 작성 전 — N1):
  시점: odev 진입 직후 최우선 (0_ki_queue 이전)
  동작:
    1. sprint_contract.md 존재 확인:
       test -f "$HOME/.claude/session-env/${UUID}/plans/sprint_contract.md"
    2. 존재하면: 내용 읽기 → 완료 기준 숙지 → otest 평가 기준으로 활용
    3. 없으면: ⚠️ sprint_contract 미존재 경고 출력 후 계속 진행
       → "⚠️ [sprint_contract 없음] otest 평가 기준 불명확. oplan §TODO의 완료 기준을 대신 사용."
       → 자체 sprint_contract 생성:
            cat > "$HOME/.claude/session-env/${UUID}/plans/sprint_contract.md" << 'EOF'
            # Sprint Contract (odev 자동 생성)
            ## 완료 기준
            {oplan TODO 항목별 체크 가능한 완료 기준 — odev가 판단}
            ## 평가 방법
            {각 기준의 검증 방법}
            EOF
  금지: sprint_contract 없이 코드 작성 돌입 (자동 생성 후 진행)

0_ki_queue_확인 (PLAN→DEV 전환 시 — 코드 작성 전 최우선):
  시점: odev 진입 직후, 0_XML_작업_명세_파싱 이전
  목적: PLAN 단계 중 사용자가 보낸 수정 요청(B분류)을 TODO에 반영
  동작:
    1. oi_queue 파일 존재 확인:
       cat "$HOME/.claude/session-env/${UUID}/oi_queue" 2>/dev/null
    2. 내용 있으면:
       - "[수정요청]" 접두사 라인을 추출하여 TODO에 반영
       - oi_queue 내용을 구현 계획에 통합 (추가 작업 또는 기존 TODO 수정)
       - 처리 완료 후 oi_queue 파일 비우기:
         > "$HOME/.claude/session-env/${UUID}/oi_queue"
    3. oi_queue 없거나 비어있으면: 스킵 (정상 흐름)
  금지: oi_queue 미확인 상태로 코드 작성 돌입

0_XML_작업_명세_파싱:
  시점: odev 진입 시 TODO 파일 로드 직후 (비판적 검토 전)
  동작:
    1. TODO 파일에서 XML 코드블록(<tasks>...</tasks>) 검출
    2. XML 파싱 → <task agent="{자신의 에이전트명}"> 요소에서 자신의 작업 추출
    3. <file path="..." scope="..."/> → 수정 대상 파일 + 범위 확정
    4. <dependencies> → 선행 작업 완료 여부 확인 (Wave 순차 spawn과 연동)
  폴백:
    XML 블록 없음 → 기존 프롬프트 기반 파일/작업 추출 방식 사용
    XML 파싱 실패 → 동일 폴백 (경고만 출력, 에러 처리 금지)
  금지: XML 파싱 실패를 에러로 처리 금지 (경고 출력 후 폴백 진행)
  안전: XML 블록이 없어도 기존 동작 완전 보장 (하위 호환 필수)

0_5_담당대상_실존_검증 (코드 작성 전 최초 1회 — 절대 규칙, 2026-09-15 사이클131/132 L-1068):
  시점: TODO 로드·XML 파싱 직후, 1_TODO_비판적_검토 진입 전
  원칙: ★지시에 나온 경로가 실존한다고 전제하지 마라.★
        부재 시 "비슷한 파일"로 대체하는 것은 없는 것을 만드는 행위다.
  배경: 사이클131/132에서 지시된 파일(`PacketHandler.cs`)이 실존하지 않았고, 지시된
        호출 지점("1051 저장 직후 발신 호출")도 구조상 존재하지 않았다(범용 SQL
        패스스루라 서버가 그 사건을 인지할 방법이 없음). 담당 에이전트가 실측으로
        반증하고 임의 대체 없이 중단·보고해 정상 처리됐다 — 이 절차는 그 판단을
        매 작업 착수 전 필수 단계로 승격한다.

  A. 경로 실존 (기계 검증):
     담당 파일 전체를 1개 명령으로 확인하고 ★rc 를 본다★:
       for f in <담당파일 전체>; do
         test -e "$f" && stat -c '%s %n' "$f" || echo "MISSING: $f"
       done
     · MISSING 0건 → 통과
     · MISSING 1건 이상 → ★코드 작성 착수 금지★
       SendMessage(to="{리더명}",
         "PATH_NOT_FOUND: {지시 경로}\n실측: 부재\n후보(추정): {grep 결과}\n지시 정정 요청")
       ⇒ ★임의 대체 절대 금지.★ 정정 회신까지 대기.

  B. 호출 지점 실존 (구조 검증 — A 통과 후):
     "X 에서 Y 를 호출하라" 형태의 지시는 ★X 가 Y 를 호출할 수 있는 구조인가★ 를 먼저 본다.
       grep -n "<Y 심볼명>" <X 파일>              # 기존 호출/참조 유무
       grep -n "<X 가 속한 계층의 진입점>" ...     # X 가 그 사건을 인지하는 경로가 있는가
     · 경로 없음(예: 범용 패스스루라 서버가 사건을 인지 못함) → ★확장 구현 금지★
       SendMessage 로 "구조상 불가 + 실측 근거 + 대안" 보고 후 대기.

  금지:
    - 지시 경로 부재를 확인하고도 "인접 파일에 구현" 으로 진행
    - 호출 경로 부재를 "만들면 된다" 로 해석해 임의 확장
    - A/B 미수행 상태로 코드 작성 착수

  참고: "Stop and Ask"(차단 발생 시 중단)는 이미 작업 중 겪는 반응형 대응이다.
        이 단계는 그보다 먼저 도는 ★착수 전 게이트★로, 역할이 다르므로 중복이 아니다.

1_TODO_비판적_검토:
  검토: 모호한 지시 / 의존성 순서 / 누락 항목 (사이드 이펙트, 참조 수정)
  우려사항: 코드 작성 전 해결 (oplan 복귀 또는 자체 보완)
  금지: 검토 없이 바로 코딩 돌입

2_스킬_자동_로드 (TODO 검토 직후):
  우선: TODO 헤더 "활용 가능 스킬" 목록 → Skill() 호출
  조건부 (TODO 미명시라도 감지 시):
    LiveCharts|Series|Axis|CartesianChart  → Skill('oskill_livecharts2')
    new Form|Designer.cs 생성             → Skill('domain-winforms')
    ALTER/CREATE TABLE|ADD COLUMN|DROP    → Skill('domain-database')
    Extract Method|Rename|메서드 분할      → Skill('domain-csharp')
    NuGet|PackageReference|새 using       → Skill('domain-context7')
    /mnt/c/ 파일 수정|파일 잠금|다중 세션  → Skill('domain-fileops')
    공유 라이브러리 시그니처 변경          → Skill('odev_impact')
  금지: 무관한 스킬 로딩 / 중복 호출
  규칙: 위 상황 해당 시 작업 시작 전 로딩 필수. "나중에 필요하면 보겠다" 패턴 금지.
```

## Stop and Ask (중단 조건)

> 착수 전 검증은 `0_5_담당대상_실존_검증` 참조 (이 섹션은 작업 중 반응형 대응).

```yaml
즉시_중단_후_질문:
  - 차단 발생 (파일 없음, API 미응답, 빌드 불가)
  - TODO 지시 불명확 (어떤 파일? 어떤 메서드?)
  - 검증 2회 반복 실패 (동일 접근법)
  - 계획 변경 감지 (사용자가 TODO 업데이트)
대응: 추측 금지 → odebug 또는 사용자 질문
```

---

## 동적 승격 (구현 중 복잡도 초과 감지)

```yaml
목적: odev 구현 중 현재 tier 임계값 초과 시 메인에 승격 요청 보고
시점: 구현 진행 중 수시 체크 (파일 추가, 줄 수 증가 시)

판단_기준:
  o1_초과 (→ o3 승격):
    - 수정 파일 3개 초과 OR 수정 줄 수 20줄 초과
    - 코드 파일(.cs/.py/.ts 등) 수정 발생 (비코드 단독이 아닌 경우)
  o2_초과 (→ o3 승격):
    - 수정 파일 4개 초과 OR 수정 줄 수 50줄 초과
    - DB 스키마 변경 필요 OR 인터페이스 변경 필요
  o3_초과 (→ o4 승격):
    - 수정 줄 수 500줄 초과
    - 새 모듈/폼 신설 필요
    - 아키텍처 변경 감지 (여러 계층 동시 변경)
  o4_초과 (→ o5 승격):
    - 수정 줄 수 1500줄 초과
    - 새 모듈 3개 이상 신설

보고_형식:
  방법: SendMessage(to:"{리더명}", content:"PROMOTION_REQUEST: o{N} → o{M}\n사유: {판단근거}\n현재: 파일 {X}개, 줄 {Y}줄")
  예시: "PROMOTION_REQUEST: o1 → o3\n사유: 수정 파일 4개, 코드 35줄 초과\n현재: 파일 4개, 줄 35줄"

메인_대응:
  승인: 현재 odev 중단 → 상위 tier 파이프라인 재시작 (기존 작업물 상속)
  거부: 현재 tier로 계속 진행 (메인 판단 존중)

금지:
  - odev가 자의적으로 승격 결정 (보고만 가능, 결정은 메인)
  - 강등 요청 (승격은 일방향 — o1→o3→o4→o5)
  - 승격 보고 없이 임계값 초과 상태로 계속 구현
```

---

## tier별 구현 절차

```yaml
o2_Simple:
  Lock: 스킵 (단일 에이전트, 충돌 없음)
  구현: 직접 수정 (1~3파일, oio 사용)
  서브스킬: 없음
  배치빌드: 스킵
  검증: obr (빌드+실행만) — otest 없음

o3_Normal:
  Lock: odev_lock (다중 에이전트 가능)
  구현: Wave 기반 순차/병렬 (odev_parallel)
  서브스킬:
    - odev_parallel: 에이전트 2+ 시 자동
    - odev_impact: 인터페이스/공통모듈 변경 감지 시
    - odev_review: 에이전트 2+ 완료 후 자동
  배치빌드: TODO 5개+ 시 3개마다 중간 빌드
  검증: otest 위임

o4_Heavy:
  Lock: odev_lock 필수
  구현: Wave 기반 + 배치 빌드 검증
  서브스킬:
    - odev_parallel: 필수 (다중 에이전트)
    - odev_impact: 필수 (아키텍처 변경 포함)
    - odev_review: 필수 (에이전트 완료 후)
    - odev_simplify: odev_review 후 자동
  배치빌드: TODO 3개마다 중간 빌드
  검증: otest 위임

o5_Massive:
  Lock: odev_lock 필수
  구현: 다단계 Wave + 중간 빌드 검증
  서브스킬:
    - odev_parallel: 필수
    - odev_impact: 필수
    - odev_review: 필수
    - odev_simplify: 필수
    - odebug: 차단/오류 시 즉시
  배치빌드: TODO 2개마다 중간 빌드
  검증: otest 위임

## 서브스킬 발동 조건 매트릭스

| 서브스킬 | 발동 조건 | o2 | o3 | o4 | o5 |
|----------|----------|:---:|:---:|:---:|:---:|
| odev_lock | 다중 에이전트 OR 다중 세션 | - | 조건부 | 필수 | 필수 |
| odev_parallel | 에이전트 2+ 할당 시 | - | 조건부 | 필수 | 필수 |
| odev_impact | 인터페이스/공통모듈 변경 | - | 조건부 | 필수 | 필수 |
| odev_review | 에이전트 2+ 완료 후 | - | 자동 | 필수 | 필수 |
| odev_simplify | odev_review 완료 후 | - | - | 자동 | 필수 |
| odebug | 차단/오류/2회+ 실패 | 수동 | 수동 | 수동 | 즉시 |
```

## 결과 파일 저장 및 완료 통보 (필수 — 절대 생략 금지)

### 오류 실시간 기록

```yaml
시점: 오류 발생 즉시 (해결 여부와 무관)
대상: $HOME/.claude/session-env/${UUID}/logs/errors.md
형식: |
  ## [odev] $(date -Iseconds)
  - 파일: {수정 중이던 파일 경로}
  - 오류: {에러 메시지}
  - 해결: {해결 방법 | 미해결}
명령: |
  cat >> $HOME/.claude/session-env/${UUID}/logs/errors.md << EOF
  ## [odev] $(date -Iseconds)
  - 파일: {path}
  - 오류: {message}
  - 해결: {resolution}
  EOF
```

### 결과 파일 저장

```yaml
시점: 메인에게 완료 통보 직전
파일명: $HOME/.claude/session-env/${UUID}/logs/odev_{대화ID}.md
대화ID 획득: cat $HOME/.claude/session-env/${UUID}/conv_id

포함_내용:
  - 수정 파일 목록 (정확한 경로 + 변경 요약)
  - 각 파일별 수정 이유 + 수정 방법
  - 발생 오류 목록 + 해결 여부 (없으면 "오류 없음")
```

### handoff_artifact 생성 (완료 통보 전 — N2)

```yaml
시점: 결과 로그 저장 직후, SendMessage 직전 (필수)
경로: $HOME/.claude/session-env/${UUID}/plans/handoff_dev_to_test.md
내용:
  # Handoff: odev → otest
  ## 수정된 파일 목록
  {수정/추가/삭제된 파일 전체 목록}
  ## 알려진 미완성 항목
  {구현 중 의도적으로 보류한 항목 — "없음"이면 명시}
  ## otest 집중 영역
  {가장 테스트가 필요한 부분, 엣지케이스 힌트}
  ## sprint_contract 기준 자체 평가
  {각 완료 기준 항목별 odev 자체 평가 (✅/⚠️)}
생성_실패_허용: 생성 실패 시 경고 출력 후 완료 통보 계속 진행 (차단 금지)
금지: handoff 파일 없이 SendMessage 완료 통보 (경고 없이 스킵)
```

### 완료 통보 (절대 생략 금지)

```yaml
시점: result.json 확정 → 결과 파일 저장 → handoff_artifact 생성 → SendMessage (이 순서 필수)
절차:
  1. result.json 최종 확정: status="completed", git_sha_after 기록
     mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/work/{에이전트명}_result.json", overwrite=true, content=최종JSON)
  2. 결과 로그 저장: $HOME/.claude/session-env/${UUID}/logs/odev_{대화ID}.md
  3. SendMessage 발송 (아래)
방법: SendMessage(to:"{리더명}", message:"odev 완료 — $HOME/.claude/session-env/${UUID}/logs/odev_{대화ID}.md\n{요약 3줄}\n📊 spawn_stats: team=N sub=N task=N", summary:"odev 완료 N개 파일 수정")

SendMessage_필수_규칙:
  - message가 문자열이면 summary 필수 (5~10단어, 누락 시 즉시 오류)
  - structured message(shutdown_request 등)는 broadcast(to:"*") 불가 → 개별 전송만

금지:
  - 결과 파일 없이 완료 통보
  - 완료 통보 없이 idle 전환
  - summary 누락한 SendMessage 호출
```

## shutdown_request 수신 시 행동

> shutdown_request 수신 즉시 approve 응답 + 작업 중단. → ok/references/SHUTDOWN_PROTOCOL.md 참조

## 파일 수정 후 read 검증 의무 (L-394)

**모든 file_write/file_edit 후 반드시 read로 재확인**:

1. file_write/file_edit 실행
2. 즉시 file_read로 수정된 부분 읽어서 의도한 내용 일치 확인
3. 불일치 시 재수정 후 다시 검증
4. 완료 보고 시 "read 검증 완료" 명시

**이유**: Silent 도구 실패 방지 — 파일 수정이 실패했는데 성공 응답이 반환되는 경우.

**올바른 예시**: file_edit → file_read(해당 라인) → 내용 일치 확인 → 완료 보고

## 완료 선언 전 자기 재현 자문 (L-546 확장, L-1060 — 2026-09-14 사이클130b)

**수정 완료를 선언하기 전, 자기 자신에게 반드시 물어라**: "내가 없애려는 그 결함 패턴이 이번에 만지지 않은 다른 곳에 그대로 남아 있지 않은가?"

```yaml
근거_사례 (사이클130b): |
  계획서는 게이트웨이 Config 클래스의 CloneForPort 한 곳만 고치도록 지시했다. 그러나 위 자문을
  스스로 수행한 결과, 계획서에 없던 게이트웨이 Program.cs 의 하위호환 폴백 경로가
  CloneForPort를 거치지 않고 원본 config를 그대로 번들에 넘기고 있음을 발견했다.
  계획서만 따랐다면 같은 계열 결함이 그대로 남았을 것이다.

수행_방법:
  1. 이번에 고친 근본 원인 패턴(예: "참조 공유", "포트 판정 우회")을 한 문장으로 요약한다.
  2. grep으로 그 패턴이 나타날 수 있는 다른 호출부/경로를 전수 검색한다
     (예: 같은 클래스의 다른 생성 경로, 같은 인터페이스의 다른 구현체).
  3. 발견되면 계획서 범위 밖이라도 수정하고, odev 결과 로그에 "자체 발견"으로 명시한다.

금지: 계획서에 명시된 파일만 고치고 "계획대로 완료"라고 선언 (자문 없이 종료).
```

## 저장 이후 상태만으로 원래 설계를 단정하지 마라 (L-1059 — 2026-09-14 사이클130b)

**conf/설정/DB 등 공유 상태를 조사할 때, "현재 저장된 값"이 곧 "원래 설계"라고 가정하지 마라.**

```yaml
근거_사례 (사이클130b): |
  메인과 진단 에이전트 둘 다 "conf 공용 1벌 = 항상 그래왔다"로 판정했으나, 이는 최근
  저장 이후의 상태만 본 것이었다. 저장 이전에는 포트별로 분리된 판정 로직이 실제로
  작동하고 있었다. 사용자가 실측 반증("최초엔 개발 OFF·운영 ON")을 제기하고 나서야
  드러났다.

수행_방법:
  1. 현재 상태만으로 "설계 의도"를 단정하지 말고, 가능하면 git log/백업본/로그로
     저장 이전 시점의 값을 대조한다.
  2. 사용자가 현재 관측과 다른 과거 사실을 제기하면 "현재 상태가 맞다"고 반박하기 전에
     먼저 재현 가능한 증거(로그 타임스탬프, 백업 conf 등)를 찾는다.
```

## 전략 swap 5단계 대칭 구조 (L-442)

런타임 중 인터페이스 구현체를 교체(swap)할 때 이벤트 누수/2중 구독을 방지하기 위한 표준 패턴.

```yaml
적용_조건:
  - 런타임 폴백 (UnifiedPipeline 실패 → LegacyPipeline 자동 swap)
  - 사용자 모드 변경 (옵션 변경 직후 즉시 swap)
  - 의존성 강제 swap (서비스 끊김 → 대체 구현체)

5단계_대칭_구조:
  1. Unsubscribe: 기존 인스턴스의 모든 이벤트 핸들러 해제
  2. DisposeAsync: 기존 인스턴스 비동기 정리 (WebSocket 종료, Timer Dispose 등)
  3. Factory.New: 새 구현체 인스턴스 생성 (Factory 경유)
  4. Subscribe: 새 인스턴스에 동일 이벤트 핸들러 등록
  5. StartAsync: 새 인스턴스 시작

코드_체크리스트:
  - Unsubscribe와 Subscribe가 같은 핸들러 메서드를 사용하는가? (메서드 그룹 참조 일치)
  - DisposeAsync가 실제 await되는가? (fire-and-forget 금지)
  - Factory.New가 실패하면 원래 인스턴스 복원 또는 명확한 에러 보고?
  - 5단계 중 어느 단계라도 실패 시 _disposing 같은 가드 플래그로 재진입 차단

위반_패턴:
  ❌ Unsubscribe 없이 New + Subscribe → 기존 핸들러 2중 구독 → 동일 이벤트 2회 처리
  ❌ DisposeAsync 누락 → WebSocket 좀비 + Timer 누수
  ❌ fire-and-forget swap (`_ = SwapAsync()`) → 예외 소실 (L-379 위반)

올바른_예 (UnifiedPipeline → LegacyPipeline 폴백):
  await _audioPipeline.UnsubscribeEvents();      // 1
  await _audioPipeline.DisposeAsync();           // 2
  _audioPipeline = AudioPipelineFactory.CreateLegacyFallback(...);  // 3
  _audioPipeline.SubscribeEvents(OnPipelineFallback, ...);          // 4
  await _audioPipeline.StartAsync();             // 5
```

## PeriodicTimer + WebSocket 결합 시 _sendLock 필수 (L-443)

```yaml
적용_조건:
  - PeriodicTimer/Timer가 WebSocket SendAsync 호출
  - 동시에 다른 경로(audio frame 송신 등)에서 WebSocket SendAsync 호출 가능

필수_패턴:
  - private SemaphoreSlim _sendLock = new(1, 1);
  - 모든 SendAsync 직전에 await _sendLock.WaitAsync()
  - finally 블록에서 _sendLock.Release()
  - L-376 IDisposable 패턴 준수: 필드 보유 시 Dispose()에서 _sendLock?.Dispose() 호출

위반_패턴:
  ❌ WebSocket SendAsync 동시 호출 → ClientWebSocket InvalidOperationException
  ❌ SemaphoreSlim 필드 사용 후 Dispose 누락 (L-376 위반)

코드_체크리스트:
  - WebSocket SendAsync 호출 경로 grep 후 동시성 검토
  - 새 송신 경로 추가 시 _sendLock으로 직렬화 강제

## VAD OFF 시 주기적 수동 commit 필수 (L-448)

```yaml
적용_조건:
  - OpenAI Realtime STT에서 turn_detection=null 분기 존재 (ServerVadEnabled=false 또는 whisper 계열)
  - turn_detection=null이면 서버 자동 commit 없음 → 스트리밍 commit 0건 → 실시간 전사 0건

필수_패턴:
  - PeriodicTimer 기반 주기적 input_audio_buffer.commit 루프 (3초 절충)
  - _audioAppendedSinceCommit(volatile bool) 추적: append 후에만 commit (빈버퍼 commit_empty 에러 회피)
  - L-443 _sendLock 동시 적용 (PeriodicTimer commit과 audio append 직렬화)
  - L-380 PeriodicTimer 콜백 전체 외부 try-catch 래핑

위반_패턴:
  ❌ turn_detection=null인데 수동 commit 루프 없음 → 실시간 전사 0건
  ❌ append 추적 없이 무조건 commit → commit_empty 에러 반복

코드_체크리스트:
  - turn_detection 분기(ServerVadEnabled/whisper) 존재 시 수동 commit 루프 동반 여부 확인
  - StartAsync의 serverVadActive 조건이 StopAsync useServerVad 조건과 동일한지 대조
```

## WebSocket 종료 await 경로의 send는 취소 가능해야 함 (L-451)

```yaml
배경: codex 적대리뷰 지적 — SendJsonAsync가 _sendLock.WaitAsync(취소 불가) +
      _ws.SendAsync(CancellationToken.None)이면 소켓 stall 시 StopAsync finally의
      await(_manualCommitTask 등)가 같은 경로에 막혀 무한 hang.

필수_패턴:
  - StopAsync/Dispose에서 await되는 send 경로: _sendLock.WaitAsync(ct) + SendAsync(ct) 또는 타임아웃
  - CancellationToken.None send를 종료 await 경로에 두지 말 것

코드_체크리스트:
  - StopAsync/Dispose에서 await하는 Task가 통과하는 모든 send 경로 grep
  - 해당 경로의 WaitAsync/SendAsync에 ct 또는 타임아웃 적용 여부 확인
  - 신규 송신 경로가 종료 await 체인에 포함되면 취소 가능성 필수 검토
```

