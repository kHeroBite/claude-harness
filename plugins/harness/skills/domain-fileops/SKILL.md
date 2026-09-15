---
name: domain-fileops
description: "파일 수정/생성/삭제의 Low-level 드라이버. 환경 감지(NTFS/EXT4), NTFS 안전 절차(cp→Edit→rsync), 원자적 파일 Lock, Stale Lock 자동 해제. Auto-activates when: file modification, NTFS safety, file locking, multi-session conflict prevention."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odev(파일수정)]
  calls: []
---

# domain-fileops — 파일 작업 Low-level 드라이버

> **범용 스킬** (하드링크 공유 — 다중 프로젝트)
> 프로젝트 고유 경로/설정 기재 금지 (CLAUDE.md 3-tier 원칙)

## 설계 철학

```yaml
역할: 파일시스템 드라이버 (Low-level)
비유: OS의 파일시스템 레이어 — 단일 파일 단위의 안전한 읽기/쓰기/Lock
상위: odev_lock (App-level) — 트랜잭션 관리자, 배치 Lock, 파이프라인 생명주기
관계: odev_lock → domain-fileops 호출 (상위가 하위를 사용)

원칙:
  - 단일 파일 단위 연산 (배치/그룹은 상위 레이어)
  - 환경 자동 감지 (호출자가 환경을 몰라도 됨)
  - Lock은 파일 옆에 위치 (.원파일명.lock)
  - 원자적 Lock 생성 (Race Condition 방지)
  - Stale Lock 자동 해제 (세션 crash 대응)
```

## 1. 환경 자동 감지

```yaml
감지_시점: 파일 작업 요청 시마다 (대상 경로 기준)

경로_패턴_분류:
  NTFS_WSL: /mnt/c/, /mnt/d/ 등 drvfs 마운트
  EXT4: /home/, /tmp/, ~/work/ 등 네이티브 Linux
  WINDOWS: C:\, D:\ 등 Windows 네이티브 경로

감지_방법: 대상 파일 경로의 prefix 패턴 매칭
  /mnt/[a-z]/ → NTFS_WSL
  ~/, /home/, /tmp/ → EXT4
  [A-Z]:\ → WINDOWS
```

## 2. 의사결정 매트릭스 (작업유형 x 환경)

| 작업 | NTFS_WSL | EXT4 | WINDOWS |
|------|----------|------|---------|
| **수정** | cp→Edit→rsync | Edit 직접 | Edit 직접 |
| **생성** | Write ext4→rsync | Write 직접 | Write 직접 |
| **삭제** | rm NTFS 직접 | rm 직접 | rm 직접 |

## 3. NTFS 안전 절차

```yaml
절차:
  1. cp "/mnt/c/.../파일" $HOME/.claude/session-env/${UUID}/work/파일  (NTFS→ext4 복사)
  2. Read $HOME/.claude/session-env/${UUID}/work/파일  (ext4 파일 읽기)
  3. Edit $HOME/.claude/session-env/${UUID}/work/파일  (ext4에서 부분 수정)
  4. rsync -a --inplace $HOME/.claude/session-env/${UUID}/work/파일 "/mnt/c/.../파일"  (동기화)

필수_옵션:
  --inplace: 임시파일 rename 방지 (NTFS metadata 오류 방지)

BOM_보존:
  cp가 바이너리 복사이므로 utf-8-sig BOM 자동 보존

작업_디렉토리:
  $HOME/.claude/session-env/${UUID}/work/ (세션별 격리 — UUID는 system-reminder 참조)

예외:
  Serena 심볼 편집: LSP 경유이므로 rsync 불필요 (유일한 예외)
```

## 4. 도구 선택 규칙

```yaml
# 전체 에이전트 (메인 + 팀 공통 — oio 최우선)
파일_수정:
  1순위: MCP oio (mcp__oio__file_edit / file_write / file_read 등)
         - NTFS rsync 자동 처리, Lock 자동 관리
         - 팀에이전트: team lead approval 우회 (0초)
         - 메인에이전트: rsync 수동 절차 불필요 (자동)
  2순위: Serena (C# 심볼 전용 — replace_symbol_body / insert_after_symbol)
         - LSP 경유, rsync 불필요
  Fallback: Claude Code Edit + rsync (oio/Serena 모두 불가 시)
삭제: mcp__oio__file_delete (Lock 자동) 또는 Bash rm
```

## 5. 파일 Lock 프로세스 (Low-level)

> 단일 파일 단위의 원자적 Lock. 상위 레이어(odev_lock)가 배치로 호출.
> 상세: [references/LOCK_MECHANISM.md](references/LOCK_MECHANISM.md) — Lock 파일 사양, 7단계 프로세스, 원자성 보장, Stale Lock 자동 해제

```yaml
핵심_요약:
  Lock_위치: .{원파일명}.lock + .{원파일명}.lockdir (동일 폴더)
  원자적_생성: mkdir (POSIX 표준 — NTFS/ext4 모두 보장)
  Stale_판정: PID 사망 OR TTL 60분 초과 → 자동 해제
  대기: 1초 간격 × 30회 (30초) → 타임아웃 시 상위 레이어 위임
```

