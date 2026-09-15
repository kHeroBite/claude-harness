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
  opush: 프로젝트 push + dotfiles push + hook 동기화 + AI repo push + ntfy 페이로드 생성 일괄 처리
  금지: 커밋만 하고 push 생략 — "마무리하자", "완료"라도 push 생략 절대 금지
```

## 커밋 메시지 형식

```yaml
제목: "{이모지} {한국어 요약} by {모델버전}"
  예: "✨ 기능 추가 by claude-sonnet-4-6"
  규칙: 제목 마지막에 반드시 "by {모델버전}" 추가 (CLAUDE.md 정책)
  모델버전: 실제 실행 중인 모델 ID (예: claude-sonnet-4-6, claude-opus-4-6)

본문: 한국어 + 이모지
footer: |
  🤖 Generated with [Claude Code](https://claude.com/claude-code) (claude-sonnet-4-6)

  Co-Authored-By: Claude <noreply@anthropic.com>
주의: footer의 모델 버전도 실제 사용 중인 모델로 업데이트
주의: 위 noreply@anthropic.com은 Anthropic 공식 Co-Authored-By 귀속 주소이며 개인정보가 아니다.
      credential_scan.sh WHITELIST에 noreply 패턴이 등재되어 있으므로 오탐 없이 그대로 사용한다.
```

## 세션 임시파일 삭제 (git push 전 — 필수)

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
push_실패_재시도 (P1):
  최대_시도: 3회
  backoff: 지수 (5초, 15초, 45초)
  절차:
    1차_실패: git pull --rebase && git push (5초 대기 후)
    2차_실패: git fetch && git rebase origin/master && git push (15초 대기 후)
    3차_실패: push 포기 → 사용자에게 수동 push 요청 알림
  충돌_시: rebase 충돌 발생하면 즉시 중단 + 사용자 알림 (자동 해결 시도 금지)
```

## 다중 세션 주의

```yaml
충돌_방지:
  작업_전: git pull, git status 확인
  작업_중: 단일 파일 집중, 자주 커밋
  충돌_시: git stash → pull → stash pop

브랜치_분리:
  세션별: feature/task-a, feature/task-b
  확인: 커밋 전 다른 세션 작업 확인
```
