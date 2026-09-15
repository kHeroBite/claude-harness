---
name: oinfra_template
description: 프로젝트 인프라 설정 골격 템플릿. 이 파일을 oinfra_{내프로젝트}/SKILL.md 로 복사한 뒤 각 섹션의 placeholder 를 자기 프로젝트 명령으로 채운다. otest_build / otest_run / obuild / odone_cleanup / opush 가 이 섹션들을 참조하므로, 채우지 않으면 해당 스킬이 동작하지 않는다.
---

<!-- 프로젝트별 빌드·배포·로그·헬스체크 명령을 수신자가 채워 넣는 인프라 스킬 골격 -->

# oinfra_template — 프로젝트 인프라 설정 골격

## 이 파일의 사용법 (먼저 읽어라)

1. 이 디렉토리 전체를 `oinfra_{내프로젝트}` 로 복사한다.
   예: `cp -r skills/oinfra_template skills/oinfra_myapp`
2. 복사본의 frontmatter `name` 을 `oinfra_myapp` 으로, `description` 을 자기 프로젝트 설명으로 바꾼다.
3. 아래 각 섹션의 `<여기에 ... 적으세요>` placeholder 를 실제 명령으로 교체한다.
4. **섹션 제목은 바꾸지 마라.** 파이프라인 스킬이 제목 문자열로 이 섹션을 찾는다.

> ⚠️ 채우기 전에는 `otest_build` / `otest_run` / `obuild` 가 실행할 명령을 찾지 못해 동작하지 않는다.

### 섹션 제목이 고정인 이유 (참조 지점 실측)

| 이 파일의 섹션 | 참조하는 스킬 |
|---|---|
| 빌드 방법 | otest_build, obuild |
| 배포 설정 | otest_run, obuild, agent_profiles |
| 로그 경로 | obuild, odone_cleanup |
| 헬스체크 | otest_run |
| 프로젝트 경로 | 전 파이프라인 공통 |
| 종료 명령 | otest_build, otest_run, obuild, odone_cleanup |
| Git Push | opush |
| ntfy 알림 | opush, ofinish |
| DB / MCP 설정 | domain-database, otest_make |

---

## 프로젝트 경로

```yaml
프로젝트_루트: <여기에 프로젝트 절대경로를 적으세요 (예: /mnt/c/work/myapp)>
솔루션_또는_진입점: <여기에 .sln / package.json / pyproject.toml 등 경로를 적으세요>
산출물_경로: <여기에 빌드 산출물 경로를 적으세요>
주요_소스_디렉토리: <여기에 적으세요>
```

---

## 빌드 방법

> otest_build / obuild 가 이 섹션의 명령을 그대로 실행한다.

```yaml
빌드_명령: |
  <여기에 빌드 명령을 적으세요>
  # 예: cmd.exe /c "cd /d C:\DATA\Project\myapp && dotnet build myapp.sln -c Debug"
  # 예: npm --prefix /mnt/c/work/myapp run build
  # 예: python3 -m compileall /mnt/c/work/myapp/src

빌드_전_필수_작업: |
  <여기에 적으세요 — 없으면 "없음">
  # 예: 실행 중 프로세스 종료 (파일 잠금 해제). 아래 "종료 명령" 섹션 참조.

성공_판정: |
  <여기에 빌드 성공 판정 기준을 적으세요>
  # 예: 출력에 "Build succeeded" 포함 AND "error CS" 0건
  # 예: rc == 0

실패_판정: |
  <여기에 적으세요>
  # 예: 출력에 "error" 또는 "FAILED" 포함, 또는 rc != 0

타임아웃_초: <여기에 적으세요 (예: 300)>
```

---

## 배포 설정

> otest_run / obuild 가 이 섹션의 명령으로 배포·기동한다.

```yaml
배포_대상_매핑:
  # 수정한 파일/모듈 → 배포 대상. 대상이 1개면 단일 항목만 두면 된다.
  <여기에 적으세요>
  # 예:
  #   src/api/**   : api-server
  #   src/web/**   : web-frontend

배포_명령: |
  <여기에 배포 명령을 적으세요>
  # 로컬 실행형이면 그대로 기동 명령을 적는다.
  # 원격 배포형이면 rsync/scp 명령을 적는다.
  # 예: rsync -az --delete ./dist/ ${REMOTE}:${REMOTE_DIR}/

기동_명령: |
  <여기에 기동 명령을 적으세요>
  # 예: cmd.exe /c start "" "C:\DATA\Project\myapp\bin\Debug\myapp.exe"
  # 예: ssh ${REMOTE} "systemctl --user restart myapp"

원격_접속_정보:
  # ★자격증명을 이 파일에 평문으로 적지 마라.★
  # 호스트/사용자도 공개 저장소에 올릴 파일이면 환경변수로 빼는 것을 권장한다.
  REMOTE: <여기에 적으세요 (예: ${MYAPP_REMOTE} 또는 user@host)>
  REMOTE_DIR: <여기에 원격 배포 디렉토리를 적으세요>
  REMOTE_BIN: <여기에 원격 실행 바이너리 경로를 적으세요 — 해당 없으면 "해당없음">
  REMOTE_PID: <여기에 원격 pid 파일 경로를 적으세요 — 해당 없으면 "해당없음">
  인증_방법: <여기에 적으세요 (예: SSH 키 — ~/.ssh/id_ed25519)>

배포후_검증: |
  <여기에 적으세요 — 없으면 "없음">
  # 단일파일 ELF 등을 원격 배포하면 md5 대조를 권장한다 (otest_run 2.5 절 참조).
```

