---
name: odone_git
description: "Git 커밋 & 푸시. 한국어+이모지 커밋 메시지 생성."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone]
  calls: [opush]
---
# odone_git — 커밋 & 푸시

## 🚨 절대 규칙 (L-101)
커밋(commit) + 푸시(push) = 세트. push 없는 커밋 = 미완료.
odone_git 실행 = 반드시 commit 후 push까지 완료.

## 커밋 절차

```yaml
1_환경설정:
  set GIT_TERMINAL_PROMPT=0

2_스테이징:
  필수: git add {이번 작업에서 실제 수정한 파일명 명시} (git add -u/-A/. 절대 금지 — L-457)
  근거: 이 저장소는 다중 세션 공유 저장소다. git add -u/-A/. 는 타 세션의 미커밋 변경까지
        통째로 스테이징에 흡수한다(실측: 직전 사이클 18건 중 14건이 타 세션분).
  NTFS_대소문자_주의: 파일명 대소문자가 실제 디스크 항목과 정확히 일치하는지 확인 후 add
        (oFinish vs ofinish 등 불일치 시 add 자체가 실패하므로 git status로 즉시 드러남)
  확인: git add 후 git status --short 로 staged 개수가 의도한 파일 수와 일치하는지 반드시 확인
        (불일치 시 커밋 중단 후 재확인)

  gitignore_체크 (필수 — git add 전):
    절차: git check-ignore {파일} 로 각 파일 검사
    매칭_시: 해당 파일 스킵 (커밋 대상에서 제외)
    금지: git add -f 절대 금지 (gitignore 우회 = 추적 오염)
    교훈: L-031 — git add가 조용히 무시되면 -f가 아닌 gitignore 확인이 정답

3_커밋:
  git -c core.editor=true commit -F .commit_message.txt

4_푸시 (절대 생략 금지 — 항상 자동 실행):
  원칙: 커밋 완료 후 반드시 Skill('opush') 호출
  opush: 프로젝트 push(wt_lib push 경유) + dotfiles push + hook 동기화 + AI repo push + ntfy 페이로드 생성 일괄 처리
  금지: 커밋만 하고 push 생략 — "마무리하자", "완료"라도 push 생략 절대 금지
```

## 커밋 메시지 형식

```yaml
제목: "{이모지} {한국어 요약} by claude-{모델계열}"
  예: "✨ 기능 추가 by claude-sonnet"
  규칙: 제목 마지막에 반드시 "by claude-{모델계열}" 추가 (CLAUDE.md 정책)
  모델계열: 실제 실행 중인 모델의 계열 별칭 (opus/sonnet/haiku/fable). 버전 숫자는 쓰지 않는다.

본문: 한국어 + 이모지
footer: |
  🤖 Generated with [Claude Code](https://claude.com/claude-code) (claude-sonnet) — 계열 별칭만 표기

  Co-Authored-By: Claude <noreply@anthropic.com>
주의: footer의 모델 버전도 실제 사용 중인 모델로 업데이트
```

## 세션 임시파일 삭제 (push 전 — 필수)

> 커밋 완료 후, 푸시 전에 세션 중 생성된 임시파일을 모두 삭제.

```yaml
시점: 3_커밋 완료 후, 4_푸시 직전
목적: 세션 임시 상태가 다음 세션에 영향 주지 않도록 정리

삭제_대상:
  SID_디렉토리: $HOME/.claude/session-env/${UUID}/ — ofinish Step 6에서 rm -rf로 일괄 삭제 (odone_git 삭제 금지)
  커밋_메시지: $HOME/.claude/session-env/${UUID}/logs/dotfiles_commit.txt, $HOME/.claude/session-env/${UUID}/logs/ai_commit.txt
  TODO_파일: {프로젝트루트}/TODO_*.md

삭제_명령:
  # UUID 디렉토리는 ofinish Step 6에서 rm -rf $HOME/.claude/session-env/${UUID} 일괄 삭제 — 여기서 삭제 금지
  mcp__oio__bash_exec(command='rm -f $HOME/.claude/session-env/${UUID}/logs/dotfiles_commit.txt $HOME/.claude/session-env/${UUID}/logs/ai_commit.txt')  # EXT4($HOME) — bash_exec 경유 필수

주의:
  - odone_review Step 0.5에서 에러 파일을 이미 읽고 JSON으로 변환 완료한 상태
  - 삭제 순서: 커밋 → 임시파일 삭제 → 푸시 (커밋에는 영향 없음)
  - TODO_*.md는 .gitignore에 포함되어 있으므로 커밋과 무관
```

> **push 이후 절차 (dotfiles/hook 동기화/AI repo/ntfy 페이로드)**: Skill('opush') 참조

## push 실패 재시도