## 6. ext4 작업 파일 보호

```yaml
문제: 병렬 에이전트가 cp NTFS→ext4 시 다른 에이전트의 미커밋 편집 덮어쓰기

규칙:
  - ext4에 이미 작업 파일 존재 → cp 금지
  - ext4 파일이 NTFS보다 최신이면 cp 차단
  - 기존 ext4 파일 직접 사용

현재_방어: ext4_freshness_guard.sh Hook
```

## 7. 일괄 편집

```yaml
절차:
  1. Glob → 대상 파일 수집 (패턴 매칭)
  2. 파일별 환경 감지 (NTFS/EXT4)
  3. 순차 수정 (환경별 절차 자동 적용)

지원_작업:
  - 정규식 치환 (파일 내 패턴 교체)
  - 문자열 교체 (리터럴 매칭)
  - 파일 간 일관성 적용
```

## 8. 텍스트 변환

```yaml
BOM_처리:
  - utf-8-sig BOM 감지/보존
  - BOM 추가/제거 옵션

줄바꿈_통일:
  - CRLF ↔ LF 변환
  - Windows 파일: CRLF 유지
  - Linux 설정: LF 유지

인코딩_변환:
  - UTF-8 ↔ EUC-KR 등
  - 프로젝트 기본: UTF-8 (BOM 포함)
```

## 9. 상위 레이어 연동 (odev_lock)

```yaml
호출_관계:
  odev_lock (App-level) → domain-fileops (Low-level)

odev_lock이_하는_것:
  - 배치 Lock (TODO 파일 전체에 대해 일괄 acquire)
  - 파이프라인 생명주기 연동 (odev 획득 → odone 해제)
  - 충돌 정책 결정 (대기/실패/강제 등)
  - 에이전트 파일 할당 매트릭스 관리

domain-fileops가_하는_것:
  - 단일 파일 Lock 생성/확인/해제
  - 환경 감지 + NTFS 안전 절차
  - Stale Lock 자동 해제
  - 원자적 Lock 보장 (mkdir)

파이프라인_내 (odev~odone):
  odev_lock이 domain-fileops를 호출하여 Lock 관리
  domain-fileops는 Lock 상태 확인만 (판단은 상위)

파이프라인_외 (o1, 스킬/문서 수정):
  domain-fileops 단독 사용 가능 (Lock 필요 시 직접 호출)
```

## 전체 흐름도

```
파일 수정/삭제 요청
  │
  ▼
┌─────────────┐     있음     ┌──────────────┐
│ 1. Lock 확인 │────────────▶│ 2. Stale 검사 │
└─────────────┘              └──────────────┘
  │ 없음                       │         │
  ▼                         Stale    정상Lock
┌──────────────────┐          │         │
│ 3. mkdir 원자적   │◀─────────┘    ┌────▼────┐
│    Lock 생성     │               │대기 30초 │
└──────────────────┘               │(1초간격) │
  │ 성공    │ 실패                  └────┬────┘
  ▼         └──▶ 1단계 재시도           │타임아웃
┌──────────────┐                  ┌─────▼─────┐
│ 4. 환경 감지  │                  │실패 반환   │
│  + 파일 수정  │                  │(상위 위임) │
└──────────────┘                  └───────────┘
  │
  ▼
┌──────────────┐
│ 5. Lock 제거  │
│ (소유권 확인) │
└──────────────┘
```

---

## PowerShell / CRLF / BOM 상세 규칙

> CLAUDE.md "언어 정책 > 인코딩 규칙" 에서 이관 (B3 oinsights 2026-03-25)

### PowerShell UTF-8 파일 쓰기 (L-148)

`Out-File -Encoding UTF8` / `Set-Content -Encoding UTF8` 사용 **절대 금지** (PowerShell 5.x에서 BOM 강제 포함 → Python/Linux 호환 불가).

```powershell
# 문자열 → 파일 (BOM 없음)
[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
# 배열 → 파일 (BOM 없음)
[System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
```

- 콘솔 세션: `chcp 65001` 및 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` 유지.
- Python 스크립트: 파일 I/O 시 `encoding='utf-8'`. 대량 치환 후 `git diff`로 한글 깨짐 확인.

### CRLF 정책

- NTFS 프로젝트 파일(`.cs`, `.md`, `.json`, `.xml` 등): CRLF 줄 끝 유지.
- rsync 동기화 후 CRLF 손상 시: `unix2dos 파일명`으로 복구.
- git 설정: `core.autocrlf = true` (Windows) / `core.autocrlf = input` (WSL) 유지.
- 신규 파일 Write 시 CRLF로 생성됨 (Claude Code 기본 — L-057). `.sh` 파일 Write 후 반드시 `sed -i 's/\r//' 파일` 실행.
- `.gitattributes`에 `* text=auto eol=crlf` 설정 시 git checkout 시 자동 CRLF 변환.

### BOM 정책

- 신규 파일: UTF-8 without BOM으로 생성.
- 기존 파일 수정 시: BOM 유무 그대로 유지 (cp 바이너리 복사로 자동 보존).
