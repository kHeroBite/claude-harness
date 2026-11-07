---
name: osync
description: 지금 세션(프로젝트·롤)의 현재까지 대화를 마스킹한 사본으로 다른 머신에 보내, 그 머신에서 같은 프로젝트·롤로 접속(cc·ccc·claude --resume)했을 때 재개 목록에 보이게 하는 스킬. 상대 머신에 이 프로젝트·롤의 세션이 떠 있지 않다는 전제로 ssh 파일 전송만 쓰고 상대 세션과 통신하지 않는다. 사용자가 '/osync', '대화 동기화', '대화 보내', '다른 머신으로 대화' 를 요청할 때 사용. 자동 실행 없이 호출할 때 1회만 동작하며 파이프라인 state 를 바꾸지 않는 단독 스킬.
---

# osync — 현재 대화를 다른 머신으로 동기화

호출한 그 시점까지의 대화(transcript)를 마스킹한 사본으로 다른 머신에 보낸다. 대상은 프로젝트 INFRA.md 의 INFRA-FIELDS `peer_ssh` 로 정한다. 파이프라인 state·classification·status 를 바꾸지 않고 어느 state 에서도 쓴다. hook·타이머 같은 자동 실행은 없다. 필요할 때마다 다시 호출한다(같은 대화는 이어 붙은 판으로 덮인다).

## 전제 — 상대 머신에는 세션이 없다

- 상대 머신에는 이 프로젝트·롤의 Claude 세션이 떠 있지 않다고 본다. SendMessage·ListAgents·peer 통지 회신·상대 세션 생존 확인에 의존하지 않는다.
- ssh 로 파일만 넘기고, 같은 ssh 호출 안에서 상대 쪽 `conv_share.py recv-import` 가 상대 머신의 재개 위치(`<상대 홈>/.claude/projects/<작업폴더 인코딩>/<sid>.jsonl`)에 넣고 재개 색인(롤 포함)에 등록한다. 그래서 나중에 상대 쪽에서 `cc <프로젝트> <롤>`·`ccc`·`claude --resume` 으로 접속하면 목록에 보인다.
- 상대 쪽 작업폴더나 재개 위치(`<홈>/.claude/projects`)가 아직 없으면 꾸며 만들지 않는다. 사본은 상대 수신함에만 남기고 사유와 사용자가 할 일을 1줄로 알린다.

## 공통 규칙

```yaml
도구: 셸은 mcp__oio__bash_exec(dash) 만 쓴다. bash 문법·source 는 bash -c 로 감싼다.
세션_ID: hook 이 매 턴 출력하는 `🆔 [UUID]` 의 36자. 없으면 "세션 ID 를 알 수 없어 동기화하지 않습니다" 1줄로 멈춘다.
프로젝트_루트: git -C <cwd> rev-parse --show-toplevel. worktree 안이면 원본(주 작업트리) 폴더 이름이 프로젝트 이름이다.
프로젝트명: python3 -B "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/role_lib.py" project-slug --cwd <cwd>
롤: 넘기지 않는다. conv_share.py 가 role_lib current_role 로 이 세션 롤을 읽어 meta 에 넣는다.
스크립트_위치(앞이 우선): <프로젝트 루트>/.claude/scripts/conv_share.py → ${HARNESS_HOME:-$HOME/.harness}/current/scripts/conv_share.py → ${HARNESS_HOME:-$HOME/.harness}/current/scripts/conv_share.py. 모두 없으면 "conv_share.py 가 없어 동기화할 수 없습니다(배포본 갱신 필요)" 1줄로 멈춘다.
INFRA_파서: ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/infra_path.sh 의 infra_md_path·infra_field 를 bash -c 로 불러 쓴다(직접 파싱 금지).
금지: 프로젝트명·호스트명·절대경로를 이 스킬이나 명령에 박지 않는다(값은 위 규칙과 INFRA 값으로만 정한다). 출력에 자격증명·이메일·ntfy 토픽을 쓰지 않는다.
```

## 절차

1. 세션 ID·프로젝트 루트·프로젝트명·스크립트 위치를 위 규칙으로 정한다.
2. INFRA 값을 읽는다.
   ```bash
   bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/infra_path.sh"; f=$(infra_md_path "<프로젝트 루트>") || exit 1; echo "peer_ssh=$(infra_field "$f" peer_ssh)"; echo "peer_cwd=$(infra_field "$f" peer_cwd)"'
   ```
   - `peer_ssh` 가 비었거나 INFRA.md 가 없으면 "INFRA.md INFRA-FIELDS 에 peer_ssh 가 없어 보낼 대상이 없습니다" 1줄로 멈춘다.
   - `peer_cwd`(선택)는 상대 머신의 이 프로젝트 작업폴더 절대경로다. 없으면 상대 쪽이 자기 `CLAUDE_PROJECT_ROOTS`(없으면 기본 루트) 아래에서 프로젝트 이름으로 찾는다.
