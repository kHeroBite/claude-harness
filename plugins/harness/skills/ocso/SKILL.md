---
name: ocso
description: "보안 감사. OWASP+STRIDE 기반 C#/.NET 보안 포스처 평가. CI/CD·인프라·Webhook·LLM·스킬 공급망 포함. 수동 전용. Auto-activates when: security audit requested, pre-release security check, compliance review."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
tools: mcp__oio__file_read, mcp__oio__list_dir, mcp__oio__find, mcp__oio__bash_exec
---
# ocso — 보안 감사 (OWASP + STRIDE + 인프라)

> **이 스킬은 읽기 전용이다.** 코드 수정 없음, 발견 사항과 수정 권고만 보고한다.

> 독립 유틸리티 스킬 — ok 파이프라인 외부, 수동 호출 전용

## 목적

C#/.NET/WinForms 프로젝트의 보안 취약점을 체계적으로 감사합니다.
**읽기 전용** — 코드 수정 없음, 발견 사항과 수정 권고만 보고합니다.

## 호출 방법

```yaml
모드:
  /ocso              → 일상 감사 (신뢰도 8/10 이상만 보고)
  /ocso --deep       → 심층 감사 (신뢰도 2/10 이상, TENTATIVE 포함)

포커스 (스코프 축소):
  /ocso --owasp      → OWASP Top 10 집중 (Phase 7만)
  /ocso --secrets    → 시크릿 스캔 집중 (Phase 2만)
  /ocso --infra      → 인프라 집중 (Phase 4~8만)

조합 플래그:
  --diff             → 현재 브랜치 변경분만 스캔 (모든 모드/포커스와 조합 가능)

예시:
  /ocso --deep --diff   → 브랜치 변경분 심층 감사
  /ocso --owasp --diff  → 변경분 OWASP 집중
  /ocso --infra         → CI/CD + 인프라 + Webhook + LLM + 스킬 공급망
```

## Phase 구성 (13 Phase)

### Phase 1: 공격 표면 인구조사 (Attack Surface Census)

코드 표면과 인프라 표면을 정량 매핑합니다.

```yaml
코드_표면:
  - .sln/.csproj 구조 스캔 (프로젝트 계층, 참조 관계)
  - REST API 엔드포인트 매핑 (Controller/[Route]/[HttpGet] 패턴)
  - DB 연결 문자열 위치 파악 (appsettings, Web.config, 하드코딩)
  - 외부 서비스 연동 지점 식별 (HttpClient, WebClient, WCF/gRPC)
  - 파일 업로드 포인트 (IFormFile, MultipartFormData)
  - 백그라운드 작업 (IHostedService, BackgroundService, Hangfire)

인프라_표면:
  - CI/CD 워크플로 파일 탐색 (.github/workflows/*.yml)
  - Dockerfile, docker-compose 설정
  - IaC 파일 (*.tf, *.tfvars, oustomization.yaml)
  - .env 파일 존재 여부

출력_형식:
  공격_표면_지도:
    코드_표면:
      공개_엔드포인트: N (비인증)
      인증_필요: N
      관리자_전용: N
      API_엔드포인트: N
      파일_업로드: N
      외부_연동: N
      백그라운드_작업: N
    인프라_표면:
      CI/CD_워크플로: N
      Webhook_수신자: N
      컨테이너_설정: N
      IaC_설정: N
      시크릿_관리: [환경변수 | KeyVault | 불명]
```

### Phase 2: 시크릿 고고학 (Secrets Archaeology)

git 히스토리 포함 전체 시크릿 유출을 조사합니다.

```yaml
git_히스토리_알려진_접두사:
  - AKIA (AWS Access Key)
  - sk- (Stripe/OpenAI 키)
  - ghp_, gho_, github_pat_ (GitHub PAT)
  - xoxb-, xoxp- (Slack 토큰)
  - password/secret/token/api_key 패턴 (*.env, *.yml, *.json, *.conf)

현재_파일_스캔:
  - appsettings.json / Web.config의 하드코딩된 시크릿
  - .env 파일 git 추적 여부
  - 하드코딩된 암호화 키, 인증서 경로
  - connectionString에 비밀번호 포함 여부

.env_git_추적_확인:
  - git ls-files '*.env' '.env.*' | grep -v '.example|.sample'
  - .gitignore에 .env 포함 여부

CI_인라인_시크릿:
  - workflow 파일에서 ${{ secrets.* }} 미사용 직접 기재 패턴

심각도:
  CRITICAL: 활성 시크릿 패턴 (AKIA, sk_live_, ghp_)
  HIGH: git 추적 .env, CI 인라인 자격증명
  MEDIUM: .env.example에 의심 값

FP_규칙:
  - 플레이스홀더 ("your_", "changeme", "TODO") 제외
  - 테스트 코드 시크릿 제외 (비테스트 코드 동일 값 제외)
  - 로테이션된 시크릿도 플래그 (이미 노출됨)
  - .env.local이 .gitignore에 있으면 정상
  - diff 모드: git log -p --all → git log -p <base>..HEAD
```

