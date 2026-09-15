---
name: oDownload
description: 하네스 배포본을 수신자 환경에서 동기화하는 스킬. 플러그인 본체(스킬/hook/규칙/oio)는 마켓플레이스가 자동갱신하므로, 이 스킬의 주 목적은 자동갱신 대상이 아닌 플러그인 바깥 자산(bin 3종 cc/ccc/cas, install.sh) 동기화다. 사용자가 '/oDownload', '하네스 업데이트', '배포본 받기', '최신 하네스 동기화' 요청 시 사용.
---

# oDownload — 하네스 배포본 동기화 (수신자용)

## ★이 스킬의 주 목적★

```
플러그인 본체(스킬 / hook / rules / oio MCP)  → 마켓플레이스가 자동갱신한다  (이 스킬 대상 아님)
플러그인 바깥(bin 3종 cc·ccc·cas / install.sh) → oDownload 가 수동 동기화한다  ★주목적★
```

플러그인이 자동갱신되어도 **`cc` / `ccc` / `cas` 와 `install.sh` 는 갱신되지 않는다.**
이 두 축이 분리되어 있다는 점이 이 스킬의 존재 이유다. 사용자가 "플러그인이 자동갱신되는데
왜 이게 필요하냐" 고 물으면 위 표로 답한다.

---

## Step 1. git pull

배포 repo 로컬 clone 경로에서 pull 한다.

```bash
bash -c 'REPO="<로컬 clone 경로>"; cd "$REPO" && git status --short | head -20'
```

- **로컬 수정이 있으면 중단하고 사용자에게 보고한다.** 강제 덮어쓰기(`git reset --hard`,
  `git checkout -f`)는 **금지**다. 사용자가 명시 승인한 경우에만 진행한다.
- 클린한 상태에서만 pull 한다.

```bash
bash -c 'REPO="<로컬 clone 경로>"; cd "$REPO" && git pull --ff-only'
```

`--ff-only` 가 실패하면 로컬 커밋이 분기한 상태다. 임의 merge/rebase 하지 말고 사용자에게 보고한다.

pull 결과에서 갱신 범위를 확인해 보고한다.

```bash
bash -c 'REPO="<로컬 clone 경로>"; cd "$REPO" && git diff --name-only HEAD@{1} HEAD | head -30'
```

---

## Step 2. bin 3종 갱신 (심볼릭링크 재생성)

`~/.local/bin/` 의 `cc` / `ccc` / `cas` 는 repo 의 `bin/` 을 가리키는 심볼릭링크다.
pull 로 링크 대상 파일 내용은 이미 갱신되었으나, **링크가 끊겼는지 확인하고 재생성**한다.

```bash
bash -c 'REPO="<로컬 clone 경로>";
  for b in cc ccc claude-as; do
    if [ -e "$HOME/.local/bin/$b" ]; then echo "OK   $b"; else echo "MISS $b"; fi
  done
  [ -e "$HOME/.local/bin/cas" ] && echo "OK   cas" || echo "MISS cas"'
```

끊긴 링크가 있거나 `MISS` 가 있으면 재생성한다 (`-sfn` 이므로 멱등).

```bash
bash -c 'REPO="<로컬 clone 경로>"; mkdir -p "$HOME/.local/bin";
  for b in cc ccc claude-as; do ln -sfn "$REPO/bin/$b" "$HOME/.local/bin/$b"; done
  ln -sfn "$HOME/.local/bin/claude-as" "$HOME/.local/bin/cas"; echo RELINKED'
```

실행 권한도 확인한다.

```bash
bash -c 'REPO="<로컬 clone 경로>"; chmod +x "$REPO"/bin/* 2>/dev/null; ls -l "$REPO/bin" | head'
```

---

## Step 3. install.sh 재실행 (멱등)

`install.sh` 는 멱등 설계이므로 재실행이 안전하다. 새 의존성(패키지, venv 갱신, 디렉토리 추가)을
반영하기 위해 반드시 재실행한다.

```bash
bash -c 'REPO="<로컬 clone 경로>"; cd "$REPO" && bash install.sh'
```

- `sudo` 프롬프트가 나올 수 있다 (tmux 설치 단계). 사용자에게 미리 알린다.
- 실패하면 어느 단계에서 멈췄는지 그대로 보고한다. 임의 우회 금지다.

---

## Step 4. 플러그인 갱신 확인 안내

플러그인 본체는 마켓플레이스가 자동갱신하지만, 즉시 반영을 원하면 사용자가 직접 갱신을 트리거한다.

- `/plugin` 메뉴에서 harness 플러그인의 버전을 확인한다.
- 갱신이 보이지 않으면 최대 10분 정도 기다린 후 재확인한다.
- 즉시 반영이 필요하면 `/reload-plugins` 를 실행한다.

규칙 문서(`rules/harness.md`)는 SessionStart hook 이 `~/.claude/rules/harness.md` 로 자동 동기화한다.
수신자 `CLAUDE.md` 에 `@~/.claude/rules/harness.md` 한 줄이 있는지 확인한다 (없으면 안내만 하고
**자동 삽입은 금지** — 사용자 CLAUDE.md 파괴 위험).

```bash
bash -c 'grep -n "rules/harness.md" "<프로젝트>/CLAUDE.md" 2>/dev/null || echo "IMPORT_LINE_MISSING"'
```

---

## Step 5. 고지 출력  ★생략 불가★

작업 종료 시 아래 고지를 **반드시** 사용자에게 출력한다. 생략하면 사용자가
"갱신했는데 왜 그대로지?" 라고 오인한다.

```
┌──────────────────────────────────────────────────────────┐
│ 플러그인 본체(스킬/hook/규칙/oio)는 자동갱신됩니다.       │
│   → 즉시 반영이 필요하면 /reload-plugins                 │
│                                                          │
│ ⚠ cc / ccc / cas 갱신분은 **다음 실행부터** 적용됩니다.  │
│   지금 도는 Claude Code 는 구(舊) 런처가 띄운 프로세스   │
│   입니다. 종료 후 cc 를 다시 실행하세요.                 │
└──────────────────────────────────────────────────────────┘
```

### 왜 현재 세션에 반영되지 않는가 (사용자 질문 대비)

`oDownload` 는 **Claude Code 안에서 실행**되는데, `cc` 는 **그 Claude Code 를 띄운 런처**다.
런처는 이미 `exec` 되어 메모리에 올라간 상태이므로, 파일을 교체해도 현재 프로세스는 영향받지 않는다.

- **안전하다** — 실행 중 런처 파일 교체는 현재 세션을 깨뜨리지 않는다.
- **단 착각 위험이 있다** — 그래서 위 고지가 생략 불가 항목이다.
- 현재 구동 중인 런처 버전은 `cc --version` 으로 확인할 수 있다(지원하는 경우).

---

## Step 6. 완료 보고

- pull 결과 (갱신된 커밋 수 / 주요 변경 파일)
- bin 3종 링크 상태 (정상 / 재생성)
- `install.sh` 결과 (성공 / 실패 단계)
- `@~/.claude/rules/harness.md` 등재 여부
- Step 5 고지 출력 완료 여부

---

## 금지 사항

- 로컬 수정이 있는 상태에서 강제 덮어쓰기(`reset --hard` / `checkout -f`) — 사용자 승인 없이는 금지.
- `git pull` 실패 시 임의 merge/rebase.
- Step 5 고지 생략.
- 수신자 `CLAUDE.md` 에 `@import` 한 줄 자동 삽입 (안내만 허용).
- `install.sh` 실패를 숨기고 성공으로 보고.