3. 보낸다.
   - `peer_ssh` 가 ssh 별칭이면
     `python3 -B <스크립트> push --sid <UUID> --project <프로젝트명> --place [--peer-cwd <peer_cwd>] <peer_ssh>`
   - `peer_ssh` 가 `outbox` 이면(이 머신으로 들어오는 ssh 만 되는 쪽)
     `python3 -B <스크립트> push --sid <UUID> --project <프로젝트명> --outbox`
   - 명령은 rc 를 반드시 확인한다(`; echo rc=$?`). stderr 를 버리지 않는다.
4. 결과를 1줄로 요약한다. 출력 줄에서 값을 그대로 옮긴다.
   - 크기·마스킹: `EXPORT ... lines=N bytes=B masked=M`
   - ssh 배치 성공(`PLACE ok cwd=<상대 작업폴더> dir=<상대 재개 폴더>`):
     `🔄 대화 동기화 — <B>바이트·<N>줄(마스킹 M건) → <peer_ssh> <상대 재개 폴더>. 상대에서 같은 프로젝트·롤로 cc·ccc 접속 시 재개 목록에 보입니다`
   - `PLACE none reason=no-cwd`: 상대에 프로젝트 작업폴더를 찾지 못했다. "상대 수신함에만 저장 — INFRA-FIELDS 에 peer_cwd: <상대 작업폴더> 를 넣거나 상대에서 ccc <프로젝트> 로 시작하면 가져옵니다"
   - `PLACE none reason=no-home`: 상대 머신에서 Claude 를 아직 한 번도 실행하지 않아 재개 위치가 없다. "상대 수신함에만 저장 — 상대에서 Claude 를 한 번 실행(로그인)한 뒤 /osync 를 다시 하거나 ccc 로 시작하면 가져옵니다"
   - `PLACE fallback reason=remote-old`: 상대 배포본이 구판이라 수신함에만 넣었다. "상대 배포본 갱신 전까지는 상대에서 ccc 로 시작할 때 가져옵니다"
   - outbox: "이 머신 송신함에 저장 — 상대 머신에서 ccc(또는 원격 접속 래퍼)로 이 프로젝트를 시작할 때 pull·import 되어 재개 목록에 보입니다"
5. 실패 처리. 고치지 말고 사유만 1줄로 알린다.
   - 크기 상한은 1GB(1073741824바이트)다. 상한을 넘으면 실패하지 않고 최신분만 잘라 보내며 출력에 `TRUNCATED` 줄이 나온다(rc=0). 최신 한 줄이 상한을 넘으면 rc=5 로 보내지 않는다. 받는 쪽도 새 판이어야 하며 구판은 rc=4 로 거부한다. 상한은 `CONV_SHARE_MAX_BYTES` 로 조정할 수 있으나 이 스킬은 바꾸지 않는다.
   - rc=3 ssh 연결 실패(상대 꺼짐·네트워크). 잠시 뒤 다시 `/osync`.
   - rc=2 사용법·검증 실패(sid·프로젝트·별칭·peer_cwd 형식), rc=1 transcript 없음 등 실행 실패, rc=4 상대가 일부 거부(sha 불일치·충돌).
   - 실패 기록은 스크립트가 `conv_share.log` 에 남긴다(본문 미기록).

## 동작 근거(conv_share.py)

- 마스킹(토큰·비밀번호·키·이메일·긴 hex/base64)과 1GB 상한(초과 시 최신분만 전송)은 export 가 그대로 적용한다. 원본 대화는 바꾸지 않는다.
- 상대 쪽 import 는 최상위 cwd 가 원본 작업폴더(또는 하위)인 줄만 상대 작업폴더로 바꾸고, 기존 로컬 기록이 수신본의 접두가 아니면 덮지 않고 충돌로 남긴다. 상대에서 재개하면 `cc` 가 `--fork-session` 으로 새 세션 번호로 이어 간다.
- 같은 판을 다시 보내면 상대 쪽은 `same` 으로 건너뛰고, 대화가 늘었으면 `extend` 로 이어 붙인다.

## 한계

- 상대 쪽 배치(recv-import)는 상대 배포본이 이 기능을 가진 판이어야 한다. 구판이면 수신함까지만 가고 상대 ccc 가 가져온다.
- outbox 방향(상대가 이 머신으로 ssh 할 수 없는 쪽)은 이 머신이 상대에 직접 넣을 수 없다. 상대가 ccc 로 시작할 때 가져간다. `cc` 로 바로 시작하면 그 전에는 보이지 않는다.
- 마스킹은 패턴 기반이고 서명 때문에 thinking 블록 본문은 마스킹하지 않는다. 양쪽 머신이 사용자 본인 소유일 때만 쓴다.