### Phase 3: 의존성 감사

```yaml
NuGet_취약점:
  - dotnet list package --vulnerable
  - dotnet list package --outdated
  - packages.config vs PackageReference 일관성

전이_의존성:
  - 전이 의존성(transitive) 취약점 확인

심각도:
  CRITICAL: 직접 의존성 알려진 CVE (CVSS high/critical)
  HIGH: 누락된 lockfile
  MEDIUM: 오래된 패키지, 중간 CVE

FP_규칙:
  - CVSS < 4.0 & 알려진 익스플로잇 없음 → 제외
```

### Phase 4: CI/CD 파이프라인 보안

CI/CD 워크플로의 보안 위협을 분석합니다.

```yaml
GitHub_Actions_분석:
  - 비고정 third-party action (SHA 미고정 @버전 태그)
  - pull_request_target 위험: fork PR이 쓰기 권한 획득
  - 스크립트 인젝션: ${{ github.event.*.body }} run 단계 내 삽입
  - CI 시크릿 env 변수 직접 노출 (마스킹 없음)
  - CODEOWNERS workflow 파일 보호 여부

심각도:
  CRITICAL: pull_request_target + PR 코드 체크아웃 조합, 스크립트 인젝션
  HIGH: 비고정 third-party action, 비마스킹 env 시크릿
  MEDIUM: workflow CODEOWNERS 미설정

FP_규칙:
  - first-party actions/* 미고정 = MEDIUM (HIGH 아님)
  - PR ref 체크아웃 없는 pull_request_target = 안전
  - 비활성/아카이브 workflow = 제외
  - with: 블록 시크릿 (env:/run: 아님) = 런타임 처리됨
```

### Phase 5: 인프라 섀도 표면 (Infrastructure Shadow Surface)

숨겨진 인프라의 과잉 접근 권한을 탐지합니다.

```yaml
Dockerfile_검사:
  - USER 지시어 누락 (root 실행)
  - ARG로 시크릿 전달
  - .env 파일 이미지에 복사
  - 노출 포트 문서화 여부

IaC_검사:
  - Terraform: IAM "*" 와일드카드, 하드코딩 시크릿 (.tf/.tfvars)
  - K8s: 권한 있는 컨테이너, hostNetwork, hostPID

Config_자격증명:
  - DB 연결 문자열 (postgres://, mysql://, mssql://) 설정 파일 내 자격증명 포함
  - 스테이징/dev 설정이 prod DB 참조 여부

심각도:
  CRITICAL: prod DB URL(자격증명 포함) 커밋 config, 시크릿 Docker 이미지 베이크, IAM "*" 민감 리소스
  HIGH: prod root 컨테이너, 스테이징→prod DB 접근, 권한 K8s
  MEDIUM: USER 지시어 누락, 문서 없는 노출 포트

FP_규칙:
  - docker-compose.yml localhost dev = 발견사항 아님
  - Terraform data 소스의 "*" = 제외
  - test/dev/local 네임스페이스 K8s + localhost = 제외
  - Dockerfile.dev / Dockerfile.local = prod 배포 참조 없으면 제외
```

### Phase 6: Webhook 및 통합 감사

인바운드 엔드포인트의 무검증 수신을 탐지합니다.

