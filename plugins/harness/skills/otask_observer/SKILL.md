---
name: otask_observer
description: >
  작업 실행 중 스킬 개선 기회를 상시 관찰·기록하는 스킬. 다단계 작업, 에이전트 워크플로,
  도구를 사용해 산출물을 만드는 모든 실질적 작업 세션에서 사용한다. 패턴, 사용자 교정,
  워크플로 통찰, 재사용 가치가 있는 방법론을 포착한다. 작업 후 피드백 논의, 그리고
  사용자가 관찰 로그·스킬 분류체계·개선 기회를 직접 언급할 때도 발동한다.
  원명 "One Skill to Rule Them All". 중요 — description 매칭만으로는 발동을 신뢰할 수
  없으므로, 이 스킬은 hook 통지(PostToolUse_observation_checkpoint.sh)로 발동을 보강한다
  (연동 지점 절 참조).
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["PostToolUse_observation_checkpoint.sh(알림)", "odone_lesson(승격 소비)"]
  calls: []
---

# otask_observer — 상시 작업 관찰 + 스킬 개선 기회 발견

**원저작자**: Eoghan Henn / [rebelytics.com](https://rebelytics.com) — 원제 "One Skill to Rule
Them All". **라이선스**: CC BY 4.0 (저작자 표시 시 공유·변형 자유). **원본 저장소**:
[github.com/rebelytics/one-skill-to-rule-them-all](https://github.com/rebelytics/one-skill-to-rule-them-all).
본 파일은 원본을 이 프로젝트(AI 하네스) 환경에 맞게 한국어로 이식하고 로그 경로·ID 체계·
연동 지점을 재구성한 버전이다. 원본의 구조·안전 원칙·문구 의도를 보존하며, 크레딧 블록은
삭제하지 않는다.

## 역할

스킬은 실제 작업 중 발생하는 마찰(friction)에서 가장 잘 개선된다. "스킬을 개선하려고 따로
앉아서" 생각해낸 것보다, 작업 도중 자연스럽게 떠오른 통찰이 훨씬 유용하다. 이 스킬은 그
알아차림을 형식화하여 세션 간 통찰이 유실되지 않도록 한다.

이 스킬은 **관찰(미검증) 저장소**다. `LESSONS.md`의 `L-NNN`(확정 교훈)과 네임스페이스를
분리한다 — `OBS-NNN`(관찰, 미검증) → 검토 후 → `L-NNN`(확정, LESSONS.md 등재)의 단방향
승격 경로를 가진다. 자세한 승격 절차는 "odone_lesson 연동" 절 참조.

## 로그 위치 (세션 격리 §(a) 필수 준수)

```
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/observations.md
```

- 원본은 프로젝트 루트 하위 `skill-observations/log.md`(워크스페이스 고정 경로)를 사용하나,
  이 환경은 다중 세션이 동시에 도는 팀에이전트 하네스이므로 **자기 세션 UUID 하위**에만
  써야 한다 (세션 격리 불변식 §(a) — 타 세션 `session-env/*/` 쓰기는 절대 금지).
- `${UUID}`는 현재 파이프라인의 `PIPELINE_UUID` (또는 메인 세션 UUID)로 치환한다.
- 파일/디렉토리가 없으면 세션 시작 시 생성한다 (`mcp__oio__dir_create` + `mcp__oio__file_write`).
- **주의**: 원본의 "persistent workspace, ephemeral checkout 재앵커링" 개념은 이 환경에서
  "session-env/${UUID}/는 세션 생명주기와 함께 소멸한다"로 대체된다 — 즉 관찰 로그는
  **세션 스코프**이며, 세션을 넘어 보존해야 할 통찰은 반드시 odone_lesson 경로를 통해
  LESSONS.md로 승격해야 한다. 세션 종료 시 자동 보존되지 않는다.

## OBS-NNN ID 체계 (LESSONS.md L-NNN과 네임스페이스 분리)

| 구분 | 의미 | 저장 위치 | 신뢰도 |
|---|---|---|---|
| `OBS-NNN` | 관찰 (미검증, 세션 스코프) | `logs/observations.md` | 낮음 — 1회 관찰일 수 있음 |
| `L-NNN` | 확정 교훈 (검증됨, 영구) | `LESSONS.md` | 높음 — 재발방지 조치와 연결됨 |

**승격 조건 (OBS → L- 경로, odone_lesson이 수행)**:
1. odone_lesson Step ①~② (odone_trans/odone_review) 실행 중 현재 세션의
   `logs/observations.md`에서 `**Status:** OPEN` 항목을 전수 스캔한다.
2. 각 OBS 항목을 기존 `odone_review`의 Level 1/2/3 분류 절차에 그대로 태운다
   (Level 1: 참고 기록 / Level 2: 스킬 규칙 강화 / Level 3: hook 물리 차단).
3. 승격이 결정된 항목은 LESSONS.md에 `L-NNN`으로 신규 기록하고, 원본 OBS 항목의
   Status를 `ACTIONED (YYYY-MM-DD) — L-NNN으로 승격`으로 갱신한다.
4. 승격되지 않은 항목(재현성 낮음, 일회성, 판단 보류)은 `DECLINED (YYYY-MM-DD) — 사유`로
   남기고 LESSONS.md에는 기록하지 않는다 — 미검증 관찰이 그대로 확정 교훈이 되는 것을 막는
   1차 필터다.
5. 이 승격 절차는 `odone_lesson/SKILL.md`(별도 담당자 소관)에 연동 지점으로 명시되어야
   하며, 본 파일은 계약만 정의한다 — 실제 SKILL.md 본문 수정은 이 스킬의 담당 범위 밖이다.

## hook 연동 지점 (자기 발동을 LLM 의지에 의존하지 않도록)

원본 SKILL.md는 frontmatter에서 스스로 이렇게 자인한다 (원문 그대로 보존 — 삭제 금지).

> "For reliable activation, pair this description with a CLAUDE.md instruction or
> harness-level session-start hook — description-level matching alone is not enforceable."
>
> (번역: 신뢰성 있는 발동을 위해서는 이 description을 CLAUDE.md 지시문 또는 하네스
> 수준의 세션 시작 hook과 병행해야 한다 — description 수준의 매칭만으로는 강제할 수 없다.)

이는 이 프로젝트의 "재발방지 = 물리적 강제. LLM 의지에 의존하는 조치는 재발방지가 아님"
원칙과 동일 사상이다. 원본 스스로가 "description 매칭만으로는 부족하다"고 인정한 것을
그대로 받아, 이 프로젝트에서는 CLAUDE.md 지시문 병기에 그치지 않고 한 단계 더 강한 물리적
장치로 대응한다 — 실제 체크포인트 강제는 `.claude/hooks/PostToolUse_observation_checkpoint.sh`
(별도 담당 odev-2 구현)가 맡는다. 즉 원본이 제안한 "설정 파일 병기" 수준을 이 환경은
"hook 물리 강제" 수준으로 격상하여 흡수한 것이다.

- **연동 계약**: hook은 `TodoWrite`(또는 이 환경의 등가 완료 이벤트) 완료 카운터를
  `session-env/${UUID}/` 하위에 누적하고, 3의 배수에 도달하면 **차단이 아닌 알림
  (notify)**으로 "관찰 기록 요구" 메시지를 stdout에 출력한다.
- 이 스킬(otask_observer)의 책임은 그 알림을 받았을 때 무엇을 어떻게 쓸지의 **본문
  규칙**을 정의하는 것이고, 발동 트리거 자체의 물리적 강제는 hook의 책임이다 — 즉 본
  스킬은 "언제 쓸지"의 로직을 hook에 위임하고, "무엇을 어떻게 쓸지"만 규정한다.
- hook 스크립트 자체는 이 파일의 담당 범위가 아니다 (odev-2 담당). 여기서는 연동
  인터페이스만 명시한다.

## 관찰 대상 (원본 taxonomy 이식)

**신규 스킬 후보 신호**: 재사용 가능한 다단계 워크플로, 기존 스킬이 못 잡는 사용자 설명
방법론, 유사 구조가 반복되는 작업 유형, 명확한 입력·단계·출력 구조를 가진 프로세스,
사용자가 "나는 항상 이렇게 한다"고 설명하는 정제된 프로세스, 작업 중 자연히 드러나는
구조적 접근.

**기존 스킬 개선 신호**: 스킬을 사용한 작업에서 나온 문제점·긍정 신호·중립적 공백 전부.
예 — 에이전트가 문서화된 규칙을 위반함(스킬에 규칙 강화가 아니라 **강제 장치**가 필요하다는
신호), 사용자 교정이 누락된 규칙/엣지케이스를 드러냄, 스킬 권장보다 나은 워크플로가 나타남,
부수적이던 기법이 충분히 검증되어 권장으로 승격할 만함, 문서화 안 된 사용 사례, 일반화 가능한
피드백, 잘못된 가정, 새 도구가 기존 단계를 무의미하게 만듦, 패턴을 이루는 반복 교정, 다른
스킬에도 적용되는 원칙, 네이밍·프레이밍·구조 제안(대화 중 나온 것 포함).

**스킬 단순화 신호 (SIMPLIFY — 신규 축, LESSONS.md에 없던 관점)**: 여러 세션 동안 한 번도
관련 없었던 섹션, 검증 안 된 단발 관찰에서 나온 규칙, 사용자가 늘 건너뛰는 워크플로,
로드는 되지만 실행되지 않는 섹션, 모순되는 규칙, "혹시 몰라서" 넣은 복잡도가 한 번도
발동하지 않은 경우, **에이전트가 반복적으로 못 지키는 규칙**(구조적 강제로 전환하거나
삭제 대상). 이 목록을 리뷰 체크리스트로 삼아 "무엇을 추가할까"만큼 "무엇을 제거할까"도
의식적으로 묻는다.

이 프로젝트의 `LESSONS.md`는 L-459까지 단조 증가만 해왔고 삭제 축이 부재하다 — SIMPLIFY
신호를 관찰 로그에 명시적으로 태깅함으로써 향후 정리 검토의 근거를 남긴다 (실제 정리 실행은
odone_lesson/LESSONS.md 담당자 소관, 본 스킬은 신호 포착만 담당).

**기록하지 않는 것**: 일반화되지 않는 1회성 교정, 이미 어떤 스킬에 포착된 선호, 방법론과
무관한 도구 버그, 오픈소스로 공개 시 특정 클라이언트/프로젝트 정보 없이는 의미가 없는 관찰.

## 기록 방법 (병렬 로그 안전 5원칙 — 필수)

**로그 기록은 조용히, 같은 턴 또는 다음 턴 안에** 한다 — 나중을 위해 머릿속으로 미루지
않는다. 쓰는 행위 자체가 강제 장치다.

이 환경은 팀에이전트가 병렬로 동시에 돈다. 원본이 정의한 동시 쓰기 안전 원칙 5가지를
한국어로 이식한다. **다중 세션 공유 저장소 사고(LESSONS.md L-457)와 직결되는 항목이므로
반드시 준수한다.**

1. **쓰기 직전 재읽기 후 병합** — 스냅샷을 근거로 파일 전체를 재작성하면, 스냅샷 이후
   동시 세션이 추가한 항목이 그대로 사라진다. 쓰기 성공, 피해자는 에러 없음, 유실은
   눈에 안 보인다. 항상 "스냅샷 → 변경 준비 → 쓰기 직전 재읽기 → diff → 새 항목 병합"
   순서를 지킨다. 오래된 스냅샷을 그대로 되쓰지 않는다.
2. **항목 단위로만 변경, 파일 전체 걸친 탐욕적(greedy)/DOTALL 치환 금지** — 실제로 파일
   전체에 걸친 정규식 치환이 한 항목의 Status 줄부터 파일 끝까지를 통째로 삼켜 이후
   16개 항목이 소실된 사고가 있었다. `### Observation N:` 헤더 기준으로 파일을 분할하여
   대상 항목만 편집 후 재조립하거나, 줄 단위로 앵커링된 치환만 사용한다.
3. **라이브 파일 기준 구조 불변식 검사** — 쓰기 직전과 직후에 `### Observation` 헤더
   개수를 라이브 파일에서 직접 세어 비교한다. 상태 변경만이면 개수 불변, append면 정확히
   +1이어야 한다. **기준은 반드시 쓰기 시점의 라이브 파일**이어야 한다 — 세션이 앞서
   읽어둔 스냅샷을 기준으로 삼으면 "의도한 대로 썼다"는 검증은 통과해도 "그 사이 남이
   쓴 것을 파괴했는지"는 놓친다.
4. **쓰기 전 백업** — 프로그램적 변경(archival, 재번호, 상태 변경) 전에 반드시 원본을
   백업한다. 사고 발생 시 완전 복구를 가능케 하는 최후 방어선이다.
5. **"쓰기 성공"이 아니라 "생존"을 검증** — 세션 종료 전, 이번 세션이 기록한 모든
   `OBS-NNN` 번호를 로그에서 grep하여 정확히 1회씩 존재하는지 확인한다. 병렬 삭제가
   발생하면 피해 세션은 에러를 받지 못한다 — 생존 확인만이 유일한 탐지 수단이다.

**번호 부여 규율 (매 append마다 필수)**:
```bash
# 1) 사전 확인 — 세션 기억이 아니라 실제 로그에서 최대 번호를 읽는다
grep -oP '### Observation OBS-\K[0-9]+' observations.md | sort -n | tail -1
# 2) 쓰기 직전 재확인 — 제안 번호가 이미 존재하는지 검사
# 3) 쓰기 후 검증 — 해당 번호가 정확히 1회 존재하는지 확인, 2회 이상이면 충돌 → 재번호
```

## 기록 형식

```markdown
### Observation OBS-[N]: [짧은 제목]

**Status:** OPEN
**Date:** [날짜]
**Session context:** [무슨 작업 중이었는지]
**Skill:** [관련 기존 스킬명, 또는 "신규 스킬 후보: [가칭]"]
**Type:** [open-source | internal]
**Phase/Area:** [스킬/워크플로의 어느 부분인지]
**Signal:** [NEW | IMPROVE | SIMPLIFY]

**Issue:** [무슨 일이 있었는지 — 몇 주 후 원래 대화 없이도 이해할 수 있을 만큼 구체적으로]

**Suggested improvement:** [구체적 변경안. 기존 스킬이면 섹션/규칙명, 신규 스킬이면 범위와
핵심 구성요소]

**Principle:** [일반화 가능한 핵심 — 가장 중요한 필드]
```

새 관찰은 항상 `**Status:** OPEN`을 첫 필드로 포함해야 한다 (필수, 생략 금지) — 이후
검토가 Status 기준으로 분류하므로, Status 없는 항목은 필터링 검토에서 보이지 않게 된다.

## 로그 구조 템플릿

```markdown
# 관찰 로그 (Skill Observation Log)

작업 중 포착된 관찰 기록. 세션 스코프 — 세션 종료 시 영구 보존되지 않으므로,
지속 보존이 필요한 통찰은 odone_lesson 승격 경로를 거쳐 LESSONS.md로 이관한다.

**Status 키**: OPEN = 미처리 | ACTIONED (YYYY-MM-DD) — [처리 내용] | DECLINED (YYYY-MM-DD) — [사유]

---

## [날짜]

### Observation OBS-1: [제목]
**Status:** OPEN
[... 전체 형식 ...]
```

## 관찰 시점

작업 세션 전체 — 실행, 작업 후 피드백/리뷰 논의, 스킬/방법론에 관한 메타 논의, 작업
방식에 관한 회고/전략 대화 모두 포함한다. 작업 이야기에서 작업을 논하는 이야기로
전환되어도 관찰 태세는 유지된다 — 리뷰 단계의 사용자 피드백이 가장 신호가 강할 때가 많다.
일상 대화와 도구·산출물이 없는 단순 사실 질문에서만 비활성이다.

## 주간 검토 (요약)

원본의 `references/weekly-review.md`에 상응하는 절차는 이 프로젝트의 `odone_lesson`
파이프라인이 대체 수행한다 (Step ①~②: odone_trans/odone_review). 별도의 독립 주간 검토
스킬을 새로 만들지 않는다 — Surgical Changes 원칙에 따라 기존 odone 체인에 편승시킨다.
자세한 승격 절차는 위 "odone_lesson 연동" 절 참조.

## 참고

- 원본 3종 참조 파일(`weekly-review.md`, `skill-authoring.md`, `environments.md`)은
  이 스킬의 `references/`에 한국어 이식본으로 보존한다. 상세 스킬 작성 규약(분류체계
  전문, 라이선싱, 기밀성 계층, 편집 규칙)은 `references/skill-authoring.md`를, 검토
  절차 전문은 `references/weekly-review.md`를, 활성화/환경 설정은
  `references/environments.md`를 필요 시 로드한다.
- 이 스킬 자체는 사용자 직접 호출(`/otask_observer`) 대상이 아니며, hook 알림과
  odone_lesson 승격 경로로만 동작한다.
