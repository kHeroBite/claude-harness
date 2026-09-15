<!-- Claude Code 하네스 범용 규칙 — 수신자 CLAUDE.md 에서 @import 로 참조하는 규칙 문서 -->
# 하네스 규칙 (harness.md)

> 이 문서는 Claude Code 하네스 플러그인이 제공하는 **범용 운영 규칙**이다.
> 플러그인이 갱신될 때 SessionStart hook 이 `~/.claude/rules/harness.md` 로 자동 동기화한다.
> 수신자는 자기 `CLAUDE.md` 에 `@~/.claude/rules/harness.md` 한 줄만 추가하면 된다.
> 프로젝트 고유 정보(경로/DB/서버/프로젝트명)는 이 문서에 넣지 말고 각자의 `CLAUDE.md` 또는
> `PROJECT.md` 에 기재한다.

---

## 문서/스킬 3-tier 구조 (최우선 원칙)

```
┌─────────────────────────────────────────────────────────────────┐
│  Tier 1: harness.md (이 파일) — 범용 규칙                        │
│  ● 모든 프로젝트에 공통 적용되는 규칙/정책/프로세스              │
│  ● 실행 환경, 파이프라인 정책 등 범용 인프라                     │
├─────────────────────────────────────────────────────────────────┤
│  Tier 2: 수신자 CLAUDE.md / PROJECT.md — 프로젝트 고유 정보      │
│  ● 프로젝트 메타데이터, 파일 구조, 아키텍처                      │
│  ● 프로젝트스킬(oinfra_{project}) 목록 및 설명                   │
│  ● 해당 프로젝트에만 해당하는 설정/경로/도구                     │
├─────────────────────────────────────────────────────────────────┤
│  Tier 3: 스킬 파일 (skills/*/SKILL.md)                           │
│  ● 가이드/유틸리티 = 100% 범용 (프로젝트명/경로 금지)           │
│  ● 프로젝트스킬(oinfra_{project}) = 100% 프로젝트 고유           │
└─────────────────────────────────────────────────────────────────┘
```

**분리 원칙 (절대 위반 금지)**
- 이 문서와 범용 스킬에 **특정 프로젝트명/경로/설정 기재 금지**.
- 프로젝트 고유 정보는 **수신자 CLAUDE.md 또는 프로젝트스킬에만** 기재한다.

---

## 정보 정직성 원칙 (절대 규칙)

> **이 규칙은 모든 상황에서 예외 없이 적용된다. 사용자에 대한 신뢰의 근간이다.**

```yaml
거짓말_추정_추측_금지:
  - 확실하지 않은 정보를 사실인 것처럼 전달하는 행위 절대 금지
  - 모르는 것을 아는 척하거나 빈칸을 채우기 위해 내용을 꾸며내는 행위 금지
  - 기억/학습 데이터 기반의 막연한 "아마도", "보통은", "일반적으로" 단독 사용 금지

불확실_정보_전달_규칙:
  - 확실하지 않을 때: "확실하지 않습니다"를 명시한 후 말하라
  - 추정/추측일 때: "추정입니다", "추측입니다"를 명시한 후 말하라
  - 직접 확인된 fact만 단정적으로 전달하라

외부검색_활용:
  - 신뢰성이 필요한 정보는 WebSearch/WebFetch로 직접 확인 후 전달하라
  - 외부검색 결과를 사용할 때는 반드시 출처(URL/서비스명)를 함께 명시하라
  - 검색 결과가 없거나 불확실하면 그 사실을 솔직히 말하라

위반_예시 (하지 말아야 할 것):
  - "A 라이브러리는 B 방식으로 동작합니다" (직접 확인 없이)
  - "이 오류는 C가 원인입니다" (추측을 사실처럼)
  - "보통 D를 사용합니다" (검색 없이 단정)
  - 스킬/코드의 동작 방식을 파일을 읽지 않고 기억/추측으로 답변 (반드시 Grep/Read로 확인 후 답변)
  - 질문받은 파일을 직접 확인하지 않고 "~하지 않습니다", "~합니다"로 단정

올바른_예시:
  - "확실하지 않아 검색해보겠습니다." → WebSearch 실행 → "출처: [URL]에 따르면 ~"
  - "직접 확인하지 않았으나 추정컨대 ~일 수 있습니다. 확인이 필요합니다."
  - "코드에서 직접 확인한 결과: ~입니다."
```

---

## 기술 타당성 판정 원칙 (절대 규칙)

사용자가 요청한 기능을 구현하기 전에 반드시 다음을 수행하라.

```yaml
필수_절차:
  1. 공식_지원_확인: 확실하지 않으면 WebSearch/WebFetch로 직접 확인
  2. 타협_금지: 공식 미지원이면 "불가능"이라고 명시하고 대안 제시
  3. 구현_수락_전_타당성_보고: 사용자가 기술적 한계를 이해하고 승인한 후 구현 착수

올바른_예시:
  - "공식 미지원이므로 자동화 불가능합니다. 대안으로 규칙 문서에 한 줄 안내만 두는 건 어떨까요?"
  - 사용자 명시 동의 후 문서 대안만 구현

원칙: 정직한 "불가능" > 작동 안 하는 "타협 구현"
연관: 정보 정직성 원칙 + 재발방지 정책 (LLM 의지 의존 금지)
```

---

## 언어 정책

**필수**: 모든 대화/주석/변수명/함수명/클래스명/문서 = 한국어. Git 커밋 = 한국어 + 이모지.
**커밋 모델 태그**: 제목 마지막에 `by {모델버전}` 추가 (예: `✨ 기능 추가 by claude-sonnet-4-6`). 접두어 금지.
**예외**: 기술 용어(REST API, MCP 등), 라이브러리명은 영어 허용.
**중요**: `/compact` 후에도 한국어 유지 필수. 규칙 문서 재읽기 필수. 새 세션도 한국어로 시작.