---

## 헬스체크

> otest_run 이 기동 직후 이 섹션으로 정상 동작을 판정한다.

```yaml
프로세스_확인: |
  <여기에 적으세요>
  # 예(Windows): cmd.exe /c tasklist | grep -i myapp.exe
  # 예(Linux):   pgrep -af myapp

엔드포인트_확인: |
  <여기에 적으세요 — 해당 없으면 "해당없음">
  # 예: curl -fsS http://localhost:8080/health

통과_기준: |
  <여기에 적으세요>
  # 예: 프로세스 1건 이상 존재 AND /health 응답이 HTTP 200

대기_시간_초: <여기에 기동 후 헬스체크까지 대기할 초를 적으세요 (예: 5)>
```

---

## 로그 경로

> obuild 가 기동 로그 확인에, odone_cleanup 이 로그 정리에 사용한다.

```yaml
애플리케이션_로그: <여기에 적으세요 (예: /mnt/c/work/myapp/logs/app.log)>
빌드_로그: <여기에 적으세요 — 없으면 "없음">
원격_로그: <여기에 적으세요 — 없으면 "해당없음">
확인_명령: |
  <여기에 적으세요>
  # 예: tail -n 100 /mnt/c/work/myapp/logs/app.log
오류_패턴: <여기에 로그에서 오류로 간주할 패턴을 적으세요 (예: ERROR|FATAL|Exception)>
```

---

## 종료 명령

> 빌드 전 파일 잠금 해제와 재기동에 사용한다.

```yaml
종료_명령: |
  <여기에 적으세요>
  # 예(Windows): cmd.exe /c taskkill /F /IM myapp.exe
  # 예(Linux):   pkill -f myapp
종료_확인: |
  <여기에 적으세요>
  # 예: 프로세스 0건이 될 때까지 최대 10초 대기
```

---

## Git Push

> opush 가 참조한다.

```yaml
원격_이름: <여기에 적으세요 (예: origin)>
기본_브랜치: <여기에 적으세요 (예: master)>
인증_방법: <여기에 적으세요 (예: SSH 키 / gh CLI)>
push_전_확인: <여기에 적으세요 — 없으면 "없음">
```

---

## ntfy 알림

> opush / ofinish 가 참조한다. 사용하지 않으면 `사용: false` 로 두면 된다.

```yaml
사용: <true 또는 false 를 적으세요>
토픽: <여기에 ntfy 토픽명을 적으세요 — 미사용 시 "미사용">
서버: <여기에 적으세요 (예: https://ntfy.sh)>
```

---

## DB / MCP 설정

> domain-database / otest_make 가 참조한다. DB 를 쓰지 않으면 `사용: false` 로 두면 된다.

```yaml
사용: <true 또는 false 를 적으세요>
DBMS: <여기에 적으세요 (예: MySQL 8.0)>
MCP_서버명: <여기에 적으세요 (예: mysql)>
스키마_문서: <여기에 적으세요 (예: {프로젝트}/DATABASE.md)>
접속_정보: |
  ★평문 자격증명을 이 파일에 적지 마라.★
  호스트/계정/비밀번호는 수신자 로컬 `.mcp.json` 또는 환경변수에만 둔다.
  이 파일에는 "어디에 설정했는지"만 적는다.
  # 예: 접속 정보는 ~/.mcp.json 의 mcpServers.mysql.env 에 있다.
```

---

## 디버그 변환 규칙

> odone_cleanup 이 참조한다. 해당 없으면 "없음" 으로 두면 된다.

```yaml
디버그_로그_패턴: <여기에 적으세요 — 없으면 "없음">
변환_규칙: |
  <여기에 적으세요 — 없으면 "없음">
  # 예: Debug2 로그는 릴리스 빌드 전 주석 처리한다.
```

---

## 채움 여부 자기 점검

복사본을 채운 뒤 아래를 실행해 placeholder 잔존을 확인하라.

```bash
grep -n "여기에" .claude/skills/oinfra_{내프로젝트}/SKILL.md
```

출력이 0줄이면 채움 완료다. 남아 있는 줄은 아직 파이프라인이 쓸 수 없는 항목이다.

## 참조

- 빌드 실행 본체: `otest_build`
- 배포·구동 본체: `otest_run`
- 빌드·기동 전담 에이전트: `obuild`