```yaml
Webhook_라우트:
  - webhook/hook/callback 패턴 파일 검색
  - 서명 검증 부재 탐지 (signature, hmac, verify, x-hub-signature 미포함)

TLS_검증_비활성화:
  - verify.*false, VERIFY_NONE, InsecureSkipVerify
  - ServicePointManager.ServerCertificateValidationCallback 무시

검증_방법:
  - 핸들러 코드 추적으로 미들웨어 체인 서명 검증 확인
  - 코드 추적 전용 — 실제 HTTP 요청 절대 금지

심각도:
  CRITICAL: 서명 검증 없는 webhook
  HIGH: prod 코드 TLS 검증 비활성화

FP_규칙:
  - 테스트 코드 TLS 비활성화 = 제외
  - API 게이트웨이 upstream 처리 webhook = 발견사항 아님 (증거 필요)
  - 사설망 내부 서비스간 webhook = MEDIUM 최대
```

### Phase 7: LLM 및 AI 보안

AI/LLM 관련 취약점을 탐지합니다.

```yaml
탐지_패턴:
  - 프롬프트 인젝션: 시스템 프롬프트 구성 근처 사용자 입력 문자열 보간
  - 비정제 LLM 출력: dangerouslySetInnerHTML, innerHTML, Raw() LLM 응답 렌더링
  - eval(LLM): eval(), exec(), Function() AI 응답 처리
  - AI API 키 코드 직접 포함: sk- 패턴, 하드코딩 API 키 할당

심층_검사:
  - 사용자 콘텐츠 → 시스템 프롬프트 유입 경로 추적
  - RAG 포이즈닝: 외부 문서가 AI 동작에 영향 가능한지
  - 도구 호출 권한: LLM 도구 호출 실행 전 검증 여부
  - 비용/리소스 공격: 무한 LLM 호출 트리거 가능한지

심각도:
  CRITICAL: 시스템 프롬프트 내 사용자 입력, 비정제 LLM 출력 HTML 렌더링, eval(LLM)
  HIGH: 도구 호출 검증 누락, AI API 키 코드 노출
  MEDIUM: 무제한 LLM 호출, RAG 입력 미검증

FP_규칙:
  - AI 대화의 user-message 위치 사용자 콘텐츠 = 인젝션 아님 (시스템 프롬프트만 해당)
```

### Phase 8: 스킬 공급망 (Skill Supply Chain)

설치된 Claude Code 스킬의 악성 패턴을 스캔합니다.

```yaml
로컬_스킬_스캔:
  경로: .claude/skills/ 디렉토리
  악성_패턴:
    - curl/wget/fetch/http (네트워크 유출)
    - ANTHROPIC_API_KEY/OPENAI_API_KEY/process.env/env. (크레덴셜 접근)
    - "IGNORE PREVIOUS"/"system override"/"disregard" (프롬프트 인젝션)

글로벌_스킬_스캔:
  자동_실행: 자동 판단으로 진행 (AskUserQuestion 없이)
  경로: ~/.claude/skills/ + ~/.claude/settings.json hooks

심각도:
  CRITICAL: 크레덴셜 유출 시도, 프롬프트 인젝션
  HIGH: 의심 네트워크 호출, 과도한 도구 권한
  MEDIUM: 미검증 출처 스킬

FP_규칙:
  - 알려진 레포 경로 스킬 = 신뢰 (경로 확인)
  - 정당한 목적 curl = 대상 URL + 자격증명 변수 함께 사용 시만 플래그
  - SKILL.md는 문서가 아닌 실행 코드 — 발견사항 제외 금지
```

### Phase 9: OWASP Top 10 (C# 특화)

```yaml
A01_접근제어:
  - [Authorize] 누락된 Controller/Action
  - [AllowAnonymous] 남용
  - 직접 객체 참조 (ID 기반 조회 시 소유자 검증 누락)

A02_암호화:
  - MD5/SHA1 사용 (약한 해시)
  - 하드코딩된 암호화 키
  - HTTP (비암호화) 통신

A03_인젝션:
  - SQL 문자열 보간: string.Format + SQL, $"SELECT...{변수}"
  - 명령 인젝션: Process.Start(사용자입력)
  - 역직렬화: BinaryFormatter / SoapFormatter (CRITICAL)
  - LDAP 인젝션, XPath 인젝션

A04_설계:
  - 인증 엔드포인트 요율 제한 (Rate Limiting) 부재
  - 중요 작업 재인증 누락

A05_설정:
  - Debug=true 프로덕션 배포
  - 상세 에러 메시지 노출 (스택 트레이스)
  - 기본 자격증명 사용

A07_인증:
  - 세션 관리 (세션 고정, 만료 정책)
  - 토큰 만료/갱신 정책
  - 비밀번호 정책 (최소 길이, 복잡도)

A09_로깅:
  - 인증 실패 로깅 여부
  - 민감 데이터 로깅 여부 (PII, 비밀번호)

A10_SSRF:
  - URL 구성에 사용자 입력 유입 여부
  - 내부 네트워크 접근 가능 여부

C#_고유_검사:
  - dynamic / reflection 남용 → 타입 안전 우회 (MEDIUM)
  - unsafe 코드 블록 → 메모리 안전 우회 (HIGH)
  - string += in loop → DoS 가능성 (LOW)
```