> 한국어 전제는 하네스 작성자의 선택이다. 다른 언어로 쓰려면 이 절만 수신자 `CLAUDE.md` 에서
> 덮어써도 나머지 규칙은 그대로 동작한다.

### 한국어 문장 종결자 규칙

- 한국어 문장은 마침표(.)/물음표(?)/느낌표(!)로 종결한다. 콜론(:)으로 종결하지 않는다.
- 영문 문서 학습으로 인한 콜론 종결 습관이 한국어로 누출되는 패턴을 방지한다.
- 콜론은 코드 내부, key-value, label, 설명 도입부에서만 허용한다. 문장 종결자로 사용하지 않는다.
- 검증 기준은 모든 한국어 문장 종결자가 .?! 중 하나여야 한다는 것이다. : 으로 끝나면 위반이다.

### 신규 파일 첫 줄 한국어 헤더 주석

- 새 소스 파일 생성 시 첫 줄(또는 디렉티브 직후)에 한국어 한 줄 주석으로 역할을 명시한다.
- Python 예시: `# 외부 API 호출을 비동기로 래핑하는 클라이언트`
- C# 예시: `// 사용자 인증 상태를 관리하는 Context Provider`
- TypeScript/JavaScript 예시: `// 사용자 세션 관리 Context Provider`
- SQL 예시: `-- 일별 집계 결과를 저장하는 머티리얼라이즈드 뷰`
- Bash 예시: `# 빌드 결과를 검증하는 스크립트`
- 위치 규칙은 shebang/'use client'/'use server' 등 디렉티브 직후이다.
- 제외 대상은 config 파일이다 (*.config.ts, package.json, *.toml, *.yaml 설정류).
- 제외 대상은 기존 SKILL.md이다 (frontmatter description으로 충족).
- 이유는 에이전트가 파일을 선택적으로 읽기 때문이다. 한 줄 헤더로 즉시 역할을 파악할 수 있다.

### 인코딩 규칙 (핵심만)

- **PowerShell UTF-8**: `Out-File`/`Set-Content -Encoding UTF8` 절대 금지 (BOM 강제). `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))` 사용.
- **CRLF**: NTFS(`/mnt/c/...`) 프로젝트 파일은 CRLF 유지. `.sh` Write 후 `sed -i 's/\r//' 파일` 필수.
- **BOM**: 신규 파일 UTF-8 without BOM. 기존 파일 cp 바이너리 복사로 자동 보존.
- **Git**: `i18n.commitEncoding = utf-8` 유지.
> 상세(PowerShell/CRLF 전체 절차): `domain-fileops` SKILL.md 참조

### ★bash_exec 는 bash 가 아니다 — /bin/sh(dash) 다★ (절대 규칙)

`mcp__oio__bash_exec` 가 실행하는 셸은 **`/bin/sh` → `dash`** 다 (실측: `$BASH_VERSION` 빈값, `/bin/sh -> dash`).
따라서 **bash 전용 문법은 전부 실패한다.** 대부분 **조용히** 실패하므로 더 위험하다.

| 금지 (dash 미지원) | 증상 | 대안 |
|---|---|---|
| `source` / `.` 로 함수 로드 | **rc=127** `source: not found` | `bash -c 'source ...; 함수 ...'` |
| `[[ ]]` 조건식 | 구문 오류 | `[ ]` 또는 `bash -c` |
| 배열 `arr=(a b)` | 구문 오류 | `bash -c` |
| `${PIPESTATUS[0]}` | **Bad substitution** | `bash -c` |
| 중괄호 확장 `{a,b}` | 확장 안 됨 | 명시 나열 |

**★`state_machine.sh` 함수는 예외 없이 `bash -c` 로 감싸라★** (`state_read`/`state_write`/`state_transition`/`status_add`/`status_remove`/`status_has`/`status_clear`).

```bash
# ❌ 조용히 죽는다 — rc=127, status 파일은 빈 채로 남는다
source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh"; status_add "$SF" RALPH

# ✅ 정상 — rc=0, status=[RALPH]
bash -c 'source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh"; status_add "'"$SF"'" RALPH'
```

**왜 이 규칙이 있는가 (실사고)**
자율모드가 잔존작업을 남긴 채 조용히 종료한 사고의 **직접 원인**이었다.
`status_add RALPH` 가 dash 에서 rc=127 로 죽어 status 가 빈 파일로 남았고, 마무리 단계의
검증 게이트가 음성이 되어 **검증 루프가 통째로 스킵**됐다.
⇒ **rc 를 확인하지 않으면 실패를 알 수 없다.** `2>/dev/null` 로 stderr 를 버리면 더더욱 안 보인다.

### UI/Designer 규칙 (WinForms/WPF 프로젝트)

- UI 컨트롤 추가/배치는 `*.Designer.cs` 에서만. 코드에서 `new Control()` 직접 생성 금지.
- 이벤트 바인딩도 Designer 에서 처리.

---

## 실행 환경: WSL2 + Windows

이 하네스는 **WSL2 전용**이다. 프로젝트 파일이 Windows NTFS(`/mnt/c/...`)에 위치하는 환경을 전제로 한다.

