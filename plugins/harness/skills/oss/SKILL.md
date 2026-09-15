---
name: oss
description: "WSL2에서 Windows 스크린샷을 Claude에게 시각적으로 전달. 1순위로 캡처 도구 자동저장 폴더(Pictures\\Screenshots)의 최신 파일을 사용하고, 폴더가 비어 있으면 클립보드로 폴백한다. 사용자가 '/oss', '스크린샷', '화면 봐줘' 요청 시 사용. 인자: '/oss'(최근 3건, 기본값), '/oss N'(최근 N건), '/oss @N'(N번째 최신 1건), '/oss N-M'(다중), '/oss all'(최대 10건), '/oss clean'(정리), '/oss --clip'(클립보드 강제), 그 외 자유 텍스트는 개수 추출 시도 후 캡처하여 분석 지시문으로 해석. 한 장만 즉시 보여줄 때는 스킬 대신 Alt+V(클립보드 이미지 직접 붙여넣기)가 더 빠르다."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
---

# oss — Windows 스크린샷 참조

**먼저 판단할 것**: 사용자가 화면 한 장을 지금 보여주려는 것뿐이라면 **Alt+V**(Claude Code 내장 이미지 붙여넣기)를 안내하라. 도구 호출 0회로 끝난다.
이 스킬은 **여러 장 일괄 / 과거 N번째 / 크롭 재분석 / 나중에 다시 참조**가 필요할 때 쓴다.

## 실행 — bash_exec 1회 + Read

> 모든 명령은 `mcp__oio__bash_exec` 사용 (Claude 내장 Bash 금지)

```yaml
1단계_경로해결:
  mcp__oio__bash_exec(command="bash ~/.claude/scripts/oss-capture.sh {ARG}")
  # {ARG} 결정 규칙:
  #   인자 없음        → 생략 (스크립트 기본값 3 적용)
  #   순수 숫자 N       → 그대로 전달 (최근 N건)
  #   @N               → 그대로 전달 (N번째 최신 1건)
  #   N-M / N..M / all / clean / --clip → 그대로 전달
  #   자유 텍스트       → 텍스트에서 개수 표현("최근 5개", "5장" 등) 정규식/자연어로 추출 시도
  #                       → 추출 성공 시 추출된 N을 인자로 전달 (예: "최근 5개 화면 봐줘" → 5)
  #                       → 추출 실패 시 인자 생략(기본 3건) + 원문은 분석 지시문으로 보존
  # 출력 형식:
  #   SOURCE=file|clip
  #   <WSL경로><TAB><나이(초)><TAB><해상도>      ← 최신순, 요청 건수만큼
  # 오류:
  #   ERROR:NO_IMAGE          → "클립보드에 이미지가 없습니다. Windows+Shift+S로 캡처 후 다시 호출하세요."
  #   ERROR:INDEX_OOB:<보유수> → 보유 건수를 알려주고 범위 안으로 다시 요청하도록 안내

2단계_전달:
  # 1차: 출력된 WSL 경로를 그대로 Claude 내장 Read로 전달 (원본 그대로, 위에서부터 최신순)
  #      Claude 내장 Read 사용 (이미지 렌더링). mcp__oio__file_read 아님.
  # 2차(폴백): 아래 중 하나 발생 시에만 리사이즈 후 재Read
  #   - Claude API 400 (Could not process image) 오류 발생
  #   - image_read_block.sh 훅이 4MB/8000px 초과로 차단
  #   → mcp__oio__image_resize(path=<원본경로>) 호출 (기본 max_width=1280/max_height=720)
  #   → 반환된 output_path를 Read로 재시도
  # SOURCE=file 이고 나이가 600초를 넘으면 "N분 전 스크린샷인데 맞습니까?" 확인 후 진행.
  #   → 방금 찍은 것을 원했던 것이면 '/oss --clip' 으로 재시도.
```

## 소스 우선순위 (스크립트 내부)

| 순위 | 소스 | 비용 | 조건 |
|---|---|---|---|
| 1 | `C:\DATA\ScreenShot` (자동저장 전용 폴더) | **~0.17초**, PowerShell 0회 | 상시 |
| 2 | OneDrive KFM 폴더 (`그림\스크린샷` 등, 과거 이력) | ~1.3초 (파일 2천여 개) | 1순위가 요청 건수를 못 채울 때만 |
| 3 | 현재 클립보드 | ~2.5초 (콜드 시 10초+) | 파일 소스가 비었고 최신 1건 요청 |
| 4 | 클립보드 히스토리 (WinRT) | ~8초 | N≥2 요청 또는 현재 클립보드에 이미지 없음 |

