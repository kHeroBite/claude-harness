---
name: opush
description: "Git 커밋 & push 서브스킬 — 미커밋 변경 자동 커밋 + push 수행. odone 파이프라인 또는 /opush 단독 호출 모두 지원."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [odone_git, 사용자]
  calls: []
---
# opush — Git Commit & Push

> odone의 서브스킬. 커밋 + push를 일괄 수행.
> **프로젝트별 push 설정**: `{프로젝트 루트}/INFRA.md` 읽기(필요 절만) — "Git Push" 절 참조

## Commit & Push 절차

```yaml
0_커밋_확인_및_실행:
  git status로 미커밋 변경 확인
  미커밋_변경_있으면:
    1. git diff --stat 으로 변경 파일 파악
    2. git log --oneline -3 으로 커밋 메시지 스타일 확인
    3. 변경 내용 분석하여 한국어+이모지 커밋 메시지 생성
    4. 세션 worktree(python3 <hooks>/lib/wt_lib.py ensure --repo <프로젝트 루트> --sid <UUID> 로 확보)에서 git -C <worktree> add {변경 파일들} (git add -A/-u/. 금지 — 민감 파일 방지)
    5. git -C <worktree> commit -m "{이모지} {한국어 요약} by {모델계열}"
  미커밋_변경_없으면: 바로 1_프로젝트_push로 진행

1_프로젝트_push:
  명령: python3 <hooks>/lib/wt_lib.py push --sid <UUID> [--repo <세션 worktree>]   # 유일한 push 경로. --sid 필수, --repo 는 원본이 아니라 세션 worktree 이거나 생략(--sid 로 해석)
  sid_출처: --sid 의 UUID 는 메인=UserPromptSubmit hook 이 출력하는 `🆔 [UUID] {값}`(또는 compact 복원의 `- UUID: {값}`), 팀원=프롬프트 첫 줄 `PIPELINE_UUID=` 값이다. 메인 셸에는 세션 ID 환경변수가 없다. 반드시 36자 full UUID 인지 확인하고(예: 6690d4cc-b90e-4a8b-8bd9-64e78b500249), 파일·명령으로 탐색하지 않는다. --sid 없이 부르지 않는다.
  worktree_경로_추출: ensure 는 JSON 한 줄을 출력하며 키 `worktree` 가 경로다. WT=$(python3 <hooks>/lib/wt_lib.py ensure --repo <레포 루트> --sid <UUID> | python3 -c 'import sys,json; print(json.load(sys.stdin)["worktree"])'). ok 가 false 면 키가 없으므로 중단하고 error 를 보고한다. 직후 `: "${WT:?worktree 확보 실패}"` 로 빈 값을 검사한다. WT= 와 이후 git -C "$WT" 명령은 같은 셸 호출 안에서 실행한다(&& 로 이어 쓰면 다른 셸에서 실행돼 WT 가 빈다).
  원본에_이미_있는_변경: 순서는 ensure → adopt → 커밋 → push 다. python3 <hooks>/lib/wt_lib.py adopt --sid <UUID> [--repo <원본>] --paths <파일...> 로 지정한 파일만 세션 worktree 로 복사한 뒤 worktree 에서 커밋한다. 경로 없는 일괄 처리·디렉터리는 rc=2 로 거부되고 세션 worktree 가 없어도 rc=2 이므로 먼저 ensure 한다. adopt 전에 ensure 로 세션 worktree 기록이 먼저 있어야 한다. 원본은 그대로 두며, push 후 wt_lib 이 원본을 되돌리고 ff 하는 것은 사전조건(원본이 기본 브랜치, 채택 대상 외 추적 변경 없음, gated 저장소면 --apply-permit)이 모두 확실할 때뿐이다. 결과 JSON 의 adopt 해석은 이렇다. `kept(ff 불가: 사유 — 원본 내용 = push 내용)` 는 원본(live)에 새 판이 유지되고 ff 만 건너뛴 상태이므로 git status 로 원본 상태를 확인하고 사유(브랜치·타 추적 변경·permit)를 해소한 뒤 같은 push 를 다시 부른다(원본 dirty 의 타 변경은 지우거나 되돌리지 않는다). `mismatch` 는 원본 내용이 push 내용과 다른 채택 파일이 있어 전부 건드리지 않은 것이므로 원본 변경을 보존하고 보고한다. `cleared` 는 원본에 남은 변경이 없어 목록에서 지운 것, `restored` 는 되돌린 뒤 ff 실패로 push 된 내용으로 원본을 다시 써서 새 판을 유지한 것이다.
  설정: INFRA.md "Git Push" 절은 인증/Fallback 참조용. 원격·브랜치는 wt_lib 이 정본으로 판정하므로 하드코딩하지 않는다.
  금지: git 명령으로 직접 올리기, pull --rebase 수동 실행, 원격/브랜치 하드코딩, 강제 push(--force/+refspec/--mirror/--delete)
  전환기_호환: wt_lib.py 가 없는 환경(구 배포본)에서만 기존 방식으로 폴백하고 그 사실을 보고한다. 있으면 폴백 금지.
  게이트_대상_저장소: 적용 허가가 필요한 저장소는 --apply-permit 인자 또는 WT_APPLY_PERMIT=1 환경변수를 넘긴다.
  rc_대응:
    0: 성공 — 결과 JSON(remote·branch·sha·ff)을 보고
    2: 추적 변경이 남아 있음 — 0_커밋부터 하고 재실행
    3: rebase 충돌 — 즉시 중단 + 충돌 파일(conflicts)을 사용자에게 알림 (자동 해결·강제 push 금지)
    4: 정본 원격/기본 브랜치 판정 실패 — push 하지 않고 error 를 보고
    5: push 잠금 대기 시간 초과 — 잠시 후 1회 재실행, 재실패 시 보고
    6: push 거절/실패 — 내부 재시도 후 실패한 것이므로 error 를 알리고 계속(수동 확인 요청). error 가 "원격이 앞섬 — worktree 에서 push 하라" 이면 원본에서 부른 것이므로 --sid <UUID> 로 worktree 에서 재실행
    7: 원본 checkout 에서 push 했는데 원격보다 앞선 세션 worktree 가 있음 — 결과 JSON 의 ahead_worktrees 를 보고 --sid 누락 또는 --repo 오지정을 바로잡으므로 --sid <UUID> 로 재실행(성공으로 간주 금지). 원본에서 push 할 때 그 sid 의 worktree 기록이 전혀 없으면 세션명과 무관하게 원격보다 앞선 worktree 를 모두 내 것으로 보고 거부되므로, push 전에 ensure 를 먼저 하고(정상 경로에서는 기록이 생긴다) `--repo <세션 worktree>` 지정 또는 `--sid <UUID>` 로 재실행한다(기록이 있을 때만 타 세션 worktree 는 warnings 에만 실린다)
    8: 원본 checkout 의 현재 브랜치가 기본 브랜치가 아님 — push 하지 않았으므로 error 를 보고하고 세션 worktree 경유로 전환

2_dotfiles_push:
  감지: git -C ~/dotfiles status --porcelain
  변경_있음:
    git -C ~/dotfiles add -u
    커밋 메시지: "🔧 update: {변경 파일 요약}"
    python3 <hooks>/lib/wt_lib.py push --sid <UUID> --repo ~/dotfiles   # rc 대응은 1_프로젝트_push 와 동일
  변경_없음: 스킵

3_AI_repo_push:
  대상: 범용 스킬/hooks 원본 레포 (다른 프로젝트와 스킬을 공유하는 저장소)
  원칙: 원본 폴더에서 직접 add/commit/push 하지 않는다. worktree 에서 커밋하고 wt_lib push 로만 올린다.
  감지: 대상 레포의 git status --porcelain
  변경_있음:
    1. python3 <hooks>/lib/wt_lib.py ensure --repo <대상 레포 toplevel> --sid <UUID> 로 worktree 확보 (출력된 worktree 경로를 이후 모든 git 명령의 -C 대상으로 사용)
    2. worktree 에서 이번 작업으로 수정한 파일만 변경 반영 후 git -C <worktree> add {변경 파일명 명시} (git add -u/-A/. 절대 금지 — L-457)
    3. git -C <worktree> status --short 로 staged 개수가 의도한 파일 수와 일치하는지 확인
    4. git -C <worktree> commit -m "🔧 update: {변경 파일 요약}"
    5. python3 <hooks>/lib/wt_lib.py push --sid <UUID> --repo <worktree>   # 게이트 대상이면 --apply-permit / WT_APPLY_PERMIT=1, rc 대응은 1_프로젝트_push 와 동일
  변경_없음: 스킵
  실패_시: 경고 후 계속 (프로젝트 push는 이미 완료)
  ⚠️ 다중_세션_주의 (L-457): 이 저장소는 여러 Claude Code 세션이 공유한다. 타 세션의 미커밋 변경이 상시 존재할 수 있으므로
     git add -u/-A/. 는 타 세션 작업을 통째로 흡수한다. 반드시 이번 작업에서 실제로 수정한 파일명을 하나씩 명시해 add 하라.
  참고:
    - 이 레포의 skills는 다른 프로젝트와 하드링크 공유
    - 어떤 프로젝트에서 수정해도 이 레포에 변경이 감지됨 → 매번 체크 필수
    - hooks는 글로벌 hooks 디렉토리에서만 실행, 이 레포로 동기화 불필요
```