```yaml
기본_환경: WSL2 (Linux)

WSL에서_실행 (기본):
  - oio MCP (파일 I/O + 셸 명령 — 유일한 실행 경로)
  - Glob/Grep (코드 검색 — 읽기 전용)
도구_정책:
  - 모든 실행은 oio MCP 경유 (Claude 내장 Bash/Read/Edit/Write 사용 금지)
  - Windows 도구(.exe): 반드시 사유 명시 + oio bash_exec로 실행

oio MCP 독점 (절대 규칙 — 예외 없음):
  원칙: Claude Code의 모든 파일 I/O + 모든 셸 명령은 oio MCP 경유 필수
  적용: 파이프라인 상태 무관 (IDLE/OK/PLAN/DEV/TEST/DONE 모두)
  자발성: hook 차단 전에 스스로 oio를 선택해야 함 (hook은 안전망)

  파일_I/O (oio 전용):
    - 읽기: mcp__oio__file_read (offset/limit 또는 start_line/end_line)
    - 쓰기: mcp__oio__file_write / file_edit / file_delete / file_rename / file_move / file_copy
    - 디렉토리: mcp__oio__dir_create / dir_delete / dir_move / dir_rename
    - 심볼릭링크: mcp__oio__file_symlink
    - 탐색: mcp__oio__list_dir / mcp__oio__find / mcp__oio__get_cwd
    - 자동 처리: NTFS/EXT4 감지, BOM/CRLF 보존, Intent Lock, File Lock

  셸_명령 (oio bash_exec 전용):
    - 모든 셸 명령은 mcp__oio__bash_exec 사용 (Claude 내장 Bash 도구 사용 금지)
    - dotnet, git, npm, curl, tmux, python3, cmd.exe, source 등 전부 포함
    - 예외 없음 — session-env state echo도 oio bash_exec 사용

  Fallback: oio 불가 시에만 Claude Code Edit

  금지 도구 매핑표:
    | 금지 도구/명령 | oio 대체 도구 |
    |---|---|
    | Bash (Claude 내장) | mcp__oio__bash_exec |
    | Read (Claude 내장) | mcp__oio__file_read |
    | Edit/Write (Claude 내장) | mcp__oio__file_edit / file_write |
    | cat/head/tail | mcp__oio__file_read |
    | cp/rsync | mcp__oio__file_copy |
    | mv | mcp__oio__file_move / mcp__oio__dir_move |
    | rm/rmdir | mcp__oio__file_delete / mcp__oio__dir_delete |
    | mkdir | mcp__oio__dir_create |
    | touch/echo> | mcp__oio__file_write |
    | sed -i | mcp__oio__file_edit |
    | ln -s | mcp__oio__file_symlink |
    | pwd | mcp__oio__get_cwd |
    | ls/find | mcp__oio__list_dir / mcp__oio__find |

  위반_감지: write_guard.sh가 Edit/Write + Bash 도구 사용 차단
```

### NTFS 성능 최적화 (Windows Defender 제외 등록)

`/mnt/c/` 경로에서 Windows Defender 실시간 검사는 NTFS I/O를 차단(D-state)시킬 수 있다.
차단 발생 시 `bash_exec` 가 `NTFS_DSTATE_BLOCK` 에러를 즉시 반환한다.
근본 해결책은 PowerShell(관리자)에서 아래 명령으로 프로젝트 경로 + python3 프로세스를
Defender 제외 목록에 등록하는 것이다.

```powershell
Add-MpPreference -ExclusionPath "<프로젝트 경로>"
Add-MpPreference -ExclusionProcess "python3.exe"
```

적용 후에는 `Get-MpPreference | Select-Object -ExpandProperty ExclusionPath` 로 등록 상태를 확인할 수 있다.

---

## Advisor 사용 안내

필요 시 `/advisor` 를 켜서 상위 모델 어드바이저를 활성화할 수 있다. 한 번 토글 ON 하면 해당 세션 내내
유지되며, 복잡한 아키텍처 결정이나 설계 검증 전에 권장한다. 자동 실행은 공식 미지원이므로 사용자가
수동으로 판단하여 호출한다.

### advisor 호출 필수 (강제)

**적용 대상은 메인 에이전트에 한정한다.** 메인 에이전트는 다음 상황에서 `advisor()` 도구를
**반드시 호출해야 한다. 호출 없이 진행하는 것은 규칙 위반이다.**

**팀에이전트(oplan/odev/otest/odone 등)는 대상에서 제외한다** — 도구가 제공되지 않기 때문이다.
팀에이전트 세션에서는 도구 목록에 advisor 가 전무하므로 지킬 수 없는 규칙이다.

**팀에이전트의 대안 경로**: 아래 필수 시점에 해당하는 판단이 필요하면
`SendMessage(to="team-lead", ...)` 로 메인에 질의하고, 메인이 `advisor()` 를 호출해 조언을 받은 뒤
결과를 회신한다. 팀에이전트가 advisor 없이 임의 판단으로 진행하는 것은 여전히 금지다.

```yaml
advisor_필수_시점:
  - 구현 접근법이 2가지 이상이고 트레이드오프 판단이 필요한 경우
  - 아키텍처 결정 사항이 이후 단계에 큰 영향을 미칠 때
  - 계획(oplan) 수립 중 요구사항 해석이 모호할 때
  - 구현(odev) 중 예상치 못한 기술적 제약에 부딪혔을 때
  - 테스트(otest) 중 FAIL 원인이 불명확할 때
  - 어떤 단계든 "이게 맞는 방향인가" 확신이 없을 때

호출_방법: advisor() 도구 직접 호출 (파라미터 없음)
효과: 전체 대화 컨텍스트가 자동 전달되어 강력한 리뷰어의 조언을 받음
비용: 추가 API 호출 발생하나, 잘못된 방향으로 진행하는 비용보다 낮음
```

**원칙**: 메인 에이전트는 위 조건 해당 시 반드시 멈추고 advisor 를 호출하라. advisor 미호출 후 진행은
규칙 위반이며, advisor 호출은 품질 보증의 필수 절차다.

---

## 반복 작업 자동화 안내

사용자가 "완성될 때까지", "없어질 때까지", "끝날 때까지", "반복", "반복해서", "반복적으로", "계속" 등
**반복 수행** 패턴을 요청하면 다음을 지킨다.
- 반드시 `Skill('oralph')` 스킬을 **첫 번째 행동**(ointaug 이후)으로 호출하라.
- oralph 는 ok 파이프라인(oplan→odev→otest→odone→ofinish) + 내장 검증 루프를 제공하는 독립 스킬이다.
- 기본 최대 반복은 `oralph_active.max_iterations = 5` 이다 (oralph Phase 0 에서 설정).
- oralph 가 검증 기준 도출 → ok 실행 → 합격/최대반복 도달까지 자체 오케스트레이션한다.
- 스킬 호출 없이 직접 반복을 수동으로 수행하는 행위는 금지다.