### Phase 10: STRIDE 위협 모델

주요 컴포넌트별 6요소 평가:

| 위협 | 질문 | C# 확인 대상 |
|------|------|-------------|
| **S**poofing | 신원 위장 가능? | 인증 메커니즘, 토큰 검증 |
| **T**ampering | 데이터 변조 가능? | 입력 검증, DB 무결성 |
| **R**epudiation | 행위 부인 가능? | 감사 로그, 로깅 |
| **I**nfo Disclosure | 정보 누출 가능? | 에러 메시지, 로그, 응답 |
| **D**oS | 서비스 거부 가능? | 입력 크기 제한, 리소스 관리 |
| **E**levation | 권한 상승 가능? | 역할 검증, 수직/수평 권한 |

격리축_클라입력_금지 (수평 권한 — Elevation 확장, 2026-09-15 사이클131/132 L-1069):
  원칙: ★클라가 보낸 값으로 격리를 판정하면 격리가 아니다.★
  탐지: 요청/DTO 모델 필드 중 아래에 해당하는 것을 전수 열거
    - 환경·테넌트 구분자 (포트·환경명·서버ID·회사ID·조직ID)
    - 권한·역할·소유자 식별자 (memberId·role·ownerId)
  판정:
    서버가 세션/레지스트리에서 재도출하지 않고 요청 값을 그대로 필터에 사용 → ★HIGH★
  정본: 요청 모델에서 그 필드를 ★제거★하고 서버가 결정한다
        (예: `ServerBundleRegistry.PortOf(세션)`. 요청의 `ServerPort` 를 신뢰하지 않는다)
  파생: 서버 필터가 재적용돼야 하는 데이터는 ★푸시에 본문을 싣지 않는다★.
        되조회를 강제해야 필터(예: "다시보지않기")가 서버에서 다시 걸린다.

### Phase 11: 데이터 분류

민감 데이터 저장 위치 및 보호 수준:

```yaml
분류:
  RESTRICTED: 비밀번호, 암호화 키, 인증 토큰
  CONFIDENTIAL: PII (개인정보), 금융 데이터
  INTERNAL: 내부 설정, 비공개 API 키
  PUBLIC: 공개 설정, 정적 리소스

검사: 각 분류의 저장/전송/폐기 보호 수준 평가
```

### Phase 12: FP 필터링 + 신뢰도 보정 + 검증

