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
> **프로젝트별 push 설정**: `Skill('oinfra_{project}')` Git Push 섹션 참조

## Commit & Push 절차

```yaml
0_커밋_확인_및_실행:
  git status로 미커밋 변경 확인
  미커밋_변경_있으면:
    1. git diff --stat 으로 변경 파일 파악
    2. git log --oneline -3 으로 커밋 메시지 스타일 확인
    3. 변경 내용 분석하여 한국어+이모지 커밋 메시지 생성
    4. git add {변경 파일들} (git add -A 금지 — 민감 파일 방지)
    5. git commit -m "{이모지} {한국어 요약} by {모델버전}"
  미커밋_변경_없으면: 바로 1_프로젝트_push로 진행

1_프로젝트_push:
  명령: git push
  설정: oinfra_{project} Git Push 섹션 참조 (인증/Fallback 포함)
  실패_시: 경고 출력 후 재시도 1회. 재실패 시 사용자에게 알리고 계속.

2_dotfiles_push:
  감지: git -C ~/dotfiles status --porcelain
  변경_있음:
    git -C ~/dotfiles add -u
    커밋 메시지: "🔧 update: {변경 파일 요약}"
    git -C ~/dotfiles push
  변경_없음: 스킵

3_AI_repo_push:
  경로: /mnt/c/DATA/Project/AI (범용 스킬/hooks 원본 레포)
  감지: git -C "/mnt/c/DATA/Project/AI" status --porcelain
  변경_있음:
    git -C "/mnt/c/DATA/Project/AI" add {변경 파일명 명시} (git add -u/-A/. 절대 금지 — L-457)
    git -C "/mnt/c/DATA/Project/AI" status --short 로 staged 개수가 의도한 파일 수와 일치하는지 확인
    커밋 메시지: "🔧 update: {변경 파일 요약}"
    git -C "/mnt/c/DATA/Project/AI" commit -m "🔧 update: {변경 파일 요약}"
    git -C "/mnt/c/DATA/Project/AI" push
  변경_없음: 스킵
  실패_시: 경고 후 계속 (프로젝트 push는 이미 완료)
  ⚠️ 다중_세션_주의 (L-457): 이 저장소는 여러 Claude Code 세션이 공유한다. git status에 타 세션의
     미커밋 변경이 상시 존재할 수 있으므로 git add -u/-A/. 는 타 세션 작업을 통째로 흡수한다.
     반드시 이번 작업에서 실제로 수정한 파일명을 하나씩 명시해 add 하라.
  참고:
    - AI repo의 skills는 다른 프로젝트와 하드링크 공유
    - 어떤 프로젝트에서 수정해도 AI repo에 변경이 감지됨 → 매번 체크 필수
    - hooks는 ~/.claude/hooks/ (글로벌)에서만 실행, AI repo로 동기화 불필요
```

## ntfy 페이로드 생성 (파이프라인 내 호출 시에만)

```yaml
조건: PIPELINE_UUID 환경변수가 있을 때만 실행 (ok 파이프라인 내 팀에이전트)
시점: 3_AI_repo_push 완료 후
목적: ofinish step7이 읽어서 curl 발송
절차:
  1. UUID=$PIPELINE_UUID
  2. ntfy 토픽: oinfra_{project} ntfy 섹션 참조
  3. 페이로드 생성:
     echo '{"topic":"{ntfy_topic}","title":"✅ 작업 완료","message":"{커밋 메시지 제목}","tags":["white_check_mark"]}' \
       > "$HOME/.claude/session-env/${UUID}/ntfy_payload.json"
  4. 검증: python3 -m json.tool "$HOME/.claude/session-env/${UUID}/ntfy_payload.json"
단독_호출_시: ntfy 페이로드 저장 스킵 (PIPELINE_UUID 없음)
금지:
  - opush에서 직접 ntfy 발송 (발송은 ofinish step7 담당)
  - -d @파일 방식 (Windows curl.exe가 WSL 경로 접근 불가 — L-272)
```

## 완료 보고 (파이프라인 내 호출 시)

```yaml
방법: SendMessage(to:"{리더명}", message:"opush 완료\n프로젝트/dotfiles/AI repo push 결과 요약", summary:"opush git push 완료")
실패_시: 경고 포함 완료 보고 (push 실패가 파이프라인 블로킹 안 함)
```
