---
name: oguard
description: 사용자가 소유한 hook·가드(PreToolUse/Stop hook, write_guard 류 차단 스크립트)의 과차단 수정이나 차단 조건 해제가 필요할 때, 에이전트가 직접 고치지 않고 정형 매뉴얼을 만든 뒤 codex(codex-companion task --write)에 강제로 넘겨 실행시키고, 결과를 독립 검증해 범위 밖 변경·검증 실패 시 원복하는 스킬. 사용자가 '/oguard', '가드 해제', '과차단 고쳐', '가드 수정 codex 로' 를 요청하거나, hook·가드 수정이 가드 작업 위험 판정에 걸려 사람용 매뉴얼로 넘기던 경우에 사용. 모델 안전 분류기·사용 정책 거부로 막힌 작업은 대상이 아니다.
---

# oguard — hook 가드 수정의 codex 위임

가드 수정은 에이전트가 직접 하지 않는다. **매뉴얼 → codex 실행 → 독립 검증 → 커밋 또는 원복** 순서를 예외 없이 따른다.
스크립트: `scripts/oguard_codex.sh` (이 SKILL.md 와 같은 폴더 아래). 매뉴얼 양식: [references/manual_template.md](references/manual_template.md).

## 0. 대상 판정 (착수 전, 생략 금지)

| 구분 | 신호 | 처리 |
|---|---|---|
| 대상 | 사용자 소유 hook 의 차단 메시지(🚫·⛔·`F-…` 코드·`PreToolUse:… hook error`), 가드 판정 완화·해제, 비활성 가드 블록 제거, 가드 시험 갱신 | oguard 진행 |
| 제외 | 모델 안전 분류기·사용 정책 거부로 응답이 막힌 작업(hook 메시지 없이 거부됨) | 진행하지 않는다. 사람용 매뉴얼까지만 만들고 실행 여부는 사용자가 판단한다 |
| 제외 | 자격증명·INFRA.md, 운영 배포, root·sudo, 타 세션 session-env, 저장소 밖 파일 | 진행하지 않고 보고한다 |

제외 대상을 codex·다른 에이전트·표현 변경으로 대신 처리하지 않는다.

## 1. 매뉴얼 작성

- 위치: `<git 루트>/docs/manuals/<주제>-<YYYY-MM-DD>.md`. docs-map 이 있으면 등재 규칙을 따른다.
- 양식의 6절(`## 목적`·`## 대상 파일`·`## 변경 내용`·`## 검증`·`## 되돌리기`·`## 금지`)을 모두 채운다.
- `## 대상 파일` 에는 수정할 파일을 백틱 절대경로로 빠짐없이 적는다. 스크립트가 이 목록으로 백업·범위 판정을 한다.
- `## 변경 내용` 은 정확 일치 치환(전·후 원문)이나 패치 스크립트로 쓴다. "적절히 수정" 같은 서술 금지.
- 패치 스크립트는 매뉴얼 옆 별도 파일(`<매뉴얼 이름>.patch.py` 등, 대상 경로는 절대경로)로 두고 매뉴얼에는 실행 한 줄만 적는다. 인라인 heredoc 은 codex 가 `bash -lc "…"` 로 옮기며 따옴표·`\n` 이 깨져 안전 검사에서 중단된다(2026-10-31 실측).
- 줄 번호에 의존하지 않는다(drift). 문자열 패턴으로 지정한다.
- 가능하면 대상 파일 사본에 패치를 먼저 적용해 검증 명령이 통과하는지 확인한다(파일 사본 작업은 허용).
- precheck 전에 `python3 -I -B <스킬경로>/scripts/manual_lint.py <매뉴얼>` 로 린트한다(`## 검증` 절의 실행 주체 모순·필수 6절 누락을 잡는다). `합계 FAIL=0` 이어야 한다.

## 2. 사전 점검과 기동

```bash
bash <스킬경로>/scripts/oguard_codex.sh precheck <매뉴얼> <git 루트>   # PRECHECK_OK 여야 한다
bash <스킬경로>/scripts/oguard_codex.sh start    <매뉴얼> <git 루트>   # RUN_DIR=… JOB=… 출력
```

- precheck 실패 항목: `MISSING_SECTION`·`NO_TARGETS`·`OUTSIDE_WORKDIR`·`DIRTY`(대상 파일에 미커밋 변경)·`NO_COMPANION`·`NO_CODEX_CLI`. 고친 뒤 다시 실행한다. DIRTY 는 먼저 커밋하거나 원인을 보고한다.
- `start` 는 대상 파일을 `RUN_DIR/backup` 에 백업하고 codex 를 `--background --write` 로 띄운다. RUN_DIR 경로는 반드시 기록해 둔다.
- 셸이 dash 이면 위 명령을 `bash` 로 직접 실행한다(`source` 금지).

## 3. 완료 대기

```bash
bash <스킬경로>/scripts/oguard_codex.sh status <RUN_DIR>   # "status": "completed" 까지
bash <스킬경로>/scripts/oguard_codex.sh result <RUN_DIR>   # codex 보고 원문
```

