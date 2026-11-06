---
name: oagent
description: 세션 에이전트명 지정·변경·해제·조회 스킬. '/oagent 이름' 으로 이 세션의 에이전트명을 정하거나 바꾸고, 인자 없는 '/oagent' 는 현재 값을 보여 준 뒤 입력을 받는다. '/oagent --clear' 로 해제한다. 같은 프로젝트에서 같은 롤·영역의 세션이 둘 이상일 때 창 제목·statusline 에 'front#이름' 으로 구분해 보이게 한다. '/oagent', '에이전트명', '세션 이름 붙여', '이름 변경' 요청 시 사용. 파이프라인 state 를 바꾸지 않는 단독 스킬.
---

# oagent — 세션 에이전트명 지정·변경·해제

같은 프로젝트에 같은 롤·영역(예 front)의 세션이 둘 이상일 때 이름으로 구분한다. 표시는 이름이 없으면 `front`, 있으면 `front#이름` 이다(영역이 있으면 `back:결제#이름`). 자동 번호는 붙지 않는다. 파이프라인 state·classification 을 바꾸지 않으며 이미 실행 중인 세션에서도 쓴다.

## 공통 규칙

```yaml
도구: 셸은 mcp__oio__bash_exec(dash), 파일은 mcp__oio__file_* 만 쓴다.
LIB: ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/role_lib.py   # 이하 role_lib (orole 스킬과 같은 라이브러리)
호출: python3 -B "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/role_lib.py" agent --sid <UUID> ...
세션_ID: --sid 는 hook 이 매 턴 출력하는 `🆔 [UUID]` 의 36자다. 없으면 rc=2 SID_MISSING 이다.
자기_세션만: 쓰기는 자기 세션 디렉터리와 자기 레지스트리 항목뿐이다.
이름_형식: 영문·숫자·한글·점(.)·밑줄(_)·하이픈(-) 만, 최대 20자, 숫자만으로 된 이름 금지(옛 자동 번호와 구분).
  공백·#·:·/·% ·따옴표·제어 문자 금지(제목과 tmux 형식 문자열에 들어가므로 화이트리스트로만 받는다).
```

## 지정·변경 — `/oagent 이름`

1. `role_lib agent --sid <UUID> <이름>` 을 실행한다. 성공하면 `ROLE_SET <롤[:영역]>#<이름>` 이 출력되고 롤 레지스트리·재개 색인에도 같이 기록된다. 같은 이름이면 `AGENT_UNCHANGED` 이다.
2. rc=2 처리는 아래와 같다.
   - `NAME_INVALID` — stderr 사유를 보여 주고 이름을 다시 받는다(1회). 그래도 실패하면 변경 없이 종료한다.
   - `NAME_TAKEN` — 같은 영역의 다른 활성 세션이 이미 그 이름을 쓴다. 다른 이름을 다시 받는다(1회).
   - `AGENT_NO_ROLE` — 롤이 all 이다. `/orole` 로 롤을 먼저 고르게 안내한다.
3. 성공해 값이 바뀌었으면 같은 턴에 orole 스킬의 `## 롤등록` 절차를 수행한다. 공지 본문의 `[롤:<값>]` 에 이름이 들어간다(UUID·team_name·state 는 넣지 않는다).

## 무인자 — `/oagent`

1. `role_lib agent --sid <UUID>` 로 현재 값을 확인한다. `AGENT_NAME <이름|(없음)>` 과 `ROLE <값>` 이 출력된다.
2. 현재 롤과 에이전트명을 한 줄로 보여 준다.
3. AskUserQuestion 으로 새 에이전트명을 묻는다. header `에이전트명`, 옵션은 `현재 유지`, `이름 해제` 두 개이고 직접 입력은 Other 로 받는다. Other 입력은 `role_lib name-check <입력>` 으로 형식을 먼저 확인한다.
4. `현재 유지` 는 변경 없이 종료, `이름 해제` 는 아래 해제 절차, Other 입력은 위 지정·변경 절차로 간다.

## 해제 — `/oagent --clear`

1. `role_lib agent --sid <UUID> --clear` 를 실행한다. 이름이 빠지고 `front` 처럼 표시된다.
2. rc=3 `NAME_REQUIRED` 면 같은 프로젝트에 이름 없는 같은 영역의 활성 세션이 있어 해제할 수 없다는 뜻이다. 사유를 보여 주고 이름을 유지한다.
3. 값이 바뀌었으면 `## 롤등록` 을 수행한다.

## 시작 시 중복 처리

`cc`·`ccc` 롤 선택, 첫 턴 롤 질문, `/orole` 로 롤을 고를 때 같은 프로젝트에 같은 영역의 활성 세션이 있으면 `role_lib set` 이 rc=3 `NAME_REQUIRED` 로 끝난다. 이때 이 스킬의 이름 입력 절차(AskUserQuestion, 직접 입력은 Other)로 이름을 받아 `<롤[:영역]>#<이름>` 으로 다시 set 한다. 활성 세션이 없으면 묻지 않는다. 죽은 세션(pid 불일치)은 중복으로 치지 않는다.

## 표시 반영 시점

- 값은 `role` 파일과 레지스트리에 즉시 기록된다.
- statusline 은 다음 갱신(새 응답 또는 refreshInterval)에 `🎭 front#이름` 으로 바뀐다.
- 창 제목은 statusline 이 쓰는 제목 갱신 경로를 따라 다음 갱신 주기에 바뀐다.
