---
name: oio
description: "oio MCP 명령 라우팅 설정. '/oio <명령>' 호출 시 ① 기존 oio 도구 매핑 → ② 100% 대용 가능하면 oio 신규 도구 생성 → ③ 둘 다 불가하면 bash_exec 래핑. 3단계 우선순위."
---

# oio — 명령 라우팅 설정

`/oio <명령>` 호출 시 해당 명령을 oio MCP 경유 필수로 전환한다.
**핵심**: 내재화 가능한 명령은 oio 전용 도구로 매핑, 불가한 명령만 bash_exec로 래핑.

## 내재화 매핑 테이블

```yaml
내재화_가능 (oio 전용 도구로 직접 매핑):
  | Bash 명령 | oio 전용 도구 | 비고 |
  |-----------|--------------|------|
  | cat/head/tail | mcp__oio__file_read | offset/limit, start_line/end_line 지원 |
  | cp | mcp__oio__file_copy | 파일 복사 |
  | mv (파일) | mcp__oio__file_move | 파일 이동 |
  | mv (디렉토리) | mcp__oio__dir_move | 디렉토리 이동 |
  | rm (파일) | mcp__oio__file_delete | 파일 삭제 |
  | rm -r (디렉토리) | mcp__oio__dir_delete | 디렉토리 삭제 |
  | mkdir | mcp__oio__dir_create | 디렉토리 생성 |
  | rmdir | mcp__oio__dir_delete | 빈 디렉토리 삭제 |
  | touch/echo>/cat> | mcp__oio__file_write | 파일 생성/덮어쓰기 |
  | sed -i | mcp__oio__file_edit | old_string→new_string 부분 수정 |
  | ln -s | mcp__oio__file_symlink | 심볼릭 링크 |
  | ls | mcp__oio__list_dir | 디렉토리 목록 |
  | stat/file | mcp__oio__file_info | 파일 메타정보 |
  | rename | mcp__oio__file_rename / mcp__oio__dir_rename | 이름 변경 |
  | pwd | mcp__oio__get_cwd | 현재 작업 디렉토리 |

신규_도구_생성_불가 + bash_exec_래핑 (복합 CLI — oio 도구로 대용 불가):
  | Bash 명령 | 래핑 도구 | 사유 |
  |-----------|----------|------|
  | git | mcp__oio__bash_exec | 복합 CLI, 내재화 불가 |
  | dotnet | mcp__oio__bash_exec | 빌드 도구 |
  | npm/npx | mcp__oio__bash_exec | 패키지 매니저 |
  | curl/wget | mcp__oio__bash_exec | HTTP 클라이언트 |
  | docker | mcp__oio__bash_exec | 컨테이너 도구 |
  | python3 | mcp__oio__bash_exec | 스크립트 실행 |
  | bash | mcp__oio__bash_exec | 셸 스크립트 실행 |
  | cmd.exe/powershell | mcp__oio__bash_exec | Windows 명령 |
```

## 동작 절차

```yaml
인자: ARGUMENTS에서 명령어 추출 (예: "git", "cp", "mv")

특수_명령:
  list: 현재 라우팅된 명령 목록 출력 (write_guard.sh에서 oio 차단 패턴 grep)
  undo <명령>: 라우팅 해제 (차단 → 화이트리스트 복원)

라우팅_절차:
  1. 내재화_판정 (3단계 우선순위):
     ① oio 기존 도구 매핑:
        - 내재화 매핑 테이블에서 해당 명령 검색
        - 매핑 존재 → 기존 oio 전용 도구로 매핑 (즉시 완료)
     ② oio 신규 도구 생성:
        - 테이블에 없지만 100% 대용 가능한 oio 도구를 만들 수 있는 경우
        - oio MCP 서버에 신규 도구 추가 → 내재화 매핑 테이블 업데이트 → 매핑
        - "100% 대용 가능" 기준: 동일 입력/출력, 부작용 없음, 원자적 실행 가능
     ③ bash_exec 래핑:
        - ①②가 모두 불가한 경우에만 (복합 CLI, 빌드 도구 등)
        - mcp__oio__bash_exec로 래핑
  2. write_guard.sh 수정:
     - _is_whitelisted() 함수에서 해당 명령 제거 (또는 주석 처리)
     - P1-A 섹션에 차단 규칙 추가:
       내재화_가능:
         ```bash
         if echo "$BASH_CMD_P1" | grep -qP '^\s*<명령>\s'; then
           echo '{"decision":"block","reason":"🚨 Bash <명령> 금지! mcp__oio__<전용도구>를 사용하세요."}'
           exit 2
         fi
         ```
       내재화_불가:
         ```bash
         if echo "$BASH_CMD_P1" | grep -qP '^\s*<명령>\s'; then
           echo '{"decision":"block","reason":"🚨 Bash <명령> 금지! mcp__oio__bash_exec(command=\"<명령> ...\")를 사용하세요."}'
           exit 2
         fi
         ```
  3. CLAUDE.md 수정:
     - "Bash 예외" 목록에서 해당 명령 제거
     - oio 대체 매핑표에 행 추가:
       내재화: | <명령> | mcp__oio__<전용도구> |
       래핑: | <명령> | mcp__oio__bash_exec |
  4. 검증:
     - write_guard.sh에서 해당 명령이 화이트리스트에 없는지 확인
     - 차단 규칙이 정상 추가되었는지 확인
  5. 결과 보고:
     기존_도구_매핑: "✅ <명령> → mcp__oio__<전용도구> 매핑 완료."
     신규_도구_생성: "✅ <명령> → mcp__oio__<신규도구> 신규 도구 생성 + 내재화 완료."
     래핑: "✅ <명령> → mcp__oio__bash_exec 래핑 완료."

대상_파일:
  - $HOME/.claude/hooks/write_guard.sh (화이트리스트 + 차단 규칙)
  - <프로젝트 루트>/CLAUDE.md (예외 목록 + 매핑표)
```

## 주의사항

- 라우팅 변경은 **현재 세션에서 즉시 적용** (hook은 매 호출마다 디스크에서 읽음)
- `undo`로 복원 가능 — 차단 규칙 제거 + 화이트리스트 복원
- 빌드 도구(dotnet, npm)는 이미 oio 경유 필수 — 중복 라우팅 시 안내
- 내재화 우선 원칙: 전용 도구가 있으면 반드시 전용 도구 사용 (bash_exec는 최후 수단)