- 한 번의 셸 호출은 90초 안으로 끊는다. `wait` 는 completed·failed·cancelled 어느 쪽이든 끝나면 종료한다: `oguard_codex.sh wait <RUN_DIR> --timeout 80 --stall 60` (종료 코드 completed=0 / failed·cancelled=1 / 시간 초과=124 / 시작 단계 정체 `STALLED`=3). 124 이면 같은 명령을 다시 호출한다.
- completed 만 기다리며 폴링하지 않는다(failed 에서 영원히 멈춘다).
- `failed`·`cancelled` 이면 4단계를 건너뛰고 5단계 원복으로 간다.

### 직전 실측 실패 3종

| # | 증상 | 확인 | 조치 |
|---|---|---|---|
| 1 | status 가 `starting` 에서 수 분 정체(`wait` 가 `STALLED` 출력) | 해당 worktree 브로커 pid 의 자식 프로세스(app-server)가 있는지 `ps --ppid <브로커 pid>` 로 확인. 자식이 없으면 중계 프로세스가 죽은 것이다 | 그 worktree 의 브로커만 정상 종료(sendBrokerShutdown) 후 `start` 를 다시 실행한다. 다른 worktree 의 브로커는 건드리지 않는다 |
| 2 | completed 인데 대상 변경 0, 결과에 `MCP tool call requires approval, but approval policy is never` | `check` 가 `NO_CHANGE` 와 `APPROVAL_DENIED` 를 출력한다. `result` 원문으로 확인 | codex 의 승인 정책이 never 라 MCP(oio) 호출이 거부된 것이다. sync 로 oio 승인 줄이 codex config 에서 사라졌는지 확인하고 복구한 뒤 재기동한다. 이 상태의 결과는 성공으로 취급하지 않는다 |
| 3 | `oio 안 보임`으로 끝나고 completed 인데 대상 변경 0 | `result` 원문에서 oio 미발견 문구, `check` 의 `NO_CHANGE` | 추정: MCP 기동 경합(브리지 기동 전 도구 검색)이다. app-server 가 oio 브리지를 띄우기 전에 턴이 시작돼 도구 검색에 oio 가 안 나온다(2026-11-06 실측: 실패 작업의 검색이 브리지 기동 시각보다 앞섰고, 같은 app-server 에서 14초 뒤 시작한 작업은 oio 를 정상 호출했다. 브리지 단독 기동은 3.2초에 도구 23개 응답). `start` 프롬프트 규칙 5 가 "안 보이면 도구 검색, 없으면 20~30초 뒤 재검색, 그래도 없으면 멈춰 보고"를 지시한다. 그래도 재현되면 설정을 고치지 말고 재기동한다 |

`check` 는 codex 가 completed 인데 대상 파일 변경이 0 이면 `NO_CHANGE` 를 출력하고 `CHECK_FAIL`(rc 1)로 판정한다.

## 4. 독립 검증 (codex 보고를 믿지 않는다)

1. `oguard_codex.sh check <RUN_DIR>` → `CHECK_OK` 여야 한다. `OUT_OF_SCOPE` 가 하나라도 있으면 실패다.
2. 매뉴얼 `## 검증` 의 명령을 **에이전트가 직접** 다시 실행해 기대값과 대조한다.
3. `git diff -- <대상 파일>` 을 읽고 `## 변경 내용` 과 다른 줄이 없는지 확인한다.

## 5. 마무리

- 전부 통과: 대상 파일과 매뉴얼만 파일명을 명시해 `git add` 후 커밋한다(`-A`·`-u`·`.` 금지, push 금지).
- 하나라도 실패: `oguard_codex.sh restore <RUN_DIR>` 로 원복하고 `git status` 로 원상 복귀를 확인한다. 실패 지점·codex 보고·검증 출력을 보고한다. 같은 매뉴얼로 재시도는 원인을 매뉴얼에 반영한 뒤 1회만 한다.
- 범위 밖 변경(OUT_OF_SCOPE) 파일은 restore 가 건드리지 않는다. 같은 폴더의 다른 작업자가 고친 것일 수 있으므로 되돌리지 않는다. `git diff` 로 내용을 확인해 보고하고, codex 변경임이 확실할 때만 주인(팀 리더)의 판단으로 처리한다. 다른 사람이 편집 중인 폴더에서는 oguard 를 전용 worktree 에서 실행한다.
- restore 는 원복 직전 내용을 `RUN_DIR/before_restore/` 에 남긴다. 실행 중 다른 사람이 같은 파일을 고쳤다면 거기서 되찾는다.
- 보호 파일 동기화(L-1494, 재발방지 3순위=스킬): gp_gate.sh·guard_promote.json·고정 시험처럼 F-GUARD-PROMOTE 대상은 파일 도구·셸 쓰기가 막힌다. 순서는 후보(`hooks/candidates/<id>/`) → `guard_promote.sh promote` 로 live 교체 → worktree 에는 `git apply` 로 동기화로 고정한다. 보호 파일을 worktree 에서 직접 쓰려 하지 않는다.

## 보고 형식

대상 판정 결과 · 매뉴얼 경로 · RUN_DIR · codex 결과 요약 · check 결과 · 검증 명령 실측 출력 · 커밋 해시 또는 원복 사실.
