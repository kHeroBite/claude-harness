---
name: domain-csharp
description: "C# 코드 품질 분석 + 리팩토링 통합. 코드 구조/복잡도/성능/메모리/스레드/보안 분석, 코딩 표준 검증, 안전한 리팩토링 기법. Auto-activates when: code review, quality assurance, refactoring, complexity evaluation, performance optimization, memory leak detection."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev(리팩토링)]
  calls: []
---

# domain-csharp -- C# 코드 품질 + 리팩토링

코드 분석(8가지 영역), 코딩 표준 리뷰 체크리스트, 안전한 리팩토링 기법(10가지)을 통합한 범용 C# 스킬.

## 사용 시점

- 코드 리뷰 (Pull Request) / 새 코드 이해
- 복잡도 높은 코드 단순화 / 중복 제거
- 성능 최적화 대상 식별
- 가독성/유지보수성 향상
- 리팩토링 전 현황 파악

---

## Part 1: 코드 분석 (8가지 영역)

### 1. 코드 구조 분석

- 단일 책임 원칙 (SRP) 준수
- 메서드 길이 (권장: 50줄 이하), 파라미터 개수 (권장: 5개 이하)
- using 문 개수 (과도한 의존성), 순환 참조 여부

### 2. 복잡도 평가

**순환 복잡도**: 권장 10 이하 / 경고 11-20 / 위험 21+
**중첩 깊이**: 권장 3 이하 / 경고 4-5 / 위험 6+

```csharp
// 조기 반환 (Early Return) 패턴
if (!condition1) return;
if (!condition2) return;
foreach (var item in list)
{
    if (!item.IsValid) continue;
    try { /* 처리 */ } catch { }
}
```

### 3. 디자인 패턴 / 안티패턴 감지

- 패턴: 템플릿 메서드, 싱글톤, 팩토리, 옵저버(이벤트)
- 안티패턴: God Object, Magic Number, Copy-Paste 코드

### 4. 성능 병목 지점 식별

```csharp
// N+1 문제: 루프 내부 DB 쿼리 → JOIN/IN 절로 1번 쿼리
// LINQ 중복 열거 → ToList() 한 번만
// UI 스레드 블로킹 → async/await + Task.Run
// 문자열 연결 → StringBuilder
```

### 5. 메모리 누수 가능성

- IDisposable 미구현 → using 블록 필수
- 이벤트 핸들러 미해제 → Dispose에서 -= 해제
- 타이머 미해제 → FormClosing에서 Stop() + Dispose()

### 6. 스레드 안전성 검증

```csharp
// UI 스레드 외부 접근 → InvokeRequired + Invoke
// 공유 리소스 → lock 또는 SemaphoreSlim
```

### 7. 보안 취약점 검증

```csharp
// SQL 인젝션 → 파라미터화 쿼리 (Parameters.AddWithValue)
// 입력 검증 → int.TryParse, null 체크
```

### 8. 코딩 표준 준수

프로젝트별 규칙은 `{project}/PROJECT.md "코딩 규칙" 섹션`에서 로드.

---

## Part 2: 코드 리뷰 체크리스트

### DB 연결 패턴
- [ ] GetOpenConnection 사용 (닫힌 연결 반환 API 금지)
- [ ] using 블록으로 연결 객체 관리
- [ ] Parameters.AddWithValue 사용 (SQL 인젝션 방지)
- [ ] reader.IsDBNull 체크

### Lambda 클로저
- [ ] foreach/for 루프 내부 람다에서 지역 변수로 복사
- [ ] sender 캐스팅 대신 명시적 파라미터 사용

### 로깅
- [ ] 적절한 로그 레벨 (Debug/Info/Warn/Error)
- [ ] 클래스명/메서드명 포함
- [ ] 예외 처리 블록에 Error 로그

### 리팩토링 안전성
- [ ] 클래스명 변경 시 생성자명 동일 변경
- [ ] IDE Rename (F2) 사용 (정규식 대량 치환 금지)
- [ ] Serena rename_symbol 또는 Visual Studio F2

### 리소스 관리
- [ ] IDisposable → using 블록
- [ ] 이벤트 핸들러 Dispose에서 해제
- [ ] 타이머 FormClosing에서 정리

---

## Part 3: 리팩토링 기법 (10가지)

### 1. 메서드 추출 (Extract Method)
복잡도 12/80줄 → 3개 메서드(검증/DB/UI), 각 복잡도 2-3/20줄

### 2. 중복 코드 제거 (DRY)
공통 함수 추출 (제네릭 헬퍼, DatabaseHelper 등)

### 3. 조건문 단순화 (Guard Clauses)
중첩 깊이 5 → Early Return으로 깊이 1

### 4. 복잡도 감소 (Switch -> Dictionary)
```csharp
private static readonly Dictionary<string, Func<Form>> FormFactory = new()
{
    ["키"] = () => new 폼클래스(),
};
```

### 5. 클래스 분할 (SRP)
God Object 500줄 → UI(200줄) + Service(150줄) + UIHelper(100줄)

### 6. N+1 문제 해결
루프 내 쿼리 N번 → JOIN으로 1번 + Dictionary 매핑

### 7. Magic Number 상수화
```csharp
private const int MAX_SCORE = 100;
private const int MONITORING_DURATION_SECONDS = 60;
```

### 8. LINQ 최적화
중복 열거 → ToList() 1번 후 재사용

### 9. 문자열 연결 최적화
루프 내 string += → StringBuilder

### 10. 변수명 개선
d, t, x → memberData, currentTime, maxRetryCount

---

## 리팩토링 전 필수 체크리스트