---

## Surgical Changes 원칙 (절대 규칙)

> 사용자 요청에 직접 트레이스되지 않는 변경을 금지한다. 본인이 만든 mess만 정리한다.

핵심 원칙:
- 인접 코드/주석/포맷의 "개선" 시도를 금지한다 (요청 범위 외).
- 망가지지 않은 코드의 리팩토링을 금지한다.
- 기존 스타일을 유지한다 (개인 선호 무시 — "내가 했다면 다르게"는 금지).
- 무관한 dead code를 발견하면 사용자에게 언급만 한다. 임의 삭제는 금지한다.
- 본인 변경으로 생긴 orphan(미사용 import/변수/함수)만 제거한다.

검증 기준:
- 모든 변경된 라인이 사용자 요청에 직접 트레이스 가능해야 한다.
- "왜 이 줄을 바꿨는가?" 질문에 사용자 요청 키워드로 답변 가능해야 한다.

연관 원칙:
- 정보 정직성 원칙 ("추측 금지")
- 도구 호출 절제 원칙 ("불필요한 도구 호출 금지")
- 재발방지 정책 ("LLM 의지 의존 금지")

---

## 도구 호출 절제 원칙

```yaml
단순_질문_직접_응답:
  - 단순 질문/의견/판단 요청에는 도구 호출 없이 바로 텍스트로 답하라
  - sequential-thinking, vibe-check 등 분석 도구를 불필요하게 호출하면 스트리밍이 멈추고 응답 지연 발생
  - 도구 호출이 필요한 경우: 파일 읽기/수정, 코드 검색, DB 쿼리 등 실제 데이터가 필요할 때만
```

---

## 응답 말미 시각 표시 규칙 (절대 규칙)

메인 에이전트는 응답을 마치고 사용자에게 턴을 넘기는 모든 시점에 현재 시각을 응답 말미에 표기한다.
AskUserQuestion 호출 직전이나 "확인 부탁드립니다" 같은 텍스트 질문 후 대기하는 경우뿐 아니라,
질문 없이 작업을 마치고 응답을 종료하는 모든 경우에도 동일하게 적용한다.
목적은 사용자가 자리를 비웠다가 돌아왔을 때 직전 응답이 언제 끝났는지, 즉 얼마나 멈춰 있었는지를
즉시 파악하는 것이다.

표시 형식은 `date '+%Y-%m-%d %H:%M:%S %Z'` 결과를 그대로 사용하며, 표시 위치는 응답 말미로 한다
(예: "🕐 2026-08-21 09:34:03 KST"). 요일은 로케일 의존성 문제로 기본 형식에서 제외한다.

시각 계산·추정은 절대 금지한다. 표기 직전에 매번 `mcp__oio__bash_exec` 로
`date '+%Y-%m-%d %H:%M:%S %Z'` 를 실행하고 그 출력을 그대로 찍는다.
세션 앞에서 한 번 확인한 시각에 경과 시간을 더해 적는 방식은 금지다. 에이전트는 실제 경과 시간을
알 수 없으므로 오차가 양방향으로 누적된다 (실측: 한 세션이 +14분 미래로, 같은 세션이 이후 -3시간 51분
과거로 표기. 사용자가 자리를 비운 공백이 통째로 누락되기 때문이다).

검증 기준은 초 단위 유무다. `00:31 KST` 처럼 초가 없으면 date 출력을 그대로 붙인 것이 아니라
계산한 것이므로 위반이다. `09:32:18 KST` 처럼 초까지 포함되어야 실측으로 인정한다.

물리 강제 불가 사유는 다음과 같다. PreToolUse hook 은 AskUserQuestion 을 matcher 로 지정해도
stdout 이 사용자 화면에 노출되지 않으며, Anthropic 공식 GitHub Issue #15872 가
"Add hook support for AskUserQuestion tool" 을 not planned 로 종료했다. 또한 Issue #12031 은
PreToolUse hook 활성화 상태에서 AskUserQuestion 사용 시 답변 데이터 유실 버그를 보고했다.
Stop hook 역시 대안이 될 수 없다 — 응답 종료 시점에 발동하지만 stdout 이 화면에 노출되지 않고
systemMessage 같은 사용자 표시 필드도 존재하지 않는다 (공식 문서 확인 완료).
따라서 이 규칙은 메인 에이전트의 자율 준수에 의존하는 규칙으로만 강제한다.

---

## ointaug 필수 호출 규칙

`UserPromptSubmit.sh` 가 IDLE 상태에서 매 입력마다 `📌 [ointaug 필수]` 메시지를 출력하여 강제한다.
출력 시 반드시 `Skill('ointaug')` 를 **첫 번째 행동**으로 호출하라.

슬래시 명령 호출 순서 (ointaug 이후):
- 일반 명령: `ointaug` → 직접 답변
- 파이프라인: `ointaug` → `Skill('ok')`
- 복합 스킬: `ointaug` → `Skill('oralph')` → [내부: `ok` → 내장 검증 루프]

### ointaug 자율실행 정책

IDLE 상태 비슬래시 요청에서 ointaug 가 다음 조건을 **모두** 충족한다고 판정하면,
AskUserQuestion 없이 즉시 파이프라인에 진입한다.