```yaml
push_단일_경로 (wt_lib push):
  명령: python3 <hooks>/lib/wt_lib.py push --sid <UUID> [--repo <세션 worktree>]   # <hooks> = 글로벌 hooks 디렉토리. --sid 필수, --repo 는 원본이 아니라 세션 worktree 이거나 생략(--sid 로 해석)
  sid_출처: --sid 의 UUID 는 메인=UserPromptSubmit hook 이 출력하는 `🆔 [UUID] {값}`(또는 compact 복원의 `- UUID: {값}`), 팀원=프롬프트 첫 줄 `PIPELINE_UUID=` 값이다. 메인 셸에는 세션 ID 환경변수가 없다. 반드시 36자 full UUID 인지 확인하고(예: 6690d4cc-b90e-4a8b-8bd9-64e78b500249), 파일·명령으로 탐색하지 않는다. --sid 없이 부르지 않는다.
  worktree_경로_추출: ensure 는 JSON 한 줄을 출력하며 키 `worktree` 가 경로다. WT=$(python3 <hooks>/lib/wt_lib.py ensure --repo <프로젝트 루트> --sid <UUID> | python3 -c 'import sys,json; print(json.load(sys.stdin)["worktree"])'). ok 가 false 면 키가 없으므로 중단하고 error 를 보고한다. 직후 `: "${WT:?worktree 확보 실패}"` 로 빈 값을 검사한다. WT= 와 이후 git -C "$WT" 명령은 같은 셸 호출 안에서 실행한다(&& 로 이어 쓰면 다른 셸에서 실행돼 WT 가 빈다).
  원본에_이미_있는_변경: 순서는 ensure → adopt → 커밋 → push 다. python3 <hooks>/lib/wt_lib.py adopt --sid <UUID> [--repo <원본>] --paths <파일...> 로 지정한 파일만 세션 worktree 로 복사한 뒤 worktree 에서 커밋한다. 경로 없는 일괄 처리·디렉터리는 rc=2 로 거부되고 세션 worktree 가 없어도 rc=2 이므로 먼저 ensure 한다. adopt 전에 ensure 로 세션 worktree 기록이 먼저 있어야 한다. 원본은 그대로 두며, push 후 wt_lib 이 원본을 되돌리고 ff 하는 것은 사전조건(원본이 기본 브랜치, 채택 대상 외 추적 변경 없음, gated 저장소면 --apply-permit)이 모두 확실할 때뿐이다. 결과 JSON 의 adopt 해석은 이렇다. `kept(ff 불가: 사유 — 원본 내용 = push 내용)` 는 원본(live)에 새 판이 유지되고 ff 만 건너뛴 상태이므로 git status 로 원본 상태를 확인하고 사유(브랜치·타 추적 변경·permit)를 해소한 뒤 같은 push 를 다시 부른다(원본 dirty 의 타 변경은 지우거나 되돌리지 않는다). `mismatch` 는 원본 내용이 push 내용과 다른 채택 파일이 있어 전부 건드리지 않은 것이므로 원본 변경을 보존하고 보고한다. `cleared` 는 원본에 남은 변경이 없어 목록에서 지운 것, `restored` 는 되돌린 뒤 ff 실패로 push 된 내용으로 원본을 다시 써서 새 판을 유지한 것이다.
  commit_위치: 커밋은 세션 worktree 에서 한다. worktree 는 python3 <hooks>/lib/wt_lib.py ensure --repo <프로젝트 루트> --sid <UUID> 로 확보하고 출력된 경로를 git -C 대상으로 쓴다. 원본 checkout 에서 직접 add/commit 하지 않는다.
  역할: 잠금 + fetch + rebase + 강제 없는 push + 재시도(최대 3회)를 wt_lib 이 일괄 수행. 정본 원격·기본 브랜치도 wt_lib 이 판정한다.
  금지: git 명령으로 직접 올리기, pull --rebase 수동 실행, 원격/브랜치 이름 하드코딩, 강제 push(--force/+refspec/--mirror/--delete)
  전환기_호환: wt_lib.py 가 없는 환경(구 배포본)에서만 기존 방식(push 후 실패 시 pull --rebase 1회)으로 폴백하고 그 사실을 보고한다. wt_lib.py 가 있으면 폴백 금지.
  게이트_대상_저장소: 적용 허가가 필요한 저장소는 --apply-permit 인자 또는 WT_APPLY_PERMIT=1 환경변수를 넘긴다.
  rc_대응:
    0: 성공 — 결과 JSON(remote·branch·sha·ff)을 보고
    2: 추적 변경이 남아 있음 — 커밋부터 하고 재실행
    3: rebase 충돌 — 즉시 중단 + 충돌 파일 목록(conflicts)을 사용자에게 알림 (자동 해결 시도 금지, 강제 push 금지)
    4: 정본 원격/기본 브랜치 판정 실패 — push 하지 않고 error 를 보고
    5: push 잠금 대기 시간 초과 — 잠시 후 1회 재실행, 재실패 시 보고
    6: push 거절/실패 — wt_lib 내부 재시도 후 실패한 것이므로 error 를 사용자에게 알리고 수동 확인 요청. error 가 "원격이 앞섬 — worktree 에서 push 하라" 이면 원본에서 부른 것이므로 --sid <UUID> 로 worktree 에서 재실행
    7: 원본 checkout 에서 push 했는데 원격보다 앞선 세션 worktree 가 있음 — 결과 JSON 의 ahead_worktrees 를 보고 --sid 누락 또는 --repo 오지정을 바로잡으므로 --sid <UUID> 로 재실행(성공으로 간주 금지). 원본에서 push 할 때 그 sid 의 worktree 기록이 전혀 없으면 세션명과 무관하게 원격보다 앞선 worktree 를 모두 내 것으로 보고 거부되므로, push 전에 ensure 를 먼저 하고(정상 경로에서는 기록이 생긴다) `--repo <세션 worktree>` 지정 또는 `--sid <UUID>` 로 재실행한다(기록이 있을 때만 타 세션 worktree 는 warnings 에만 실린다)
    8: 원본 checkout 의 현재 브랜치가 기본 브랜치가 아님 — push 하지 않았으므로 error 를 보고하고 세션 worktree 경유로 전환
```

## 다중 세션 주의

```yaml
충돌_방지:
  작업_전: git pull, git status 확인
  작업_중: 단일 파일 집중, 자주 커밋
  충돌_시: stash 를 쓰지 않는다(refs/stash 는 모든 worktree 가 공유해 남의 변경을 꺼낼 수 있다). 임시 보관은 WIP 커밋, 합류는 wt_lib push, rc=3 이면 충돌 파일을 보고한다

브랜치_분리:
  세션별: feature/task-a, feature/task-b
  확인: 커밋 전 다른 세션 작업 확인
```