## ntfy 페이로드 생성 (파이프라인 내 호출 시에만)

```yaml
조건: PIPELINE_UUID 환경변수가 있을 때만 실행 (ok 파이프라인 내 팀에이전트)
시점: 3_AI_repo_push 완료 후
목적: ofinish step7이 읽어서 curl 발송
절차:
  1. UUID=$PIPELINE_UUID
  2. ntfy 토픽: INFRA.md 헤더 ntfy_topic
  3. 페이로드 생성:
     echo '{"topic":"{ntfy_topic}","title":"✅","message":"{커밋 메시지 제목}","tags":["white_check_mark"]}' \
       > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ntfy_payload.json"
  4. 검증: python3 -m json.tool "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ntfy_payload.json"
  경로_통일: odone·ofinish(ntfy_send.sh)와 같은 ${CLAUDE_CONFIG_DIR:-$HOME/.claude} 기준이다. $HOME/.claude 고정 경로에 쓰면 ofinish 가 읽지 못한다.
단독_호출_시: ntfy 페이로드 저장 스킵 (PIPELINE_UUID 없음)
금지:
  - opush에서 직접 ntfy 발송 (발송은 ofinish step7 담당)
  - -d @파일 방식 (Windows curl.exe가 WSL 경로 접근 불가 — L-272)
```

## 완료 보고 (파이프라인 내 호출 시)

```yaml
방법: SendMessage(to:"{리더명}", message:"opush 완료\n프로젝트/dotfiles/AI repo push 결과 요약", summary:"opush push 완료")
실패_시: 경고 포함 완료 보고 (push 실패가 파이프라인 블로킹 안 함)
```