- [ ] Git 백업 (커밋)
- [ ] 테스트 시나리오 준비 (REST API, 로그, 스크린샷)
- [ ] PROJECT.md/CLAUDE.md 확인

## 리팩토링 후 검증

- [ ] 빌드 테스트 (dotnet build)
- [ ] 로그 분석 (ERROR 0건)
- [ ] REST API 테스트
- [ ] 스크린샷 비교 (Before/After)

---

## 자동 검증 패턴

```bash
# 구조 분석
Grep("^\\s*public class", "*.cs", output_mode="count")
# 복잡도 추정
Grep("\\b(if|else|for|while|switch|case)\\b", "파일명.cs", output_mode="count")
# N+1 문제
Grep("foreach.*\\{[\\s\\S]*ExecuteReader", "*.cs", multiline=true)
# UI 블로킹
Grep("(Thread\\.Sleep|Task\\.Wait)", "*.cs")
# using 없는 리소스
Grep("new MySqlConnection", "*.cs")
# 문자열 연결 쿼리
Grep("\\$\"SELECT.*\\{", "*.cs")
# Lambda 클로저
Grep("foreach.*=>", "*.cs")
# WPF Dispatcher 위험 패턴 (L-369) — async 람다를 Invoke에 전달하면 async void 처리됨
Grep("Dispatcher\\.Invoke\\(async", "*.cs")
```

## 분석 보고서 템플릿

```markdown
# [파일명] 코드 품질 보고서
## 코드 구조: 클래스 N개 / 메서드 N개 / 평균 N줄
## 복잡도: 평균 순환 복잡도 N / 최대 중첩 깊이 N
## 성능: N+1(있음/없음) / UI 블로킹(있음/없음)
## 메모리/스레드: IDisposable(정상/미흡) / 스레드 안전성(정상/미흡)
## 보안: SQL 인젝션(있음/없음) / 입력 검증(정상/미흡)
## 우선순위별 개선: 1.긴급 2.높음 3.중간 4.낮음
```

## .NET 백엔드 패턴

### Result<T> 패턴 (비즈니스 로직 에러)

```csharp
// 예외 대신 Result 반환 (flow control에 예외 사용 금지)
public static Result<T> Success(T value);
public static Result<T> Failure(string error, string? code = null);
// 사용: var result = await CreateOrderAsync(request);
// return result.IsSuccess ? Ok(result.Value) : BadRequest(result.Error);
```

### IOptions 3가지 수명

```yaml
IOptions<T>: 싱글톤, 앱 시작 시 1회 읽기
IOptionsSnapshot<T>: 스코프(요청)당 재읽기
IOptionsMonitor<T>: 싱글톤, 변경 시 OnChange 알림
```

### ValueTask<T> 캐싱 최적화

```yaml
사용_조건: hot path에서 동기 반환 가능 시
이점: Task 할당 없이 동기 반환 (ValueTask.FromResult)
주의: await 2회 금지, 동시 await 금지
```

### 금지 사항

```yaml
❌_블로킹: .Result / .Wait() (데드락 위험)
❌_async_void: 이벤트 핸들러 외 사용 금지
❌_SELECT_*: 필요한 컬럼만 지정
❌_new_HttpClient: IHttpClientFactory 사용
❌_AsNoTracking_누락: 읽기 전용 쿼리에 필수
❌_ConfigureAwait_누락: 라이브러리 코드에서 .ConfigureAwait(false) 사용
❌_ConfigureAwait_위치오류: 멀티라인 체인에서 괄호 위치 잘못 삽입 (L-372)
❌_tuple_삼항_unnamed_추론: `condition ? tv : (0m, 0)` 형태 금지 (L-371)
  이유: 두 분기 공통 타입을 unnamed (decimal, int)로 추론 → LINQ .Sum/.Count 멤버 접근 CS1061
  대안_1: if-else + named tuple 리터럴 사용
    var result = condition ? tv : (Value: 0m, Count: 0);  // named tuple
  대안_2: static local function으로 추출
    static (decimal Value, int Count) GetDefault() => (0m, 0);
  패턴: (await x.GetAsync()).Property.ConfigureAwait(false)  ← 컴파일 에러 또는 의미 없음
  대안: (await x.GetAsync().ConfigureAwait(false)).Property  ← Task에 직접 적용
  주의: 대량 적용 시 `(await [^)]+)\)\.` 패턴을 grep으로 먼저 식별 후 수동 검토 필수
❌_Dispatcher.Invoke(async): async 람다를 Invoke에 전달 금지 (L-369)
  이유: Dispatcher.Invoke는 동기 메서드 — async 람다 전달 시 async void Task 처리됨
       예외 전파 불가 + 호출 스레드 블로킹 발생
  대안: await Dispatcher.InvokeAsync(() => { ... }) 사용
       메서드 시그니처를 async void/async Task로 변경 후 await 적용
```

### WPF/UI 스레드 체크리스트 (코드 리뷰 시 필수)

- [ ] `Dispatcher.Invoke(async ...)` 패턴 없는지 확인 (L-369 금지 패턴)
- [ ] 대량 ConfigureAwait 적용 후 `(await [^)]+)\)\.` 패턴 grep 검토 (L-372 — 괄호 위치 오류)
- [ ] UI 업데이트가 필요한 비동기 메서드에서 `await Dispatcher.InvokeAsync(...)` 사용 여부
- [ ] `CheckAccess()` 분기 후 `InvokeAsync` 호출 패턴 확인
- [ ] tuple 반환 삼항 연산자에서 unnamed tuple 추론 여부 — `.Sum/.Count` 접근 오류 시 L-371 패턴 의심