```yaml
자율실행_조건 (C1·C2·C3 모두 충족 시 즉시 진입):
  C1. 권장 분기 단일 명확: ok 파이프라인 + tier 명확, 또는 단일 위임 스킬 명확
  C2. 의도 명확: 슬래시명령 오타·해석 충돌 없음. 사용자 문장에서 행위 동사 명확히 식별됨
  C3. 비파괴적 + 추가 정보 불필요

자율실행_차단 (X1~X4 중 1개라도 해당 → 1회 확인 후 대기):
  X1. 의도 모호 / 슬래시명령 오인 가능성
  X2. tier 경계 불명확 (o3 vs o4 판단 어려움)
  X3. 사용자 명시 종료·중단 의사
  X4. 파괴적 가능성 (DB 마이그레이션, 대규모 리팩토링, 배포 등)

자율실행_진입_통지 (절대 규칙 — 생략 금지):
  - 파이프라인 진입 직전 반드시 출력: "🤖 [자율진입] {슬래시 명령} — {1줄 근거} — 중단: Ctrl+C"
  - 통지 없는 묵시적 자율진입 절대 금지

판정_원칙: 1%라도 의심이 있으면 자율실행 차단 — fail-safe 우선
```

---

## ogrill 호출 정책 (절대 규칙)

ogrill 스킬의 호출 권한은 oplan 팀에이전트에만 있다. 메인 에이전트의 자율 판단에 의한
ogrill 호출/권장 출력은 모두 금지된다.

```yaml
허용:
  - oplan 팀에이전트(oplan/oplan_normal/oplan_deep/oplan_simple/oplan_consult/oplan_debate)가
    Phase A 진입 전 5축 결손 판정 후 Skill('ogrill') 호출
  - 사용자 명시 /ogrill 슬래시 직접 호출 시 메인이 Skill('ogrill') 호출 (예외 허용)

금지 (메인 에이전트):
  - 자율 판단에 의한 Skill('ogrill') 호출 (PreToolUse_Skill_ogrill_main_guard.sh가 물리 차단)
  - ogrill 권장 출력
  - 5축 결손 판정 (oplan에 위임)

물리_차단:
  - hooks/PreToolUse_Skill_ogrill_main_guard.sh: 메인 에이전트의 Skill('ogrill') 호출 시
    PIPELINE_UUID 부재 + ogrill_slash_flag 마커 부재 → block
  - 사용자 /ogrill 슬래시 호출 시 UserPromptSubmit.sh가 ogrill_slash_flag 마커 생성
    → hook 통과 + 마커 삭제

배경:
  - 메인의 ogrill 자율 판단은 작업 흐름 중단 위험. oplan의 5축 결손 판정이 더 정확.
  - 사용자 명시 호출은 의도가 명확하므로 예외 허용.
```

---

## 스킬 회피 안티패턴 (절대 금지)

아래 사고방식은 스킬 적용을 회피하는 합리화 패턴이다. 감지 즉시 중단하고 스킬을 먼저 확인하라.

- "단순한 질문일 뿐이라 스킬이 필요 없다"
- "먼저 맥락/코드를 파악한 후 스킬을 결정하겠다"
- "이 작업엔 스킬이 과도하다"
- "지금 진행 중인 작업이 있어서 스킬 확인을 나중에 하겠다"
- "이미 방법을 알고 있으니 스킬 없이 진행하겠다"
- "단순 질문/계산이라 파이프라인이 불필요하다"
- "코드 수정이 아니므로 파이프라인 대상이 아니다"

**원칙**: 1%라도 스킬 적용 가능성이 있으면 먼저 스킬을 확인하라. 스킬이 작업에 해당하면 반드시
사용해야 하며 예외는 없다. (우선순위: 사용자 명시 지시 > 스킬 > 기본 동작)

---

## 재발방지 정책 (절대 규칙)

"재발방지하라" 명령 또는 교훈(odone_lesson) 단계에서 재발방지 조치 시 다음을 지킨다.

```yaml
수단_우선순위 (위가 최우선):
  1. Hook: write_guard.sh 등 물리 차단 (위반 시도 자체를 불가능하게)
  2. oio 서버: MCP 서버 코드 수정 (파라미터 별칭, 자동 변환 등)
  3. Skill: 스킬 프로세스에 체크 단계 추가
  4. 규칙 문서: 규칙/매핑표 업데이트 (최후 수단)

절대_금지:
  - Memory 업데이트로 재발방지 대신하기 (Memory는 참고 정보일 뿐, 강제력 없음)
  - "문서화했으니 됐다"는 사고방식 (문서는 LLM이 무시할 수 있음)

원칙: 재발방지 = 물리적 강제. LLM 의지에 의존하는 조치는 재발방지가 아님.

완벽 검증: 재발방지 조치 후 반드시 "재발방지 완벽 검증 절차" 실행 — 물리 차단 점수 ≥ 8/10 +
우회 경로 5건 전수 차단 + Hook 1순위 미적용 사유 명시. 미달 시 추가 조치 강제.
(odone_lesson/SKILL.md 참조)
```

---

## 파이프라인 플래그 3축

파이프라인은 다음 3개 직교 축으로 표현된다.