캡처 도구 자동저장이 켜져 있어 **폴더가 곧 히스토리**다 — 3·4순위는 거의 타지 않는다.
2순위는 파일 수가 많아 stat 비용이 크므로 1순위로 못 채울 때만 스캔한다.
저장 위치를 또 옮겼다면 `OSS_SHOT_DIRS="경로1:경로2"` 환경변수로 1순위를 덮어쓸 수 있고,
한국어 Windows/OneDrive 조합(`그림`·`사진` × `Screenshots`·`스크린샷`)은 자동 탐색된다.

## 인자

> ⚠️ 문법 변경(2026-07-31): 순수 숫자 인자의 의미가 "N번째 최신 1건"→"최근 N건"으로 바뀌었다.
> 구 동작이 필요하면 `@N`을 사용하라 (예: 구 `/oss 3` → 신 `/oss @3`).

```
/oss              → 최근 3건 (기본값 — 기존 1건에서 변경)
/oss N            → 최근 N건 (기존 "N번째 최신 1건" 의미 폐기 — breaking change)
/oss @N           → N번째 최신 1건 (신규 — 구 "/oss N"의 의미를 이전)
/oss N-M / N..M   → N~M번째 다중 (상한 10, 기존 유지)
/oss all          → 최신 최대 10건
/oss --clip [N]   → 파일 소스 무시하고 클립보드 강제
/oss clean        → 캡처 산출물 정리
/oss <자유텍스트>  → 텍스트에서 개수 추출 시도(예: "최근 5개") → 실패 시 최근 3건 + 텍스트를 분석 지시문으로 해석
```

N-M에서 M<N이면 자동 swap, 10 초과는 잘라냄 — 모두 스크립트가 처리한다.

## 2-pass 크롭 분석

1차 Read 후 텍스트가 작아 판독이 어렵거나(폭·높이 1500px 이상) 여러 영역을 상세히 봐야 하면 자동 수행.

```bash
# 좌표는 1차 Read에서 결정 (left, top, width, height)
python3 -c "from PIL import Image; im=Image.open('{SRC}'); im.crop((L,T,L+W,T+H)).save('/tmp/screenshot/crop_{TS}.png')"
```

크롭 산출물은 반드시 `/tmp/screenshot/` 아래에 쓸 것 — Read 훅 허용 경로다. 최대 3회 재크롭 후 전체 이미지 분석으로 확정.

## 주의사항

- **Read 훅**: `image_read_block.sh`가 이미지 Read를 전역 차단하되 `/mnt/c/DATA/ScreenShot/`, `/tmp/screenshot/`, `/mnt/c/temp/cc/`, `*/Pictures/Screenshots/`, `*/그림|사진/스크린샷/`만 허용한다. 다른 경로의 이미지를 Read하려 하면 차단되므로 위 경로로 복사 후 읽어라. 허용 경로여도 4MB 또는 8000px 초과 시 차단된다(API 400 방지) — 크롭하거나 위 "2단계_전달" 폴백대로 `mcp__oio__image_resize`로 축소 후 읽을 것.
- **PowerShell 저장 경로**: 클립보드 폴백은 `C:\temp\cc`에 저장한다. UNC(`\\wsl.localhost\...`)에 GDI+ Save 하면 "일반 오류"가 나므로 WSL 경로로 직접 쓰지 않는다.
- **포맷 변환 불필요**: 산출물은 GDI+ PNG 인코딩이라 항상 PNG다. 별도 변환·메타데이터 strip 단계를 넣지 말 것.
- Windows+Shift+S 후 ~0.5초 기다렸다 호출 (클립보드 반영 시간).
- 클립보드 히스토리(N≥2)는 Windows 설정 → 시스템 → 클립보드 → "클립보드 기록" ON 필요.
- `/tmp/screenshot/` 은 WSL 재시작 시 초기화됨. `/mnt/c/temp/cc/` 는 유지되므로 `/oss clean`으로 정리.

## 구현 위치

- `~/.claude/scripts/oss-capture.sh` — 소스 선택·인자 파싱·경로 출력 (bash)
- `~/.claude/scripts/oss-clip.ps1` — 클립보드/히스토리 추출 (PowerShell, 폴백 전용)