```yaml
신뢰도_보정 (Confidence Calibration 1-10):
  | 점수 | 의미 | 표시 규칙 |
  |------|------|----------|
  | 9-10 | 코드 추적 검증된 구체적 익스플로잇 경로 | 정상 표시 |
  | 7-8  | 고신뢰도 패턴 매치 | 정상 표시 |
  | 5-6  | 중간 — FP 가능 | "중간 신뢰도, 직접 확인 권장" 경고 |
  | 3-4  | 낮음 — 의심스럽지만 괜찮을 수 있음 | 메인 보고서 제외, 부록만 |
  | 1-2  | 추측 | P0 심각도일 때만 보고 |

발견사항_형식:
  "[P{심각도}] (신뢰도: N/10) 파일:라인 — 설명"
  예: "[P1] (신뢰도: 9/10) Controllers/AuthController.cs:42 — WHERE 절 없는 SQL 직접 보간"

신뢰도_학습:
  조건: 신뢰도 < 7로 보고했는데 사용자가 실제 이슈 확인 시
  동작: 해당 패턴을 교훈으로 기록 (향후 더 높은 신뢰도로 탐지)

신뢰도_게이트:
  일상_모드: 8/10 이상만 보고 (노이즈 제로)
  심층_모드: 2/10 이상 보고 (TENTATIVE 포함)

C#_FP_자동제외:
  - Designer.cs 파일의 패턴 매치 (자동 생성 코드)
  - test/Tests 프로젝트의 하드코딩 값
  - localhost/127.0.0.1 connectionString
  - .example/.sample 파일의 시크릿 패턴
  - Program.cs/Startup.cs의 개발 환경 설정
  - EF Core 파라미터화 쿼리 (SQL 인젝션 아님)
  - 메모리 안전 언어이므로 버퍼 오버플로 류 자동 제외
  - 비활성/아카이브 workflow CI/CD 발견사항

하드_제외 (자동 폐기):
  - DoS/리소스 소진 (예외: LLM 비용 증폭은 금융 리스크 → 제외 안 함)
  - 암호화/권한 설정된 디스크 시크릿
  - 비보안 필드 입력 검증 (증명된 영향 없음)
  - 누락된 강화 조치 (구체적 취약점만 보고)
    (예외: 비고정 third-party action, CODEOWNERS 미설정은 구체적 위험)
  - 메모리 안전 언어 메모리 안전 이슈
  - 테스트 전용 파일 (비테스트 코드 미임포트)
  - 로그 스푸핑
  - 경로만 제어 가능한 SSRF (호스트/프로토콜 불가)
  - AI 대화 user-message 위치 콘텐츠 (프롬프트 인젝션 아님)
  - 비보안 컨텍스트 비안전 랜덤 (UI ID 등)
  - CVSS < 4.0 & 알려진 익스플로잇 없는 의존성 CVE
  - *.md 문서 파일 보안 우려 (예외: SKILL.md는 실행 코드)

검증_절차:
  - 발견 건별 코드 추적으로 VERIFIED / UNVERIFIED / TENTATIVE 판정
  - UNVERIFIED는 보고서에 표시하되 별도 섹션으로 분리
  - TENTATIVE: 심층 모드 전용, 신뢰도 8 미만
  - 변형 분석: 동일 패턴이 다른 위치에도 존재하는지 확인

능동_검증:
  시크릿: 실제 키 형식 확인 (길이, 접두사) — 라이브 API 테스트 금지
  Webhook: 핸들러 → 미들웨어 체인 서명 검증 추적 — HTTP 요청 금지
  SSRF: URL 구성 → 내부 서비스 도달 경로 추적 — 요청 금지
  CI/CD: workflow YAML 파싱으로 pull_request_target 실제 PR 코드 체크아웃 확인
  의존성: 취약 함수 직접 import/호출 여부 확인 (VERIFIED/UNVERIFIED)
  LLM: 데이터 흐름 추적으로 사용자 입력 → 시스템 프롬프트 도달 확인
```

### Phase 13: 마크다운 보고서

```yaml
보고서_형식: 마크다운 전용 (JSON 불필요)

구조:
  ## 보안 감사 보고서
  ### 요약 (심각도별 카운트)
  | CRITICAL | HIGH | MEDIUM | LOW | TOTAL |

  ### Findings 테이블 (심각도 순)
  | # | 심각도 | 신뢰도 | Phase | 발견 | 파일:라인 | 상태 |

  ### 상세 (각 Finding)
  #### F-{번호}: {제목}
  - 심각도: CRITICAL / HIGH / MEDIUM / LOW
  - 신뢰도: N/10
  - 위치: {파일}:{라인}
  - 공격 시나리오: (필수 — 단계별 공격 경로)
  - 수정 권장사항: (필수 — 구체적 코드 예시)
  - 상태: VERIFIED / UNVERIFIED / TENTATIVE

필수_규칙:
  - 각 finding에 공격 시나리오 + 수정 권장사항 필수
  - 심각도별 정렬 (CRITICAL → HIGH → MEDIUM → LOW)
  - FP 필터 + 신뢰도 게이트 통과 건만 보고
  - 부록: 신뢰도 3-4 발견사항 (심층 모드에서만)
```

## ok 파이프라인 연동

```yaml
연동: 수동 전용 (ok 파이프라인 외부)
이유: 보안 감사를 일상 파이프라인에 끼우면 형식적 변질 위험
odone_review: "보안 감사 권장" 제안 가능 (자동 호출 아님)
```

## 읽기 전용 원칙

```yaml
절대_금지: 코드 수정
허용: 발견 사항 보고 + 수정 권장사항 제시
```