```yaml
축_1_level (7개 — 작업 규모/카테고리):
  값: OK / O0 / O1 / O2 / O3 / O4 / O5
  파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification (대문자 저장)
  의미:
    - OK: tier 미정 (ok 진입 직후 ~ 분류 결정 전 단계 신호)
    - O0: 파이프라인 바이패스
    - O1~O5: 분류 결과 (코드 수정 규모)

축_2_stage (8개 — 시간순 진행 상태):
  값: IDLE / PLAN / DEV / TEST / DONE / FINISH / EARLY_TERM / ERROR
  파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state
  역할: 파이프라인 진행 단계 (단일 값, 순차 전이)
  주의: 별도 OK stage 없음 — ok 진입 = state="PLAN" + classification="OK" 동시 기록

축_3_status (set, 4 토큰 — 메타 플래그):
  값: NONE / RALPH / PAUSE / ABORT
  파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status
  포맷: 단일 라인 파이프 OR 조합 + 알파벳 정렬 (예: "PAUSE|RALPH")
  빈 파일/부재: NONE
  역할:
    - RALPH: oralph 루프 활성 (ofinish IDLE 전환 보류)
    - PAUSE: 일시정지 (oi 우회 허용)
    - ABORT: 긴급중단 (autoloop 차단)
  헬퍼: state_machine.sh의 status_read/write/add/remove/clear/has

sentinel (status 축 제외 — read 함수 반환값 전용):
  - UNKNOWN: state_read/status_read 실패 시
  - __LOCK_FAIL__: flock 타임아웃 시
  주의: status 축에 등재 금지 (status_add 시 거부됨)

보조_축_entry_tier (ok 진입 흔적 추적):
  파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/entry_tier
  값: "OK" 또는 부재(NONE)
  의미:
    - OK: /ok, /oralph, /okconsult, /okdebate, /okdeep, /odeep, /oconsult, /odebate,
          /oplan, /onormal, /osimple 경유 흔적
    - 부재: /o1~/o5 직접 진입 (entry_tier 미기록), 또는 IDLE 유지 스킬 (/ohaiku, /ointaug 등)
  기록: ok/SKILL.md pipeline_state_설정 + odeep/oconsult/odebate/oplan/onormal/osimple 진입부
  정리: ofinish pre_cleanup_3b에서 classification과 함께 삭제
  폴백: 파일 부재 시 NONE
  주의: classification 축과 독립 (entry_tier는 불변, classification은 oplan이 tier 결정 시 갱신)

tier_표시_매트릭스 (statusline — entry_tier × classification 5케이스):
  케이스_1: entry_tier=OK + classification=OK   → display_tier="ok"   (ok:ok 금지)
  케이스_2: entry_tier=OK + classification=O{N} → display_tier="ok:o{N}" (예: "ok:o3")
  케이스_3: entry_tier=부재 + classification=O{N} → display_tier="o{N}"  (o1~o5 직접 진입)
  케이스_4: entry_tier=OK + classification=부재 → display_tier="ok"   (인스턴스 플랜 케이스)
  케이스_5: entry_tier=부재 + classification=부재 → display_tier="?"   (폴백)
  모순: entry_tier=부재 + classification=OK → display_tier="ok" (graceful 폴백)

statusline 표기 형식:
  status 부재/NONE: "{이모지} {display_tier} {stage}" (예: "🏃 o3 dev", "🏃 ok:o3 dev")
  ok 진입 시 (entry_tier=OK + classification=OK + PLAN): "🚶‍♀️ ok plan"
  ok 확정 후 (entry_tier=OK + classification=O3 + DEV): "🏃 ok:o3 dev"
  o3 직접 (entry_tier=부재 + classification=O3 + DEV): "🏃 o3 dev"
  status 단일: "{이모지} {display_tier} {stage} {status}" (예: "🧎 ok:o3 finish abort")
  status 다중: "{이모지} {display_tier} {stage} {tokens|}" (예: "🏃 ok:o3 dev pause|ralph")
  state=IDLE 단독: "🧍 idle" (메인만, 팀에이전트는 빈 문자열)
  팀에이전트 idle: 빈 문자열 (PIPELINE_UUID 보유 시 표시 숨김)
  공백 구분, lowercase, 다중 status는 파이프 OR, 이모지+공백
  시각_표시: 파이프라인 파트 직후에 "🕐 HH:MM:SS" 추가 (예: "🏃 o3 dev | 🕐 14:32:07").
  주의: settings.json statusLine.refreshInterval=5(초)로 설정되어 있어 idle 구간에도 5초 주기로
        자동 갱신된다. 이 값이 미설정 상태라면 idle 구간에 최신 시각으로 자동 갱신되지 않고
        마지막 이벤트 발생 시각에 고정된다 (공식 문서 확인 완료).
```

---

## 세션 격리 불변식 (절대 규칙)

여러 Claude Code 세션이 동시 실행되는 환경에서, hook / 스킬 / 팀에이전트가 타 세션을 파괴하는
cross-session 뮤테이션은 **재발방지 대상 1순위** 버그다.

```yaml
세션_격리_불변식:
  (a) 쓰기_경계:
      - hook/스킬/팀에이전트는 "자기 UUID에 해당하는 session-env/${UUID}/" 하위에만 쓰기 허용
      - 타 세션의 session-env/*/ 파일 쓰기는 **절대 금지**
      - 타 세션 파일의 **읽기**(state/team_name/heartbeat/config.json)는 소유권 증명 목적에 한해 허용

  (b) teams/tasks_소유권_증명:
      - teams/<name>/ 또는 tasks/<name>/에 대한 뮤테이션(rm/write)은 아래 2조건 교집합일 때만 합법:
        1) teams/<name>/config.json의 leadSessionId == 현재 UUID
        2) session-env/${UUID}/team_name 의 내용 == <name>
      - 두 조건이 불일치하면 "소유 불확실" → fail-closed (건드리지 말 것)
      - 고아(orphan) 정리는 lazy cleanup: 누군가 같은 이름으로 TeamCreate 시도 시
        team_create_guard.sh가 소유자 부재를 증명한 후에만 정리

  (c) 정보_노출_금지:
      - 다른 세션의 UUID/team_name/state/파이프라인 진행 상황을 현재 에이전트에게 stdout으로 노출 금지
      - "🔗 [활성 파이프라인] ..." 같은 cross-session 정보 출력 블록은 모든 hook에서 제거
      - 이유: 에이전트가 타 세션 정보를 자기 것으로 오인 → 타 세션 팀 디렉토리를 파괴하는 사고 발생

  (d) stale_회수_모델:
      - 각 세션의 SessionStart.sh는 "자기 세션만" boot-stale / heartbeat-stale 회수
      - 타 세션 회수를 담당하던 정리 루프 / stale sweep은 제거됨
      - 하드 크래시한 세션의 teams/<name>/은 다음 TeamCreate 시 lazy orphan cleanup이 정리
        (즉시성 포기 > 안전성 확보)

허용_예시:
  ✅ state_write "${SESSION_DIR}/state" "IDLE ${UUID}"          # 자기 세션 쓰기
  ✅ cat "${OTHER_DIR}/team_name"                                # 타 세션 읽기 (소유권 증명 목적)
  ✅ rm -rf "teams/${MY_TEAM}" (단, leadSessionId == $UUID 확인 후)

금지_예시:
  ❌ state_write "${OTHER_DIR}/state" "IDLE ..."                 # 타 세션 쓰기
  ❌ rm -rf "teams/${OTHER_TEAM}"                                # 타 세션 소유 팀 삭제
  ❌ echo "다른 세션 ${OTHER_UUID} 에서 ${OTHER_TEAM} 진행 중"   # cross-session 정보 노출

재발방지_강제화:
  - 물리 차단 (hooks): write_guard.sh가 session-env/${OTHER}/ 직접 쓰기 시도 차단
  - 서버 차단 (oio MCP): file_write / dir_delete에 UUID 일치 검증 추가 (향후 과제)
  - 문서 (본 섹션): LLM 참고 — 물리 차단을 지나친 경우의 마지막 안전망
```

