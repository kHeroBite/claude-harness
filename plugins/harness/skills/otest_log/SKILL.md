---
name: otest_log
description: "로그 분석 서브스킬 — 빌드 출력, 런타임 로그, stderr 분석. 에러/경고 패턴 감지, 스택 트레이스 파싱. otest Phase 2에서 호출. Auto-activates when: otest Phase 2 log analysis needed."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [otest_infra, otest(Phase 2)]
  calls: []
---
# otest_log — 로그 분석

> **호출 시점**: otest Phase 2에서 Skill('otest_log') 호출
> **목적**: 빌드 출력, 런타임 로그, stderr를 분석하여 에러/경고 패턴 감지

## 진입 UUID 결정 (필수)

```yaml
UUID_결정:
  UUID=$PIPELINE_UUID
  mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/{logs,evidence}')

팀에이전트_UUID_규칙: PIPELINE_UUID 환경변수 값을 그대로 사용. resolve_uuid() 호출 금지.
```

## 분석 대상

```yaml
로그_소스:
  빌드_출력: $HOME/.claude/session-env/${UUID}/logs/build_output.log
  런타임_로그: $HOME/.claude/session-env/${UUID}/logs/runtime.log
  stderr: $HOME/.claude/session-env/${UUID}/logs/stderr.log
  프로젝트_로그: oinfra_{project}에서 지정된 로그 경로 (있는 경우)

폴백:
  파일_없음: 해당 소스 스킵 (에러 아님)
  전체_없음: "분석 대상 로그 없음" 보고 → 빈 결과 반환
```

## 분석 절차

```yaml
1_에러_패턴_감지:
  패턴:
    - "error|Error|ERROR" (대소문자 구분 없이)
    - "exception|Exception|EXCEPTION"
    - "fatal|Fatal|FATAL"
    - "fail|Fail|FAIL" (빌드 실패 포함)
  출력: 매칭 라인 + 전후 3줄 컨텍스트

2_경고_패턴_감지:
  패턴:
    - "warn|Warn|WARNING"
    - "deprecated|Deprecated"
    - "obsolete|Obsolete"
  출력: 매칭 라인 (컨텍스트 1줄)

3_스택_트레이스_파싱:
  감지:
    - "at " + 네임스페이스 패턴 (C#: "at Namespace.Class.Method")
    - "Traceback" (Python)
    - "Stack Trace:" 또는 "StackTrace:"
  파싱:
    - 최상위 프레임 (root cause) 추출
    - 프로젝트 코드 프레임 vs 프레임워크 프레임 분리
    - 예외 타입 + 메시지 추출

4_빌드_출력_분석:
  감지:
    - "Build succeeded" / "Build FAILED"
    - "warning CS" / "error CS" (C# 컴파일러)
    - "warning NU" / "error NU" (NuGet)
  집계:
    - 에러 수 / 경고 수
    - 프로젝트별 빌드 결과

5_패턴_집계:
  - 에러 유형별 빈도
  - 반복 발생 에러 (동일 메시지 2회+)
  - 시간 순서 정렬 (타임스탬프 있는 경우)
```

## 출력 형식

```yaml
결과_파일: $HOME/.claude/session-env/${UUID}/evidence/log_analysis.json
형식:
  {
    "timestamp": "ISO-8601",
    "sources_analyzed": ["build_output.log", "runtime.log"],
    "summary": {
      "error_count": 0,
      "warning_count": 0,
      "stack_traces": 0,
      "build_result": "success|failure|unknown"
    },
    "errors": [
      {
        "source": "runtime.log",
        "line": 42,
        "level": "ERROR",
        "message": "에러 메시지",
        "context": "전후 3줄",
        "stack_trace": "파싱된 스택 (있는 경우)"
      }
    ],
    "warnings": [...],
    "patterns": {
      "repeated_errors": [...],
      "build_warnings": [...]
    }
  }

증거_파일: $HOME/.claude/session-env/${UUID}/evidence/log_analysis_ok
내용: "log_analysis $(date -Iseconds) errors={N} warnings={M}"
```

## 판정 기준

```yaml
PASS:
  - error_count == 0
  - build_result == "success" 또는 "unknown" (빌드 로그 없음)

WARN:
  - error_count == 0 AND warning_count > 0
  - 경고만 존재 — Phase 4 비교에서 판정

FAIL:
  - error_count > 0
  - build_result == "failure"
  - 미해결 스택 트레이스 존재
```

## otest 복귀 보고

```yaml
보고_형식:
  PASS: "✅ 로그 분석 정상 — 에러 0건, 경고 {N}건"
  WARN: "⚠️ 로그 분석 경고 — 에러 0건, 경고 {N}건 (상세: log_analysis.json)"
  FAIL: "❌ 로그 분석 실패 — 에러 {N}건 (상세: log_analysis.json)"
```