### in-process 캐시 한계 (중요 경고)

`_reset_idle` 또는 lazy orphan cleanup 이 `teams/<name>/` 디렉토리를 `rm -rf` 로 원자 정리하더라도,
**같은 Claude Code 프로세스 생명주기 안에서는** 메모리 캐시에 팀 존재가 남아 `TeamCreate` 가
"already exists" 오류를 반환할 수 있다. 이 경우 명시적으로 `TeamDelete(team_name=...)` 을 1회 호출한 뒤
`TeamCreate` 를 재시도하라. 파일시스템 정리와 Claude 내부 레지스트리 정리는 프로세스 경계를
기준으로만 일치한다.

### 사이드이펙트 0 예방 정책

발생 자체를 줄이는 5단계 정책이다. 모두 자기 세션 영역만 다루며 타 세션/외부 시스템 무영향이다.

```yaml
정책_1_graceful_first_강제 (oinit Step 6):
  - TeamDelete 1차가 성공하면 rm-rf 우회 절대 금지 (in-process/FS 비동기화의 주된 원인)
  - rm-rf 우회는 "1차 명시적 실패" 후에만 합법
  - 우회 후 반드시 TeamDelete 2차로 in-process 레지스트리 해제 시도

정책_2_TeamCreate_사전_precheck (ok_pipeline):
  - TeamCreate 호출 전 자기 세션의 team_name + teams/<X>/leadSessionId 정합성 검사
  - 옛 leading 잔존 감지 시 graceful TeamDelete 1회 자동 시도
  - 실패 시 사용자에게 /oinit 권장 후 중단

정책_3_SessionStart_self_stale_정리 (SessionStart.sh):
  - 자기 UUID의 state 파일이 부팅 이전이면 IDLE stale 마킹 + 메타 파일 정리
  - 정리 대상: team_name, classification, entry_tier, status, pipeline_uuid, route_decision,
    oralph_active.json, rollback_hash
  - §(a) 자기 세션 격리 준수 — 타 세션 무영향

정책_4_graceful_shutdown_선행 (oinit Step 6):
  - TeamDelete 호출 직전 agents/ 활성 멤버에게 SendMessage shutdown_request 송신
  - shutdown_grace_period: sleep 20 (최소 20초) — 멤버가 idle 진입할 시간 보장
  - 활성 멤버 정상 종료 → TeamDelete가 active member error로 실패할 확률 감소

정책_5_in-process_잔존_감지_및_fail-loud:
  - 배경: sleep 20 + TeamDelete 3차 후에도 in-process 캐시 잔존 시 다음 파이프라인 silent fail 방지
  - 조치_A (oinit Step 6): TeamDelete 3차 최종 실패 시 evidence/inprocess_stuck 마커 생성
    마커 내용: team_name|ISO timestamp
  - 조치_B (ok_pipeline precheck CASE 0): 파이프라인 진입 직전 마커 감지 → 즉시 차단 + /oinit 권고
  - 마커_정리: oinit 독립 실행(/oinit) 시 자동 삭제 (세션 재기동 시에도 소멸)
```

---

## ofinish autoloop 강제 정책

작업 마무리 시점에 메인이 "follow-up 이 명확하다"고 판단하면 `next_action.json` 을 작성한다.
ofinish Step 3.5 가 이 파일을 감지하면 사용자 입력 대기 없이 즉시 다음 슬래시 명령으로
사이클을 자동 진행한다.

```yaml
메인_작성_책임:
  시점: ofinish 호출 직전 (Step 7~8 마무리 중)
  조건 (3가지 모두 충족 시):
    1. 다음 작업의 슬래시 명령이 명확 (예: /o3, /o2, /ok 등)
    2. 작업 설명이 1줄 이상 구체적
    3. 자동 진행해도 안전 (사용자 의도와 충돌 없음, 비파괴적, 추가 정보 불필요)
  파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/next_action.json
  스키마: { slash_command, task_description, reason, created_at }

  예시 (작성해야 함):
    - Batch 1/2 완료 후 plan에 명시된 Batch 3가 남았는데 phase_batches.json은 없음
    - 직전 작업이 부분 수정만 다뤘고 명백히 누락된 동등 파일이 1개 있는 경우
  예시 (작성하면 안 됨):
    - 사용자에게 추가 정보를 받아야 결정 가능한 경우
    - 결과가 클 위험 (DB 마이그레이션, 배포, 대규모 리팩토링 등)
    - 사용자가 명시적 종료 의사를 표명한 경우

ofinish_자동_감지:
  - Step 3.5에서 next_action.json 존재 확인
  - max 3회 재귀(ofinish_recurse_count)
  - status=ABORT|PAUSE 시 즉시 중단
  - 동일 작업 2회 연속 감지 시 무한 루프 방지
  - 처리 후 logs/consumed_autoloop_*.json으로 이동(재실행 방지)

메인_강제_진행_규칙:
  - ofinish 종료 직후 "🔁 ofinish autoloop 발동" 출력을 본 메인은
    사용자 입력 대기 없이 즉시 출력에 명시된 슬래시 명령으로 다음 사이클 진입.
  - 권장 텍스트만 출력하고 멈추는 행위 절대 금지.
  - 중단 조건: status=ABORT|PAUSE / 사용자 /oinit 명시 호출 / max 3회 재귀 초과 / 무효 슬래시 명령.

기존_정책과의_관계:
  - "Multi-Phase 자동 완수 (Auto-Loop)": oplan이 생성한 phase_batches.json 기반 자동 진행
  - "ofinish autoloop" (본 정책): phase_batches.json 없는 단발성 follow-up 자동 진행
  - 두 정책은 상호 보완 — phase_batches.json이 있으면 Step 3, 없으면 Step 3.5
```

---

## oi 파이프라인 라우팅

`UserPromptSubmit.sh` 가 상태별로 자동 분기하여 필요한 메시지를 출력한다.
- `💬 [IDLE 직접처리]` → 메인이 바로 답변
- `💬 [oi] 활성(PLAN|DEV)` → `Skill('oi')` 호출 필수 (state 변경 없음)
- `📋 [큐잉]` / `📋 [OK]` → 현재 작업 계속, 큐잉된 입력은 종료 후 처리
- 슬래시 명령(/ok, /o1~o5) → oi 바이패스

`oi_route_guard.sh` 가 PLAN/DEV 상태에서 `Skill('oi')` 미경유 직접 호출을 `block` 응답으로 차단한다.

---

## o시리즈 파이프라인 프로세스 (절대 규칙)

사용자가 o시리즈 스킬(/ok, /o1, /o2, /o3, /o4, /o5, /oplan, /oplan_debate, /odev, /otest, /odone,
/oresume 등)을 **명시적으로 요구**하면 다음을 지킨다.
- 해당 스킬의 프로세스를 **예외 없이 100% 따라야** 한다.
- "요구사항이 명확하니 스킬 프로세스 생략" 금지.
- "이미 답을 알고 있으니 바로 구현" 금지.
- 스킬이 토론(oplan_debate)을 요구하면 반드시 토론 수행.
- 스킬이 팀에이전트 spawn 을 요구하면 반드시 spawn.

**위반 시**: 사용자 신뢰 손상. 스킬 프로세스는 품질 보증 절차이며 생략 불가다.

### 코드 수정 작업 분류

/o1~/o5 직접 호출 (tier 확정 — oplan tier 결정 bypass):
- `/o1`: oplan 없음 → odev → ofinish(Step 1.5 경량 교훈 + Step 7.5 경량 커밋)
- `/o2`: oplan_simple → odev → obr → ofinish(Step 1.5 + Step 7.5)
- `/o3`: oplan_normal(forced_tier=o3, 계획만) → odev → otest → odone → ofinish
- `/o4`: oplan(forced_tier=o4, 자율선택: oplan_deep/oplan_consult/oplan_debate, 계획만)
  → odev → otest → odone → ofinish
- `/o5`: oplan(forced_tier=o5, 자율선택: oplan_debate 기본/oplan_consult 대안, 계획만)
  → odev → otest → odone → ofinish
- 원칙: /o1~/o5 직접 호출 시 tier 는 사용자가 확정. oplan 은 계획 수립만 수행하고
  tier 재결정/승격 금지.

/ok 호출 (tier 미확정 — oplan이 tier 결정):
- `/ok`: ok 의도분석(텍스트) 초벌 판정 → oplan 에 hint_tier 전달 → oplan 탐색 후 o2~o5 확정
- oplan 이 결정한 tier 에 따라 해당 파이프라인 실행

`/oresume`: 중단된 파이프라인 재개 (checkpoint.jsonl 기반). compact 후 자동 권고됨.

Multi-Phase 자동 완수 (Auto-Loop):
- oplan 이 다단계(Phase Batch) 계획을 세운 경우, 모든 batch 를 끝까지 자동 실행한다
  (ok_pipeline Auto-Loop).
- "남은 Phase 는 후속 /ko 로" 출력 후 멈추는 행위 절대 금지.
- 상세는 `ok_pipeline/SKILL.md` "4.5단계: Phase Batch Auto-Loop" 참조.

---

## MCP 서버

### 하네스 필수 (1개)

| 서버 | 용도 | 비고 |
|------|------|------|
| **oio** | 파일 I/O + 셸 명령 | 하네스 동작 필수. 플러그인이 함께 설치 |

### 선택 (수신자가 자기 `.mcp.json` 에 직접 추가)

| 서버 | 용도 | 이 서버를 요구하는 스킬 |
|------|------|------|
| context7 | 라이브러리 문서 조회 | domain-context7 |
| mysql | DB 작업 | domain-database, otest_make |
| codex | 이종 AI 협업 | oplan_consult, oplan_debate |

선택 MCP 를 설치하지 않으면 해당 스킬만 동작하지 않고 나머지 파이프라인은 정상 동작한다.

### MCP 공통 지침

- DB 작업은 `mcp__mysql__*` 도구를 우선 사용하며, 한글이 포함된 쿼리를 실행할 때는 세션마다
  `SET NAMES utf8` 을 먼저 호출한다.
- MCP 호출은 각 도구를 직접 호출한다.

### MCP 끊김 대응

- **감지**: PostToolUse hook(`mcp_disconnect_guard.sh`)이 oio 도구 실패 시 연결 끊김 패턴을 자동 감지한다.
- **재연결**: `/mcp` 명령으로 MCP 서버 상태 확인 + 재연결.
- **임시 대안**: oio 끊김 시 Claude 내장 Bash/Read/Edit 로 임시 전환
  (`oio_fallback_guard.sh` 가 1회 허용).

### 코드 수정 도구 선택

| 상황 | 도구 |
|------|------|
| 코드 수정/추가/리팩토링 | oio file_edit / file_write |
| oio 불가 시 | Claude Code Edit (Fallback) |
