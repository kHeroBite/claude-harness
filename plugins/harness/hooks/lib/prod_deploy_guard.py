# 에이전트(메인·팀)의 운영 배포·승격·운영 데몬 조작 명령을 프로젝트 설정 목록으로 판정해 차단하는 PreToolUse 코어
"""
입력: stdin = PreToolUse hook JSON (Bash / mcp__oio__bash_exec / 파일 쓰기·복사·이동 도구)
env : PDG_HOOK_DIR(필수 — 비상 스위치 위치), PDG_SWITCH_TTL_MIN(기본 30), PDG_NOW(테스트용 epoch)
출력: 차단 시 stdout 에 PreToolUse deny JSON. 통과 시 무출력.

설정(프로젝트 고유 — 범용 hook 은 목록을 갖지 않는다): <프로젝트>/.claude/prod_deploy_guard.json
  rules[]: {id, match_all:[정규식...], unless_any:[정규식...], reason}  — 명령 문자열에 match_all 전부 일치 + unless_any 무일치 → 차단
  file_op_rules: [rule id...] — 파일 복사·이동·이름변경·링크의 원본/대상 경로가 이 규칙에 일치하면 차단(우회 실행 준비 방지)
  file_op_exempt: [정규식...] — (선택, c185) 파일 복사·이동·이름변경·삭제의 ★대상(결과가 놓이는 곳)★ 이 전부 설정이 속한
    프로젝트 루트(realpath) 안이고 그 상대경로가 이 영역에 맞으면 file_op_rules 판정을 건너뛴다. 키가 없으면
    script_write_exempt 를 쓰고, 키를 명시하면(빈 배열 포함) 폴백하지 않는다. 링크 생성·디렉터리 조작·셸 명령은 예외 없음.
    ⇒ 예외 영역 안 스크립트는 고치고 갈아 끼울 수 있다(수정 허용). 실행(셸)과 영역 밖으로 꺼내기는 종전대로 차단.
  exec_block_dirs: [정규식...] — (선택, c186) 셸 실행 차단 영역. 설정이 속한 프로젝트 루트 기준 상대경로("/"+rel, 디렉터리는
    끝에 "/")가 이 영역에 맞는 스크립트를 셸로 실행하면 차단한다(규칙 id exec_in_block_dir). 실행 대상은 ★유효 작업 디렉터리★
    (도구 working_dir/workdir/cwd · hook cwd · 명령 안 cd/pushd/cd /d/env -C 등) 기준으로 풀어 판정한다.
    키가 없으면 file_op_exempt 를 ★명시한★ 경우에만 그 값을 쓴다 — 전제: "파일 수정 허용 영역 = 실행 차단 영역".
    이 전제가 맞지 않는 프로젝트는 exec_block_dirs 를 명시하라. script_write_exempt 로는 폴백하지 않는다. 둘 다 없으면 기능 꺼짐.
  exec_block_unless: [정규식...] — (선택, c186) 영역 안이어도 실행을 허용할 대상(같은 상대경로 기준). exec_block_reason: 차단 문구(선택).
  exec_allow: [{path, sha256, args_re, rules}] — (선택, c196) 해시·인자 고정 실행 예외(빌드 래퍼 등). path 는 설정 프로젝트 루트
    기준 상대경로("/" 로 시작), sha256 은 그 파일의 64자리 16진 해시, args_re 는 인자 토큰을 공백 하나로 이은 문자열에 fullmatch 하는
    정규식, rules 는 그 구간에서만 판정을 빼는 규칙 id 목록(exec_in_block_dir 는 항상 포함). 아래를 ★모두★ 충족한 구간만 예외다 —
    따옴표 혼동 없음·$ ` < > ( ) { } 없음(무해 리다이렉트 제거 후), 앞뒤 구분자가 | · 단일 & 아님, 구간 = `bash <경로> 인자…` 또는
    `<경로(/ 포함)> 인자…`(환경 대입·env·sudo·nohup·timeout 등 접두, bash 옵션, source·.·sh·dash 형태 불가), 명령에 cd/pushd/popd/chdir
    구간 없음, 상대경로는 모든 작업 디렉터리 후보에서 같은 realpath, realpath 일치·정규 파일·1 MiB 이하·실행 시점 sha256 일치,
    인자에 $ ` 글롭 문자 없음, 명령의 나머지 구간은 전부 엄격 읽기전용. 판정 중 오류는 예외 없음(종전 판정 — fail-closed).
    키가 없으면 무동작. 설정 파일은 가드 자기 보호 대상이라 사용자만 편집한다.
    잔존 한계(정직 고지): 래퍼를 정당하게 고칠 때마다 사용자가 sha256 을 다시 적어야 한다(불일치면 자동 재차단). 판정 직후~실행
    사이 다른 프로세스의 파일 교체 경쟁은 막지 못한다. 래퍼가 부르는 dotnet csproj Exec 타깃 등 간접 실행은 기존 dotnet build 와
    같은 등급이다.
  script_write_exempt: [정규식...] — 스크립트 파일(.sh/.bat/.cmd/.ps1/.py) 쓰기 내용 검사에서 제외할 경로
  설정 탐색: 입력 cwd·CLAUDE_PROJECT_DIR·도구 working_dir 와, 명령/경로에 등장하는 절대경로의 상위 디렉토리를 올라가며
  .claude/prod_deploy_guard.json 을 찾는다(여러 개면 모두 적용). 설정이 없으면 통과.

셸 명령 판정(conv_179163042411): 명령을 구간(; && || | 줄바꿈)으로 나눠 "엄격 읽기전용" 구간만 건너뛴다.
  엄격 읽기전용 = 조회 동사 + 명령 치환($( ) · 백틱 · <( ) · >( ))·환경변수 접두(LC_ALL/LANG 외)·sudo·출력 리다이렉트·heredoc 없음
  + 동사별 실행·쓰기 옵션 없음(find -exec/-delete/-fprint, sed 는 -n + 행 출력 스크립트만, sort -o/--compress-program,
  git -O/--output/--open-files-in-pager/--ext-diff, rg --pre, iconv -o, xxd -r/출력파일, uniq 출력파일, file -C).
  무해 리다이렉트(N>/dev/null, N>&M)는 판정 전에 지운다. bash -c '<내용>' 단독 구간은 내용을 같은 기준으로 재판정(깊이 2).
  ⇒ 치환·find -exec·sed e·git -O 등 안에 숨긴 배포 명령도 규칙 판정에 걸린다(종전에는 읽기 구간으로 보고 건너뛰었다).
  따옴표 혼동 방지: 원문에 백슬래시·# 이 있거나 따옴표 안 개행이 있으면 어떤 구간도 읽기전용으로 보지 않는다
  (분할기가 \\' 이스케이프·# 주석을 몰라 `echo \\'; cp …`·`echo x #'⏎cp … #'` 를 한 구간으로 오인하던 우회 차단).
  c196: printenv 와 인자 없는 env 는 조회 동사다(인자 있는 env 는 실행 접두 — 종전대로 비조회). git 은 --no-pager · -C <dir>(분리형)
  전역 옵션을 건너뛴 뒤 서브명령을 본다(-c·--git-dir·--work-tree·-p 등 그 밖의 전역 옵션은 종전대로 비조회). 따옴표 혼동 때문에
  조회 면제가 꺼져 차단된 경우(혼동만 없으면 전 구간이 엄격 읽기전용)에는 차단 문구에 작은따옴표 사용 안내(QUOTE_HINT)를 붙인다
  — 판정 결과는 바꾸지 않는다. 인자 없는 env 는 환경변수 전체를 출력한다: 이 가드의 목적(배포 실행 차단) 밖이고
  printenv X·echo $X 로 이미 읽히던 정보라 새 구멍이 아니다.

c213 과차단 해소(사용자 지시 2026-10-26 "운영 배포가 아닌데 불필요하게 막지 마라" · "과차단 재발을 막아라"):
  ① 비실행 인자(NX) 면제 — 허용 목록 방식. 인자를 실행하지 않는 구간만 규칙 정규식 대상에서 뺀다(_nonexec_args).
     git: --no-pager·-C 뒤 하위명령이 add commit push status diff log show blame grep ls-files cat-file check-ignore rev-parse,
       금지 옵션(_long_hit: --exec --receive-pack --upload-pack --output --open-files-in-pager --ext-diff --push-option
       --config-env --exec-path, 단일 대시 -O·-o 묶음·정확히 -c·-x), push 인자 :: (ext::·fd:: 원격 도우미),
       add 의 -p/-i/-e·--edit 류 거부. commit 은 -m/--message/-F/--file 필수(없으면 에디터 경로), 메시지에 실행 동사와 규칙
       일치가 함께 있으면 NX 아님.
     sed: 옵션 -i[접미사]·--in-place[=S]·-n·--quiet·-E·-r·-e·--expression 만, 스크립트는 [주소]s///[g p I i 숫자]·d·p 만
       (e w W m M 플래그·e w r R y a i c 명령·& · \\숫자 역참조 거부), 각 s 치환부(이스케이프 해제)가 규칙에 걸리면 NX 아님.
       패턴부는 보지 않는다(증거 문구 치환 과차단 해소).  shellcheck: 파일을 읽기만 한다.
     공통: 작은따옴표 밖 $ · 백틱 · < · > 없음, shlex 성공, LC_ALL/LANG 외 환경 접두 없음, 첫 낱말 / 는 SAFE_BIN_DIRS 만.
     명령 단위 전제(_nx_cmd_ok): 함수 정의(`()`·function)·상태 내장(source·alias·export·set·shopt·enable·hash …)·환경 대입·
       실행기 구간(셸·env·nohup·timeout·xargs·find·해석기·로컬 실행 파일 — 엄격 읽기전용인 bash -n 등은 제외)이 하나라도 있으면
       NX 를 통째로 끈다(이름 가로채기·PATH 바꿔치기 차단, 글롭 실행 앞 git add 가 면제 덕에 새로 통과하지 않게). amb 이면 NX 없음.
     교차 판정: 파이프 묶음은 모든 구간이 _droppable 또는 NX 일 때만 버린다 — 실행기가 섞인 묶음은 NX 구간까지 남긴다.
  ② 자기 보호: GIT_READ_SUBS 에 check-ignore·rev-parse 추가, git 색인 반영(_git_index_only)에 push(리터럴 원격·refspec,
     -u·--set-upstream·-q·--tags·--follow-tags·-v 만, :: 거부) 추가.
  ③ 이름 보존 복사(_name_keep_copy): file_copy 이고 basename(대상)==basename(원본)·대상 절대경로·hook 디렉터리 밖·가드 경로 아님이면
     file_op_rules 판정 생략(사본도 같은 이름이라 실행 시 같은 규칙에 걸린다). 개명 복사는 종전대로 차단.
  ④ 차단 원문 로그(_block_log): 모든 차단 경로(rule·self-modify·self-switch·self-file)에서 <HOOK_DIR>/logs/
     prod_deploy_guard_blocks.jsonl 에 1줄(ts·kind·rule·who·tool·cwd·session_id·마스킹 명령 최대 4000자·paths).
     tool_input.env 계열은 기록하지 않는다. 화면 승인 통과는 기록하지 않는다. 5 MiB 초과 시 .1 로 1회 회전.
  잔존 한계(정직 고지 — 이번 변경이 새로 만든 구멍이 아닌 기존 미탐 포함):
     ⓐ `cat() { bash "$@"; }; cat <배포 스크립트>` — 엄격 읽기전용 경로의 함수 가로채기(NX 전제는 NX 면제에만 적용).
     ⓑ 글롭으로 이름을 숨긴 실행(`bash ./Deploy/dep*`). ⓒ 다른 파일·저장된 메시지 내용의 실행(`cat x.txt | bash`,
        `git log -1 --format=%B | bash`) — 정적 판정 불가. ⓓ git 저장소 설정(hooksPath·filter·pager·alias·textconv)을 미리 바꿔 두면
        add/commit/push/diff 가 코드를 실행할 수 있다(기존 한계와 같음). ⓔ 커밋 메시지를 저장한 뒤 다른 호출에서 실행하는 2단계.

c214 커밋·조회 명령 과차단 재발 방지(사용자 지시 2026-10-26 "커밋이 운영 배포 가드에 막히지 않도록 수정해서 재발방지하라"):
  T1 _q_strip — NX 판정의 < > 는 작은·큰따옴표 밖에서만 거부(커밋 트레일러 <email> 이 commit 구간 NX 를 끄던 원인). $ · 백틱은 종전.
  T2 _msg_exec_shape — 커밋 메시지 실행 모양 판정(종전 LOW-2: 메시지 어디든 실행 동사 + 규칙). 규칙 일치 전제 + ① 점 실행 절
     ② 메시지를 줄·; & | ( ) { } $( ` <( >( 로 자른 조각의 명령 자리 첫 낱말이 실행기·해석기·source/eval/exec/command/builtin 이고
     그 조각이 규칙에 걸림 ③ 실행 동사 바로 뒤 낱말(옵션 건너뜀)이 규칙에 걸림 ④ (리뷰 M1) 명령 자리 첫 낱말이 경로(/)·규칙 이름인
     조각과 실행 동사인 조각이 함께 있음(메시지를 셸에 넘기면 "경로; bash" 순 실행). "SSH 비밀번호"·"timeout 처리"·"env 정리"·
     "경로 실행은 bash 5 에서" 같은 서술만 풀린다. _commit_msg_split — 따옴표 구분자 heredoc 커밋 메시지를 규칙 판정 전용으로
     -m 'MSG' 로 바꾼다(본문이 실행 모양이면 정규화 안 함).
  T3 _ansi_safe — 따옴표 밖 $'…' 내용이 일반 글자와 \\r \\n \\t \\\\ \\0 뿐이면 '…' 로(규칙 판정 전용). \\x \\u 8진 \\' 가 하나라도 있으면 원문.
  T4 _strict_readonly — command -v|-V 이름… 은 위치 조회. _nx_cmd_ok 의 상태 동사 거부에서 그 구간만 예외(command x · -p 는 실행).
  T5 _droppable — 첫 낱말이 셸이 아니면 $ · 백틱 · 괄호를 작은따옴표 밖에서만 센다(grep 'x$' · grep '^f()' 조회 파이프 과차단).
  D-1 _heredoc_norm(규칙 판정 전용, raw·정규화 양쪽 치환 수가 같을 때만): 읽기 소비자(cat grep head tail wc sort uniq)이고 그
     파이프 묶음의 다른 구간이 전부 _droppable·NX, 출력 리다이렉트 대상이 문서 확장자뿐이면 본문을 HEREDOC 로 바꾼다. 본문을 파일에
     쓴 경우 명령의 나머지 구간이 전부 엄격 읽기전용·버림 가능·NX 여야 한다(문서에 쓰고 곧바로 셸로 실행 차단). python[3] - 소비자는
     .py 쓰기와 같은 기준(규칙 무일치 또는 _PY_EXEC_RE 무일치)이고 파이프·리다이렉트가 없을 때만. 따옴표 없는 구분자는 본문에
     $ · 백틱 · \\ 가 없을 때만. bash/sh/perl/node 등 실행기·tee·<<< 는 원문. 한 줄 heredoc 둘·종결 줄 불일치도 원문.
  D-1 _py_strip_comments·_py_comments_only — .py 쓰기 내용이 규칙에 걸리면, 그 규칙이 주석 텍스트만으로도 성립하고 COMMENT 토큰을
     지운 본문은 어떤 규칙에도 안 걸릴 때만 통과(주석 속 이름만 풀림). 조건이 주석·코드에 나뉜 조합(고정 C18-D6)·토큰화 실패는 종전. _PY_EXEC_RE 보강(fail-closed): startfile·asyncio·__builtins__·globals(·getattr(os|sys|builtins·code.·interact·
     sys.modules 추가(exec( eval( __import__ importlib runpy ctypes 는 종전부터).
  D-3 _bash_n_read·_awk_read(배포 규칙 판정 전용 — 구간 판정·교차 판정·_nx_cmd_ok 실행기 판정에서만, 자기 보호 무변경):
     bash|sh|dash -[nvx]…(n 포함) 파일 1개 구문검사, awk -F 만 + 프로그램에 system·getline·close·fflush·|·>·@·ENVIRON·PROCINFO 없음.
     bash -n -c · bash -ne · 뒤 구간 실행·| bash 는 종전 판정(차단).
  D-16 셸 교차 판정(_match_cmd 파이프 묶음 버림)에서만 조회 동사(DROP_V_OK_VERBS: grep·egrep·fgrep·rg·cat·head·tail·ls·nl)의 -v 를
     상태 변경으로 보지 않는다(_droppable v_ok). git add·diff·status·log 경로 인자 + `2>&1 | grep -v …` 스테이징 사슬 과차단 해소.
     printf·test·awk 등 목록 밖 -v·스크립트 쓰기 재판정(고정 C18-D36)·heredoc 정규화·실행 결합(| bash·&& ./…)은 종전.
  잔존 한계(정직 고지): ⓕ 규칙 이름이 명령 어디에도 없는 실행(문자열 조립 importlib·hex exec — 규칙 판정 밖, c213 과 같음).
     ⓖ 저장된 메시지를 awk·sed 로 재조립해 실행하는 2단계는 메시지 판정으로 못 막는다(ⓔ 와 같은 계열).
     ⓗ .sh 쓰기 내용의 주석 속 이름은 여전히 판정 대상(과차단 쪽, 별건).

cgit 일반 git 명령 과차단 해소(사용자 지시 2026-10-27 "git 명령을 가드에서 막지 않도록 해달라"):
  A1 _quoted_msg_norm — git commit·tag·notes add|append 의 -m/--message(commit 은 -am 포함) 바로 다음 인용 낱말 하나와
     --message=<인용> 을 규칙 판정·자기 보호 판정 전용으로 'MSG' 로 바꾼다(_commit_msg_split·_commit_msg_literal 뒤 단계).
     원인(실측 10-27 09:39:48·09:39:59): 메시지 따옴표 안 실제 개행 → _quote_ambiguous=True → NX 면제 전체가 꺼져 메시지 속 배포
     스크립트 이름이 규칙에 걸렸다. 작은따옴표는 내용 무제한, 큰따옴표는 $ · 백틱 · \\ · \" 가 없을 때만. 본문이 실행 모양
     (_msg_exec_shape — 점 실행 절 등)이면 _rule_hit 가 정규화를 통째로 버린다. 명령 어디든 \\ · << · 따옴표 밖 # · $'…' · 함수 정의 ·
     구간 머리 대입·상태 내장이 있거나 git 전역 옵션이 --no-pager · -C <리터럴> 밖(-c 등)이면 정규화하지 않는다(종전 판정).
     원문에 \\ 가 있으면 변환본(cmd_n)에도 하지 않는다(_win2wsl 이 \\ 를 / 로 바꿔 따옴표 경계가 달라질 수 있다).
     명령이 NX 명령 단위 전제(_nx_cmd_ok — 실행기·함수·상태 내장·대입 없음)를 어기면 하지 않는다(고정 C214-X33: 같은 명령의
     `git log -1 --format=%s | bash` 가 저장한 메시지를 곧바로 실행). 정규화한 구간이 NX 구조(_nx_git — tag -s·-e, notes -e,
     commit --edit 등 거부)가 아니면 그 구간은 정규화하지 않는다.
  A2 _timeout_git — `timeout [-k 시간|-s 신호|--foreground|--preserve-status|-v] 시간 git …` 은 git 부분이 NX 일 때만 NX
     (_nonexec_args), git 부분이 NX 구조이고 $ · 백틱이 없으면 _nx_cmd_ok 실행기 판정에서 뺀다. timeout bash · timeout git -c 는 종전 차단.
  A3 _nx_git_tag·_nx_git_notes — tag 는 -a·-f·-d·-l·-n·-m·-F(+장옵션)만, -s·-u·-e·--cleanup 등 거부, 주석 태그 메시지 없음(에디터) 거부.
     notes 는 add|append + 메시지 필수 + 대상 1개 이하. 메시지는 _msg_exec_shape 검사.
  A4 _git_index_sub·_xargs_git_index — 인덱스 전용(작업 트리 불변) git: restore --staged|-S [-q] · rm --cached [-r] [-q] ·
     reset [-q] -- 경로 / reset [-q] HEAD [--] 경로 · xargs [-r|--no-run-if-empty] git <그중 하나> --(끝 -- 필수).
     -W·-SW·--worktree·--source·-s·--no-staged·--no-cached·-p·--overlay·-f·--hard·--soft·--mixed·--merge·--keep·HEAD 외 커밋 거부.
     자기 보호(_git_index_only)와 NX(_nx_git·_nonexec_args·_nx_cmd_ok) 양쪽에 적용.
  A6 사용자 지시 2026-10-27 10:52 "위험한 git도 막지 말고 그대로 진행해라"(리드 판단 — 운영 배포 실행 결합 X1~X9 와 가드 파일 디스크
     내용을 바꾸는 git 은 F-GUARD-PROMOTE 절대 규칙으로 유지, 디스크를 바꾸지 않는 git 은 자기 보호에서 해제):
     push --force 계열(-f·--force·--force-with-lease[=…]·--force-if-includes)·--delete·--mirror·--all·--prune·--atomic·--no-verify·--dry-run,
     reset --soft·--mixed·커밋 지정, restore --staged --source, rm --cached -f·-n·--ignore-unmatch, commit --amend(--no-edit)·--no-verify·
     --allow-empty·-s·--author=, add -A·-u·-f·-N·-n, tag·notes(구조 판정) 를 _git_index_only 가 허용한다. commit -a 는 고정 GI-D7 로 유지.
     실행 옵션(push --receive-pack·--exec·--upload-pack·-o·::)·작업 트리 변경(restore 작업트리·reset --hard/--merge/--keep·checkout·stash·
     clean·rm)·git config(자기 보호) 는 종전대로 차단. 배포 규칙 판정(NX 밖)은 git 위험 형태를 따로 막지 않는다 — 배포 이름이 인자에
     있을 때만 판정하며, checkout·switch·stash·clean·restore/reset 작업 트리 형태는 NX(비실행)로 본다. git config 는 조회 형태와
     실행 무관 키(user.*·core.autocrlf·core.quotepath 등 GIT_CONFIG_SAFE_KEY_RE) 설정만 NX — alias·core.hooksPath·core.sshCommand·
     core.pager·core.fsmonitor 등 실행 통로 키는 종전(배포 이름이 있으면 차단, F-5 결정은 사용자 10:52 지시로 대체).
  R1 역라우팅(ai-28 원문 2026-10-27 11:51:31 — 승격 산출물 커밋 준비 `B=<경로>; git add -- … $B/…` 가 자기 보호에 막힘):
     _all_strict_or_git_index 가 안전 리터럴 순수 대입(_pure_assign_names·_assign_refs_ok — _all_strict 의 c206 F-2① 과 같은 기준)을
     인정하고, 뒤 구간의 단어 머리 $이름·${이름} 을 리터럴 값으로 펼친 뒤 git 색인·엄격 읽기전용 판정을 한다. 대입 전 참조·단어 중간 참조·
     위험 이름(GIT_*·PATH 등)·남은 $ 확장($? 제외)은 거부. 펼친 구간에 rm·cp·checkout·실행기가 있으면 종전대로 차단.
  잔존 한계(정직 고지): 같은 uid 의 git 설정 변조(hooksPath·alias·filter·서명 프로그램 gpg.program·core.editor)는 종전대로 판정 밖이다.
     저장된 메시지를 나중에 실행하는 2단계(ⓔ)는 종전 한계 그대로다. 정규화는 규칙·자기 보호 판정 전용이며 명령은 바꾸지 않는다.

unblock3 남은 git 예외 전면 해제(사용자 지시 2026-10-27 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라"):
  화면 결정 ① "결합 형태도 전부 해제" — git 이 결합된 셸 명령은 운영 배포 가드에서 모두 통과, git 뒤에 붙인 deploy.sh 도 통과
     (사용자가 알고 선택). 화면 결정 ② "자동 원복까지 해제" — 보호 파일의 git 변경 허용. ③ 메인 W5 는 write_guard 소관.
  U1 _git_composite — 셸 명령(커밋 메시지 정규화 후)에 git 머리 구간(_git_head)이 하나라도 있으면 2) 규칙 판정 전체(규칙·X1~X9·
     실행 통로 config·push 실행 옵션·commit -a GI-D7·C214-X33·exec_block_dirs·cwd/문서 실행)를 생략한다. 화면 승인 코드는 무변경.
  U2 _self_git_ok — 자기 보호(1)에서 모든 구간이 git 머리 구간(따옴표 밖 쓰기 리다이렉트·명령 치환 없음) 또는 엄격 읽기·cd 이면 통과.
  유지(정직 고지): 비 git 쓰기 구간(git status; rm <가드 파일>)·git 구간의 리다이렉트 쓰기·비상 스위치 생성 판정·파일 도구 자기 보호·
     git 없는 단독 deploy.sh·bash -c '…git…' 안쪽(바깥이 bash — 가정 1)·따옴표 혼동 소지 명령은 종전 판정. pdg_hook 래퍼 fail-closed 유지.

비상 해제: <hook 디렉토리>/DISABLE_PROD_DEPLOY_GUARD 파일, mtime 이 TTL(30분) 이내일 때만 유효(가드 전체 BYPASS).
  환경변수 우회는 없다(에이전트가 스스로 설정할 수 있으므로). 에이전트는 이 스위치를 만들거나 지우지 않는다.
  자기 보호: 스위치 이름을 담은 셸 명령은 엄격 읽기전용이고 스위치 이름이 경로 토큰(/ 포함)에 없을 때만 통과(이름 조회·grep 허용),
  가드 파일명을 담은 셸 명령 중 엄격 읽기전용이 아닌 것, 가드 파일(hook·코어·설정)·스위치·그 상위 디렉토리를 건드리는
  파일 도구 호출은 항상 차단한다(사람 승인 예외 없음).
승격 경로(가드 파일 교체 — 배포 실행 승인이 아니다): 가드 코어·hook 교체는
  `bash <hooks>/lib/guard_promote.sh promote <id> --core <후보> [--test <후보 시험>]` 로만 자동 반영된다.
  그 스크립트가 등록부(lib/guard_promote.json)의 고정 회귀 시험·카나리·통과 건수 기준을 모두 통과한 후보만 원자 교체한다.
운영 배포 규칙에 걸린 명령은 기본적으로 에이전트가 실행하지 않는다 — 그 단계만 건너뛰고 나머지를 끝까지 진행하며,
  최종 보고의 운영 배포 보류 목록에 명령 1줄을 남긴다. 예외는 아래 화면 승인 1가지뿐이다.

화면 승인(2026-10-24 사용자 결정 — 셸 규칙 차단 전용):
  대상: 셸 도구(Bash·mcp__oio__bash_exec)의 2단계 설정 규칙 차단만. 자기 보호(가드 파일·스위치)·파일 도구 차단·
    스크립트 쓰기 내용 판정은 승인 대상이 아니다(항상 차단). 비상 스위치와는 독립(스위치를 만들거나 읽지 않는다).
  성립 조건(전부 충족 — 하나라도 어긋나면 종전대로 차단, 판정 오류도 차단):
    ① hook 입력에 agent_id 가 없다(팀원 거부).
    ② session_id 가 UUID 형식이고 transcript_path 가 메인 세션 원본이다 — 절대경로, basename == session_id + ".jsonl",
       /subagents/ 없음, 조부모 디렉터리 이름 projects, realpath 가 일반 파일.
    ③ 트랜스크립트 끝 8 MiB 안에 AskUserQuestion tool_use 가 있고, header == '승인:PROD_DEPLOY' 인 질문 본문에 고정 문구와
       ``` 블록이 정확히 1개 있으며 블록 내용이 실행할 명령 원문과 완전히 같다(공백 정규화 없음). 도구 working_dir/workdir/cwd 를
       쓰면 본문(블록 밖)의 '작업 디렉터리: <값>' 줄이 그 값과 같아야 하고, 쓰지 않으면 그 줄이 없어야 한다.
    ④ 입력에 answers/annotations 가 없다(위조 거부), isSidechain 아님, 질문·결과 항목에 agentName/teamName 없음,
       항목 sessionId(있으면) == session_id.
    ⑤ 결과 항목: tool_result 가 오류가 아니고 permissionDecision 이 accept·source user*, sourceToolAssistantUUID 일치,
       answers[질문] == '승인 (10분 1회)', timestamp 가 10분 이내(미래 60초 초과 금지).
    ⑥ tool_use_id 가 소비 기록에 없다 — 통과 시 flock 아래 1줄 기록(1회용).
  소비 기록: <hook 디렉토리>/logs/prod_deploy_guard_approval_consumed.log (이름에 가드명이 있어 자기 보호 대상).
  막는 우회: 다른 명령 바꿔치기·인자 추가(원문 완전 일치), 재사용(1회용), TTL 만료, 팀원 승인, 타 세션 승인,
    answers 위조 호출, 다른 작업 디렉터리 실행, 소비 기록 삭제(자기 보호).
  잔존 한계(정직 고지): 같은 uid 의 일관된 트랜스크립트 위조는 write_guard F-ASKQ-PROT 만 막는다(변수 간접화 여지).
    승인은 명령 문자열에만 묶인다 — 승인 뒤 스크립트 내용이 바뀌면 다른 동작이 실행된다. hook 입력의 agent_id·
    session_id·transcript_path 는 Claude Code 가 채운다는 전제다. hook 래퍼 머리 주석의 '질문·대기 없음' 은 낡은 표현이다.
"""
import datetime
import glob
import hashlib
import json
import os
import re
import shlex
import sys
import time

HOOK_DIR = os.environ.get("PDG_HOOK_DIR", "")
try:
    TTL = int(os.environ.get("PDG_SWITCH_TTL_MIN", "30"))
except ValueError:
    TTL = 30
try:
    NOW = int(os.environ.get("PDG_NOW", "") or time.time())
except ValueError:
    NOW = int(time.time())

SWITCH_NAME = "DISABLE_PROD_DEPLOY_GUARD"
SELF_NAMES = ("prod_deploy_guard",)  # hook·코어·설정 파일명 공통 부분
CONF_REL = os.path.join(".claude", "prod_deploy_guard.json")
SCRIPT_EXT = (".sh", ".bat", ".cmd", ".ps1", ".py", ".bash")
BASH_TOOLS = ("Bash", "mcp__oio__bash_exec")
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "mcp__oio__file_write", "mcp__oio__file_edit")
FILEOP_TOOLS = ("mcp__oio__file_copy", "mcp__oio__file_move", "mcp__oio__file_rename", "mcp__oio__file_symlink",
                "mcp__oio__file_delete", "mcp__oio__dir_move", "mcp__oio__dir_rename", "mcp__oio__dir_delete")
PROMOTE_GUIDE = ("가드 코어·hook 교체는 `bash <hooks>/lib/guard_promote.sh promote <id> --core <후보> [--test <후보 시험>]` "
                 "경로로만 자동 반영된다(고정 회귀 시험 전체 통과 시 원자 교체). 직접 편집·삭제·이동은 항상 차단된다.")
HOLD_GUIDE = ("운영 배포는 에이전트가 실행하지 않는다. 이 단계만 건너뛰고 나머지를 끝까지 진행하라. "
              "최종 보고의 운영 배포 보류 목록에 명령 1줄을 적어라. "
              # c199f C8: 화면 승인 채널(APPROVAL_GUIDE)과 한 거부 문구 안에서 충돌하던 옛 괄호 문구(질문·대기 일괄 금지)를 정합 문장으로 바꾼다
              "화면 승인 채널(AskUserQuestion header 승인:PROD_DEPLOY, 10분 1회, 원문 일치)은 셸 규칙 차단에 한해 "
              "메인 에이전트만 쓴다. 팀원은 질문·대기하지 말고 team-lead 에 보고한 뒤 나머지를 진행한다.")
# c196 A-2′: 따옴표 혼동(amb) 때문에 조회 면제가 꺼져 차단된 경우에만 붙이는 안내 — 판정은 바꾸지 않는다
QUOTE_HINT = ("(따옴표 혼동 판정: 큰따옴표 안 백슬래시·따옴표 밖 # 이 있으면 조회 면제가 꺼진다. "
              "조회 명령이면 정규식을 작은따옴표로 감싸 다시 실행하라 — 작은따옴표 안 \\·# 은 허용)")
# 화면 승인 채널(2026-10-24 사용자 결정) — 셸 규칙 차단 전용. TTL 은 환경변수로 바꿀 수 없다(에이전트 재정의 방지)
APPROVAL_HEADER = "승인:PROD_DEPLOY"
APPROVAL_PHRASE = "운영 배포 가드가 막은 명령 1건을 10분 동안 1회 실행합니다"
APPROVAL_LABEL = "승인 (10분 1회)"
APPROVAL_TTL_SEC = 600
APPROVAL_TAIL_BYTES = 8 * 1024 * 1024
APPROVAL_LEDGER = "prod_deploy_guard_approval_consumed.log"   # <HOOK_DIR>/logs/ — 이름에 가드명이 있어 자기 보호 대상
APPROVAL_SID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")
APPROVAL_BLOCK_RE = re.compile(r"```[^\n]*\n(.*?)\n```", re.S)
APPROVAL_WD_PREFIX = "작업 디렉터리: "
APPROVAL_GUIDE = ("예외(사용자 결정 2026-10-24): 이번 실행이 꼭 필요하면 메인 에이전트만 AskUserQuestion 화면 승인을 받을 수 있다 — "
                  "header '" + APPROVAL_HEADER + "', 질문 본문에 '" + APPROVAL_PHRASE + "' 와 명령 원문을 ``` 로 감싼 블록 1개"
                  "(도구 working_dir 를 쓰면 '" + APPROVAL_WD_PREFIX + "<값>' 줄 추가), 옵션 '" + APPROVAL_LABEL + "' / '거부'. "
                  "answers 를 직접 채운 호출은 무효다. 승인 후 10분 안에 같은 명령을 한 글자도 바꾸지 않고 1회 실행한다. "
                  "팀원은 승인을 받을 수 없다 — team-lead 에 보고한다.")


# ── c195 C-29: 로그 비밀 값 마스킹 ─────────────────────────────────
#   차단·통과 로그에는 명령 원문 일부가 남는다. 비밀 값(비밀번호·토큰·자격증명 파일 내용)은 기록 전에 *** 로 가린다.
#   ① 키=값 형태(password·passwd·pwd·secret·token·api_key 등, 접두 허용 — MYSQL_PWD= 포함)  ② Bearer/Basic 토큰
#   ③ -p<값> 붙여 쓴 형태(mysql 계열)·sshpass -p 값·--password 값  ④ URL 자격증명(://사용자:값@)·curl -u 사용자:값
#   ⑤ IDENTIFIED BY '값'  ⑥ 자격증명 파일 내용 리터럴: $HOME/.*/pw (env PDG_SECRET_FILES 로 콜론 구분 목록 재정의)
#   ★값 자체는 어디에도 출력하지 않는다(마스킹 실패는 원문 대신 MASK_ERROR 표기). 잘림(%.200s) 전에 가리도록 호출부도 _mask 를 쓴다.
MASK = "***"
_MASK_RES = [
    (re.compile(r"(?i)([A-Za-z0-9_.-]*(?:password|passwd|passphrase|pwd|secret|token|api[_-]?key|access[_-]?key)"
                r"[\"']?\s*[=:]\s*)(\"[^\"]*\"|'[^']*'|[^\s;&|,'\"]+)"), r"\1" + MASK),
    (re.compile(r"(?i)\b(bearer|basic)(\s+)[A-Za-z0-9._~+/=-]{4,}"), r"\1\2" + MASK),
    (re.compile(r"(?i)(--password(?:=|\s+))(\"[^\"]*\"|'[^']*'|\S+)"), r"\1" + MASK),
    (re.compile(r"(?i)\b(sshpass\s+-p\s*)(\"[^\"]*\"|'[^']*'|\S+)"), r"\1" + MASK),
    (re.compile(r"(?i)(://[^/\s:@]+:)([^@\s/]+)(@)"), r"\1" + MASK + r"\3"),
    (re.compile(r"(?i)((?:^|\s)(?:-u|--user)\s+[^:\s]+:)(\S+)"), r"\1" + MASK),
    (re.compile(r"(?i)(identified\s+(?:with\s+\S+\s+)?by\s+)(\"[^\"]*\"|'[^']*'|\S+)"), r"\1" + MASK),
]
# ③-a -p<값> 은 find -print·-path 같은 일반 옵션과 겹치므로 mysql 계열 명령이 든 줄에서만 가린다
_MASK_DBCLI_RE = re.compile(r"(?i)\b(mysql\w*|mariadb\w*)\b")
_MASK_P_RE = re.compile(r"(?<![\w-])(-p)(\"[^\"]*\"|'[^']*'|[^\s\"'-][^\s;&|]*)")
_SECRET_CACHE = None


def _secret_values():
    """자격증명 파일 내용(줄 단위, 4자 이상) — 읽기만 한다. 실패는 빈 목록"""
    global _SECRET_CACHE
    if _SECRET_CACHE is not None:
        return _SECRET_CACHE
    vals = set()
    try:
        env = os.environ.get("PDG_SECRET_FILES")
        if env is not None:
            files = [os.path.expanduser(x) for x in env.split(":") if x]
        else:
            files = glob.glob(os.path.join(os.path.expanduser("~"), ".*", "pw"))
        for p in files:
            try:
                if not os.path.isfile(p) or os.path.getsize(p) > 4096:
                    continue
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    for ln in f.read().splitlines():
                        v = ln.strip()
                        if len(v) >= 4:
                            vals.add(v)
            except Exception:
                continue
    except Exception:
        pass
    _SECRET_CACHE = sorted(vals, key=len, reverse=True)
    return _SECRET_CACHE


def _mask(s):
    """비밀 값 마스킹 — 실패 시 원문을 돌려주지 않는다"""
    try:
        s = str(s)
        for v in _secret_values():
            s = s.replace(v, MASK)
        for rx, rep in _MASK_RES:
            s = rx.sub(rep, s)
        if _MASK_DBCLI_RE.search(s):
            s = _MASK_P_RE.sub(r"\1" + MASK, s)
        return s
    except Exception:
        return "MASK_ERROR"


def _log(line):
    try:
        d = os.path.join(HOOK_DIR, "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "prod_deploy_guard.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(NOW)), _mask(line)))
    except Exception:
        pass


# c206 S3d: 차단 사유 유형에 맞는 정식 진행 경로를 고정 표지 [대체경로] 뒤에 1줄 덧붙인다(판정 결과는 그대로 — 작업이 멈추지 않게).
#   사용자 지시(2026-10-25): 운영 배포 가드 과차단도 작업 중단·진행 불가·auto 질문을 없애는 것이 목표. 문구만 보강하고 규칙은 유지한다.
#   표지 [대체경로] 는 redir 판정·고정 시험(DA 류)이 안내 줄을 식별하는 문자열이다 — 바꾸지 않는다.
#   c207: 엄격 읽기전용 분기에 고정 시험 실행·로그 덧붙이기·스테이징 경로, 파일 도구 분기에 file_read 읽기 경로를 보강(문구만, 판정 불변).
def _alt_line(reason):
    r = reason or ""
    # 자기 보호 셸 분기("엄격 읽기전용 … 일 때만 통과")는 조회 과차단(awk·sort 등으로 면제가 꺼짐)과 실제 수정(cp·sed -i)이
    #   같은 사유 문구를 쓴다 — 텍스트로 구분할 수 없으므로 조회·교체 둘 다 안내한다(판정은 그대로, 작업이 멈추지 않게).
    if "엄격 읽기전용" in r:
        return "[대체경로] → 조회면 oio file_read·search 로 읽고 센다(셸 파이프·집계 없이). 고정 시험 실행은 AC 실행기 또는 인자 없는 직접 실행으로 한다(결과를 세션 밖에 쓰지 않는다). 로그 덧붙이기는 oio file_edit 로, 새 파일 생성은 oio file_write 로 한다. 임의 입력으로 판정을 확인하려면 후보 고정 시험에 사례를 추가해 실행한다. 스테이징은 git add -u 나 가드 이름 없이 파일명만 쓴 단독 git add 로 한다. 가드 코어·hook 교체면 bash <hooks>/lib/guard_promote.sh promote pdg_core --core <후보> 로."
    if "파일 도구로 수정" in r or "비상 해제 스위치" in r or "비상 스위치" in r:
        return "[대체경로] → 가드 로그·가드 파일 읽기와 집계는 oio file_read·search 로 한다(file_copy·file_move 로 옮기지 않는다). 가드 코어·hook 교체는 bash <hooks>/lib/guard_promote.sh promote pdg_core --core <후보>, 복구는 restore 로 한다."
    if "운영 배포" in r:
        return "[대체경로] → 운영 배포는 실행하지 말고 보류 목록에 남긴다. 등록 고정 시험은 AC 실행기 또는 결과를 세션 밖에 쓰지 않는 직접 실행으로 한다."
    return "[대체경로] → 가드 관련 파일 읽기는 oio file_read·search 도구로 한다(셸 파이프·집계 없이)."


def _deny(reason):
    reason = "%s %s" % (reason, _alt_line(reason))
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                        "permissionDecisionReason": reason}}, ensure_ascii=False))


# c213: 차단 원문 구조화 로그 — 과차단 후보를 원문 그대로 고정 시험 A 사례로 옮기기 위한 피드백 경로.
#   <HOOK_DIR>/logs/prod_deploy_guard_blocks.jsonl 에 차단 1건 = 1줄. 가드명이 든 파일명이라 자기 보호 대상(에이전트 변조 불가, 읽기 허용).
#   명령·경로는 _mask 후 최대 4000자. tool_input.env·environ·environment 는 내용·키 이름 모두 기록하지 않는다(비밀값 경로).
#   화면 승인 통과(askq-approval)는 차단이 아니므로 기록하지 않는다. 5 MiB 초과 시 .1 로 1회 회전. 기록 실패는 판정에 영향 없음.
BLOCKS_LOG = "prod_deploy_guard_blocks.jsonl"
BLOCKS_MAX = 5 * 1024 * 1024
BLOCKS_CMD_MAX = 4000


def _block_log(kind, rule, who, tool, inp, cmd, paths):
    try:
        if not HOOK_DIR:
            return
        d = os.path.join(HOOK_DIR, "logs")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, BLOCKS_LOG)
        try:
            if os.path.getsize(p) > BLOCKS_MAX:
                os.replace(p, p + ".1")
        except OSError:
            pass
        row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(NOW)), "kind": kind, "rule": rule or "",
               "who": who, "tool": tool, "cwd": _mask(inp.get("cwd") or "")[:BLOCKS_CMD_MAX],
               "session_id": str(inp.get("session_id") or "")[:80],
               "cmd": _mask(cmd or "")[:BLOCKS_CMD_MAX],
               "paths": [_mask(x)[:BLOCKS_CMD_MAX] for x in (paths or [])][:16]}
        with open(p, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _switch_on():
    p = os.path.join(HOOK_DIR, SWITCH_NAME)
    try:
        age = NOW - os.path.getmtime(p)
    except Exception:
        return False
    if age <= TTL * 60:
        return True
    _log("SWITCH_STALE age=%ds (TTL %d분 초과 — 무시)" % (age, TTL))
    return False


def _win2wsl(s):
    return re.sub(r"\b([A-Za-z]):\\", lambda m: "/mnt/%s/" % m.group(1).lower(), s).replace("\\", "/")


def _strings(ti):
    """tool_input 에서 명령·경로 문자열 추출"""
    cmd = ""
    for k in ("command", "cmd"):
        if isinstance(ti.get(k), str):
            cmd = ti[k]
    paths = []
    for k in ("file_path", "filepath", "path", "source", "src", "destination", "dest", "dst", "target", "new_path",
              "old_path", "new_name", "link_path", "target_path", "to"):
        if isinstance(ti.get(k), str):
            paths.append(ti[k])
    content = ""
    for k in ("content", "new_string", "new_content", "new_text", "new", "text", "data", "body", "replace"):
        if isinstance(ti.get(k), str):
            content += "\n" + ti[k]
    wd = [ti[k] for k in ("working_dir", "workdir", "cwd") if isinstance(ti.get(k), str)]
    return cmd, paths, content, wd


def _find_configs(seeds):
    found = []
    seen = set()
    for s in seeds:
        if not s or not s.startswith("/"):
            continue
        d = s if os.path.isdir(s) else os.path.dirname(s)
        for _ in range(16):
            if not d or d in seen:
                break
            seen.add(d)
            c = os.path.join(d, CONF_REL)
            if os.path.isfile(c) and c not in found:
                found.append(c)
            nd = os.path.dirname(d)
            if nd == d:
                break
            d = nd
    return found


def _load_rules(paths):
    rules, fileop_ids, exempt, fileop_exempt = [], set(), [], []
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = json.load(f)
        except Exception as e:
            _log("CONF_ERROR %s %r" % (p, e))
            continue
        for r in c.get("rules") or []:
            try:
                rules.append({
                    "id": str(r.get("id")), "src": p, "reason": str(r.get("reason") or ""),
                    "all": [re.compile(x, re.I) for x in (r.get("match_all") or [])],
                    "unless": [re.compile(x, re.I) for x in (r.get("unless_any") or [])],
                })
            except re.error as e:
                _log("REGEX_ERROR %s %s %r" % (p, r.get("id"), e))
        fileop_ids |= set(c.get("file_op_rules") or [])
        root = os.path.dirname(os.path.dirname(p))  # <프로젝트>/.claude/prod_deploy_guard.json → <프로젝트>
        for x in c.get("script_write_exempt") or []:
            try:
                exempt.append((re.compile(x, re.I), root))
            except re.error:
                pass
        # c185: 파일 도구 대상 예외 영역 — file_op_exempt 키가 있으면(빈 배열 포함) 그것만, 없으면 script_write_exempt
        fx = c.get("file_op_exempt") if "file_op_exempt" in c else c.get("script_write_exempt")
        rxs = []
        for x in (fx if isinstance(fx, list) else []):
            try:
                rxs.append(re.compile(str(x), re.I))
            except re.error:
                pass
        fileop_exempt.append((rxs, root))
    return rules, fileop_ids, exempt, fileop_exempt


# ── 엄격 읽기전용 판정 ─────────────────────────────────────────────
READONLY_VERBS = {"cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "wc", "ls", "stat", "file", "md5sum", "sha1sum",
                  "sha256sum", "diff", "cmp", "echo", "printf", "readlink", "realpath", "basename", "dirname", "test", "[",
                  "jq", "find", "du", "od", "xxd", "hexdump", "iconv", "sort", "uniq", "cut", "tr", "column", "nl",
                  "date", "pwd", "true", "whoami", "uname", "nproc",  # c183 B8: 무해 조회 동사(date 는 설정 인자 제외)
                  "which", "type",  # c183 B8: 위치 조회만(실행 없음 — command 는 실행 가능하므로 넣지 않는다)
                  "printenv"}  # c196 A-1′: 환경변수 출력만(실행 없음). env 는 인자 0개일 때만 — _strict_readonly 분기
SAFE_BIN_DIRS = ("/bin", "/usr/bin", "/usr/local/bin")
GIT_READ_SUBS = ("log", "show", "diff", "status", "blame", "grep", "ls-files", "cat-file",
                 "check-ignore", "rev-parse")   # c213: 읽기 전용 하위명령 추가(git check-ignore·status 가드 파일명 과차단 해소)
FIND_BAD = ("-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls")
# 무해 리다이렉트 — N>/dev/null, N>>/dev/null, &>/dev/null, N>&M (판정 전에 지운다)
HARMLESS_REDIR_RE = re.compile(r"(?:&|[0-9]*)>>?[ \t]*/dev/null(?![\w./-])|[0-9]*>&[0-9]+(?![\w>])")
SED_PRINT_RE = re.compile(r"^[0-9,$p;]+$")


def _strip_harmless(cmd):
    return HARMLESS_REDIR_RE.sub(" ", cmd)


def _long_hit(tok, names):
    """GNU 장옵션 축약(--out=x 등)까지 고려해 tok 가 금지 장옵션인가"""
    if not tok.startswith("--") or tok == "--":
        return False
    n = tok.split("=", 1)[0]
    return len(n) >= 3 and any(x.startswith(n) for x in names)


def _short_has(tok, letters):
    """단일 대시 묶음 옵션(-uo 등)에 금지 글자가 있는가"""
    return tok.startswith("-") and not tok.startswith("--") and len(tok) > 1 and any(c in tok[1:] for c in letters)


def _positionals(toks, takes_value):
    out, skip = [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if t in takes_value:
            skip = True
            continue
        if t.startswith("-") and t != "-":
            continue
        out.append(t)
    return out


def _git_sub_args(args):
    """c196 A-3: git 전역 옵션 --no-pager · -C <dir>(분리형) 을 건너뛴 인자 목록. -C 값이 없거나 비면 None(비조회)"""
    a = list(args)
    while a:
        if a[0] == "--no-pager":
            a = a[1:]
            continue
        if a[0] == "-C":
            if len(a) < 2 or not a[1]:
                return None
            a = a[2:]
            continue
        break
    return a


def _strict_readonly(seg, depth=0):
    """엄격 읽기전용 구간인가 — 실행·쓰기 수단이 하나라도 있으면 False(규칙 판정 대상)
    c183 B8: 작은따옴표 안 글자는 bash 가 문자 그대로 넘기므로(grep '=>' · grep '^+') 치환·리다이렉트 판정에서 뺀다.
    bash -c '…' 내용은 아래 bash 분기가 원문으로 다시 판정한다."""
    if any(x in _sq_strip(seg) for x in ("$(", "`", "<(", ">(", ">", "<<")):
        return False
    try:
        toks = shlex.split(seg)
    except ValueError:
        return False
    while toks and re.fullmatch(r"^(LC_ALL|LANG)=[^\s]*$", toks[0]):
        toks = toks[1:]
    if not toks or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]):
        return False  # 그 밖의 환경변수 접두(LD_PRELOAD= 등)·단독 대입
    v = toks[0]
    if "/" in v:  # ./cat 같은 로컬 실행 파일은 조회 동사로 보지 않는다
        if os.path.dirname(v) not in SAFE_BIN_DIRS:
            return False
        v = os.path.basename(v)
    args = toks[1:]
    if v == "cd":
        return len(args) <= 1
    if v == "env":  # c196 A-1′: 인자 0개(환경 출력)만 조회. 인자가 있으면 실행 접두·대입이므로 종전대로 비조회
        return len(args) == 0
    if v == "command":  # c214 T4: command -v/-V 이름… 은 위치 조회만(실행 없음). 그 밖(command x · -p)은 실행이므로 비조회
        return len(args) >= 2 and args[0] in ("-v", "-V") and all(re.fullmatch(r"^[\w.+-]+$", t) and not t.startswith("-")
                                                                  for t in args[1:])
    if v in ("bash", "sh", "dash"):
        if len(args) == 2 and args[0] == "-n":
            return True
        if v == "bash" and _gp_query(args):  # c206 F-2②: 승격기 조회 실행(verify·status)만
            return True
        if len(args) == 2 and args[0] == "-c" and depth < 2:
            m = re.fullmatch(r"^\s*\S+\s+-c\s+'([^']*)'\s*$", seg)
            return bool(m) and _all_strict(m.group(1), depth + 1)
        return False
    if v == "git":
        args = _git_sub_args(args)
        if not args or args[0] not in GIT_READ_SUBS:
            return False
        for t in args[1:]:
            if t.startswith("-O") or _long_hit(t, ("--output", "--open-files-in-pager", "--ext-diff")):
                return False
        return True
    if v == "sed":
        opts = [t for t in args if t.startswith("-") and t != "-"]
        if "-n" not in opts or any(t not in ("-n", "-E", "-r", "--quiet", "--silent") for t in opts):
            return False
        pos = [t for t in args if not (t.startswith("-") and t != "-")]
        return bool(pos) and bool(SED_PRINT_RE.fullmatch(pos[0]))
    if v not in READONLY_VERBS:
        return False
    if v == "find":
        return not any(t in FIND_BAD or t.startswith("-fprint") for t in args)
    if v == "sort":
        return not any(t == "-o" or _short_has(t, "o") or _long_hit(t, ("--output", "--compress-program")) for t in args)
    if v == "iconv":
        return not any(_short_has(t, "o") or _long_hit(t, ("--output",)) for t in args)
    if v == "rg":
        return not any(_long_hit(t, ("--pre", "--pre-glob")) for t in args)
    if v == "file":
        return not any(_short_has(t, "C") or _long_hit(t, ("--compile",)) for t in args)
    if v == "xxd":
        if any(t.startswith("-r") for t in args):
            return False
        return len(_positionals(args, {"-c", "-g", "-l", "-s", "-o", "-n", "-cols", "-groupsize", "-len", "-seek",
                                       "-offset", "-name"})) <= 1
    if v == "uniq":
        return len(_positionals(args, {"-f", "-s", "-w"})) <= 1
    if v == "date":  # -s/--set·비 + 위치 인자(MMDDhhmm)는 시각 설정 — 조회로 보지 않는다
        return not any(_short_has(t, "s") or _long_hit(t, ("--set",)) or (not t.startswith(("-", "+"))) for t in args)
    if v == "printf":  # c206: printf -v 이름 은 셸 변수 대입(뒤 구간 $이름 으로 옵션 주입 가능) — 조회로 보지 않는다
        return not (args and args[0].startswith("-v"))
    return True


# c206 F-2②: 승격기 조회 실행 — gp_gate G2 와 같은 규칙. 정확히 bash <H>/lib/guard_promote.sh verify | status [<id>]
#   <H> = ${HARNESS_HOME:-$HOME/.harness}/current/hooks 또는 그 realpath(사본·후보 경로 불가). promote·restore·register·init 등 다른 하위 명령은 비조회.
#   verify 는 읽기 전용(guard_promote.sh cmd_verify 주석), status 는 등록부·파일 해시 대조 출력만 한다.
GP_ID_RE = re.compile(r"^[a-z0-9_]+$")


def _gp_query(args):
    """args(= bash 뒤 낱말)가 승격기 조회(verify | status [<id>])인가"""
    if len(args) < 2:
        return False
    sub, rest = args[1], args[2:]
    if not ((sub == "verify" and not rest) or
            (sub == "status" and len(rest) <= 1 and all(GP_ID_RE.fullmatch(x) for x in rest))):
        return False
    try:
        h = os.path.join(os.path.expanduser("~"), ".claude", "hooks")
        if args[0] == h + "/lib/guard_promote.sh":
            return True
        hr = os.path.realpath(h)
    except Exception:
        return False
    return bool(hr) and args[0] == hr + "/lib/guard_promote.sh"


def _segments(cmd):
    """셸 명령을 ; && || | 줄바꿈 단위 구간으로 나눈다(따옴표 안의 구분자는 무시 — 근사)"""
    segs, buf, q = [], [], None
    i = 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            buf.append(ch)
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
            buf.append(ch)
        elif ch in ";\n|&":
            segs.append("".join(buf))
            buf = []
            while i + 1 < len(cmd) and cmd[i + 1] in "|&":
                i += 1
        else:
            buf.append(ch)
        i += 1
    segs.append("".join(buf))
    return [s.strip() for s in segs if s.strip()]


def _pipe_groups(cmd):
    """_segments 와 같은 분할이되 파이프(| 단독·|&)로 이어진 구간을 한 묶음으로 돌려준다 — [[구간, …], …]"""
    groups, cur, buf, q = [], [], [], None
    i = 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            buf.append(ch)
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
            buf.append(ch)
        elif ch in ";\n|&":
            pipe = ch == "|" and not (i + 1 < len(cmd) and cmd[i + 1] == "|")
            s = "".join(buf).strip()
            if s:
                cur.append(s)
            buf = []
            while i + 1 < len(cmd) and cmd[i + 1] in "|&":
                i += 1
            if not pipe and cur:
                groups.append(cur)
                cur = []
        else:
            buf.append(ch)
        i += 1
    s = "".join(buf).strip()
    if s:
        cur.append(s)
    if cur:
        groups.append(cur)
    return groups


def _quote_ambiguous(raw):
    """구간 분할기가 bash 와 다르게 읽을 수 있는 명령인가(역라우팅 #1, conv_179163042411).
    _segments 는 백슬래시 이스케이프(\\' \\")·# 주석·$'…' 을 모른다 → `echo \\'; cp …` 나 `echo x #'⏎cp … #'` 에서
    따옴표 상태가 어긋나 뒤 명령을 따옴표 안으로 오인한다. 이런 명령은 읽기전용 면제를 주지 않는다(fail-closed).
    ★raw 명령으로 판정한다 — _win2wsl 은 백슬래시를 / 로 바꿔 흔적을 지운다.
    c183 B8: bash 는 작은따옴표 안 글자를 문자 그대로 읽는다(이스케이프·주석 없음) — 분할기와 해석이 같으므로
    작은따옴표 안 \\ · # 은 혼동 소지가 아니다(grep -n 'a\\|b' 파일 | head 오차단 해소). 작은따옴표 밖·큰따옴표 안의
    \\, 작은따옴표 밖 #, $'…'(ANSI 따옴표), 따옴표 안 개행, 닫히지 않은 따옴표는 종전대로 혼동 소지다.
    c199 A-2: 큰따옴표 안 \\ 는 뒤 글자가 $ ` \" \\\\ 개행일 때만 혼동 소지(grep -c "a\\|b" 파일 과차단 해소)."""
    if _quote_scan(raw)[0]:
        return True
    return any("\n" in s or "\r" in s for s in _segments(raw))  # 따옴표 안 개행(분할기가 개행을 삼킨 경우)


def _quote_scan(raw):
    """bash 따옴표 규칙으로 훑는다 → (혼동 소지 여부, 작은따옴표 내용을 지운 문자열)"""
    out, q, amb = [], None, False
    for i, ch in enumerate(raw):
        if q == "'":
            if ch == "'":
                q = None
                out.append(ch)
            elif ch in "\n\r":
                amb = True
            continue
        if q == '"':
            if ch == "\\":
                if i + 1 >= len(raw) or raw[i + 1] in '$`"\\\n\r':
                    amb = True
            elif ch in "\n\r":
                amb = True
            elif ch == '"':
                q = None
            out.append(ch)
            continue
        if ch in "\\#":
            amb = True
        elif ch == "'":
            if i > 0 and raw[i - 1] == "$":
                amb = True
            q = "'"
        elif ch == '"':
            q = '"'
        out.append(ch)
    if q:
        amb = True
    return amb, "".join(out)


def _sq_strip(seg):
    """작은따옴표 안 내용을 지운 구간(치환·리다이렉트 기호 판정용)"""
    return _quote_scan(seg)[1]


def _q_strip(seg):
    """c214 T1: 작은따옴표·큰따옴표 안 내용을 모두 지운 구간(따옴표 밖 리다이렉트 기호 판정용). 닫히지 않은 따옴표면 원문(보수적)"""
    out, q, i = [], None, 0
    while i < len(seg):
        ch = seg[i]
        if q == "'":
            if ch == "'":
                q = None
                out.append(ch)
        elif q == '"':
            if ch == "\\" and i + 1 < len(seg):
                i += 2
                continue
            if ch == '"':
                q = None
                out.append(ch)
        elif ch == "\\" and i + 1 < len(seg):
            out.append(seg[i:i + 2])
            i += 2
            continue
        elif ch in ("'", '"'):
            q = ch
            out.append(ch)
        else:
            out.append(ch)
        i += 1
    return seg if q else "".join(out)


# c214 T3: 안전한 ANSI-C 따옴표 $'…' 를 일반 작은따옴표로 바꾼다 — 내용이 일반 글자와 \r \n \t \\ \0 뿐일 때만.
#   bash 는 그 값을 확장 없이 리터럴로 넘긴다(\xHH·\uHHHH·\NNN·\' 처럼 글자를 숨기거나 따옴표 경계를 흐리는 이스케이프는 그대로 두어 종전 amb).
#   $ 와 백슬래시만 지우므로 내용 글자는 그대로 규칙 판정 대상에 남는다(실행기 + $'배포 스크립트 경로' 는 계속 차단).
ANSI_SAFE_RE = re.compile(r"\$'((?:[^'\\\n\r]|\\[rnt0\\])*)'")


def _ansi_safe(cmd):
    try:
        out, q, i = [], None, 0
        while i < len(cmd):
            ch = cmd[i]
            if q == "'":
                out.append(ch)
                if ch == "'":
                    q = None
                i += 1
                continue
            if q == '"':
                out.append(ch)
                if ch == "\\" and i + 1 < len(cmd):
                    out.append(cmd[i + 1])
                    i += 2
                    continue
                if ch == '"':
                    q = None
                i += 1
                continue
            if ch == "\\" and i + 1 < len(cmd):
                out.append(cmd[i:i + 2])
                i += 2
                continue
            if ch == "$" and cmd.startswith("$'", i):
                m = ANSI_SAFE_RE.match(cmd, i)
                if not m:
                    return cmd   # 안전하지 않은 ANSI 따옴표가 하나라도 있으면 원문 그대로(종전 amb·fail-closed)
                out.append("'" + m.group(1).replace("\\", "") + "'")
                i = m.end()
                continue
            if ch in ("'", '"'):
                q = ch
            out.append(ch)
            i += 1
        return cmd if q else "".join(out)
    except Exception:
        return cmd


# c199f 건2(Mars L-1363 ④): 읽기 전용 for/do/done 반복 — 반복 단어마다 본문을 펼쳐 엄격 판정한다.
#   면제하지 않는 것: 단어에 / · 글롭(* ? [) · 치환($ `) · 공백 · 따옴표/셸 기호(고정 시험 S17 — 가드 경로 반복은 계속 차단),
#   `do` 단독 줄, done 누락, 본문 안 중첩·제어 구조, 펼친 본문이 하나라도 엄격 읽기전용이 아닌 경우.
#   단어는 공백·글롭이 없으므로 bash 의 단어 분할·경로 확장이 일어나지 않는다 → 날 값 치환이 실제 실행과 같다.
FOR_HEAD_RE = re.compile(r"^for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)$", re.S)
LOOP_WORD_RE = re.compile(r"^[\w.,:@%+=()-]+$")
LOOP_CTRL_HEADS = ("for", "do", "done", "while", "until", "if", "then", "elif", "else", "fi", "case", "esac",
                   "select", "function", "{", "}", "(", ")")


def _loop_strict(segs, i, depth):
    """segs[i] 가 엄격 읽기전용 for 반복의 헤더면 짝 done 의 인덱스, 아니면 None"""
    m = FOR_HEAD_RE.fullmatch(segs[i])
    if not m:
        return None
    var, words_raw = m.group(1), m.group(2)
    if any(c in words_raw for c in "$`/*?[\\"):
        return None
    try:
        words = shlex.split(words_raw)
    except ValueError:
        return None
    if not words or not all(LOOP_WORD_RE.fullmatch(w) for w in words):
        return None
    j = next((k for k in range(i + 1, len(segs)) if segs[k] == "done"), None)
    if j is None or j == i + 1:
        return None
    body = list(segs[i + 1:j])
    if not body[0].startswith("do ") and not body[0].startswith("do\t"):
        return None
    body[0] = body[0][3:].strip()
    for b in body:
        if not b or b.split()[0] in LOOP_CTRL_HEADS:
            return None
    pat = re.compile(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (var, var))
    for w in words:
        for b in body:
            if not _strict_readonly(pat.sub(lambda _m: w, b), depth):
                return None
    return j


# c206 F-2①: 구간 머리 순수 대입(S=…;) 허용 — 명령 전체를 보는 _all_strict 문맥에서만 판정한다(같은 명령 안 참조까지 봐야 하므로).
#   허용: 구간 전체가 `이름=값` 낱말 1개 이상뿐이고, 값은 리터럴 문자([A-Za-z0-9_./:@%+,=-])만·비어 있지 않음·'-' 로 시작하지 않음,
#     이름은 위험 이름(ASSIGN_DANGER_RE)이 아니고 현재 환경에 이미 있는 이름도 아님(대입하면 자식 환경이 바뀐다).
#   참조 제약: 같은 명령 안에서 대입한 이름은 단어 머리의 $이름·${이름} 으로만 쓸 수 있다(-$O · -"$S"e 같은 옵션 조립 차단 —
#     값이 '-' 로 시작하지 않으므로 단어 머리 확장은 옵션이 될 수 없다). 대입이 있으면 ${이름} 밖의 ${…}(${S/a/-o}·${!S}·${#S})와
#     $[ ] 도 거부한다. 대입 이름을 명령 자리에 쓰면 _strict_readonly 가 비조회로 본다(종전).
#   종전 유지: `S=x cat …`(환경 접두 + 명령)은 비조회, LC_ALL/LANG 접두는 종전대로.
ASSIGN_DANGER_RE = re.compile(
    r"^(PATH|IFS|ENV|BASH_ENV|CDPATH|HOME|SHELL|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|GLOBIGNORE|OLDPWD|PWD|TMPDIR|"
    r"POSIXLY_CORRECT|FUNCNEST|PAGER|EDITOR|VISUAL|MANPAGER|NODE_OPTIONS|RUBYOPT|RUBYLIB|LANG|LANGUAGE|TERM|TZ|TZDIR|"
    r"INPUTRC|GREP_OPTIONS|GREP_COLORS?|LD_\w*|DYLD_\w*|GIT_\w*|PYTHON\w*|PERL\w*|BASH\w*|LC_\w*|LESS\w*|HIST\w*|"
    r"XDG_\w*|CLAUDE\w*|PDG_\w*|OIO_\w*|TB_\w*|SM_\w*|PIPELINE_\w*|SUDO_\w*|SSH_\w*|MAIL\w*|COMP\w*|READLINE\w*|"
    r"RIPGREP_\w*|GCONV_PATH|LOCPATH|NLSPATH|MALLOC_\w*|HOSTALIASES|JQ_\w*|GREP_\w*|SORT_\w*)$")
ASSIGN_TOK_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=([A-Za-z0-9_./:@%+,=][A-Za-z0-9_./:@%+,=-]*)$")
ASSIGN_SEG_BAD = set("$`()<>\\'\"~*?[]{}!;&|#")


def _pure_assign_names(seg):
    """구간이 안전한 리터럴 순수 대입(1개 이상)만으로 되어 있으면 이름 목록, 아니면 None"""
    if not seg or any(c in ASSIGN_SEG_BAD for c in seg):
        return None
    toks = seg.split()
    if not toks:
        return None
    names = []
    for t in toks:
        m = ASSIGN_TOK_RE.fullmatch(t)
        if not m:
            return None
        n = m.group(1)
        if ASSIGN_DANGER_RE.match(n) or n in os.environ:  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
            return None
        names.append(n)
    return names


def _assign_refs_ok(segs, names):
    """대입 이름 참조가 전부 단어 머리의 $이름·${이름} 인가(+ ${…} 확장형·$[ ] 없음)"""
    text = "\n".join(segs)
    if "$[" in text or "${!" in text:
        return False
    if re.search(r"\$\{(?![A-Za-z_][A-Za-z0-9_]*\})", text):
        return False
    alt = "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
    ref = re.compile(r"\$\{?(?:%s)" % alt)   # 접두 일치도 참조로 본다(-$Se 처럼 뒤에 글자가 붙은 조립 포함 — fail-closed)
    for s in segs:
        if _pure_assign_names(s) is not None or not ref.search(s):
            continue
        try:
            toks = shlex.split(s)
        except ValueError:
            return False
        for t in toks:
            if any(m.start() != 0 for m in ref.finditer(t)):
                return False
    return True


def _all_strict(cmd, depth=0):
    """명령의 모든 구간이 엄격 읽기전용인가(무해 리다이렉트 제거 후). 따옴표 혼동 소지가 있으면 False
    c199f 건2: 엄격 읽기전용 for 반복(_loop_strict)은 헤더~done 을 한 묶음으로 인정한다.
    c206 F-2①: 안전 리터럴 순수 대입 구간(_pure_assign_names)은 참조 제약(_assign_refs_ok)을 만족할 때만 인정한다."""
    if _quote_ambiguous(cmd):
        return False
    segs = _segments(_strip_harmless(cmd))
    if not segs:
        return False
    names = set()
    for s in segs:
        n = _pure_assign_names(s)
        if n:
            names.update(n)
    if names and not _assign_refs_ok(segs, names):
        return False
    i = 0
    while i < len(segs):
        j = _loop_strict(segs, i, depth)
        if j is not None:
            i = j + 1
            continue
        if not _strict_readonly(segs[i], depth) and not (names and _pure_assign_names(segs[i])):
            return False
        i += 1
    return True


# c196 oi-fix-1 P6②: 가드 산출물 git 색인 반영 허용 — c195 사용자 조치 #16(승격 산출물 git add 가 자기 보호에 막혀 이력 공백).
#   git add(리터럴 경로)·git commit(-m·-F·-q 만)은 작업 트리의 파일을 바꾸지 않는다(색인·이력 기록). 가드 파일 교체는 여전히
#   승격 경로(guard_promote.sh)로만 되고, 이 허용은 "이미 설치된 파일을 이력에 남기는 것"만 연다.
#   막는 것: 글롭·변수·치환·리다이렉트·옵션 주입(-c 설정·--chmod·-p 등)·add/commit 밖 하위 명령(checkout·restore·stash·reset 등).
#   잔존 한계: 같은 uid 가 git 설정(filter·hooksPath)을 미리 바꿔 두면 add/commit 이 코드를 실행할 수 있다 — 설정 변조는 이 판정 밖이다.
GIT_INDEX_PATH_RE = re.compile(r"^[\w./@%+,=:-]+$")


def _git_index_only(seg):
    """git add <리터럴 경로…> 또는 git commit (-m 메시지 | -F 파일 | -q)… 구간인가"""
    if any(x in _sq_strip(seg) for x in ("$(", "`", "<(", ">(", ">", "<<")):
        return False
    try:
        toks = shlex.split(seg)
    except ValueError:
        return False
    if toks and toks[0] == "xargs":   # cgit A4: … | xargs [-r] git (restore --staged|rm --cached|reset) --
        return _xargs_git_index(toks)
    if not toks or toks[0] not in ("git", "/usr/bin/git"):
        return False
    args = _git_sub_args(toks[1:])
    if not args:
        return False
    sub, rest = args[0], args[1:]
    if sub in GIT_INDEX_SUBS:   # cgit A4: 인덱스 전용 restore --staged · rm --cached · reset -- 경로
        return _git_index_sub(sub, rest)
    if sub == "add":
        paths, dd = [], False
        for t in rest:
            if not dd and t == "--":
                dd = True
                continue
            if not dd and t in GIT_ADD_SAFE:   # cgit(사용자 지시 10:52): 인덱스만 바꾸는 add 옵션
                continue
            if t.startswith("-") or not GIT_INDEX_PATH_RE.fullmatch(t):
                return False
            paths.append(t)
        return bool(paths)
    if sub == "commit":
        i, has_msg = 0, False
        while i < len(rest):
            t = rest[i]
            if t in ("-m", "--message", "-F", "--file"):
                if i + 1 >= len(rest):
                    return False
                if t in ("-F", "--file") and not GIT_INDEX_PATH_RE.fullmatch(rest[i + 1]):
                    return False
                has_msg, i = True, i + 2
                continue
            if t.startswith("--message="):
                has_msg, i = True, i + 1
                continue
            if t in ("-q", "--quiet") or t in GIT_COMMIT_SAFE or t.startswith("--author="):
                i += 1
                continue
            if t == "--no-edit":   # cgit: --amend --no-edit 은 에디터 없이 직전 메시지를 쓴다
                has_msg, i = True, i + 1
                continue
            return False
        return has_msg
    if sub == "push":   # c213: 작업 트리를 바꾸지 않는다 — 리터럴 원격·refspec 과 무해 옵션만(실행 옵션·원격 도우미 :: 거부)
        for t in rest:
            if t in ("-u", "--set-upstream", "-q", "--quiet", "--tags", "--follow-tags", "-v", "--verbose") or \
                    t in GIT_PUSH_SAFE or t.startswith("--force-with-lease="):
                continue
            if t.startswith("-") or "::" in t or not GIT_INDEX_PATH_RE.fullmatch(t):
                return False
        return True
    if sub == "tag":   # cgit: 태그는 refs 만 바꾼다(가드 파일 디스크 불변) — 서명·에디터 옵션 거부는 NX 와 같은 구조 판정
        return _nx_git_tag(rest, [])
    if sub == "notes":
        return _nx_git_notes(rest, [])
    return False


# cgit(사용자 지시 2026-10-27 10:52 "위험한 git도 막지 말고 그대로 진행해라" — 리드 판단: 가드 파일 디스크 내용을 바꾸지 않는
#   git 형태는 자기 보호에서 푼다. 작업 트리를 바꾸는 restore·reset --hard·checkout·rm·stash·clean 은 F-GUARD-PROMOTE 절대 규칙으로 유지).
#   push --force 계열(-f·--force·--force-with-lease[=…]·--force-if-includes)·--delete·--mirror·--all·--prune·--atomic·--no-verify·
#   --dry-run 은 원격 refs 만 바꾼다. 실행 옵션(--receive-pack·--exec·--upload-pack·-o/--push-option·원격 도우미 ::)은 종전대로 거부.
GIT_PUSH_SAFE = ("-f", "--force", "--force-with-lease", "--force-if-includes", "--delete", "-d", "--mirror", "--all",
                 "--prune", "--atomic", "--no-verify", "-n", "--dry-run", "--porcelain", "--no-force-with-lease")
GIT_COMMIT_SAFE = ("--amend", "--no-verify",   # -a·--all 은 고정 GI-D7(commit -a 차단) 유지로 넣지 않는다 "-n", "--allow-empty", "--allow-empty-message", "-s",
                   "--signoff", "--dry-run", "--reset-author", "-v", "--verbose")
GIT_ADD_SAFE = ("-v", "--verbose", "-A", "--all", "-u", "--update", "-f", "--force", "-N", "--intent-to-add", "-n",
                "--dry-run", "--ignore-errors", "--renormalize")


# cgit A4(사용자 지시 2026-10-27 "git 명령을 가드에서 막지 않도록"): 작업 트리를 바꾸지 않는 인덱스 전용 git 형태.
#   근거(git restore -h · git rm -h 실측): -S/--staged 는 인덱스, -W/--worktree 는 작업 트리(지정이 없으면 기본값), --source 는
#   다른 커밋 내용으로 덮는다 / rm --cached 는 인덱스에서만 지운다. 허용 목록 밖 옵션(-W·-SW 묶음·--worktree·--source·-s·
#   --no-staged·--no-cached·-p·--patch·--overlay·-f·--hard·--soft·--mixed·--merge·--keep 등)이 하나라도 있으면 거부한다.
#   reset 은 `reset [-q|--soft|--mixed] [<리터럴 커밋>] [--] [경로…]` (사용자 지시 2026-10-27 10:52 "위험한 git도 막지 말고 그대로
#   진행해라" — 리드 판단: 가드 파일 디스크 내용을 바꾸지 않는 형태는 푼다. --soft·--mixed·커밋 지정은 HEAD·인덱스만 바꾼다).
#   --hard·--merge·--keep·-p·--recurse-submodules 는 작업 트리를 바꾸므로 거부. restore 는 --staged 필수에 --source/-s 허용(인덱스만),
#   rm 은 --cached 필수에 -r·-q·-f·-n·--ignore-unmatch 허용.
#   xargs 형태는 git 뒤 끝 낱말이 `--` 여야 한다(입력 이름이 옵션으로 읽히지 않게). xargs 옵션은 -r·--no-run-if-empty 만.
GIT_INDEX_SUBS = ("restore", "rm", "reset")
_GIX_SHORT = {"restore": "Sq", "rm": "rqfn", "reset": "q"}
_GIX_LONG = {"restore": ("--staged", "--quiet"), "rm": ("--cached", "--quiet", "--force", "--dry-run", "--ignore-unmatch"),
             "reset": ("--quiet", "--soft", "--mixed")}
_GIX_NEED = {"restore": ("S", "--staged"), "rm": (None, "--cached"), "reset": (None, None)}
GIT_REV_RE = re.compile(r"^[\w./@~^+-]+$")


def _git_index_sub(sub, rest, xargs=False):
    """git restore|rm|reset 인자가 인덱스 전용(가드 파일 디스크 불변) 형태인가. xargs=True 면 경로 없이 끝이 `--` 여야 한다"""
    try:
        if sub not in GIT_INDEX_SUBS:
            return False
        short, longs = _GIX_SHORT[sub], _GIX_LONG[sub]
        need_s, need_l = _GIX_NEED[sub]
        has_need, dd, paths, i = need_s is None and need_l is None, False, [], 0
        while i < len(rest):
            t = rest[i]
            i += 1
            if dd:
                if not GIT_INDEX_PATH_RE.fullmatch(t):
                    return False
                paths.append(t)
                continue
            if t == "--":
                dd = True
                continue
            if sub == "restore" and (t == "-s" or t == "--source" or t.startswith("--source=")):
                v = t.split("=", 1)[1] if "=" in t else (rest[i] if i < len(rest) else "")
                if "=" not in t:
                    i += 1
                if not v or v.startswith("-") or not GIT_REV_RE.fullmatch(v):
                    return False
                continue
            if t.startswith("--"):
                if t not in longs:
                    return False
                if t == need_l:
                    has_need = True
                continue
            if t.startswith("-") and len(t) > 1:
                if any(c not in short for c in t[1:]):
                    return False
                if need_s and need_s in t[1:]:
                    has_need = True
                continue
            if sub == "reset" and not paths:
                if not GIT_REV_RE.fullmatch(t):
                    return False
                paths.append(t)   # 첫 위치 인자 = 커밋 또는 경로 — 어느 쪽이든 HEAD·인덱스만 바뀐다
                continue
            if not GIT_INDEX_PATH_RE.fullmatch(t) or t.startswith("-"):
                return False
            paths.append(t)
        if not has_need:
            return False
        if xargs:
            return dd and bool(rest) and rest[-1] == "--"   # 표준입력 이름은 끝 -- 뒤에 붙는다(옵션으로 읽히지 않음)
        return bool(paths) or sub == "reset"
    except Exception:
        return False


def _xargs_git_index(toks):
    """xargs [-r|--no-run-if-empty] git (restore --staged | rm --cached [-r] [-q] | reset [-q] [HEAD]) -- 인가"""
    try:
        if not toks or toks[0] != "xargs":
            return False
        i = 1
        while i < len(toks) and toks[i] in ("-r", "--no-run-if-empty"):
            i += 1
        rest = toks[i:]
        if len(rest) < 3 or rest[0] != "git" or rest[-1] != "--":
            return False
        return _git_index_sub(rest[1], rest[2:], xargs=True)
    except Exception:
        return False


def _all_strict_or_git_index(cmd):
    """모든 구간이 엄격 읽기전용 또는 git 색인 반영(add·commit)이고, git 색인 반영이 하나 이상인가"""
    if _quote_ambiguous(cmd):
        return False
    segs = _segments(_strip_harmless(cmd))
    if not segs:
        return False
    # cgit R1(ai-28 원문 11:51:31 `B=.claude/hooks/backup/guard_promote; git add -- … $B/… ;`): 안전 리터럴 순수 대입(_all_strict 의
    #   c206 F-2① 과 같은 기준 — _pure_assign_names·_assign_refs_ok)을 인정하고, 뒤 구간의 단어 머리 $이름·${이름} 을 리터럴 값으로
    #   펼친 뒤 판정한다. 값은 [A-Za-z0-9_./:@%+,=-] 만이라 펼침 결과가 bash 와 같다(단어 분할·글롭 없음). 대입 전 참조는 거부.
    names = set()
    for s in segs:
        n = _pure_assign_names(s)
        if n:
            names.update(n)
    if names and not _assign_refs_ok(segs, names):
        return False
    vals, any_git = {}, False
    for s in segs:
        if names and _pure_assign_names(s):
            for t in s.split():
                k, v = t.split("=", 1)
                vals[k] = v
            continue
        e = s
        if names:
            for n in sorted(names, key=len, reverse=True):
                if re.search(r"\$\{?%s(?![A-Za-z0-9_])" % re.escape(n), e):
                    if n not in vals:
                        return False   # 대입 전 참조(환경값 — 판정 불가)
                    e = re.sub(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (re.escape(n), re.escape(n)), lambda _m, _v=vals[n]: _v, e)
            if "$" in _sq_strip(e).replace("$?", ""):
                return False
        g = _git_index_only(e)
        if not (g or _strict_readonly(e)):
            return False
        any_git = any_git or g
    return any_git


# c199f C9(AI L-687): git commit 메시지 본문 속 가드 파일명 오탐 — 따옴표 구분자 heredoc 메시지만 'MSG' 로 정규화한다.
#   따옴표로 감싼 구분자(<<'TAG' · <<"TAG")의 본문은 bash 가 확장하지 않는 순수 데이터다. 따옴표 없는 구분자는 그대로 둔다
#   (본문의 $(…) 가 실행되므로 종전대로 차단). 이 정규화는 자기 보호 분기의 git 색인 판정에만 쓰고, _all_strict·규칙 판정은 원문으로 한다.
#   메시지 밖(checkout·restore·stash·경로 인자·뒤 명령)은 그대로 남아 _all_strict_or_git_index 가 종전대로 판정한다.
#   종결 줄은 bash 와 같게 "구분자와 정확히 같은 첫 줄" 로 찾는다(정규식 지연 매칭은 첫 종결 줄 뒤 명령을 데이터로 삼킬 수 있다).
_GIT_COMMIT_PFX = r"(\bgit\b[^\n;&|]*?\bcommit\b[^\n;&|]*?"
COMMIT_MSG_SUBST_OPEN = re.compile(
    _GIT_COMMIT_PFX + r"(?:-m|--message)[ \t]+)\"\$\(cat[ \t]+<<[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2[ \t]*\n")
COMMIT_MSG_FILE_OPEN = re.compile(
    _GIT_COMMIT_PFX + r")(?:-F|--file)[ \t]+-[ \t]+<<[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2([^\n]*)\n")
SUBST_CLOSE_RE = re.compile(r"[ \t]*\)\"")


def _heredoc_end(cmd, pos, tag):
    """pos(본문 첫 글자)부터 구분자와 정확히 같은 첫 줄을 찾아 (그 줄 시작, 그 줄 끝 — 개행 제외) 를 돌려준다. 없으면 None"""
    p = pos
    while p <= len(cmd):
        e = cmd.find("\n", p)
        line_end = len(cmd) if e < 0 else e
        if cmd[p:line_end] == tag:
            return p, line_end
        if e < 0:
            return None
        p = e + 1
    return None


def _commit_msg_literal(cmd):
    """git commit 의 따옴표 구분자 heredoc 메시지(-m "$(cat <<'T' … T)" · -F - <<'T' … T)를 -m 'MSG' 로 바꾼 명령.
    형태가 조금이라도 다르면(종결 줄 부재, 종결 줄 바로 뒤가 )" 가 아님 등) 원문을 그대로 돌려준다(종전 판정 = 차단)."""
    try:
        out, n = cmd, 0
        while n < 16:
            n += 1
            m = COMMIT_MSG_SUBST_OPEN.search(out)
            if m:
                end = _heredoc_end(out, m.end(), m.group(3))
                if not end or end[1] >= len(out):
                    return cmd
                c = SUBST_CLOSE_RE.match(out, end[1] + 1)
                if not c:
                    return cmd
                out = out[:m.start()] + m.group(1) + "'MSG'" + out[c.end():]
                continue
            m = COMMIT_MSG_FILE_OPEN.search(out)
            if m:
                end = _heredoc_end(out, m.end(), m.group(3))
                if not end:
                    return cmd
                out = out[:m.start()] + m.group(1) + "-m 'MSG'" + m.group(4) + out[end[1]:]
                continue
            break
        return _quoted_msg_norm(out)[0]   # cgit A1
    except Exception:
        return cmd


# cgit A1(사용자 지시 2026-10-27 "git 명령을 가드에서 막지 않도록"): 인용 메시지 인자 정규화.
#   원인(실측 09:39:48·09:39:59): `git commit -m "…⏎…"` 처럼 메시지 따옴표 안에 실제 개행이 있으면 _quote_ambiguous 가 True →
#   NX 면제 전체가 꺼져 메시지 속 배포 스크립트 이름이 규칙에 걸렸다. bash 는 따옴표 안 개행을 그대로 git 에 넘긴다(실행 아님).
#   대상: 구간 첫 낱말이 정확히 git(·/usr/bin/git)이고 전역 옵션은 --no-pager · -C <리터럴> 뿐이며 하위명령이 commit · tag ·
#     notes add|append 인 구간의 메시지 옵션(-m · --message · commit 의 -am) 바로 다음 낱말 하나 또는 --message=<인용>.
#     그 낱말 전체가 따옴표 하나 — 작은따옴표 '…'(내용 무제한) 또는 큰따옴표 "…"(내용에 $ · 백틱 · \ · " 없음) — 일 때만 'MSG' 로 바꾸고
#     내용을 bodies 에 넣는다. bodies 가 실행 모양(_msg_exec_shape)이면 _rule_hit 가 정규화를 통째로 버린다(종전 판정).
#   정규화 안 함(원문 = 종전 판정): 명령 어디든 \ · heredoc(<<) · 따옴표 밖 # · $'…' · 닫히지 않은 따옴표, 함수 정의(`()`·function),
#     구간 머리 대입·상태 내장(alias·source·eval·export·hash·enable·command·builtin …)·괄호 묶음 — git 이름 가로채기·재해석 차단.
#     git -c · --git-dir 등 그 밖의 전역 옵션(X3 core.hooksPath)·첫 낱말이 eval/xargs/ssh/env 등인 구간도 대상이 아니다.
#     명령에 실행기 구간이 있거나(_nx_cmd_ok 거짓 — 고정 C214-X33 `… | bash`) 정규화 구간이 NX 구조가 아니면(_nx_git) 하지 않는다.
QMSG_SEPS = ";&|\n\r()"


def _qmsg_scan(cmd):
    """따옴표 규칙으로 최상위 낱말을 훑는다 → [[(시작, 끝, 원문), …] 구간별]. 판정 불확실이면 None"""
    segs, cur, i, n = [], [], 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if ch in " \t":
            i += 1
            continue
        if ch in QMSG_SEPS:
            if cur:
                segs.append(cur)
                cur = []
            i += 1
            continue
        if ch == "#":
            return None
        st, q = i, None
        while i < n:
            ch = cmd[i]
            if q == "'":
                if ch == "'":
                    q = None
                i += 1
                continue
            if q == '"':
                if ch == '"':
                    q = None
                i += 1
                continue
            if ch in " \t" or ch in QMSG_SEPS:
                break
            if ch == "'":
                if i > 0 and cmd[i - 1] == "$":
                    return None
                q = "'"
            elif ch == '"':
                q = '"'
            i += 1
        if q:
            return None
        cur.append((st, i, cmd[st:i]))
    if cur:
        segs.append(cur)
    return segs


def _qmsg_inner(w):
    """낱말 전체가 따옴표 하나면 그 내용, 아니면 None(큰따옴표는 $ · 백틱 · \\ · \" 없을 때만)"""
    if len(w) < 2 or w[0] not in "'\"" or w[-1] != w[0]:
        return None
    inner = w[1:-1]
    if w[0] == "'":
        return None if "'" in inner else inner
    return None if any(c in inner for c in '"$`\\') else inner


def _quoted_msg_norm(cmd):
    """cgit A1: (정규화 명령, [메시지 본문…]). 조건이 하나라도 어긋나면 (원문, [])"""
    try:
        if "\\" in cmd or "<<" in cmd or NX_FUNC_RE.search(_sq_strip(cmd)):
            return cmd, []
        # 고정 C214-X33: 같은 명령 안 실행기(`git log -1 --format=%s | bash` 등)가 저장한 메시지를 곧바로 실행할 수 있다 —
        #   NX 명령 단위 전제(_nx_cmd_ok: 실행기·함수·상태 내장·대입 없음)를 만족할 때만 정규화한다.
        if not _nx_cmd_ok(cmd):
            return cmd, []
        segs = _qmsg_scan(cmd)
        if not segs:
            return cmd, []
        reps = []   # (시작, 끝, 새 글자)
        bodies = []
        for ws in segs:
            raw = [w[2] for w in ws]
            h = raw[0]
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\+?=", h) or h in STATE_VERBS or h in ("{", "}"):
                return cmd, []   # 구간 머리 대입·상태 내장 — 이름 가로채기·재해석 소지(명령 전체 정규화 포기)
            if h not in ("git", "/usr/bin/git"):
                continue
            k = 1
            while k < len(raw):
                if raw[k] == "--no-pager":
                    k += 1
                    continue
                if raw[k] == "-C" and k + 1 < len(raw) and GIT_INDEX_PATH_RE.fullmatch(raw[k + 1]):
                    k += 2
                    continue
                break
            if k >= len(raw):
                continue
            sub = raw[k]
            if sub in ("commit", "tag"):
                k += 1
            elif sub == "notes" and k + 1 < len(raw) and raw[k + 1] in ("add", "append"):
                k += 2
            else:
                continue
            flags = ("-m", "--message", "-am") if sub == "commit" else ("-m", "--message")
            seg_reps, seg_bodies = [], []
            while k < len(raw):
                t = raw[k]
                if t in flags and k + 1 < len(raw):
                    inner = _qmsg_inner(raw[k + 1])
                    if inner is not None:
                        seg_reps.append((ws[k + 1][0], ws[k + 1][1], "'MSG'"))
                        seg_bodies.append(inner)
                    k += 2
                    continue
                if t.startswith("--message="):
                    inner = _qmsg_inner(t[len("--message="):])
                    if inner is not None:
                        seg_reps.append((ws[k][0] + len("--message="), ws[k][1], "'MSG'"))
                        seg_bodies.append(inner)
                k += 1
            if not seg_reps:
                continue
            # 구간 구조 확인: 정규화한 구간이 NX 구조(_nx_git — 서명 -s·에디터 -e·-c 등 거부)일 때만 적용한다(고정 CGIT-D13·D14·D31)
            s0, s1 = ws[0][0], ws[-1][1]
            seg_txt = cmd[s0:s1]
            for st, en, s in sorted(seg_reps, reverse=True):
                seg_txt = seg_txt[:st - s0] + s + seg_txt[en - s0:]
            try:
                stoks = shlex.split(seg_txt)
            except ValueError:
                continue
            if not _nx_git(stoks[1:], []):
                continue
            reps.extend(seg_reps)
            bodies.extend(seg_bodies)
        if not reps:
            return cmd, []
        out = cmd
        for st, en, s in sorted(reps, reverse=True):
            out = out[:st] + s + out[en:]
        return out, bodies
    except Exception:
        return cmd, []


def _commit_msg_split(cmd, qmsg=True):
    """c214 T2: _commit_msg_literal 과 같은 정규화 + 뽑아낸 heredoc 본문 목록 → (정규화 명령, [본문…]).
    형태가 조금이라도 다르면 (원문, []) — 종전 판정.
    cgit A1: qmsg=True 면 인용 메시지 인자 정규화(_quoted_msg_norm)도 한다. _rule_hit 는 원문에 \\ 가 있으면 변환본(cmd_n — \\ 가
    / 로 바뀌어 따옴표 경계가 원문과 달라질 수 있다)에 qmsg=False 를 넘긴다(원문은 \\ 때문에 스스로 정규화하지 않는다)."""
    try:
        out, n, bodies = cmd, 0, []
        while n < 16:
            n += 1
            m = COMMIT_MSG_SUBST_OPEN.search(out)
            if m:
                end = _heredoc_end(out, m.end(), m.group(3))
                if not end or end[1] >= len(out):
                    return cmd, []
                c = SUBST_CLOSE_RE.match(out, end[1] + 1)
                if not c:
                    return cmd, []
                bodies.append(out[m.end():end[0]])
                out = out[:m.start()] + m.group(1) + "'MSG'" + out[c.end():]
                continue
            m = COMMIT_MSG_FILE_OPEN.search(out)
            if m:
                end = _heredoc_end(out, m.end(), m.group(3))
                if not end:
                    return cmd, []
                bodies.append(out[m.end():end[0]])
                out = out[:m.start()] + m.group(1) + "-m 'MSG'" + m.group(4) + out[end[1]:]
                continue
            break
        if not qmsg:
            return out, bodies
        out, qb = _quoted_msg_norm(out)   # cgit A1: 인용 메시지 인자(개행 포함) 정규화
        return out, bodies + qb
    except Exception:
        return cmd, []


# c214 T2: 커밋 메시지 실행 모양 판정(LOW-2 정밀화) — 메시지를 나중에 셸에 넘겨도 명령 자리(줄·; & | 뒤, $( ` <( >( ( { 안)의
#   첫 낱말만 실행된다. 그 첫 낱말이 실행기·해석기·경로형 실행 파일(/ 포함·. 시작)·규칙 일치 이름이고, 그 조각이 규칙에 걸릴 때만
#   "실행 모양" 으로 본다. 종전(메시지 어디든 실행 동사 + 규칙)은 "SSH 비밀번호" · "timeout 처리" · "env 정리" 같은 서술을 막았다.
MSG_CUT_RE = re.compile(r"\$\(|`|<\(|>\(|[\n\r;&|(){}]")
MSG_DOT_EXEC_RE = re.compile(r"(?:^|[\s'\"=;&|(])\.(?:\s|/)")
MSG_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "time", "!", "{", "}", "(", ")"}


def _msg_exec_shape(m, rules):
    try:
        if not _match(rules, m):
            return False
        if MSG_DOT_EXEC_RE.search(m):   # 종전 LOW-2 의 점 실행 절(./경로 · . 파일)은 위치 무관 그대로 유지
            return True
        # 리뷰 M1(X1·X2·X18): 명령 자리 첫 낱말이 경로(/ 포함)·규칙 일치 이름인 조각과, 명령 자리 첫 낱말이 실행 동사인 조각이
        #   함께 있으면 실행 모양(메시지를 셸에 넘기면 "배포 경로; bash" 순으로 실행). 서술 중간의 실행 동사(X22)는 해당 없음
        heads = []
        for piece in MSG_CUT_RE.split(m):
            toks = piece.split()
            while toks and (toks[0] in MSG_KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
                toks = toks[1:]
            if toks:
                heads.append(toks[0].strip("'\""))
        if any(("/" in h or _match(rules, h)) for h in heads) and any(
                os.path.basename(h) in NX_EXECUTORS or NX_INTERP_RE.match(os.path.basename(h))  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
                or os.path.basename(h) in ("source", "eval", "exec", "command", "builtin") for h in heads):
            return True
        for piece in MSG_CUT_RE.split(m):
            toks = piece.split()
            while toks and (toks[0] in MSG_KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
                toks = toks[1:]
            if not toks:
                continue
            h = toks[0].strip("'\"")
            b = os.path.basename(h)
            # 종전 LOW-2 의 부분집합만 남긴다(실행 동사가 명령 자리에 있을 때) — 경로형·규칙 이름 첫 낱말은 종전에도 통과였다(단조 완화)
            exe = b in NX_EXECUTORS or NX_INTERP_RE.match(b) or b in (".", "source", "eval", "exec", "command", "builtin")  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
            if exe and _match(rules, " ".join(toks)):
                return True
            # 보수 보강: 명령 자리가 아니어도 실행 동사 바로 뒤(옵션 낱말 건너뜀) 낱말이 규칙에 걸리면 실행 모양으로 본다("run bash 배포스크립트")
            for k, t in enumerate(toks):
                bt = os.path.basename(t.strip("'\"")).lower()
                if bt in NX_EXECUTORS or NX_INTERP_RE.match(bt) or bt in ("source", "eval", "exec", "command", "builtin"):  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
                    nxt = [x for x in toks[k + 1:] if not x.startswith("-")][:1]
                    if nxt and _match(rules, nxt[0]):
                        return True
        return False
    except Exception:
        return True


def _amb_only_readonly(text, raw):
    """c196 A-2′: 따옴표 혼동(amb) 때문에만 조회 면제가 꺼진 명령인가 — raw 가 amb 이고, amb 를 무시하면 text 의
    모든 구간이 엄격 읽기전용. 차단 문구에 작은따옴표 안내를 붙일지만 정한다(판정 결과는 바꾸지 않는다)."""
    try:
        if not _quote_ambiguous(raw):
            return False
        segs = _segments(_strip_harmless(text))
        return bool(segs) and all(_strict_readonly(s) for s in segs)
    except Exception:
        return False


def _switch_name_read_only(cmd):
    """스위치 이름이 든 셸 명령을 통과시켜도 되는가 — 엄격 읽기전용 + 스위치 이름이 경로 토큰(/ 포함)에 없음.
    (예: grep -n DISABLE_… 파일 → 통과 / ls <hooks>/DISABLE_… · touch … → 차단)"""
    if not _all_strict(cmd):
        return False
    low = SWITCH_NAME.lower()
    for seg in _segments(_strip_harmless(cmd)):
        try:
            toks = shlex.split(seg)
        except ValueError:
            return False
        for t in toks:
            if low in t.lower() and "/" in t:
                return False
    return True


# ── c213: 비실행 인자(NX) 면제 — 인자를 절대 실행하지 않는 동사·하위명령 구간만 규칙 정규식 대상에서 뺀다(허용 목록) ──
#   사용자 지시(2026-10-26): "운영 배포가 아닌데 불필요하게 막는거라면 막지 않도록" — git add/commit/push 의 경로·메시지,
#   sed -i 증거 문구 치환, shellcheck 가 배포 스크립트 이름 때문에 막히던 과차단 해소. 실행기(bash·env·xargs·eval·ssh 등)는 종전 판정.
#   명령 단위 전제(_nx_cmd_ok): 함수 정의(`()`·function)·alias·상태 내장(source·export·set …)·환경 대입 구간이 하나라도 있으면
#   NX 를 통째로 끈다(이름 가로채기 `shellcheck() { bash "$@"; }` · PATH 바꿔치기 차단).
#   구간 조건(_nonexec_args): 작은따옴표 밖 $ · 백틱 · < · > 없음(치환·리다이렉트로 사본을 만들어 실행하는 꼴 차단), shlex 성공,
#   LC_ALL/LANG 외 환경 접두 없음, 첫 낱말에 / 가 있으면 SAFE_BIN_DIRS 안.
NX_GIT_SUBS = ("add", "commit", "push", "status", "diff", "log", "show", "blame", "grep", "ls-files", "cat-file",
               "check-ignore", "rev-parse",
               "tag", "notes", "restore", "rm", "reset",   # cgit A3·A4: 전용 판정(_nx_git_tag·_nx_git_notes·_git_index_sub)
               "checkout", "switch", "stash", "clean",     # cgit A6: 비실행 작업 트리 git(공통 금지 옵션 판정)
               "config")                                   # cgit A6: 조회·실행 무관 키만(_nx_git_config)
NX_GIT_BAD_LONG = ("--exec", "--receive-pack", "--upload-pack", "--output", "--open-files-in-pager", "--ext-diff",
                   "--push-option", "--config-env", "--exec-path")
NX_GIT_EDIT_LONG = ("--edit", "--interactive", "--patch", "--reedit-message", "--template")
# 커밋 메시지 속 실행 동사(리뷰 LOW-2) — 규칙 일치와 함께 있으면 NX 를 끈다(메시지를 저장해 두고 실행하는 2단계의 앞쪽)
NX_EXEC_WORD_RE = re.compile(r"(?i)(?:^|[^\w.-])(?:bash|sh|dash|zsh|ksh|source|eval|exec|env|nohup|timeout|xargs|"
                             r"cmd(?:\.exe)?|powershell(?:\.exe)?|pwsh|ssh)(?![\w-])|(?:^|[\s'\"=;&|(])\.(?:\s|/)")
NX_FUNC_RE = re.compile(r"\(\s*\)|(?:^|[\s;&|({])function(?:\s|$)")
NX_SED_SUFFIX_RE = re.compile(r"^[\w.~-]*$")
NX_EXECUTORS = {"bash", "sh", "dash", "zsh", "ksh", "ash", "mksh", "busybox", "eval", "exec", "env", "nohup", "timeout",
                "xargs", "nice", "setsid", "stdbuf", "sudo", "doas", "watch", "script", "time", "cmd", "cmd.exe",
                "powershell", "powershell.exe", "pwsh", "pwsh.exe", "wsl", "wsl.exe", "ssh", "make", "find", "parallel",
                "awk", "gawk", "mawk", "perl", "ruby", "node", "php", "lua", "tclsh", "expect", "chroot", "unshare", "flock"}
NX_INTERP_RE = re.compile(r"^(python[0-9.]*|py|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node[0-9.]*)$")
NX_SED_FLAGS = set("gpIi0123456789")


def _nx_cmd_ok(cmd):
    """c213: 명령 전체가 NX 면제를 받을 수 있는가 — 함수 정의·alias·상태 내장·환경 대입이 있으면 False(리뷰 MEDIUM-2)"""
    try:
        sq = _sq_strip(cmd)
        if NX_FUNC_RE.search(sq):
            return False
        for seg in _segments(_strip_harmless(cmd)):
            try:
                toks = shlex.split(seg)
            except ValueError:
                return False
            while toks and re.fullmatch(r"^(LC_ALL|LANG)=[^\s]*$", toks[0]):
                toks = toks[1:]
            if not toks:
                continue
            h = toks[0]
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\+?=", h):
                return False
            if h in STATE_VERBS or os.path.basename(h) in STATE_VERBS or h in ("{", "}", "(", ")"):
                if not (h == "command" and _strict_readonly(seg)):   # c214 T4: command -v 이름 조회는 상태를 바꾸지 않는다
                    return False
            # 실행기 구간(셸·래퍼·해석기·로컬 실행 파일)이 하나라도 있으면 NX 를 끈다 — 글롭으로 이름을 숨긴 실행 앞의
            #   git add(탐침 P6 `git add 배포 && bash ./Deploy/dep*`)·`cat Deploy/dep* | bash`(P11) 를 현행처럼 차단 유지.
            #   bash -n 처럼 엄격 읽기전용인 구간은 실행기로 보지 않는다.
            b = os.path.basename(h).lower()
            # cgit A2·A4: `timeout [옵션] 시간 git …`(git 부분이 NX 구조) · `xargs [-r] git <인덱스 전용> --` 는 실행기로 보지 않는다.
            #   $ · 백틱(작은따옴표 밖)이 있으면 종전(실행기). 규칙 의존 판정(커밋 메시지 실행 모양)은 구간 판정 _nonexec_args 가 한다.
            if os.path.basename(h) in ("timeout", "xargs") and ("/" not in h or os.path.dirname(h) in SAFE_BIN_DIRS) and \
                    not any(x in _sq_strip(seg) for x in ("$", "`")):
                t2 = [b] + toks[1:]
                if b == "xargs" and _xargs_git_index(t2):
                    continue
                if b == "timeout":
                    ga = _timeout_git(t2)
                    if ga is not None and _nx_git(ga, []):
                        continue
            if ((b in NX_EXECUTORS or NX_INTERP_RE.match(b) or ("/" in h and os.path.dirname(h) not in SAFE_BIN_DIRS))  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
                    and not _strict_readonly(seg) and not _bash_n_read(seg)):   # c214 D-3: bash -nv 구문검사도 실행기 아님
                return False
        return True
    except Exception:
        return False


def _nx_git_commit(rest, rules):
    """git commit 인자가 NX 인가 — 메시지 옵션 필수(LOW-4), 에디터 경로 거부, 메시지 실행 동사+규칙 일치 거부(LOW-2)"""
    msgs, has_msg, i = [], False, 0
    while i < len(rest):
        t = rest[i]
        if t in ("-m", "--message", "-F", "--file"):
            if i + 1 >= len(rest):
                return False
            if t in ("-m", "--message"):
                msgs.append(rest[i + 1])
            has_msg, i = True, i + 2
            continue
        if t.startswith("--message="):
            msgs.append(t.split("=", 1)[1])
            has_msg, i = True, i + 1
            continue
        if t.startswith("--file="):
            has_msg, i = True, i + 1
            continue
        if t.startswith("--"):
            if t == "--" or _long_hit(t, NX_GIT_EDIT_LONG) or _long_hit(t, NX_GIT_BAD_LONG) or \
                    t.split("=", 1)[0] in ("--reuse-message", "--squash", "--fixup", "--cleanup", "--gpg-sign"):
                return False
            i += 1
            continue
        if t.startswith("-") and len(t) > 1:
            body, j = t[1:], 0
            while j < len(body):
                ch = body[j]
                if ch in "mF":
                    val = body[j + 1:]
                    if not val:
                        if i + 1 >= len(rest):
                            return False
                        val, i = rest[i + 1], i + 1
                    if ch == "m":
                        msgs.append(val)
                    has_msg = True
                    break
                if ch not in "aqvsn":
                    return False
                j += 1
            i += 1
            continue
        i += 1   # 경로 인자(부분 커밋) — 실행 아님
    if not has_msg:
        return False
    for m in msgs:
        if _msg_exec_shape(m, rules):   # c214 T2: 명령 자리의 실행 동사 + 규칙 일치만 거부(종전 LOW-2 의 부분집합)
            return False
    return True


# cgit A2: timeout 래퍼 — `timeout [-k 시간|--kill-after=시간] [-s 신호|--signal=신호] [--foreground] [--preserve-status] [-v]
#   시간 git …` 의 git 뒤 인자를 돌려준다. 그 밖(시간 형식 불일치·git 이 아닌 명령·경로 붙은 git·알 수 없는 옵션)은 None(실행기 판정 유지).
TIMEOUT_DUR_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)?[smhd]?$")
TIMEOUT_SIG_RE = re.compile(r"^[A-Za-z0-9+-]+$")


def _timeout_git(toks):
    try:
        if not toks or toks[0] != "timeout":
            return None
        i = 1
        while i < len(toks):
            t = toks[i]
            if t in ("--foreground", "--preserve-status", "-v", "--verbose"):
                i += 1
                continue
            if t in ("-k", "--kill-after", "-s", "--signal"):
                if i + 1 >= len(toks):
                    return None
                v = toks[i + 1]
                if not (TIMEOUT_DUR_RE if t in ("-k", "--kill-after") else TIMEOUT_SIG_RE).match(v):
                    return None
                i += 2
                continue
            if t.startswith(("--kill-after=", "--signal=")):
                k, v = t.split("=", 1)
                if not (TIMEOUT_DUR_RE if k == "--kill-after" else TIMEOUT_SIG_RE).match(v):
                    return None
                i += 1
                continue
            if t.startswith(("-k", "-s")) and len(t) > 2:
                if not (TIMEOUT_DUR_RE if t[1] == "k" else TIMEOUT_SIG_RE).match(t[2:]):
                    return None
                i += 1
                continue
            break
        if i >= len(toks) or not TIMEOUT_DUR_RE.fullmatch(toks[i]):
            return None
        i += 1
        if i >= len(toks) or toks[i] != "git":
            return None
        return toks[i + 1:]
    except Exception:
        return None


# cgit A3: git tag · git notes 메시지는 데이터다 — 에디터·서명 프로그램을 띄우는 옵션은 거부하고 메시지는 실행 모양 검사.
NX_TAG_FLAGS = set("afdl")


def _nx_git_tag(rest, rules):
    """git tag 인자가 NX 인가 — -a·--annotate·-f·--force·-d·--delete·-l·--list·-n[숫자]·-m/--message·-F/--file 만.
    -s·-u·--sign·--local-user·-e·--edit·--cleanup 등 그 밖의 옵션 거부, 주석 태그(-a)인데 메시지가 없으면(에디터) 거부"""
    msgs, has_msg, annot, i = [], False, False, 0
    while i < len(rest):
        t = rest[i]
        if t in ("-m", "--message", "-F", "--file"):
            if i + 1 >= len(rest):
                return False
            if t in ("-m", "--message"):
                msgs.append(rest[i + 1])
            has_msg, i = True, i + 2
            continue
        if t.startswith(("--message=", "--file=")):
            if t.startswith("--message="):
                msgs.append(t.split("=", 1)[1])
            has_msg, i = True, i + 1
            continue
        if t in ("--annotate", "--force", "--delete", "--list"):
            annot = annot or t == "--annotate"
            i += 1
            continue
        if re.fullmatch(r"^-n[0-9]*$", t):
            i += 1
            continue
        if t.startswith("--"):
            return False
        if t.startswith("-") and len(t) > 1:
            body, j = t[1:], 0
            while j < len(body):
                ch = body[j]
                if ch in "mF":
                    val = body[j + 1:]
                    if not val:
                        if i + 1 >= len(rest):
                            return False
                        val, i = rest[i + 1], i + 1
                    if ch == "m":
                        msgs.append(val)
                    has_msg = True
                    break
                if ch not in NX_TAG_FLAGS:
                    return False
                annot = annot or ch == "a"
                j += 1
            i += 1
            continue
        if not GIT_INDEX_PATH_RE.fullmatch(t):
            return False
        i += 1
    if annot and not has_msg:
        return False
    return not any(_msg_exec_shape(m, rules) for m in msgs)


def _nx_git_notes(rest, rules):
    """git notes add|append (-m/--message · -F/--file · -f/--force · --allow-empty)… [리터럴 대상] — 메시지 필수(없으면 에디터)"""
    if not rest or rest[0] not in ("add", "append"):
        return False
    msgs, has_msg, pos, i = [], False, 0, 1
    while i < len(rest):
        t = rest[i]
        if t in ("-m", "--message", "-F", "--file"):
            if i + 1 >= len(rest):
                return False
            if t in ("-m", "--message"):
                msgs.append(rest[i + 1])
            has_msg, i = True, i + 2
            continue
        if t.startswith(("--message=", "--file=")):
            if t.startswith("--message="):
                msgs.append(t.split("=", 1)[1])
            has_msg, i = True, i + 1
            continue
        if t in ("-f", "--force", "--allow-empty"):
            i += 1
            continue
        if t.startswith("-") or not GIT_INDEX_PATH_RE.fullmatch(t):
            return False
        pos, i = pos + 1, i + 1
    if not has_msg or pos > 1:
        return False
    return not any(_msg_exec_shape(m, rules) for m in msgs)


# cgit A6(사용자 지시 2026-10-27 10:52 — F-5 결정 대체, 리드 확인): git config 는 실행 통로 키(alias.* · core.hooksPath ·
#   core.sshCommand · core.pager · core.fsmonitor · core.editor · *.textconv · filter.* · diff.*.command 등)를 설정하면 나중에 코드를 실행한다.
#   NX 는 ① 조회 형태(--get · --get-all · --get-regexp · --list/-l · --show-origin · --name-only · --null 등, 값 인자 없이)는 키 무관,
#   ② 설정·해제는 GIT_CONFIG_SAFE_KEY_RE(실행과 무관한 키) 만. 범위 옵션은 --global · --local · --system · --worktree 만
#   (--file · -f · --blob · -e/--edit · --includes 등 거부). 그 밖은 종전(규칙 판정 — 배포 이름이 인자에 있으면 차단).
GIT_CONFIG_SAFE_KEY_RE = re.compile(
    r"^(user\.(name|email|signingkey)|core\.(autocrlf|quotepath|safecrlf|filemode|ignorecase|longpaths|eol|precomposeunicode)|"
    r"i18n\.[a-z]+|color\.[a-z.]+|push\.(default|autosetupremote)|pull\.(rebase|ff)|init\.defaultbranch|"
    r"status\.showuntrackedfiles|fetch\.prune|merge\.ff|advice\.[a-z]+|log\.[a-z]+|branch\.[\w./-]+\.(remote|merge|rebase))$", re.I)
_GIT_CONFIG_SCOPE = ("--global", "--local", "--system", "--worktree")
_GIT_CONFIG_READ = ("--get", "--get-all", "--get-regexp", "--list", "-l", "--show-origin", "--show-scope", "--name-only",
                    "--null", "-z", "--default", "--type", "--bool", "--int", "--path")
_GIT_CONFIG_SET = ("--unset", "--unset-all", "--add", "--replace-all")


def _nx_git_config(rest):
    try:
        reads, sets, pos = False, False, []
        for t in rest:
            if t in _GIT_CONFIG_SCOPE:
                continue
            if t in _GIT_CONFIG_READ or t.startswith(("--type=", "--default=")):
                reads = True
                continue
            if t in _GIT_CONFIG_SET:
                sets = True
                continue
            if t.startswith("-"):
                return False
            pos.append(t)
        if reads and not sets:
            return True
        if not pos:
            return False
        return bool(GIT_CONFIG_SAFE_KEY_RE.fullmatch(pos[0]))
    except Exception:
        return False


def _nx_git(args, rules):
    """git 구간이 NX 인가 — 하위명령 허용 목록 + 금지 옵션 명시 판정(리뷰 MEDIUM-3·LOW-1)"""
    a = list(args)
    while a:
        if a[0] == "--no-pager":
            a = a[1:]
            continue
        if a[0] == "-C" and len(a) >= 2 and a[1]:
            a = a[2:]
            continue
        break
    if not a or a[0] not in NX_GIT_SUBS:   # 전역 -c · --config-env · --exec-path 등은 여기서 걸러진다
        return False
    sub, rest = a[0], a[1:]
    for t in rest:
        if t.startswith("--") and _long_hit(t, NX_GIT_BAD_LONG):
            return False
    if sub == "commit":
        return _nx_git_commit(rest, rules)
    if sub == "tag":   # cgit A3
        return _nx_git_tag(rest, rules)
    if sub == "notes":   # cgit A3
        return _nx_git_notes(rest, rules)
    if sub in GIT_INDEX_SUBS and _git_index_sub(sub, rest):   # cgit A4: 인덱스 전용 형태
        return True
    if sub == "config":   # cgit A6: 조회 형태(키 무관)·실행 무관 키 설정만 NX — alias·core.hooksPath 등 실행 통로 키는 종전(규칙 판정)
        return _nx_git_config(rest)
    # cgit A6(사용자 지시 10:52): restore·rm·reset(작업 트리 형태 포함)·checkout·switch·stash·clean 은 배포 파일을 인자로 받아도
    #   실행하지 않는다 — 아래 공통 금지 옵션(-c·-x·-O·-o·실행 장옵션)만 보고 NX. 자기 보호(가드 파일)는 _git_index_only 가 따로 막는다.
    #   git config 는 alias·core.hooksPath·core.sshCommand 로 실행 통로를 만들므로 NX 에 넣지 않는다(F-5 사용자 결정과 같음).
    for t in rest:
        if t in ("-c", "-x") or _short_has(t, "Oo"):
            return False
        if sub == "push" and "::" in t:
            return False
        if sub == "add" and (_short_has(t, "pie") or _long_hit(t, NX_GIT_EDIT_LONG)):
            return False
    return True


def _nx_sed_script(sc, rules):
    """sed 스크립트가 [주소]s///[gpIi숫자] · [주소]d · [주소]p 만으로 되어 있고 치환부가 규칙에 안 걸리는가(리뷰 LOW-3·MEDIUM-1)"""
    i, n = 0, len(sc)

    def _delim_part(k, d):
        out = []
        while k < n:
            c = sc[k]
            if c == "\\":
                if k + 1 >= n:
                    return None, k
                out.append(sc[k:k + 2])
                k += 2
                continue
            if c == d:
                return "".join(out), k + 1
            out.append(c)
            k += 1
        return None, k

    while True:
        while i < n and sc[i] in " \t\n;":
            i += 1
        if i >= n:
            return True
        # 주소: 숫자·$·,·~·+ 그리고 /정규식/
        while i < n:
            if sc[i] in "0123456789$,~+ \t!":
                i += 1
                continue
            if sc[i] == "/":
                part, i = _delim_part(i + 1, "/")
                if part is None:
                    return False
                if i < n and sc[i] == "I":
                    i += 1
                continue
            break
        if i >= n:
            return False
        c = sc[i]
        if c in "dp":
            i += 1
        elif c == "s":
            if i + 1 >= n or sc[i + 1] in "\n\\":
                return False
            d = sc[i + 1]
            pat, i = _delim_part(i + 2, d)
            if pat is None:
                return False
            repl, i = _delim_part(i, d)
            if repl is None:
                return False
            # & · \숫자 는 패턴이 맞힌 글자를 치환부에 넣는다 — 치환부 판정이 무력해지므로 NX 아님(fail-closed)
            if re.search(r"(?<!\\)(?:\\\\)*&|\\[0-9]", repl):
                return False
            plain = re.sub(r"\\(.)", lambda m: "\n" if m.group(1) == "n" else m.group(1), repl, flags=re.S)
            if _match(rules, plain):
                return False
            while i < n and sc[i] not in " \t\n;":
                if sc[i] not in NX_SED_FLAGS:   # e w W m M 등 — 실행·파일 쓰기 플래그 거부
                    return False
                i += 1
        else:
            return False   # e w W r R y a i c { } 등 그 밖의 명령 전부 거부
        while i < n and sc[i] in " \t":
            i += 1
        if i < n and sc[i] not in ";\n":
            return False


def _nx_sed(args, rules):
    """sed 구간이 NX 인가 — 옵션 허용 목록(-i[접미사]·--in-place[=S]·-n·--quiet·-E·-r·-e·--expression)만"""
    scripts, nonopt, has_e, i = [], [], False, 0
    while i < len(args):
        t = args[i]
        if t == "--":
            nonopt += args[i + 1:]
            break
        if t.startswith("--"):
            n = t.split("=", 1)[0]
            if n == "--in-place":
                if "=" in t and not NX_SED_SUFFIX_RE.fullmatch(t.split("=", 1)[1]):
                    return False
            elif t in ("--quiet", "--silent", "--regexp-extended"):
                pass
            elif n == "--expression":
                if "=" in t:
                    scripts.append(t.split("=", 1)[1])
                else:
                    if i + 1 >= len(args):
                        return False
                    i += 1
                    scripts.append(args[i])
                has_e = True
            else:
                return False
            i += 1
            continue
        if t.startswith("-") and t != "-":
            body, j = t[1:], 0
            while j < len(body):
                ch = body[j]
                if ch in "nEr":
                    j += 1
                    continue
                if ch == "i":   # GNU: -i 뒤에 붙은 글자는 전부 백업 접미사(-ie = -i + 접미사 e)
                    if not NX_SED_SUFFIX_RE.fullmatch(body[j + 1:]):
                        return False
                    break
                if ch == "e":
                    v = body[j + 1:]
                    if not v:
                        if i + 1 >= len(args):
                            return False
                        i += 1
                        v = args[i]
                    scripts.append(v)
                    has_e = True
                    break
                return False   # -f -s -z -u -l --debug 등
            i += 1
            continue
        nonopt.append(t)
        i += 1
    if not has_e:
        if not nonopt:
            return False
        scripts.append(nonopt[0])
    return bool(scripts) and all(_nx_sed_script(s, rules) for s in scripts)


def _nonexec_args(seg, rules):
    """c213: 인자를 실행하지 않는 동사 구간인가(NX) — git(허용 하위명령)·sed(치환/삭제/출력만)·shellcheck.
    True 면 그 구간은 규칙 정규식 판정에서 뺀다. 조금이라도 해석이 불확실하면 False(종전 판정 — fail-closed)."""
    try:
        # c214 T1: $ · 백틱은 큰따옴표 안에서도 확장되므로 작은따옴표 밖 전체에서 거부(종전).
        #   < · > 는 따옴표(작은·큰) 안에서는 bash 가 문자 그대로 넘기는 데이터다 — 따옴표 밖에서만 거부(커밋 트레일러 <email> 과차단 해소).
        if any(x in _sq_strip(seg) for x in ("$", "`")) or any(x in _q_strip(seg) for x in ("<", ">")):
            return False
        toks = shlex.split(seg)
    except ValueError:
        return False
    except Exception:
        return False
    while toks and re.fullmatch(r"^(LC_ALL|LANG)=[^\s]*$", toks[0]):
        toks = toks[1:]
    if not toks or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]):
        return False
    v = toks[0]
    if "/" in v:
        if os.path.dirname(v) not in SAFE_BIN_DIRS:
            return False
        v = os.path.basename(v)
    args = toks[1:]
    try:
        if v == "git":
            return _nx_git(args, rules)
        if v == "sed":
            return _nx_sed(args, rules)
        if v == "shellcheck":
            return True
        if v == "timeout":   # cgit A2: timeout 래퍼를 벗긴 git 부분이 NX 일 때만
            ga = _timeout_git([v] + args)
            return ga is not None and _nx_git(ga, rules)
        if v == "xargs":   # cgit A4: xargs [-r] git <인덱스 전용> -- 만
            return _xargs_git_index([v] + args)
    except Exception:
        return False
    return False


def _match_cmd(rules, cmd, raw=None, allow=None):
    """셸 명령 판정 — 구간별로 보고, 엄격 읽기전용 구간만 건너뛴다. 원격 실행(ssh '...')은 한 구간으로 본다.
    raw(변환 전 명령)에 따옴표 혼동 소지가 있으면 어떤 구간도 건너뛰지 않는다(전 구간 + 전체 문자열 판정).
    c199: amb 가 아니면 교차 판정은 비조회 구간이 든 파이프 묶음만 이어 붙여 본다.
    c196: allow(_exec_allow_plan 결과)가 있으면 허용 구간과 전체 문자열은 allow["rules"] 를 뺀 규칙으로 판정한다
    (허용 구간 밖의 구간은 전부 엄격 읽기전용임이 plan 조건으로 보장된다)."""
    amb = _quote_ambiguous(cmd if raw is None else raw)
    segs = _segments(_strip_harmless(cmd))
    red = [r for r in rules if r["id"] not in allow["rules"]] if allow else rules
    nx_ok = not amb and _nx_cmd_ok(cmd if raw is None else raw) and _nx_cmd_ok(cmd)   # c213: NX 면제 명령 단위 전제

    def _nx(s):
        return nx_ok and _nonexec_args(s, red if (allow and s in allow["segs"]) else rules)

    for seg in segs:
        if not amb and (_strict_readonly(seg) or _bash_n_read(seg) or _awk_read(seg) or _nx(seg)):   # c214 D-3
            continue
        r = _match(red if (allow and seg in allow["segs"]) else rules, seg)
        if r:
            return r
    # 구간을 가로지르는 조합(예: kill 과 운영 경로가 다른 구간)은 한 번 더 본다.
    # c199 A-1″: 비조회 구간이 든 파이프 묶음만 이어 붙인다 — ; && || & 개행으로 떨어진 조회 묶음은 빼고
    #   (date -s …; cat 배포 → 통과), 파이프로 실행기에 넘기는 묶음은 조회 구간까지 넣는다(cat 배포 | bash → 차단).
    #   따옴표 혼동(amb)이면 종전대로 전체 문자열.
    # c195b: 직전 인자 $_ 참조가 있으면 조회 구간 값이 뒤 구간으로 넘어가므로 전체 문자열로 판정한다(amb 와 같은 취급)
    if segs and (amb or LAST_ARG_RE.search(cmd)):
        return _match(red, cmd)
    rest = []
    for grp in _pipe_groups(_strip_harmless(cmd)):
        # c195c: 버릴 수 있는 묶음은 _droppable(허용 목록 — 스크립트 재판정과 공유)을 전부 만족할 때만. cd 계열·$·백틱·-v·상태 내장은 남긴다
        # c213: 묶음의 모든 구간이 버릴 수 있거나 NX 일 때만 버린다 — 실행기가 하나라도 섞인 파이프 묶음은 NX 구간까지 통째로 남긴다
        if not all(_droppable(s, v_ok=True) or _nx(s) for s in grp):   # c214 D-16: 셸 교차 판정만 조회 동사 -v 허용
            rest.extend(grp)
    if rest:
        return _match(red, " ; ".join(rest))
    return None


def _match(rules, text, only=None):
    for r in rules:
        if only is not None and r["id"] not in only:
            continue
        if r["all"] and all(x.search(text) for x in r["all"]) and not any(x.search(text) for x in r["unless"]):
            return r
    return None


# ── c195 C-18: 셸 스크립트 쓰기 내용의 조회 줄 제외 재판정 ─────────────────────────
#   종전: 스크립트 쓰기 내용 전체에 match_all 을 걸어, 규칙의 두 조건이 서로 다른 줄(하나는 조회 줄)에만 있어도 차단했다.
#   변경: .sh/.bash 쓰기 내용이 규칙에 걸리면, 주석 줄과 "전부 엄격 읽기전용(+curl 읽기 형태)인 파이프 묶음" 을 뺀
#   나머지로 한 번 더 판정해 무일치면 통과시킨다. 셸 명령 판정(_match_cmd)의 묶음 단위 교차 판정과 같은 기준이다.
#   fail-closed(재판정 안 함 → 종전 차단): heredoc(<<) · 줄 끝 \ · 줄 안 따옴표 혼동(_quote_ambiguous — 닫히지 않은 따옴표,
#   따옴표 밖 \ · #, $'…', 큰따옴표 안 위험 이스케이프) · CR 만 있는 줄바꿈. .py 등 다른 확장자는 대상이 아니다(종전 유지).
#   잔존 한계(정직 고지): 조회로 본 줄이 만든 값을 다른 줄이 쓰는 경로는 없다(조회 줄은 대입·치환·리다이렉트가 없다).
#   ss·lsof 등 READONLY_VERBS 밖 조회는 비조회로 남아 종전처럼 차단된다(과차단 잔존 — 목록 확장은 별건).
CURL_BAD_SHORT = set("dFTOoKDc")
CURL_BAD_LONG = ("--data", "--form", "--upload-file", "--json", "--output", "--remote-name", "--config", "--dump-header",
                 "--cookie-jar", "--stderr", "--trace", "--libcurl", "--etag-save", "--hsts", "--alt-svc", "--post")


def _curl_read(seg):
    """curl 읽기 형태 구간인가 — GET 외 메서드·본문 전송·업로드·파일 쓰기 옵션·치환·리다이렉트가 없을 것"""
    if any(x in _sq_strip(seg) for x in ("$(", "`", "<(", ">(", ">", "<")):
        return False
    try:
        toks = shlex.split(seg)
    except ValueError:
        return False
    if not toks:
        return False
    v = toks[0]
    if "/" in v:
        if os.path.dirname(v) not in SAFE_BIN_DIRS:
            return False
        v = os.path.basename(v)
    if v != "curl":
        return False
    args = toks[1:]
    i = 0
    while i < len(args):
        t = args[i]
        if t.startswith("--"):
            n = t.split("=", 1)[0]
            if n == "--request":
                val = t.split("=", 1)[1] if "=" in t else (args[i + 1] if i + 1 < len(args) else "")
                if val.upper() != "GET":
                    return False
                i += 1 if "=" in t else 2
                continue
            if any(n.startswith(b) for b in CURL_BAD_LONG):
                return False
        elif t.startswith("-") and len(t) > 1:
            body = t[1:]
            if "X" in body:
                k = body.index("X")
                if any(c in CURL_BAD_SHORT for c in body[:k]):
                    return False
                val = body[k + 1:] or (args[i + 1] if i + 1 < len(args) else "")
                if val.upper() != "GET":
                    return False
                i += 1 if body[k + 1:] else 2
                continue
            if any(c in CURL_BAD_SHORT for c in body):
                return False
        i += 1
    return True


# c195b(odev_review 🟡2): 조회로 분류된 구간이라도 뒤 구간으로 상태를 넘기는 경로가 있으면 교차 판정에서 빼지 않는다.
#   ① 작업 디렉터리 — cd(엄격 읽기전용 허용) 가 바꾼 위치가 뒤 구간의 상대경로(kill $(cat x.pid) 등) 의미를 바꾼다
#      ⇒ cd 계열 구간은 묶음째 남긴다(조건 없는 cd 는 남겨도 무해 — 규칙 조건이 없으면 일치하지 않는다).
#   ② 직전 인자 $_ / ${_…} — 조회 구간의 마지막 인자(경로)가 뒤 구간으로 값 그대로 넘어간다
#      ⇒ 본문·명령에 있으면 조회 구간을 하나도 빼지 않는다(스크립트: 재판정 안 함 → 종전 차단, 셸: 전체 문자열 판정).
#   c195c(재검토 1차 — printf -v · ${n:=w} · ${n=w} 잔존)에서 블랙리스트 확장을 버리고 ★허용 목록★으로 바꿨다 — _droppable 참조.
CWD_VERBS = ("cd", "pushd", "popd", "chdir")
LAST_ARG_RE = re.compile(r"\$\{?_(?![A-Za-z0-9_])")
STATE_VERBS = ("read", "mapfile", "readarray", "declare", "typeset", "local", "export", "eval", "source", ".", "alias",
               "set", "shopt", "trap", "function", "unset", "readonly", "builtin", "command", "enable", "hash", "ulimit",
               "umask", "getopts", "let")


def _droppable(seg, v_ok=False):
    """c195c 허용 목록: 교차 판정·스크립트 재판정에서 버려도 되는 조회 구간인가 — 상태를 뒤 구간으로 넘길 구성이 ★전혀 없는★ 구간만.
    조건(하나라도 어기면 False — 버리지 않는다, fail-closed):
      ① 엄격 읽기전용 또는 curl 읽기(리다이렉트·치환·실행 수단 없음 — 기존 조건)
      ② $ · 백틱 0개(작은따옴표 안 포함) — 모든 확장·치환·대입(${n:=w}·$[ ]·$(( )) 등) 차단
      ③ 단일 대시 옵션에 v 0개(printf -v 류) · 괄호 0개(함수 정의)
      ④ 첫 단어가 상태 변경 내장(read·declare·export·eval·source·set …)·cd 계열이 아님
    조회 줄에 $ 가 꼭 필요한 사례는 버리지 않으므로 종전 전체 판정(차단 쪽)으로 돌아간다 — 보호 우선."""
    # c214 T5: 작은따옴표 안 $ · 백틱 · 괄호는 bash 가 글자 그대로 넘긴다(grep 'x.sh$' · grep '^f()') — 판정에서 뺀다.
    #   단 첫 낱말이 셸(bash/sh/dash -c '…')이면 작은따옴표 내용이 다음 셸의 코드이므로 종전대로 원문 전체를 본다.
    try:
        _h = shlex.split(seg)[:1]
    except ValueError:
        return False
    _chk = seg if (not _h or os.path.basename(_h[0]) in ("bash", "sh", "dash", "zsh", "ksh")) else _sq_strip(seg)
    if "$" in _chk or "`" in _chk or "(" in _chk or ")" in _chk:
        return False
    try:
        toks = shlex.split(seg)
    except ValueError:
        return False
    while toks and re.fullmatch(r"^(LC_ALL|LANG)=[^\s]*$", toks[0]):
        toks = toks[1:]
    if not toks:
        return False
    v = os.path.basename(toks[0])
    if v in CWD_VERBS or v in STATE_VERBS or toks[0] in STATE_VERBS:
        return False
    if _bash_n_read(seg) or _awk_read(seg):   # c214 D-3: 구문검사·awk 읽기(배포 규칙 판정 전용 — 자기 보호 판정은 무변경)
        return True
    # c214 D-16: ③ 의 -v 거부는 변수에 값을 넣는 옵션(printf -v 류) 대비다. 아래 동사의 -v 는 반전(grep·rg)·비인쇄 문자 표시(cat)·
    #   머리 표시(head·tail)·자연 정렬(ls)·시작 번호(nl) 뿐이라 셸 상태를 바꾸지 못한다 — 이 동사만 ③ 에서 뺀다(나머지 조건은 그대로).
    #   실측 원인: `git add … Deploy/<배포 스크립트> 2>&1 | grep -v "…"` 의 grep -v 가 파이프 묶음을 못 버려 git add(NX)까지 교차 판정에 남았다.
    #   v_ok=True 는 셸 명령 교차 판정(_match_cmd)만 쓴다 — 스크립트 쓰기 재판정·heredoc 정규화는 종전(고정 C18-D36 수용 과차단 유지).
    if not (v_ok and os.path.basename(toks[0]) in DROP_V_OK_VERBS) and \
            any(t.startswith("-") and not t.startswith("--") and "v" in t[1:] for t in toks[1:]):
        return False
    return _strict_readonly(seg) or _curl_read(seg)


DROP_V_OK_VERBS = {"grep", "egrep", "fgrep", "rg", "cat", "head", "tail", "ls", "nl"}   # c214 D-16: -v 가 상태를 바꾸지 않는 조회 동사


# c214 D-3: 배포 규칙 판정 전용 읽기 구간 — _strict_readonly 에 넣지 않는다(자기 보호의 엄격 읽기전용 판정·고정 DA2/DA4/DA6 무변경).
#   _match_cmd 구간 판정·_droppable(교차 판정)·_nx_cmd_ok(실행기 판정)에서만 쓴다.
AWK_HEADS = ("awk", "gawk", "mawk", "nawk")
AWK_BAD_RE = re.compile(r"system|getline|close|fflush|[|>@]|\benviron\b|procinfo", re.I)


def _rr_head(seg, heads):
    """seg 의 첫 낱말이 heads 중 하나(경로는 SAFE_BIN_DIRS 만)면 (토큰들), 아니면 None. $ · 백틱 · 치환·리다이렉트·heredoc 이 따옴표 밖에 있으면 None"""
    sq = _sq_strip(seg)
    if any(x in sq for x in ("$", "`", "<", ">")):
        return None
    try:
        toks = shlex.split(seg)
    except ValueError:
        return None
    if not toks:
        return None
    h = toks[0]
    if "/" in h and os.path.dirname(h) not in SAFE_BIN_DIRS:
        return None
    if os.path.basename(h) not in heads:
        return None
    return toks


def _bash_n_read(seg):
    """bash|sh|dash 에 -[nvx] 옵션 묶음만(하나 이상에 n) + 위치 인자 정확히 1개(파일) — 구문검사만 하고 아무것도 실행하지 않는다.
    -c · -s · -i · -o · -- · + 옵션 · 추가 인자가 하나라도 있으면 False(bash -n -c '…' · bash -ne x 등은 종전 판정)"""
    try:
        toks = _rr_head(seg, ("bash", "sh", "dash"))
        if not toks:
            return False
        opts = [t for t in toks[1:] if t.startswith(("-", "+"))]
        pos = [t for t in toks[1:] if not t.startswith(("-", "+"))]
        if len(pos) != 1 or toks[1:] != opts + pos:
            return False
        return bool(opts) and all(re.fullmatch(r"^-[nvx]+$", t) for t in opts) and any("n" in t for t in opts)
    except Exception:
        return False


def _awk_read(seg):
    """awk 읽기 — 옵션은 -F 만, 프로그램(첫 위치 인자)에 system · getline · close · fflush · | · > · @ · ENVIRON · PROCINFO 가
    없을 때만(출력 리다이렉트·파이프·명령 실행·확장 적재 수단 없음). -f · -v · -e · -i · -l · -E · --* 는 False(종전 판정)"""
    try:
        toks = _rr_head(seg, AWK_HEADS)
        if not toks:
            return False
        args, i = toks[1:], 0
        while i < len(args) and args[i].startswith("-"):
            t = args[i]
            if t == "-F" and i + 1 < len(args):
                i += 2
                continue
            if t.startswith("-F") and len(t) > 2:
                i += 1
                continue
            return False
        rest = args[i:]
        if not rest or AWK_BAD_RE.search(rest[0]):
            return False
        return all(not t.startswith("-") for t in rest[1:])
    except Exception:
        return False


def _script_drop_reads(body):
    """셸 스크립트 본문에서 주석 줄·조회 묶음을 뺀 나머지(재판정용). 판정할 수 없는 본문이면 None(fail-closed)
    c195b: $_ 참조가 있으면 None. c195c: 버릴 묶음은 _droppable(허용 목록 — cd 계열·$·백틱·-v·상태 내장 제외)만"""
    try:
        if "<<" in body:
            return None
        if LAST_ARG_RE.search(body):
            return None
        kept = []
        for ln in body.replace("\r\n", "\n").split("\n"):
            if "\r" in ln:
                return None
            s = ln.strip()
            if not s or s.startswith("#"):
                continue
            if s.endswith("\\"):
                return None
            if _quote_ambiguous(s):
                return None
            for grp in _pipe_groups(_strip_harmless(s)):
                if not all(_droppable(x) for x in grp):   # c195c: 허용 목록 판정(셸 교차 판정과 공유)
                    kept.append(" | ".join(grp))
        return "\n".join(kept)
    except Exception:
        return None


# ── 자기 보호 ─────────────────────────────────────────────────────
def _guard_paths():
    """설치된 가드 실체(코어·hook·스위치) realpath 소문자 — 상위 디렉토리 삭제·이동 판정용"""
    if not HOOK_DIR:
        return []
    out = []
    for rel in (os.path.join("lib", SELF_NAMES[0] + ".py"), "PreToolUse_%s.sh" % SELF_NAMES[0], SWITCH_NAME):
        try:
            out.append(os.path.realpath(os.path.join(HOOK_DIR, rel)).lower())
        except Exception:
            pass
    return out


def _self_path(p):
    """가드 파일·스위치이거나 그것을 품은 디렉토리인가(대소문자 무시 — NTFS 는 대소문자를 구별하지 않는다)"""
    if not p:
        return False
    try:
        rp = os.path.realpath(p)
    except Exception:
        rp = p
    for x in (p, rp):
        b = os.path.basename(x.rstrip("/")).lower()
        if any(n in b for n in SELF_NAMES) or SWITCH_NAME.lower() in x.lower():
            return True
    pre = rp.rstrip("/").lower() + "/"
    if any(g.startswith(pre) for g in _guard_paths()):
        return True
    try:
        if os.path.isdir(rp) and (os.path.isfile(os.path.join(rp, CONF_REL)) or
                                  os.path.isfile(os.path.join(rp, os.path.basename(CONF_REL)))):
            return True
    except Exception:
        pass
    return False


# c206 F-2c: 가드 파일을 ★원본★ 으로 한 file_copy(후보 작성용 사본 만들기)는 가드 파일을 바꾸지 않는다 — 대상이 안전할 때만 통과.
#   조건(전부): 도구 = mcp__oio__file_copy, HOOK_DIR 설정됨, 원본 키(path·file_path·filepath·source·src)·대상 키(_fileop_dests)가
#   각각 1개 이상이고 그 밖의 경로 키 없음, 가드 경로인 원본은 설치된 가드 실체(_guard_paths — 코어·hook)의 정규 파일
#   (디렉터리·스위치·차단 목록 설정 json 불가), 모든 대상이 절대경로이고
#   _self_path 아님(가드 파일·스위치·그 상위 디렉터리·설정 디렉터리) + 대상 realpath 가 ★허용 목록★ 안 —
#   hook 디렉터리(HOOK_DIR·${HARNESS_HOME:-$HOME/.harness}/current/hooks 의 realpath)의 candidates/ 아래 또는 /tmp/ 아래(scratchpad 포함)만.
#   그 밖(다른 hook·lib 파일, settings.json 등 hook 등록 파일, candidates 안 외부 링크가 가리키는 곳)은 종전대로 차단한다
#   (odev-8 교차검토: 루트 밖 무제한 허용이면 settings.json 을 가드 내용으로 덮어 hook 등록을 깨는 길이 열린다).
#   file_move·rename·delete·symlink·dir_* 는 원본이 사라지거나 가드를 가리키므로 종전대로 차단한다.
_CO_SRC_KEYS = ("path", "file_path", "filepath", "source", "src")


def _co_hook_roots():
    out = []
    for h in (HOOK_DIR, os.path.join(os.path.expanduser("~"), ".claude", "hooks")):
        if h:
            try:
                out.append(os.path.realpath(h).rstrip("/"))
            except Exception:
                pass
    return out


def _copy_out_ok(tool, ti):
    try:
        if tool != "mcp__oio__file_copy" or not HOOK_DIR or not isinstance(ti, dict):
            return False
        srcs = [_win2wsl(x) for x in _fx_vals(ti, _CO_SRC_KEYS)]
        dests = _fileop_dests(tool, ti)
        if not srcs or not dests:
            return False
        known = set(_CO_SRC_KEYS) | set(_FX_DEST_KEYS)
        for k in ("file_path", "filepath", "path", "source", "src", "destination", "dest", "dst", "target", "new_path",
                  "old_path", "new_name", "link_path", "target_path", "to"):
            if k not in known and isinstance(ti.get(k), str) and ti[k].strip():
                return False
        gps = set(_guard_paths())   # 설치된 가드 실체(코어 .py·hook .sh) — 차단 목록 설정(json)·스위치는 원본이어도 종전대로 차단(고정 F-D20)
        for s in srcs:
            if _self_path(s):
                rs = os.path.realpath(s)
                if SWITCH_NAME.lower() in s.lower() or not os.path.isfile(rs) or rs.lower() not in gps:
                    return False
        roots = _co_hook_roots()
        allow = [r + "/candidates/" for r in roots] + ["/tmp/"]
        for d in dests:
            if _self_path(d):
                return False
            rd = os.path.realpath(d)
            for r in roots:   # hook 디렉터리 안은 candidates/ 아래만(hook 디렉터리가 /tmp 아래여도 우선 적용)
                if (rd == r or rd.startswith(r + "/")) and not rd.startswith(r + "/candidates/"):
                    return False
            if not any(rd.startswith(a) for a in allow):
                return False
        return True
    except Exception:
        return False


# c213: 이름 보존 복사(file_copy) — 사본도 이름이 같아 셸로 실행하면 같은 규칙(배포 스크립트 규칙 등)에 그대로 걸린다.
#   개명 복사(배포 스크립트 → z.sh · 이름.bak)는 이름을 바꿔 규칙을 피하는 우회라 종전대로 차단(고정 R-file_copy·AP28·F-D15).
#   조건(전부): 도구 file_copy, 원본 키 정확히 1개·대상 키 1개 이상, 용도 불명 경로 키 없음(_copy_out_ok 와 같은 검사),
#   모든 대상이 절대경로·_self_path 아님·basename(대상)==basename(원본)(대소문자 구별, realpath 도 같음)·hook 디렉터리 밖.
def _name_keep_copy(tool, ti):
    try:
        if tool != "mcp__oio__file_copy" or not isinstance(ti, dict):
            return False
        srcs = [_win2wsl(x) for x in _fx_vals(ti, _CO_SRC_KEYS)]
        dests = _fileop_dests(tool, ti)
        if len(srcs) != 1 or not dests:
            return False
        known = set(_CO_SRC_KEYS) | set(_FX_DEST_KEYS)
        for k in ("file_path", "filepath", "path", "source", "src", "destination", "dest", "dst", "target", "new_path",
                  "old_path", "new_name", "link_path", "target_path", "to"):
            if k not in known and isinstance(ti.get(k), str) and ti[k].strip():
                return False
        sb = os.path.basename(srcs[0].rstrip("/"))
        if not sb:
            return False
        roots = _co_hook_roots()
        for d in dests:
            if not d.startswith("/") or _self_path(d):
                return False
            rd = os.path.realpath(d)
            if os.path.basename(d) != sb or os.path.basename(rd) != sb:
                return False
            if any(rd == r or rd.startswith(r + "/") for r in roots):
                return False
        return True
    except Exception:
        return False


def _rule_hit(inp, tool, cmd, cmd_n, paths_n, content, wd):
    """프로젝트 설정 규칙 판정 → (규칙, 대상) 또는 (None, '')"""
    # c186: working_dir 가 Windows 경로여도 설정 탐색 seed 가 되도록 변환값을 쓴다(종전 원문은 '/' 로 시작하지 않으면 무시됐다)
    seeds = [inp.get("cwd") or "", os.environ.get("CLAUDE_PROJECT_DIR", "")] + [_win2wsl(x) for x in wd] + paths_n
    seeds += re.findall(r"/[^\s'\"`;|&<>()]+", cmd_n)
    confs = _find_configs(seeds)
    if not confs:
        return None, ""
    rules, fileop_ids, exempt, fileop_exempt = _load_rules(confs)
    if not rules and tool not in BASH_TOOLS:  # c186: 셸은 규칙이 없어도 실행 차단 영역(exec_block_dirs) 판정을 한다
        return None, ""
    if tool in BASH_TOOLS:
        plan = _exec_allow_plan(cmd, cmd_n, inp, tool, wd, confs)   # c196 B: 해시·인자 고정 실행 예외(없으면 None)
        # c214 T2·T3: 규칙 판정 전용 정규화 — 안전한 $'…' → '…', 따옴표 구분자 heredoc 커밋 메시지 → -m 'MSG'.
        #   본문이 실행 모양(_msg_exec_shape)이면 정규화하지 않는다(종전 판정). 원문 판정(자기 보호·실행 영역)은 그대로 원문으로 한다.
        j_raw, bodies = _commit_msg_split(_ansi_safe(cmd))
        j_n, bodies_n = _commit_msg_split(_ansi_safe(cmd_n), qmsg="\\" not in cmd)   # cgit A1: 원문 \ 이면 변환본도 인용 정규화 안 함
        if any(_msg_exec_shape(b, rules) for b in bodies + bodies_n):
            j_raw, j_n = cmd, cmd_n
        # c214 D-1: 커밋 메시지 외 heredoc 본문 정규화 — raw 와 cmd_n 에서 같은 수만큼 치환될 때만 적용(한쪽만이면 원문)
        h_raw, k1 = _heredoc_norm(j_raw, rules)
        h_n, k2 = _heredoc_norm(j_n, rules)
        if k1 and k1 == k2:
            j_raw, j_n = h_raw, h_n
        hit = _match_cmd(rules, j_n, raw=j_raw, allow=plan)
        if hit:
            return hit, cmd
        hit, what = _cwd_exec_hit(inp, tool, cmd, cmd_n, wd, confs,
                                  skip=plan["abs"] if plan else None)   # c186: 유효 작업 디렉터리 기준 실행 차단 영역
        if hit:
            return hit, what
        hit, what = _doc_exec_hit(rules, cmd_n, inp, wd)   # c183 B8 ⑥: bash x.md 처럼 문서 파일을 셸로 실행
        if not hit and plan:
            _log("PASS exec-allow path=%s args=%s" % (",".join(sorted(plan["abs"])), " | ".join(plan["args"])))
        return hit, what
    if tool in FILEOP_TOOLS:
        ti = inp.get("tool_input") or {}
        dests = _fileop_dests(tool, ti)
        if _name_keep_copy(tool, ti):   # c213: 이름 보존 복사는 file_op_rules 판정 생략
            _log("PASS fileop-namekeep tool=%s dests=%s" % (tool, dests))
            return None, ""
        if dests and all(_fileop_exempt_hit(fileop_exempt, d) for d in dests):
            _log("PASS fileop-exempt tool=%s dests=%s" % (tool, dests))
            return None, ""
        for p in paths_n:
            hit = _match(rules, p, only=fileop_ids)
            if hit:
                return hit, p
        return None, ""
    # 스크립트 파일 쓰기 내용 — 운영 명령을 스크립트에 숨겨 실행하는 우회 방지
    #   .md·.txt 등 비실행 문서는 SCRIPT_EXT 밖이라 내용 판정 대상이 아니다(문서는 아무것도 실행하지 않는다 — c183 B8 ⑤).
    #   그 문서를 셸로 실행하는 명령은 _doc_exec_hit 가 막는다(⑥).
    tgt = paths_n[0] if paths_n else ""
    if tgt.lower().endswith(SCRIPT_EXT) and not _exempt_hit(exempt, tgt):
        body = _win2wsl(content)
        hit = _match(rules, body)
        if hit and tgt.lower().endswith(".py"):
            # c214 D-1: .py 주석(COMMENT 토큰)만 지운 본문으로 재판정 — 주석 속 이름만 풀린다(문자열·코드 속 이름은 종전 판정)
            nc = _py_strip_comments(body)
            #   조건: 걸린 규칙이 주석만으로도 성립하고(규칙 조건 전부가 주석 안), 주석을 뺀 본문은 어떤 규칙에도 안 걸린다.
            #   규칙 조건이 주석·코드에 나뉘어 있으면(고정 C18-D6) 풀지 않는다 — 주석이 실행 대상을 가리키는 맥락일 수 있다.
            cm = _py_comments_only(body)
            if nc is not None and cm is not None and _match(rules, cm) and not _match(rules, nc):
                _log("PASS script-py-comment-only rule=%s tgt=%s" % (hit["id"], tgt))
                return None, ""
        if hit and hit["id"] in fileop_ids and _script_ok(body, tgt, hit):
            _log("PASS script-sandbox rule=%s tgt=%s" % (hit["id"], tgt))
            return None, ""
        if hit and tgt.lower().endswith((".sh", ".bash")):
            # 원문에 \ 가 있으면 재판정하지 않는다 — body 는 _win2wsl 이 \ 를 / 로 바꿔 줄 끝 이어쓰기·이스케이프 흔적이 지워진 값이다
            red = _script_drop_reads(body) if "\\" not in content else None
            if red is not None and not _match(rules, red):
                _log("PASS script-readonly-lines rule=%s tgt=%s" % (hit["id"], tgt))
                return None, ""
        return hit, "%s 에 쓰는 내용" % tgt
    return None, ""


# ── c196 B: exec_allow — 해시·인자 고정 실행 예외(빌드 래퍼 등) ─────────────────────────────
#   설정 항목 {path, sha256, args_re, rules} 이 가리키는 파일 하나를, 정해진 인자로, 다른 실행·쓰기 수단 없이 실행하는
#   구간만 규칙(rules ∪ {exec_in_block_dir}) 판정에서 뺀다. 조건은 머리 docstring exec_allow 항목 참조. 하나라도 어기면 None.
EA_MAX_BYTES = 1 << 20
EA_BAD_CHARS = "$`<>(){}"
EA_ARG_BAD = "$`*?["
EA_OK_SEP = (";", "\n", "&&", "||", "")
EA_CD = ("cd", "pushd", "popd", "chdir")


def _load_exec_allow(confs):
    """설정별 exec_allow 항목 목록 — 형식 오류 항목은 CONF_ERROR 로그 후 무시(예외 없음 방향)"""
    out = []
    for p in confs:
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = json.load(f)
        except Exception:
            continue  # CONF_ERROR 는 _load_rules 가 이미 기록했다
        if not isinstance(c, dict) or "exec_allow" not in c:
            continue
        lst = c.get("exec_allow")
        if not isinstance(lst, list):
            _log("CONF_ERROR exec_allow %s 목록이 아님" % p)
            continue
        root = os.path.dirname(os.path.dirname(p))
        for it in lst:
            try:
                if not isinstance(it, dict):
                    raise ValueError("항목이 객체가 아님")
                path, sha, ar, rl = it.get("path"), it.get("sha256"), it.get("args_re"), it.get("rules") or []
                if not isinstance(path, str) or not path.startswith("/") or ".." in path.split("/"):
                    raise ValueError("path 는 '/' 로 시작하는 프로젝트 루트 기준 상대경로")
                if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
                    raise ValueError("sha256 은 64자리 16진")
                if not isinstance(ar, str):
                    raise ValueError("args_re 문자열 아님")
                if not isinstance(rl, list) or not all(isinstance(x, str) for x in rl):
                    raise ValueError("rules 는 문자열 목록")
                out.append({"abs": os.path.realpath(root + path), "sha": sha.lower(), "re": re.compile(ar),
                            "rules": set(rl) | {EXEC_RULE_ID}, "src": p})
            except Exception as e:
                _log("CONF_ERROR exec_allow %s %r" % (p, e))
    return out


def _ea_no(why, cmd):
    _log("NOALLOW %s cmd=%.200s" % (why, _mask(cmd)))
    return None


def _exec_allow_plan(cmd, cmd_n, inp, tool, wd, confs):
    """적용 가능하면 {"segs": 허용 구간 문자열 집합, "rules": 제외 규칙 id 합집합, "abs": 허용 realpath 집합,
    "args": 허용 구간 인자 목록} 아니면 None. 판정 중 예외 → None(종전 판정 — fail-closed)"""
    try:
        items = _load_exec_allow(confs)
        if not items:
            return None
        if _quote_ambiguous(cmd):
            return _ea_no("quote_ambiguous", cmd)
        s = _strip_harmless(cmd_n)
        if any(ch in s for ch in EA_BAD_CHARS):
            return _ea_no("meta_char", cmd)
        segs = _cx_segments(s)
        if not segs:
            return None
        parsed = []
        for seg, _sep in segs:
            toks = shlex.split(seg)
            if toks and os.path.basename(toks[0]).lower() in EA_CD:
                return _ea_no("cd_segment", cmd)
            parsed.append(toks)
        cw = None
        allow_segs, rules, abss, argl = set(), set(), set(), []
        for k, (seg, sep) in enumerate(segs):
            if _strict_readonly(seg):
                continue
            prev = segs[k - 1][1] if k else ""
            if sep not in EA_OK_SEP or prev not in EA_OK_SEP:
                return _ea_no("pipe_or_background", cmd)
            toks = list(parsed[k])
            bash_form = bool(toks) and toks[0] == "bash"
            if bash_form:
                toks = toks[1:]
            if not toks or toks[0].startswith("-") or _CX_ASSIGN.match(toks[0]):
                return _ea_no("prefix_or_option", cmd)
            path, args = toks[0], toks[1:]
            if not bash_form and "/" not in path:
                return _ea_no("not_path", cmd)
            if any(ch in path for ch in EA_ARG_BAD + "~"):
                return _ea_no("path_meta", cmd)
            if path.startswith("/"):
                rps = {os.path.realpath(path)}
            else:
                if cw is None:
                    cw = _cwd_candidates(inp, tool, wd, [os.path.dirname(os.path.dirname(it["src"])) for it in items])
                rps = {os.path.realpath(os.path.join(c, path)) for c in cw}
            if len(rps) != 1:
                return _ea_no("cwd_ambiguous", cmd)
            rp = rps.pop()
            if any(ch in a for a in args for ch in EA_ARG_BAD):
                return _ea_no("arg_meta", cmd)
            joined = " ".join(args)
            hit = next((it for it in items if it["abs"] == rp and it["re"].fullmatch(joined)), None)
            if hit is None:
                return _ea_no("no_item path=%s args=%s" % (rp, joined), cmd)
            if not os.path.isfile(rp) or os.path.getsize(rp) > EA_MAX_BYTES:
                return _ea_no("not_regular_or_large %s" % rp, cmd)
            with open(rp, "rb") as f:
                digest = hashlib.sha256(f.read(EA_MAX_BYTES + 1)).hexdigest()
            if digest != hit["sha"]:
                return _ea_no("sha_mismatch %s" % rp, cmd)
            allow_segs.add(seg)
            rules |= hit["rules"]
            abss.add(rp)
            argl.append(joined)
        if not allow_segs:
            return None
        return {"segs": allow_segs, "rules": rules, "abs": abss, "args": argl}
    except Exception as e:
        return _ea_no("error %r" % (e,), cmd)


def _exempt_hit(exempt, tgt):
    """script_write_exempt — c183 B8 N7: 설정이 속한 프로젝트 루트 ★안★ 의 경로에만 적용한다
    (종전: 정규식만 봐서 _tmp_x/Deploy/a.py 처럼 저장소 밖 'Deploy' 폴더도 내용 판정을 통째로 건너뛰었다)."""
    try:
        rt = os.path.realpath(tgt)
    except Exception:
        rt = tgt
    for rx, root in exempt:
        r = os.path.realpath(root) if root else ""
        if not r:
            continue
        for x in (tgt, rt):
            if x.lower().startswith(r.lower().rstrip("/") + "/"):
                rel = "/" + x[len(r.rstrip("/")) + 1:]
                if rx.search(rel) or rx.search(x):
                    return True
    return False


# c185 — 파일 도구 대상 예외(사용자 지시 2026-10-14: 예외 영역 아래 스크립트는 개발 소스 — 수정 허용, 실행은 차단 유지).
#   copy·move·rename·delete 4개만. 결과가 놓이는 곳(대상)이 ★전부★ 예외 영역 안일 때만 file_op_rules 판정을 건너뛴다.
#   대상 추출에 실패하거나(키 없음·상대경로·이름에 경로 구분자·용도 불명 키) 하나라도 영역 밖이면 종전 판정(fail-closed).
#   symlink·dir_* 는 예외 없음. 영역 판정은 realpath 만 본다(literal 폴백 없음 — 링크 디렉터리로 밖을 가리키는 탈출 차단).
FILEOP_EXEMPT_TOOLS = ("mcp__oio__file_copy", "mcp__oio__file_move", "mcp__oio__file_rename", "mcp__oio__file_delete")
_FX_DEST_KEYS = ("destination", "dest", "dst", "to", "target", "new_path")
_FX_ODD_KEYS = ("new_name", "name", "link_path", "target_path", "old_path")


def _fx_vals(ti, keys):
    return [ti[k] for k in keys if isinstance(ti.get(k), str) and ti[k].strip()]


def _fileop_dests(tool, ti):
    """파일 도구 조작의 대상 경로 목록 — 판정 불가면 [] (예외 없음)"""
    if tool not in FILEOP_EXEMPT_TOOLS or not isinstance(ti, dict):
        return []
    if tool in ("mcp__oio__file_copy", "mcp__oio__file_move"):
        if _fx_vals(ti, _FX_ODD_KEYS):
            return []
        out = _fx_vals(ti, _FX_DEST_KEYS)
    elif tool == "mcp__oio__file_rename":
        if _fx_vals(ti, ("link_path", "target_path", "old_path")):
            return []
        out = _fx_vals(ti, _FX_DEST_KEYS)
        names = _fx_vals(ti, ("new_name", "name"))
        if names:
            base = _fx_vals(ti, ("path", "file_path", "filepath", "source", "src"))
            if not base:
                return []
            for n in names:
                if "/" in n or "\\" in n or n.strip() in (".", ".."):
                    return []
                for b in base:
                    b = _win2wsl(b)
                    if not b.startswith("/"):
                        return []
                    out.append(os.path.join(os.path.dirname(b.rstrip("/")), n))
    else:  # file_delete — 대상 = 지워지는 파일
        out = _fx_vals(ti, ("path", "file_path", "filepath"))
    res = []
    for d in out:
        d = _win2wsl(d)
        if not d.startswith("/"):
            return []
        res.append(d)
    return res


def _fileop_exempt_hit(fileop_exempt, dest):
    """대상의 realpath 가 설정 프로젝트 루트(realpath) 안이고, 그 상대경로가 예외 영역 정규식에 맞는가"""
    try:
        rp = os.path.realpath(dest)
    except Exception:
        return False
    low = rp.lower()
    for rxs, root in fileop_exempt:
        if not rxs or not root:
            continue
        try:
            r = os.path.realpath(root).rstrip("/")
        except Exception:
            continue
        if not r or not low.startswith(r.lower() + "/"):
            continue
        rel = "/" + rp[len(r) + 1:]
        if any(rx.search(rel) for rx in rxs):
            return True
    return False


# c183 B8 — 배포 스크립트 이름이 든 실행 파일(.py/.sh 등) 쓰기를 허용하는 두 경우(리드 결정 2026-10-14 12:22·12:35).
#   (A) 실행 수단이 전혀 없는 .py — 이름을 문자열 데이터·정규식으로만 다룬다(표본 P2).
#   (B) 네트워크 분리 샌드박스 실행 — 아래 ①~④ 를 ★모두★ 충족(표본 P1). 하나라도 어기면 차단(N1~N6).
#       ① unshare -rn(또는 -n·--net)  ② env -i + PATH= (스텁 PATH 한정)  ③ 저장소(설정이 속한 프로젝트 루트) 경로·./deploy 상대
#       실행 표현 0 — 실행 대상은 샌드박스 사본  ④ WSL interop 실행 표현 0(.exe·/mnt/<드라이브>/Windows·powershell·pwsh·cmd.exe·
#       wsl.exe) — unshare -rn 안에서도 interop 으로 뜬 Windows 프로세스는 netns 밖 네트워크를 쓴다(odev-6-4 실측 12:3x).
#   잔존 한계(정직 고지): 파일 단위 문자열 판정이다. 같은 파일 안 실행 경로별 대응은 보지 않으므로 ①②가 한 곳에만 있고
#   다른 호출이 그것 없이 배포 사본이 아닌 상대 경로를 실행하면 ③④로만 걸러진다. 문자열 쪼개기 난독화는 종전 등급.
_PY_EXEC_RE = re.compile(r"subprocess|os\.(system|popen|exec\w*|spawn\w*|fork\w*|posix_spawn\w*)|\bpopen\b|pty\.|"
                         r"__import__|importlib|runpy|ctypes|multiprocessing|create_subprocess|pexpect|\bexec\s*\(|"
                         r"\beval\s*\(|\bcompile\s*\(|shutil\.which|webbrowser|\bplumbum\b|\bsh\.|"
                         r"startfile|asyncio|__builtins__|\bglobals\s*\(|\bgetattr\s*\(\s*(os|sys|builtins)\b|\bcode\.|"
                         r"\binteract\b|\bsys\.modules\b", re.I)   # c214 D-1: fail-closed 보강
_INTEROP_RE = re.compile(r"\.exe\b|/mnt/[a-z]/windows|powershell|\bpwsh\b|cmd\.exe|wsl\.exe|\bcmd\s*/c\b", re.I)


def _py_strip_comments(body):
    """c214 D-1: python tokenize 로 COMMENT 토큰만 지운 소스. 토큰화 실패(문법 오류 등)면 None(종전 판정 — fail-closed)"""
    try:
        import io
        import tokenize
        toks = [t for t in tokenize.generate_tokens(io.StringIO(body).readline) if t.type != tokenize.COMMENT]
        return tokenize.untokenize(toks)
    except Exception:
        return None


def _py_comments_only(body):
    """c214 D-1: COMMENT 토큰 문자열만 줄바꿈으로 이은 텍스트. 토큰화 실패면 None"""
    try:
        import io
        import tokenize
        return "\n".join(t.string for t in tokenize.generate_tokens(io.StringIO(body).readline) if t.type == tokenize.COMMENT)
    except Exception:
        return None


# c214 D-1: heredoc 본문 정규화 — 본문이 실행되지 않는 소비자일 때만 본문을 판정에서 뺀다(나머지는 원문 = 종전 판정).
#   (a) 읽기 소비자(cat·grep·head·tail·wc·sort·uniq) — 그 파이프 묶음의 다른 구간이 전부 _droppable·NX 이고, 같은 줄 출력
#       리다이렉트 대상이 문서 확장자(.txt .md .json .log .csv .yaml .yml .xml .html)일 때만(.sh·확장자 없음 등은 나중 실행 가능 → 원문)
#   (b) python[3] [-I|-u|-B…] - — .py 파일 쓰기와 같은 기준: 본문이 규칙에 안 걸리거나 _PY_EXEC_RE(실행 수단) 없음일 때만.
#       파이프로 다음 구간에 넘기거나 출력 리다이렉트가 있으면 원문
#   (c) 따옴표 없는 <<TAG 는 본문에 $ · 백틱 · \ 가 없을 때만(확장·치환 불가 = 따옴표 구분자와 같음). <<< · 그 밖의 소비자
#       (bash·sh·perl·node·ruby 등 실행기, tee, 알 수 없는 명령)는 원문
HD_OPEN_RE = re.compile(r"<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
HD_READ_CONSUMERS = {"cat", "grep", "egrep", "fgrep", "head", "tail", "wc", "sort", "uniq"}
HD_DOC_EXT = (".txt", ".md", ".json", ".log", ".csv", ".yaml", ".yml", ".xml", ".html")


def _open_quote(s):
    """s 끝에서 bash 따옴표 상태 — 열린 따옴표 글자 또는 None(작은따옴표 안 \\ 는 문자, 큰따옴표·밖의 \\ 는 다음 글자 이스케이프)"""
    q, i = None, 0
    while i < len(s):
        ch = s[i]
        if q == "'":
            if ch == "'":
                q = None
        elif ch == "\\":
            i += 2
            continue
        elif q == '"':
            if ch == '"':
                q = None
        elif ch in ("'", '"'):
            q = ch
        i += 1
    return q


def _heredoc_norm(cmd, rules):
    """→ (정규화 명령, 치환 수). 판단이 하나라도 불확실하면 그 heredoc 이 아니라 명령 전체를 원문으로(치환 0) 돌려준다."""
    try:
        out, n, guard = cmd, 0, 0
        pos, wrote = 0, False
        while guard < 16:
            guard += 1
            m = None
            for mm in HD_OPEN_RE.finditer(out, pos):
                if _open_quote(out[:mm.start()]):
                    continue                        # 따옴표 안의 << 는 heredoc 이 아니다
                if out[mm.start():mm.start() + 3] == "<<<":
                    return cmd, 0
                m = mm
                break
            if not m:
                break
            # 여는 줄과 본문
            ls = out.rfind("\n", 0, m.start()) + 1
            le = out.find("\n", m.end())
            if le < 0:
                return cmd, 0
            line = out[ls:le]
            tag, quoted, dash = m.group(3), bool(m.group(2)), bool(m.group(1))
            p, body_end, term_end = le + 1, None, None
            while p <= len(out):
                e = out.find("\n", p)
                le2 = len(out) if e < 0 else e
                cur = out[p:le2]
                if (cur.lstrip("\t") if dash else cur) == tag:
                    body_end, term_end = p, le2
                    break
                if e < 0:
                    break
                p = e + 1
            if body_end is None:
                return cmd, 0
            body = out[le + 1:body_end]
            if HD_OPEN_RE.search(line[m.end() - ls:]):
                return cmd, 0                       # 한 줄에 heredoc 둘 — 판정 안 함
            if not quoted and any(c in body for c in "$`\\"):
                return cmd, 0
            # 여는 줄에서 heredoc 이 붙은 구간과 그 파이프 묶음
            op_line = line[:m.start() - ls] + " HEREDOC " + line[m.end() - ls:]
            groups = _pipe_groups(_strip_harmless(op_line))
            grp = next((g for g in groups if any("HEREDOC" in s for s in g)), None)
            if not grp:
                return cmd, 0
            seg = next(s for s in grp if "HEREDOC" in s)
            try:
                toks = shlex.split(seg)
            except ValueError:
                return cmd, 0
            if not toks:
                return cmd, 0
            v = os.path.basename(toks[0])
            others = [s for s in grp if s is not seg]
            redir = re.findall(r"(?:^|[^<>&0-9])[0-9]?>>?\s*([^\s;&|]+)", _sq_strip(seg))
            if v in HD_READ_CONSUMERS:
                if not all(_droppable(s) or _nonexec_args(s, rules) for s in others):
                    return cmd, 0
                if any(not t.lower().endswith(HD_DOC_EXT) for t in redir):
                    return cmd, 0
                wrote = wrote or bool(redir)
            elif NX_INTERP_RE.match(v) and v.startswith(("python", "py")):  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
                rest = toks[1:]
                if not rest or any(not (t == "-" or t == "HEREDOC" or re.fullmatch(r"^-[IuBEsS]+$", t)) for t in rest) \
                        or "-" not in rest:
                    return cmd, 0
                if others or redir:
                    return cmd, 0
                if _match(rules, body) and _PY_EXEC_RE.search(body):
                    return cmd, 0
            else:
                return cmd, 0
            out = out[:ls] + op_line + out[le:le + 1] + out[term_end + 1 if term_end < len(out) else term_end:]
            n += 1
            pos = ls + len(op_line)
        # odev-1 보강(E7): 문서 파일에 본문을 쓴 뒤 같은 명령에서 그 문서를 실행할 수 있다(cat <<'E' > x.md; bash x.md).
        #   본문을 파일에 쓴 heredoc 이 하나라도 있으면 나머지 구간이 전부 엄격 읽기전용·버림 가능·비실행 인자일 때만 정규화한다.
        if wrote:
            for s in _segments(_strip_harmless(out)):
                if "HEREDOC" in s:
                    continue
                if not (_strict_readonly(s) or _droppable(s) or _nonexec_args(s, rules)):
                    return cmd, 0
        return out, n
    except Exception:
        return cmd, 0


def _script_ok(body, tgt, hit):
    low = body.lower()
    if tgt.lower().endswith(".py") and not _PY_EXEC_RE.search(body):
        return True                                                  # (A) 실행 수단 없음
    if not re.search(r"unshare\W+(-[a-z]*n[a-z]*\b|--net\b)", low):
        return False                                                 # ①
    if not (re.search(r"\benv\W+-i\b", low) and _path_vals(body)):
        return False                                                 # ② env -i + PATH 지정(PATH=… 또는 {"PATH": …})
    root = os.path.dirname(os.path.dirname(hit.get("src") or ""))
    roots = {root.lower().rstrip("/")} if root else set()
    try:
        if root:
            roots.add(os.path.realpath(root).lower().rstrip("/"))
    except Exception:
        pass
    if any(r and r in low for r in roots):
        return False                                                 # ③ 저장소 원본 경로 언급
    if re.search(r"(^|[^\w/.])\.\.?/+deploy", low):
        return False                                                 # ③ ./deploy · ../deploy 상대 실행
    if _INTEROP_RE.search(body) and not _stub_path_only(body):
        return False                                                 # ④ interop
    return True


# c183 B8 ④ 정밀화(리드 결정 — odev-6-4 제안 2): interop 이름(.exe·powershell·cmd.exe 등)이 있어도 Windows 실행 파일에
#   닿는 길은 PATH 검색 또는 /mnt/<드라이브>/ 절대경로뿐이다. 그래서 ①②③(위에서 이미 확인)에 더해
#   (a) 모든 PATH= 값의 구성요소가 스텁 디렉터리뿐(시스템 경로 /usr·/bin·/sbin·/lib·/opt·/snap·/etc·/mnt/ 금지, 빈 값 금지)
#   (b) 내용 어디에도 /mnt/<드라이브>/ 절대경로가 없음 (c) 스텁 디렉터리 생성(makedirs·mkdir) 표현이 있음 — 을 모두 충족하면 스텁 이름 언급은 통과(하네스 스텁 가로채기).
#   /usr/bin/bash 같은 리눅스 절대경로 실행 자체는 PATH 가 아니므로 허용.
#   잔존 한계(정직 고지): 변수·문자열 조합으로 PATH 값이나 /mnt 경로를 만들면(예: "/m"+"nt/c") 문자열 판정이 못 본다 — 종전 난독화 등급.
_SYS_PATH_RE = re.compile(r"^/(usr|bin|sbin|lib\w*|opt|snap|etc|mnt|proc|sys|root|home)(/|$)", re.I)


def _stub_path_only(body):
    if re.search(r"/mnt/[a-z](/|\b)", body, re.I):
        return False                                                 # (b)
    if not re.search(r"\bmakedirs\b|\bmkdir\b", body):
        return False                                                 # (c) 스텁 디렉터리를 만드는 내용이 아니면 이름 언급은 스텁이 아니다(고정 D Z11 유지)
    vals = _path_vals(body)
    if not vals:
        return False
    for v, is_expr in vals:
        if is_expr:
            # 식(os.path.join(root, "bin") 등): 상속 표현 금지 + 식 안 절대경로 리터럴은 모두 비시스템이어야 한다
            if re.search(r"environ|getenv|\bPATH\b|\$PATH|\$\{PATH", v):
                return False
            for lit in re.findall(r"[\"']([^\"']*)[\"']", v):
                for comp in lit.split(":"):
                    if comp.startswith("/") and _SYS_PATH_RE.search(comp):
                        return False                                 # (a)
            continue
        if not v:
            return False                                             # 값 없음 — 판정 불가
        for comp in v.split(":"):
            c = comp.strip()
            if not c or c in (".", "..") or _SYS_PATH_RE.search(c) or c.startswith("$PATH") or "${PATH" in c:
                return False                                         # (a)
    return True


def _path_vals(body):
    """PATH 지정 값 목록 [(값, 식인가)] — 리터럴 PATH=값(문자열 안 포함) · 사전/키워드 "PATH": 식 · PATH=식(키워드 인자).
    f"{k}={v}" 조립처럼 PATH= 리터럴이 없어도 사전 키 "PATH" 로 지정하면 잡는다(odev-6-4 하네스 실측 형태)."""
    out = []
    for v in re.findall(r"(?<![A-Za-z0-9_])PATH=([^\s\"',\]\)]+)", body):
        out.append((v, False))
    for v in re.findall(r"[\"']PATH[\"']\s*:\s*([^,}\n]+)", body):
        v = v.strip()
        m = re.fullmatch(r"^[\"']([^\"']*)[\"']$", v)
        out.append((m.group(1), False) if m else (v, True))
    for v in re.findall(r"(?<![\w\"'])PATH\s*=\s*(?![\"'])([^,)\n]+)", body):
        out.append((v.strip(), True))
    return out


def _doc_exec_hit(rules, cmd_n, inp, wd):
    """c183 B8 ⑥ — 셸 해석기로 문서 파일(.md·.txt)을 실행하는 구간이면 그 파일 내용을 규칙으로 판정"""
    b0 = (wd[0] if wd else "") or inp.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR", "")
    bases = [b0] + [d if d.startswith("/") else os.path.join(b0, d)
                    for d in re.findall(r"(?:^|[;&|\s(])cd\s+['\"]?([^\s;&|'\"]+)", cmd_n)]
    for m in re.finditer(r"(?:^|[;&|\s(])(?:bash|sh|dash|zsh|ksh|source|\.)\s+(?:-\S+\s+)*['\"]?([^\s;&|'\"]+\.(?:md|txt|markdown))\b",
                         cmd_n, re.I):
        q = m.group(1)
        for p in ([q] if q.startswith("/") else [os.path.join(b, q) for b in bases if b]):
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    body = f.read(1 << 20)
            except Exception:
                continue
            hit = _match(rules, _win2wsl(body))
            if hit:
                return hit, "%s 를 셸로 실행(문서 내용)" % p
    return None, ""


# ── c186: 유효 작업 디렉터리 기준 실행 차단 영역(exec_block_dirs) ───────────────────────────
#   명령 문자열만 보던 판정에 ★유효 cwd★ 를 결합한다. 셸 구간마다 "실행 대상"(경로형 명령어·인터프리터 첫 위치 인자·
#   표준입력 스크립트·cmd 의 현재 디렉터리 검색 대상 등)을 유효 cwd 후보 기준 절대경로로 풀어(normpath·realpath 둘 다)
#   영역 안이고 exec_block_unless 비일치면 차단한다(synthetic 규칙 exec_in_block_dir).
#   cwd 후보: bash_exec 도구 입력 working_dir/workdir/cwd 가 있으면 그 값들(합집합), 없으면 hook 입력 cwd·CLAUDE_PROJECT_DIR.
#     상대 값은 hook cwd·CLAUDE_PROJECT_DIR·설정 프로젝트 루트 각각에 붙인 것 모두. 비면 설정 프로젝트 루트.
#   명령 안 cd/pushd/cd /d/chdir/Set-Location 은 같은 셸에서 ; · 줄바꿈으로 이어질 때만 후보를 ★교체★하고, && · || · | · & ·
#     서브셸 ( ) · 조건문(then/do…) · eval 안에서는 ★더한다★(합집합 — oio 는 && 에서 별도 실행으로 쪼개 cd 가 이어지지 않는다).
#     bash -c · cmd /c · pwsh -Command · $( ) 는 자식 셸이라 상태 사본으로 보고 바깥 후보는 바꾸지 않는다.
#     env -C/--chdir·sudo -D·wsl --cd·pwsh -WorkingDirectory·start /d·ruby -C 는 그 명령에만 적용한다(명령 단위 사본 교체).
#     인자가 변수·~·-·+N·없음(홈)이거나 popd 면 cwd 불명 → 이후 상대경로 실행 대상은 차단. 접두어의 미지 옵션도 차단(fail-closed).
#   인터프리터·접두어는 basename(.exe 제거)으로 판정하고, 경로형 명령어 낱말은 역할과 별개로 그 자체를 실행 대상으로 본다
#     (/bin/bash x.sh · /usr/bin/env bash x.sh · Deploy/bash x 모두 판정). 구간 선두 ( { ! 와 then/do/else/elif/if/while/until 은 벗긴다.
#   glob 대상은 후보 cwd 마다 glob 으로 실제 확장(하나라도 영역 안이면 차단). 파일명에만 glob 이면 디렉터리 부분으로도 판정.
#   python3 -m <모듈> 은 스크립트 실행이 아니다(대상 없음 — 리드 결정). bash < x.sh 는 x.sh 를 대상으로 본다.
#   보조 그물: shlex 파싱 실패 구간, python/perl/node/php 의 -c/-e 코드, pwsh -Command 코드에서 스크립트형 경로(.sh/.bash/.bat/.cmd/
#     .ps1/.py)를 정규식으로 뽑아 같은 방식으로 판정한다. 따옴표 혼동 소지(백슬래시·#)가 있으면 변환 전 원문도 한 번 더 훑는다.
#   역라우팅 #1 보강: ① 파이프 — 인자 없는(-s · - · /dev/stdin) sh 계열·python·pwsh 등이 표준입력을 실행하면, 같은 파이프라인
#     앞 구간의 조회 명령(cat·head·tail·sed·awk·tee·type 등)이 읽는 파일 인자를 실행 대상으로 본다(cat x.sh | bash).
#     ② 치환 — $( ) · 백틱 · <( ) 를 자리표시로 바꾸고 그 안 조회 명령이 읽는 파일을 기억해, 자리표시가 명령어 자리·스크립트 인자·
#     -c/-e 코드·표준입력에 오면 그 파일을 실행 대상으로 본다(sh -c "$(cat x.sh)" · bash <(cat x.sh) · source <(…)).
#     ③ 실행 래퍼 — script -c · flock [-c] · xargs · chrt · unbuffer · watch 의 명령 인자를 재판정한다.
#   잔존 한계(정직 고지): 변수(경로의 디렉터리 부분까지 변수인 경우)·find -exec·make·인라인 인터프리터 코드(os.chdir 후 실행 등)·
#     awk system()·git alias(!)·npx/npm exec 가 만든 간접 실행, xargs 가 표준입력·목록 파일에서 받은 스크립트 이름, 앞 구간이 무엇을
#     내는지 모르는 파이프(curl … | bash), 별칭/함수, 셸 cp/mv/ln 으로 영역 밖에 꺼낸 사본 실행, 인터프리터의 미지 값-옵션 오해석.
#   알려진 과차단(수용): cwd 불명 뒤 상대 실행, 영역 안 cwd 에서의 heredoc 본문 줄·pwsh 위치 인자·cmd /c 외부 명령,
#     -c/-Command 코드 안 영역 스크립트 경로 언급(읽기 포함), 영역 cwd 에서 && · 서브셸로 다른 곳에 cd 한 뒤의 상대 실행(합집합).
#   c196: exec_allow plan 이 있으면 그 허용 realpath(skip)와 같은 실행 후보 경로는 건너뛴다(다른 후보 경로는 종전대로 판정).
EXEC_RULE_ID = "exec_in_block_dir"
EXEC_REASON = ("실행 차단 영역(exec_block_dirs) 안의 스크립트를 셸로 실행한다 — 작업 디렉터리(working_dir·cd) 기준 "
               "상대경로 실행도 같은 판정이다. 영역 안 파일은 파일 도구로 수정만 하고 실행하지 않는다")
_CX_GLOB = "*?["
_CX_VAR = "$`%"
_CX_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_CX_STRUCT = {"(", "((", ")", "))", "{", "}", "!", "then", "do", "else", "elif", "if", "while", "until", "fi", "done",
              "esac"}
_CX_SH = {"bash", "sh", "dash", "zsh", "ksh", "ash", "mksh"}
_CX_SRC = {"source", "."}
_CX_PY_RE = re.compile(r"^(python[0-9.]*|py|pypy[0-9.]*)$")
_CX_CD = {"cd", "chdir", "pushd", "set-location", "sl", "push-location"}
_CX_POP = {"popd", "pop-location"}
_CX_CMD_BUILTIN = {"echo", "dir", "type", "set", "if", "for", "cd", "chdir", "cls", "copy", "del", "erase", "md", "mkdir",
                   "rd", "rmdir", "ren", "rename", "move", "pushd", "popd", "exit", "rem", "ver", "vol", "title", "color",
                   "path", "prompt", "setlocal", "endlocal", "shift", "goto", "pause", "verify", "mklink", "assoc", "ftype",
                   "date", "time", "break", "where", "whoami", "tasklist", "taskkill", "findstr", "find", "more", "sort",
                   "xcopy", "robocopy", "attrib", "ping", "git", "dotnet", "curl", "msbuild", "nuget", "npm", "npx", "chcp"}
# 파일을 읽어 표준출력으로 내는 조회 명령 — cat x.sh | bash · sh -c "$(cat x.sh)" 에서 읽는 파일을 실행 대상으로 본다
_CX_READERS = {"cat", "head", "tail", "sed", "awk", "gawk", "mawk", "tee", "type", "tac", "less", "more", "cut", "sort",
               "uniq", "grep", "egrep", "fgrep", "rg", "nl", "dd", "iconv", "base64", "zcat", "gunzip", "envsubst",
               "get-content", "gc"}
_CX_NET_RE = re.compile(r"[\w./~-]+\.(?:sh|bash|bat|cmd|ps1|py)(?![\w.])", re.I)
_CX_SUBST_RE = re.compile(r"\$\(((?:[^()]|\([^()]*\))*)\)|`([^`]*)`|[<>]\(((?:[^()]|\([^()]*\))*)\)")
_CX_MAX_CWDS = 64
# 접두어 옵션 표: (값을 받는 옵션, 작업 디렉터리 옵션, 명령 문자열 옵션, 값 없는 옵션, 건너뛸 위치 인자 수)
_CX_PREFIX = {
    "env": ({"-u", "--unset"}, {"-C", "--chdir"}, {"-S", "--split-string"},
            {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug", "--default-signal", "--ignore-signal",
             "--block-signal", "--list-signal-handling"}, 0),
    "sudo": ({"-u", "-g", "-h", "-p", "-r", "-t", "-U", "-T", "-C", "--user", "--group", "--host", "--prompt", "--role",
              "--type", "--other-user", "--command-timeout", "--close-from"}, {"-D", "--chdir"}, set(),
             {"-A", "-b", "-E", "-H", "-i", "-k", "-K", "-n", "-P", "-S", "-s", "-B", "-N", "--askpass", "--background",
              "--bell", "--preserve-env", "--set-home", "--login", "--reset-timestamp", "--remove-timestamp",
              "--non-interactive", "--no-update", "--preserve-groups", "--stdin", "--shell"}, 0),
    "doas": ({"-u", "-C"}, set(), set(), {"-n", "-s", "-L"}, 0),
    "nohup": (set(), set(), set(), set(), 0),
    "exec": ({"-a"}, set(), set(), {"-c", "-l"}, 0),
    "command": (set(), set(), set(), {"-p"}, 0),
    "builtin": (set(), set(), set(), set(), 0),
    "call": (set(), set(), set(), set(), 0),
    "setsid": (set(), set(), set(), {"-c", "-f", "-w", "--ctty", "--fork", "--wait"}, 0),
    "time": ({"-f", "-o", "--format", "--output"}, set(), set(),
             {"-p", "-v", "-a", "-q", "--portability", "--verbose", "--append", "--quiet"}, 0),
    "nice": ({"-n", "--adjustment"}, set(), set(), set(), 0),
    "ionice": ({"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"}, set(), set(),
               {"-t", "--ignore"}, 0),
    "stdbuf": ({"-i", "-o", "-e", "--input", "--output", "--error"}, set(), set(), set(), 0),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, set(), set(),
                {"--preserve-status", "--foreground", "-v", "--verbose", "-f"}, 1),
    "taskset": (set(), set(), set(), {"-a", "--all-tasks", "-c", "--cpu-list", "-p", "--pid"}, 1),
    "wsl": ({"-d", "--distribution", "-u", "--user", "--shell-type"}, {"--cd"}, set(), {"-e", "--exec", "--system"}, 0),
    # 역라우팅 #1 — 실행 래퍼: 명령 인자(또는 -c 문자열)를 실행 대상으로 재판정
    "flock": ({"-w", "--wait", "--timeout", "-E", "--conflict-exit-code"}, set(), {"-c", "--command"},
              {"-s", "--shared", "-x", "-e", "--exclusive", "-u", "--unlock", "-n", "--nb", "--nonblock", "-o",
               "--close", "-F", "--no-fork", "--verbose"}, 1),
    "xargs": ({"-a", "--arg-file", "-d", "--delimiter", "-E", "-I", "-L", "-n", "--max-args", "-P", "--max-procs",
               "-s", "--max-chars", "--process-slot-var", "-i", "-e", "-l"}, set(), set(),
              {"-0", "--null", "-r", "--no-run-if-empty", "-t", "--verbose", "-p", "--interactive", "-x", "--exit",
               "-o", "--open-tty", "--show-limits", "--eof", "--replace", "--max-lines"}, 0),
    "chrt": ({"-T", "-P", "-D", "--sched-runtime", "--sched-period", "--sched-deadline"}, set(), set(),
             {"-a", "--all-tasks", "-b", "--batch", "-d", "--deadline", "-e", "--ext", "-f", "--fifo", "-i", "--idle",
              "-o", "--other", "-r", "--rr", "-R", "--reset-on-fork", "-v", "--verbose", "-m", "--max", "-p",
              "--pid"}, 1),
    "unbuffer": (set(), set(), set(), {"-p"}, 0),
}
# 비-sh 인터프리터: (코드 옵션, 값 옵션, 작업 디렉터리 옵션, 스크립트 파일 옵션)
_CX_INTERP = {
    "perl": ({"-e", "-E"}, set(), set(), set()),
    "ruby": ({"-e"}, {"-r", "-I", "-E", "-F"}, {"-C"}, set()),
    "node": ({"-e", "--eval", "-p", "--print"}, {"-r", "--require", "--import", "--loader", "--experimental-loader",
                                                  "--conditions", "--input-type", "--env-file"}, set(), set()),
    "php": ({"-r"}, {"-c", "-d", "-z", "-t"}, set(), {"-f"}),
}
_CX_INTERP["nodejs"] = _CX_INTERP["node"]
# pwsh/powershell 옵션(대소문자 무시, 고유 접두 허용)
_CX_PW = {"file": "file", "f": "file", "command": "code", "c": "code", "commandwithargs": "code", "cwa": "code",
          "encodedcommand": "enc", "ec": "enc", "e": "enc", "enc": "enc", "workingdirectory": "cwd", "wd": "cwd",
          "executionpolicy": "val", "ep": "val", "ex": "val", "windowstyle": "val", "w": "val", "version": "val",
          "v": "val", "configurationname": "val", "config": "val", "outputformat": "val", "o": "val", "of": "val",
          "inputformat": "val", "if": "val", "in": "val", "settingsfile": "val", "settings": "val",
          "custompipename": "val", "psconsolefile": "val", "encodedarguments": "val", "ea": "val",
          "noprofile": "flag", "nop": "flag", "noninteractive": "flag", "noni": "flag", "nologo": "flag", "nol": "flag",
          "noexit": "flag", "noe": "flag", "sta": "flag", "mta": "flag", "login": "flag", "l": "flag",
          "interactive": "flag", "i": "flag", "noprofileloadtime": "flag"}
_CX_PW_PRIO = ("enc", "code", "file", "cwd", "val", "flag")


def _cx_pathify(s):
    """Windows 경로(C:\\x · C:/x)를 WSL 경로로"""
    s = _win2wsl(s or "")
    return re.sub(r"^([A-Za-z]):/", lambda m: "/mnt/%s/" % m.group(1).lower(), s)


def _cx_compile(lst, p, key):
    out = []
    for x in (lst if isinstance(lst, list) else []):
        try:
            out.append(re.compile(str(x), re.I))
        except re.error as e:
            _log("REGEX_ERROR %s %s %r" % (p, key, e))
    return out


def _load_exec_dirs(confs):
    """설정별 실행 차단 영역 — exec_block_dirs 명시 → 그 값, 아니면 file_op_exempt 명시 → 그 값, 아니면 꺼짐"""
    out = []
    for p in confs:
        try:
            with open(p, "r", encoding="utf-8") as f:
                c = json.load(f)
        except Exception:
            continue  # CONF_ERROR 는 _load_rules 가 이미 기록했다
        if not isinstance(c, dict):
            continue
        key = "exec_block_dirs" if "exec_block_dirs" in c else ("file_op_exempt" if "file_op_exempt" in c else None)
        if key is None:
            continue
        rxs = _cx_compile(c.get(key), p, key)
        if not rxs:
            continue
        root = os.path.dirname(os.path.dirname(p))
        roots = []
        for r in (os.path.normpath(root), os.path.realpath(root)):
            r = r.rstrip("/")
            if r and r not in roots:
                roots.append(r)
        if not roots:
            continue
        out.append({"rxs": rxs, "unless": _cx_compile(c.get("exec_block_unless"), p, "exec_block_unless"),
                    "roots": roots, "src": p, "reason": str(c.get("exec_block_reason") or EXEC_REASON)})
    return out


def _cwd_candidates(inp, tool, wd, roots):
    """유효 작업 디렉터리 후보(절대경로 목록)"""
    base = []
    for b in (inp.get("cwd") or "", os.environ.get("CLAUDE_PROJECT_DIR", "")):
        b = _cx_pathify(b) if isinstance(b, str) else ""
        if b.startswith("/"):
            base.append(os.path.normpath(b))
    vals = [v for v in wd if isinstance(v, str) and v.strip()]
    out = []
    if vals:
        for v in vals:
            v = _cx_pathify(v.strip())
            if v.startswith("~"):
                v = os.path.expanduser(v)
            if v.startswith("/"):
                out.append(os.path.normpath(v))
            else:
                out += [os.path.normpath(os.path.join(b, v)) for b in base + roots]
        if tool == "Bash":
            out += base[:1]
    else:
        out = list(base)
    if not out:
        out = list(roots)
    return list(dict.fromkeys(out))


def _cx_add(out, t, st, why="", force=False):
    if t and "__cxsub" in t:  # 치환 자리표시 — 그 치환이 읽는 파일이 실행 대상(bash <(cat x.sh) · source <(…))
        _cx_ph(t, st, out)
        return
    out.append({"t": t, "cwds": list(st["cwds"]), "unk": st["unk"] or force, "why": why})


def _cx_stdin(stdin, st, out):
    """표준입력으로 들어오는 스크립트 — < 파일 + 같은 파이프라인 앞 구간이 읽는 파일(cat x.sh | bash)"""
    for f in list(stdin) + list(st.get("pipe") or []):
        _cx_add(out, f, st, why="표준입력 스크립트")


def _cx_copy(st):
    return {"cwds": list(st["cwds"]), "unk": st["unk"], "amb": st["amb"], "ph": st.setdefault("ph", {}),
            "pipe": list(st.get("pipe") or [])}


def _cx_reads(text):
    """text 안 조회 명령(cat·head·sed 등)이 읽는 파일 인자 목록 — 파이프·치환으로 인터프리터에 흘려 넣는 스크립트 판정용"""
    files = []
    for seg, _ in _cx_segments(_strip_harmless(text or "")):
        toks = _cx_tokens(seg) or []
        cur = []
        for t in toks + [";"]:
            if not (t and set(t) <= set(";&|")):
                cur.append(t)
                continue
            c = [x for x in cur if x not in (")", "))")]
            cur = []
            while c and c[0] in _CX_STRUCT:
                c = c[1:]
            words, k = [], 0
            while k < len(c):
                x = c[k]
                if x and set(x) <= set("<>&|") and ("<" in x or ">" in x):
                    if x in ("<", "<>") and k + 1 < len(c):
                        files.append(c[k + 1])
                    k += 2
                    continue
                words.append(x)
                k += 1
            while words and _CX_ASSIGN.match(words[0]):
                words = words[1:]
            if not words or _cx_name(words[0], "sh") not in _CX_READERS:
                continue
            for a in words[1:]:
                if a.startswith("if="):
                    files.append(a[3:])
                elif not (a.startswith("-") or "=" in a):
                    files.append(a)
    return files


def _cx_ph(s, st, out):
    """명령·프로세스 치환 자리표시(__cxsubN__)가 실행 위치에 오면 그 치환이 읽는 파일을 실행 대상으로 본다"""
    for name in re.findall(r"__cxsub\d+__", s or ""):
        for f in st.setdefault("ph", {}).get(name, []):
            _cx_add(out, f, st, why="치환으로 읽어 실행")


def _cx_cd(arg, st, replace=False):
    """cd 류 — replace 면 후보 cwd 를 바꾸고(같은 셸에서 ; 로 이어질 때·명령 단위 cwd 옵션), 아니면 더한다(합집합).
    판정 불가 인자면 cwd 불명"""
    a = _cx_pathify(arg or "")
    if not a or a == "-" or a[0] in "~+" or any(c in a for c in _CX_VAR):
        st["unk"] = True
        return
    bases = [a] if a.startswith("/") else [os.path.join(c, a) for c in st["cwds"]]
    new = []
    for b in bases:
        b = os.path.normpath(b)
        if any(ch in b for ch in _CX_GLOB):
            new += [m for m in glob.glob(b) if os.path.isdir(m)]
        else:
            new.append(b)
    if replace:
        if new:  # glob 무일치면 cd 실패 — cwd 그대로
            st["cwds"] = list(dict.fromkeys(new))
            if a.startswith("/"):
                st["unk"] = False
        return
    for b in new:
        if b not in st["cwds"]:
            st["cwds"].append(b)
    if len(st["cwds"]) > _CX_MAX_CWDS:
        st["unk"] = True


def _cx_name(w, mode):
    b = os.path.basename(w.rstrip("/")).lower()
    if mode == "cmd":
        b = b.lstrip("@")
    if b.endswith(".exe"):
        b = b[:-4]
    return b


def _cx_tokens(s):
    """셸 낱말 분해(( ) < > ; & | 는 따로) — 파싱 실패면 None. # 로 시작하는 낱말부터는 주석"""
    try:
        lx = shlex.shlex(s, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        lx.commenters = ""
        toks = list(lx)
    except ValueError:
        return None
    for k, t in enumerate(toks):
        if t.startswith("#"):
            return toks[:k]
    return toks


def _cx_net(s, st, out):
    """보조 그물 — 문자열 안 스크립트형 경로를 실행 대상으로 본다(코드 문자열 속 치환 자리표시 포함)"""
    _cx_ph(s, st, out)
    for m in _CX_NET_RE.finditer(_cx_pathify(s or "")):
        _cx_add(out, m.group(0), st, why="코드 문자열")


def _cx_segments(cmd):
    """_segments 와 같은 분할 + 각 구간 뒤 구분자(; · 줄바꿈 · && · || · | · & · 끝은 '')"""
    segs, buf, q = [], [], None
    i = 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            buf.append(ch)
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
            buf.append(ch)
        elif ch in ";\n|&":
            sep = ch
            while i + 1 < len(cmd) and cmd[i + 1] in "|&":
                i += 1
                sep += cmd[i]
            segs.append(("".join(buf), sep))
            buf = []
        else:
            buf.append(ch)
        i += 1
    segs.append(("".join(buf), ""))
    return [(s.strip(), sep) for s, sep in segs if s.strip()]


def _cx_scan(text, st, depth, mode, out, union=False):
    """text 를 구간·명령 단위로 훑어 cwd 를 갱신하고 실행 대상을 out 에 모은다. mode: sh|cmd|pwsh
    cd 는 같은 셸에서 ; · 줄바꿈으로 이어질 때만 교체, 그 밖(&& · || · | · & · 서브셸 · 조건문 · union)은 합집합."""
    if depth > 3:
        _cx_net(text, st, out)
        return
    if mode != "cmd":
        ph = st.setdefault("ph", {})

        def _sub(m):  # 명령 치환·프로세스 치환은 자식 셸 — 상태 사본으로 훑고, 자리표시로 바꿔 읽는 파일을 기억한다
            inner = next((g for g in m.groups() if g is not None), "")
            if inner.strip():
                _cx_scan(inner, _cx_copy(st), depth + 1, mode, out)
            name = "__cxsub%d__" % len(ph)
            ph[name] = _cx_reads(inner)
            return name
        text = _CX_SUBST_RE.sub(_sub, text)
    pipe = []
    for seg, sep in _cx_segments(_strip_harmless(text)):
        ro = mode == "sh" and not st["amb"] and _strict_readonly(seg)
        persist = not union and not st["amb"] and sep in (";", "\n", "")
        for sub in (seg.splitlines() if st["amb"] else [seg]):
            toks = _cx_tokens(sub)
            if toks is None:
                _cx_net(sub, st, out)
                continue
            cur = []
            for t in toks + [";"]:
                if t and set(t) <= set(";&|"):
                    if cur:
                        _cx_command(cur, st, depth, mode, ro, out, persist and t == ";" and len(cur) == len(toks),
                                    pipe)
                    cur = []
                else:
                    cur.append(t)
        # 같은 파이프라인 뒤 구간의 표준입력 = 앞 구간들이 읽는 파일(합집합 — 중간 필터는 통과시킨다)
        pipe = pipe + _cx_reads(seg) if sep in ("|", "|&") else []


def _cx_command(toks, st, depth, mode, ro, out, persist=False, pipe=None):
    """한 단순 명령(낱말 목록) 판정. st 는 셸 상태(cd·popd 만 바꾼다), 명령 단위 cwd 옵션·실행 판정은 사본(lst)으로 한다"""
    if toks and toks[0] in _CX_STRUCT or any(t in ("(", ")", "((", "))") for t in toks):
        persist = False  # 서브셸·조건문 안의 cd 는 이후 명령에 이어진다고 단정하지 않는다(합집합)
    toks = [t for t in toks if t not in (")", "))")]
    while toks and toks[0] in _CX_STRUCT:
        toks = toks[1:]
    while toks and toks[-1] == "}":
        toks = toks[:-1]
    rt, stdin, here = [], [], []
    i = 0
    while i < len(toks):  # 리다이렉트 — 표준입력 파일(<)·here-string(<<<)은 기억, 나머지는 지운다
        t = toks[i]
        if t and set(t) <= set("<>&|") and ("<" in t or ">" in t):
            f = toks[i + 1] if i + 1 < len(toks) else ""
            if t in ("<", "<>") and f and not f.isdigit():
                stdin.append(f)
            elif t == "<<<" and f:
                here.append(f)
            if rt and rt[-1].isdigit():
                rt.pop()
            i += 2
            continue
        rt.append(t)
        i += 1
    if not rt:
        return
    lst = _cx_copy(st)  # 명령 단위 상태 — env -C·sudo -D·wsl --cd 등은 이 명령에만 적용된다
    lst["pipe"] = list(pipe or [])
    i = 0
    while i < len(rt):  # 대입·접두어
        w = rt[i]
        if _CX_ASSIGN.match(w):
            if not ro:
                _cx_assign(w, lst, out)
            i += 1
            continue
        if "/" in w and not ro:
            _cx_add(out, w, lst)  # 경로형 낱말은 그 자체가 실행 파일 — 역할(인터프리터·접두어) 판정과 별개로 본다
        nm = _cx_name(w, mode)
        if nm in _CX_PREFIX and not ro:
            j = _cx_prefix(rt, i, nm, lst, depth, out)
            if j is None:
                return
            i = j
            continue
        break
    if i >= len(rt):
        return
    w = rt[i]
    nm = _cx_name(w, mode)
    args = rt[i + 1:]
    if nm in _CX_CD:
        _cx_cd_cmd(nm, args, st, mode, persist)
        return
    if nm in _CX_POP:
        st["unk"] = True
        return
    if ro:
        return
    if "__cxsub" in w:
        _cx_ph(w, lst, out)  # $(cat x.sh) 를 명령어 자리에 둔 실행(sh -c "$(cat x.sh)" · eval "$(…)")
    if nm in _CX_SH:
        _cx_sh(args, stdin, here, lst, depth, out)
    elif nm in _CX_SRC:
        pos = [a for a in args if a != "--"]
        if pos and pos[0] in ("-", "/dev/stdin"):
            _cx_stdin(stdin, lst, out)
        elif pos:
            _cx_add(out, pos[0], lst)
    elif nm == "script":
        _cx_script(args, lst, depth, out)
    elif nm == "watch":
        _cx_watch(args, lst, depth, out)
    elif _CX_PY_RE.match(nm):  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
        _cx_py(args, stdin, lst, out)
    elif nm in _CX_INTERP:
        _cx_interp(nm, args, stdin, lst, out)
    elif nm in ("pwsh", "powershell"):
        _cx_pwsh(args, stdin, lst, depth, out)
    elif nm == "cmd":
        _cx_cmd(args, lst, depth, out)
    elif nm in ("start", "start-process", "saps"):
        _cx_start(args, lst, mode, out)
    elif nm == "eval":
        _cx_scan(" ".join(args), st, depth + 1, "sh", out, union=True)  # 같은 셸 — cd 는 합집합으로 바깥에 남긴다
    elif mode == "cmd" and "/" not in w and nm not in _CX_CMD_BUILTIN:
        _cx_add(out, w, lst)  # cmd 는 현재 디렉터리를 먼저 찾는다(x.bat · 확장자 없는 x)


def _cx_assign(w, st, out):
    n, v = w.split("=", 1)
    if n in ("BASH_ENV", "ENV") and v:
        _cx_add(out, v, st)  # 비대화형 셸이 먼저 실행하는 파일


def _cx_optval(kind, v, st, depth, out):
    if kind == "cwd":
        _cx_cd(v, st, replace=True)  # st = 명령 단위 사본
    elif kind == "code":
        _cx_scan(v, _cx_copy(st), depth + 1, "sh", out)


def _cx_prefix(rt, i, nm, st, depth, out):
    """접두어 옵션을 소비하고 명령어 낱말 위치를 돌려준다. None = 이후 실행 없음(또는 미지 옵션으로 차단 기록)"""
    val, cwd, code, flag, skip = _CX_PREFIX[nm]
    j = i + 1
    while j < len(rt):
        t = rt[j]
        if t == "--":
            return j + 1
        if nm == "env" and (t == "-" or _CX_ASSIGN.match(t)):
            if t != "-":
                _cx_assign(t, st, out)
            j += 1
            continue
        if nm == "command" and t in ("-v", "-V"):
            return None  # 위치 조회 — 실행 아님
        if t.startswith("-") and len(t) > 1:
            if t.startswith("--"):
                n, eq, v = t.partition("=")
                kind = ("cwd" if n in cwd else "code" if n in code else "val" if n in val else
                        "flag" if n in flag else None)
                if kind is None:
                    _cx_add(out, "", st, why="%s 의 미지 옵션 %s" % (nm, t), force=True)
                    return None
                if kind != "flag" and not eq:
                    v = rt[j + 1] if j + 1 < len(rt) else ""
                    j += 1
                _cx_optval(kind, v, st, depth, out)
                j += 1
                continue
            k = 1
            while k < len(t):
                o = "-" + t[k]
                kind = "cwd" if o in cwd else "code" if o in code else "val" if o in val else None
                if kind:
                    v = t[k + 1:]
                    if not v:
                        v = rt[j + 1] if j + 1 < len(rt) else ""
                        j += 1
                    _cx_optval(kind, v, st, depth, out)
                    break
                if o not in flag and not t[k].isdigit():
                    _cx_add(out, "", st, why="%s 의 미지 옵션 %s" % (nm, t), force=True)
                    return None
                k += 1
            j += 1
            continue
        if skip:
            skip -= 1
            j += 1
            continue
        break
    return j


def _cx_cd_cmd(nm, args, st, mode, persist=False):
    pos = []
    j = 0
    while j < len(args):
        t = args[j]
        tl = t.lower()
        if tl in ("/d", "-p", "-l", "-e", "-@", "--", "-passthru"):
            j += 1
            continue
        if tl in ("-path", "-literalpath", "-lp", "-pspath"):
            pos.append(args[j + 1] if j + 1 < len(args) else "")
            j += 2
            continue
        if tl == "-stackname":
            j += 2
            continue
        pos.append(t)
        j += 1
    if not pos:
        if mode == "cmd" and nm in ("cd", "chdir"):
            return  # cmd 의 인자 없는 cd 는 현재 위치 출력
        st["unk"] = True  # sh 의 인자 없는 cd = 홈, pushd = 맞바꾸기 → 불명
        return
    _cx_cd(pos[0], st, replace=persist)


def _cx_sh(args, stdin, here, st, depth, out):
    code = synt = sin = False
    j = 0
    while j < len(args):
        t = args[j]
        if t == "--":
            j += 1
            break
        if t in ("--rcfile", "--init-file"):
            if j + 1 < len(args):
                _cx_add(out, args[j + 1], st)
            j += 2
            continue
        if t.startswith("--"):
            j += 1
            continue
        if len(t) > 1 and t[0] in "-+":
            letters = t[1:]
            code = code or "c" in letters
            synt = synt or (t[0] == "-" and "n" in letters)
            sin = sin or "s" in letters
            if "o" in letters or "O" in letters:
                j += 1
            j += 1
            continue
        break
    pos = args[j:]
    if synt:
        return  # -n 구문 검사만
    if code:
        if pos:
            _cx_scan(pos[0], _cx_copy(st), depth + 1, "sh", out)  # 자식 셸 — 그 안의 cd 는 바깥에 남지 않는다
        return
    if pos and not sin and pos[0] not in ("-", "/dev/stdin"):
        _cx_add(out, pos[0], st)
        return
    _cx_stdin(stdin, st, out)
    for h in here:
        _cx_scan(h, _cx_copy(st), depth + 1, "sh", out)


def _cx_py(args, stdin, st, out):
    j = 0
    while j < len(args):
        t = args[j]
        if t == "--":
            j += 1
            break
        if t == "-":
            break
        if t.startswith("--"):
            j += 2 if t == "--check-hash-based-pycs" else 1
            continue
        if t.startswith("-") and len(t) > 1:
            letters = t[1:]
            if letters[0].isdigit():  # py -3 · py -3.12
                j += 1
                continue
            for k, ch in enumerate(letters):
                if ch == "c":
                    _cx_net(letters[k + 1:] or (args[j + 1] if j + 1 < len(args) else ""), st, out)
                    return
                if ch == "m":
                    return  # 모듈 실행 — 스크립트 실행 아님(리드 결정 c186)
                if ch in "WX":
                    if not letters[k + 1:]:
                        j += 1
                    break
            j += 1
            continue
        break
    pos = args[j:]
    if pos and pos[0] not in ("-", "/dev/stdin"):
        _cx_add(out, pos[0], st)
        return
    _cx_stdin(stdin, st, out)


def _cx_interp(nm, args, stdin, st, out):
    code, val, cwd, fil = _CX_INTERP[nm]
    j = 0
    while j < len(args):
        t = args[j]
        if t == "--":
            j += 1
            break
        if t.startswith("-") and len(t) > 1:
            if t.startswith("--"):
                n, eq, v = t.partition("=")
                if n in code:
                    _cx_net(v if eq else (args[j + 1] if j + 1 < len(args) else ""), st, out)
                    return
                if n in val and not eq:
                    j += 1
                j += 1
                continue
            o, v = t[:2], t[2:]
            nxt = args[j + 1] if j + 1 < len(args) else ""
            if o in code:
                _cx_net(v or nxt, st, out)
                return
            if o in fil:
                _cx_add(out, v or nxt, st)
                return
            if o in cwd:
                _cx_cd(v or nxt, st, replace=True)
                j += 1 if v else 2
                continue
            if o in val and not v:
                j += 1
            j += 1
            continue
        break
    pos = args[j:]
    if pos and pos[0] not in ("-", "/dev/stdin"):
        _cx_add(out, pos[0], st)
        return
    _cx_stdin(stdin, st, out)


def _cx_pw_isopt(t):
    return (t.startswith("-") and len(t) > 1) or bool(re.fullmatch(r"^/[A-Za-z]+$", t))


def _cx_pw_kind(t):
    n = t.lstrip("-/").split(":", 1)[0].lower()
    if n in _CX_PW:
        return _CX_PW[n]
    kinds = {v for k, v in _CX_PW.items() if len(n) >= 2 and k.startswith(n)}
    for k in _CX_PW_PRIO:
        if k in kinds:
            return k
    return "flag"


def _cx_pwsh(args, stdin, st, depth, out):
    j = 0
    while j < len(args):
        t = args[j]
        if not _cx_pw_isopt(t):
            break
        k = _cx_pw_kind(t)
        v = args[j + 1] if j + 1 < len(args) else ""
        if k == "file":
            if v == "-":
                _cx_stdin(stdin, st, out)
            else:
                _cx_add(out, v, st)
            return
        if k == "code":
            if v == "-":
                _cx_stdin(stdin, st, out)
                return
            rest = " ".join(args[j + 1:])
            _cx_scan(rest, _cx_copy(st), depth + 1, "pwsh", out)
            _cx_net(rest, st, out)
            return
        if k == "enc":
            _cx_add(out, "", st, why="pwsh -EncodedCommand(내용 판정 불가)", force=True)
            return
        if k == "cwd":
            _cx_cd(v, st, replace=True)
            j += 2
            continue
        j += 2 if k == "val" else 1
    pos = args[j:]
    if pos:
        _cx_add(out, pos[0], st)  # pwsh 7 은 첫 위치 인자를 -File 로, Windows PowerShell 은 -Command 로 본다 — 둘 다 판정
        rest = " ".join(pos)
        _cx_scan(rest, _cx_copy(st), depth + 1, "pwsh", out)
        _cx_net(rest, st, out)
    else:
        _cx_stdin(stdin, st, out)


def _cx_script(args, st, depth, out):
    """script [옵션] [기록파일] — -c/--command 문자열을 sh 로 재판정(없으면 대화형 셸 — 대상 없음)"""
    j = 0
    while j < len(args):
        t = args[j]
        if t == "--":
            break
        if t.startswith("--"):
            n, eq, v = t.partition("=")
            if n == "--command":
                _cx_scan(v if eq else (args[j + 1] if j + 1 < len(args) else ""), _cx_copy(st), depth + 1, "sh", out)
                return
            if n in ("--log-out", "--log-in", "--log-io", "--log-timing", "--echo", "--logging-format",
                     "--output-limit") and not eq:
                j += 1
            j += 1
            continue
        if t.startswith("-") and len(t) > 1:
            letters = t[1:]
            for k, ch in enumerate(letters):
                if ch == "c":
                    code = letters[k + 1:] or (args[j + 1] if j + 1 < len(args) else "")
                    _cx_scan(code, _cx_copy(st), depth + 1, "sh", out)
                    return
                if ch in "OIBTEmo":
                    if not letters[k + 1:]:
                        j += 1
                    break
        j += 1  # 위치 인자 = 기록 파일


def _cx_watch(args, st, depth, out):
    """watch [옵션] 명령… — 명령을 sh -c 로 실행하므로 이어 붙여 재판정"""
    j = 0
    while j < len(args):
        t = args[j]
        if t == "--":
            j += 1
            break
        if t.startswith("-") and len(t) > 1:
            j += 2 if t in ("-n", "--interval", "-q", "--equexit") else 1
            continue
        break
    if args[j:]:
        _cx_scan(" ".join(args[j:]), _cx_copy(st), depth + 1, "sh", out)


def _cx_cmd(args, st, depth, out):
    j = 0
    while j < len(args):
        t = args[j]
        tl = t.lower()
        if tl in ("/c", "/k", "/r"):
            _cx_scan(" ".join(args[j + 1:]), _cx_copy(st), depth + 1, "cmd", out)
            return
        if re.match(r"^/[ckr]\S", tl) and "/" not in t[1:]:
            _cx_scan(" ".join([t[2:]] + args[j + 1:]), _cx_copy(st), depth + 1, "cmd", out)
            return
        if re.fullmatch(r"^/[a-z]+(:\S*)?$", tl) and "/" not in t[1:]:
            j += 1
            continue
        break
    if args[j:]:
        _cx_scan(" ".join(args[j:]), _cx_copy(st), depth + 1, "cmd", out)


def _cx_start(args, st, mode, out):
    j = 0
    while j < len(args):
        t = args[j]
        tl = t.lower()
        nxt = args[j + 1] if j + 1 < len(args) else ""
        if tl == "/d":
            _cx_cd(nxt, st, replace=True)
            j += 2
            continue
        if re.match(r"^/d[^/]", tl) and len(t) > 2:
            _cx_cd(t[2:], st, replace=True)
            j += 1
            continue
        if tl in ("/node", "/affinity"):
            j += 2
            continue
        if re.fullmatch(r"^/[a-z]+$", tl):
            j += 1
            continue
        if mode == "pwsh" and t.startswith("-") and len(t) > 1:
            n = tl.lstrip("-")
            if n.startswith("wo"):
                _cx_cd(nxt, st, replace=True)
                j += 2
                continue
            j += 1
            continue
        if t:
            _cx_add(out, t, st)  # 제목·프로그램·인자 모두 후보(제목 인용 조각 때문 — 계획 §3.5 (d))
        j += 1


def _cx_area(x, areas):
    """경로 x(정규화·realpath 둘 다)가 어느 영역 안이고 unless 비일치인가 → 영역 또는 None"""
    try:
        rx_ = os.path.realpath(x)
    except Exception:
        rx_ = x
    for a in areas:
        for y in dict.fromkeys((x, rx_)):
            yl = y.lower()
            for r in a["roots"]:
                if not yl.startswith(r.lower() + "/"):
                    continue
                rel = "/" + y[len(r) + 1:]
                try:
                    if os.path.isdir(y):
                        rel += "/"
                except Exception:
                    pass
                if any(z.search(rel) for z in a["rxs"]) and not any(z.search(rel) for z in a["unless"]):
                    return a
    return None


def _cx_eval(e, areas, skip=None):
    """실행 대상 1건 판정 → (영역, 설명) 또는 None. skip(c196 exec_allow 허용 realpath 집합)과 같은 후보 경로는 건너뛴다"""
    if e["why"] and not e["t"]:
        return (areas[0], e["why"]) if e["unk"] else None
    t = _cx_pathify(e["t"])
    if not t:
        return None
    if t.startswith("~"):
        t = os.path.expanduser(t)
    ks = [k for k in (t.find(c) for c in _CX_VAR) if k >= 0]
    if ks:
        pre = t[:min(ks)]
        if "/" not in pre:
            return None  # 잔존 한계 — 디렉터리까지 변수로 만든 경로
        t = pre[:pre.rfind("/") + 1] + "_"
    if t.startswith("/"):
        paths = [t]
    elif e["unk"]:
        return areas[0], ("%s — 작업 디렉터리 불명(cd 인자가 변수·~·-·없음 또는 popd) 상태의 상대경로 실행. "
                          "절대경로로 쓰거나 cd 인자를 리터럴로 쓰라" % e["t"])
    else:
        paths = [os.path.join(c, t) for c in e["cwds"]]
    for p in paths:
        p = os.path.normpath(p)
        cands = [p]
        if any(ch in p for ch in _CX_GLOB):
            cands = glob.glob(p)
            if not any(ch in os.path.dirname(p) for ch in _CX_GLOB):
                cands.append(p)  # 파일명에만 glob — 디렉터리 부분으로 판정(확장 결과 불문)
        for x in cands:
            if skip and os.path.realpath(x) in skip:
                continue
            a = _cx_area(x, areas)
            if a:
                return a, x
    return None


def _cwd_exec_hit(inp, tool, cmd, cmd_n, wd, confs, skip=None):
    """c186 — 유효 작업 디렉터리 기준으로 푼 실행 대상이 실행 차단 영역 안인가 → (synthetic 규칙, 대상) 또는 (None, '')"""
    areas = _load_exec_dirs(confs)
    if not areas:
        return None, ""
    try:
        cw = _cwd_candidates(inp, tool, wd, [a["roots"][0] for a in areas])
        amb = _quote_ambiguous(cmd)
        for text in ([cmd_n, cmd] if amb else [cmd_n]):  # 따옴표 혼동 소지면 변환 전 원문(백슬래시 이스케이프 보존)도 훑는다
            st = {"cwds": list(cw), "unk": False, "amb": amb}
            out = []
            _cx_scan(text, st, 0, "sh", out)
            for e in out:
                r = _cx_eval(e, areas, skip)
                if r:
                    a, what = r
                    return ({"id": EXEC_RULE_ID, "src": a["src"], "reason": a["reason"], "all": [], "unless": []},
                            "%s → %s (작업 디렉터리 후보: %s)" % (e["t"] or e["why"], what, ", ".join(e["cwds"][:4])))
    except Exception as ex:  # 영역이 설정된 프로젝트에서 판정 오류는 fail-closed
        _log("ERROR cwd-exec %r cmd=%.200s" % (ex, _mask(cmd)))
        a = areas[0]
        return ({"id": EXEC_RULE_ID, "src": a["src"], "all": [], "unless": [],
                 "reason": "작업 디렉터리 기준 실행 판정 중 오류 — fail-closed(%r)" % (ex,)}, cmd)
    return None, ""


# ── 화면 승인 채널(2026-10-24) — askq_approval.py 판정 기준을 코어 안에 복제(보호 경계 밖 파일을 import 하지 않는다) ──
def _ap_main_transcript(sid, tpath):
    """메인 세션 트랜스크립트 판별 → (realpath|None, code)"""
    if not isinstance(sid, str) or not APPROVAL_SID_RE.fullmatch(sid):
        return None, "bad_session"
    if not isinstance(tpath, str) or not tpath or not os.path.isabs(tpath):
        return None, "no_transcript"
    norm = os.path.normpath(tpath)
    if os.path.basename(norm) != sid + ".jsonl":
        return None, "not_main_transcript"
    if "/subagents/" in norm.replace("\\", "/") + "/" or \
            os.path.basename(os.path.dirname(os.path.dirname(norm))) != "projects":
        return None, "not_main_transcript"
    real = os.path.realpath(norm)
    if not os.path.isfile(real):
        return None, "no_transcript"
    return real, "ok"


def _ap_tail_lines(path):
    """파일 끝 APPROVAL_TAIL_BYTES 만 읽어 줄 목록으로. 잘린 첫 줄은 버린다"""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        start = max(0, size - APPROVAL_TAIL_BYTES)
        f.seek(start)
        data = f.read()
    lines = data.split(b"\n")
    if start > 0 and lines:
        lines = lines[1:]
    return lines


def _ap_ts(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        t = s.strip()
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        d = datetime.datetime.fromisoformat(t)
        if d.tzinfo is None:
            d = d.replace(tzinfo=datetime.timezone.utc)
        return d.timestamp()
    except Exception:
        return None


def _ap_blocks(entry):
    msg = entry.get("message")
    if not isinstance(msg, dict):
        return []
    c = msg.get("content")
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def _ap_foreign(entry, sid):
    """팀원 기록 흔적 또는 다른 세션 기록이면 True"""
    if "agentName" in entry or "teamName" in entry:
        return True
    s = entry.get("sessionId")
    return s is not None and s != sid


def _ap_question(qtext, cmd, wd_exp):
    """질문 본문 판정 — 고정 문구·명령 블록 1개(원문 완전 일치)·작업 디렉터리 줄 → code"""
    if APPROVAL_PHRASE not in qtext:
        return "phrase_missing"
    if qtext.count("```") != 2:
        return "block_count"
    m = APPROVAL_BLOCK_RE.search(qtext)
    if not m:
        return "block_missing"
    blk = m.group(1)
    if not (blk == cmd or blk + "\n" == cmd):
        return "cmd_mismatch"
    outside = qtext[:m.start()] + "\n" + qtext[m.end():]
    wds = [ln[len(APPROVAL_WD_PREFIX):] for ln in outside.split("\n") if ln.startswith(APPROVAL_WD_PREFIX)]
    if len(wds) > 1:
        return "wd_mismatch"
    if (wds[0] if wds else None) != wd_exp:
        return "wd_mismatch"
    return "ok"


def _ap_collect(lines, sid):
    """승인 질문 tool_use 후보(header 일치)와 tool_result 항목을 모은다"""
    uses, order, results = {}, [], {}
    for raw in lines:
        if b"AskUserQuestion" not in raw and b"toolUseResult" not in raw:
            continue
        try:
            e = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        if not isinstance(e, dict):
            continue
        for b in _ap_blocks(e):
            bt = b.get("type")
            if bt == "tool_use" and b.get("name") == "AskUserQuestion":
                bi = b.get("input")
                if not isinstance(bi, dict):
                    continue
                qs = bi.get("questions")
                qs = qs if isinstance(qs, list) else []
                qtext = None
                for q in qs:
                    if isinstance(q, dict) and q.get("header") == APPROVAL_HEADER:
                        qtext = q.get("question") if isinstance(q.get("question"), str) else ""
                        break
                if qtext is None:
                    continue
                tid = b.get("id")
                if not isinstance(tid, str) or not tid:
                    continue
                uses[tid] = {"entry_uuid": e.get("uuid"), "sidechain": e.get("isSidechain") is True,
                             "question": qtext, "forged": ("answers" in bi) or ("annotations" in bi),
                             "foreign": _ap_foreign(e, sid)}
                order.append(tid)
            elif bt == "tool_result":
                tid = b.get("tool_use_id")
                if isinstance(tid, str) and tid:
                    results[tid] = (e, b)
    return uses, order, results


def _ap_judge(use, res, sid, cmd, wd_exp):
    """후보 1건 판정 → code("ok" 면 성립)"""
    if use["foreign"]:
        return "team_member"
    if use["forged"]:
        return "forged_answers"
    qc = _ap_question(use["question"], cmd, wd_exp)
    if qc != "ok":
        return qc
    if use["sidechain"]:
        return "sidechain"
    if res is None:
        return "no_result"
    e, b = res
    if _ap_foreign(e, sid):
        return "team_member"
    if b.get("is_error") is True:
        return "tool_error"
    if e.get("isSidechain") is True:
        return "sidechain"
    pd = e.get("permissionDecision")
    if not isinstance(pd, dict) or pd.get("decision") != "accept" \
            or not str(pd.get("source") or "").startswith("user"):
        return "not_user_decision"
    if not use["entry_uuid"] or e.get("sourceToolAssistantUUID") != use["entry_uuid"]:
        return "uuid_mismatch"
    tur = e.get("toolUseResult")
    ans = tur.get("answers") if isinstance(tur, dict) else None
    if not isinstance(ans, dict) or str(ans.get(use["question"], "")).strip() != APPROVAL_LABEL:
        return "label_mismatch"
    ts = _ap_ts(e.get("timestamp"))
    if ts is None:
        return "expired"
    if ts > NOW + 60:
        return "future_ts"
    if NOW - ts > APPROVAL_TTL_SEC:
        return "expired"
    return "ok"


def _ap_consumed_ids(path):
    ids = set()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for ln in f:
                p = ln.split("\t", 1)[0].strip()
                if p:
                    ids.add(p)
    except FileNotFoundError:
        pass
    return ids


def _ap_consume(path, tid, cmd, rule_id):
    """flock 아래 재확인 후 원자적 append. 이미 소비됐으면 False"""
    import fcntl
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if tid in _ap_consumed_ids(path):
            return False
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        h = hashlib.sha256(cmd.encode("utf-8", "replace")).hexdigest()[:16]
        os.write(fd, ("%s\t%s\trule=%s\t%s\n" % (tid, h, rule_id, stamp)).encode("utf-8"))
        return True
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _approval(inp, ti, tool, cmd, hit):
    """셸 규칙 차단에 대한 화면 승인 판정 → (ok, code, tool_use_id). 예외는 전부 불인정(fail-closed)"""
    try:
        if tool not in BASH_TOOLS:
            return False, "not_shell", ""
        if inp.get("agent_id"):
            return False, "team_member", ""
        sid = inp.get("session_id")
        path, code = _ap_main_transcript(sid, inp.get("transcript_path"))
        if path is None:
            return False, code, ""
        if not cmd:
            return False, "no_cmd", ""
        if "```" in cmd:
            return False, "unsupported_cmd", ""
        if not HOOK_DIR:
            return False, "no_ledger", ""
        wd_exp = None
        for k in ("working_dir", "workdir", "cwd"):
            v = ti.get(k)
            if isinstance(v, str) and v:
                wd_exp = v
                break
        uses, order, results = _ap_collect(_ap_tail_lines(path), sid)
        if not order:
            return False, "no_candidate", ""
        ledger = os.path.join(HOOK_DIR, "logs", APPROVAL_LEDGER)
        consumed = _ap_consumed_ids(ledger)
        last = None
        for tid in reversed(order):   # 가장 최근 후보부터
            c = _ap_judge(uses[tid], results.get(tid), sid, cmd, wd_exp)
            if c == "ok" and tid in consumed:
                c = "consumed"
            if c == "ok" and not _ap_consume(ledger, tid, cmd, hit.get("id", "")):
                c = "consumed"
            if c == "ok":
                return True, "ok", tid
            if last is None:
                last = c
        return False, last or "no_candidate", ""
    except Exception as ex:
        return False, "error_%s" % type(ex).__name__, ""


# unblock3(사용자 지시 2026-10-27 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라" + 화면 결정 "결합 형태도 전부 해제"):
#   셸 명령에 git 머리 구간이 하나라도 있으면 규칙 판정(2)을 통째로 생략한다(git 뒤에 붙인 배포 스크립트도 통과 — 사용자가 알고 선택).
#   머리 = 구간(; && || | & 개행)의 첫 명령어에서 VAR=값 · ( · { · ! · then · do 와 실행 접두어(env·timeout·nice·nohup·command·
#   exec·sudo·xargs·stdbuf·time, 옵션 포함)를 벗긴 뒤 이름이 git(·git.exe)인 것. echo git · grep git · 메시지 속 git 은 머리가 아니다.
#   bash -c '…git…' 안쪽은 세지 않는다(바깥이 bash). 따옴표 혼동 소지·파싱 실패면 git 아님(종전 판정).
_U3_PREFIX = ("env", "timeout", "nice", "nohup", "command", "exec", "sudo", "xargs", "stdbuf", "time")
_U3_LEAD = ("(", "{", "!", "then", "do")
_U3_GIT_PATH_RE = re.compile(r"/Git/(?:cmd|bin|mingw64/bin)/git(?:\.exe)?$")


def _u3_git_name(t):
    """낱말 t 가 git 실행 파일 이름인가(경로가 붙으면 표준 bin 디렉터리·Windows Git 설치 경로만)"""
    base = os.path.basename(t)
    if base not in ("git", "git.exe"):
        return False
    if "/" not in t:
        return True
    return os.path.dirname(t) in SAFE_BIN_DIRS or bool(_U3_GIT_PATH_RE.search(t))


def _git_head(seg):
    """구간 seg 의 머리 명령어가 git 인가(unblock3 가정 1)"""
    try:
        toks = shlex.split(_strip_harmless(seg))
    except ValueError:
        return False
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if t in _U3_LEAD:
            i += 1
            continue
        if t.startswith("(") and len(t) > 1:
            toks[i] = t = t.lstrip("(")
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
            continue
        nm = os.path.basename(t)
        if nm in _U3_PREFIX and nm in _CX_PREFIX:
            val, cwd, code, flag, skip = _CX_PREFIX[nm]
            j = i + 1
            while j < n:
                o = toks[j]
                if o == "--":
                    j += 1
                    break
                if nm == "env" and (o == "-" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", o)):
                    j += 1
                    continue
                if o.startswith("-") and len(o) > 1:
                    if nm == "command" and o in ("-v", "-V"):
                        return False   # 위치 조회 — 실행 아님
                    if o.startswith("--"):
                        k, eq, _v = o.partition("=")
                        if k in code:
                            return False
                        if k in val or k in cwd:
                            j += 1 if eq else 2
                            continue
                        if k in flag:
                            j += 1
                            continue
                        return False   # 미지 옵션 — 판정 불가
                    o1 = o[:2]
                    if o1 in code:
                        return False
                    if o1 in val or o1 in cwd:
                        j += 1 if len(o) > 2 else 2
                        continue
                    if all(("-" + c) in flag or c.isdigit() for c in o[1:]):
                        j += 1
                        continue
                    return False
                if skip:
                    skip -= 1
                    j += 1
                    continue
                break
            i = j
            continue
        return _u3_git_name(t)
    return False


def _u3_segs(cmd):
    """커밋 메시지 정규화 후 구간 목록. 따옴표 혼동 소지면 None(종전 판정)"""
    try:
        c = _commit_msg_literal(cmd)
        if _quote_ambiguous(c):
            return None
        return _segments(_strip_harmless(c))
    except Exception:
        return None


def _bashc_inner(seg):
    """보수적으로 인식 가능한 bash|sh|dash -c 리터럴 본문을 돌려준다."""
    m = re.fullmatch(r"\s*(bash|sh|dash)\s+-c\s+('([^']*)'|\"([^\"`$\\]*)\")\s*", seg)
    if not m:
        return None
    return m.group(3) if m.group(3) is not None else m.group(4)


def _inner_git_only(cmd, depth=0):
    if depth > 2:
        return False
    segs = _u3_segs(cmd)
    if not segs:
        return False
    names = set()
    for s in segs:
        n = _pure_assign_names(s)
        if n:
            names.update(n)
    if names and not _assign_refs_ok(segs, names):
        return False
    vals, any_git = {}, False
    for s in segs:
        if names and _pure_assign_names(s):
            for t in s.split():
                k, v = t.split("=", 1); vals[k] = v
            continue
        e = s
        if names:
            for n in sorted(names, key=len, reverse=True):
                if re.search(r"\$\{?%s(?![A-Za-z0-9_])" % re.escape(n), e):
                    if n not in vals:
                        return False
                    e = re.sub(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (re.escape(n), re.escape(n)), lambda _m, _v=vals[n]: _v, e)
            if "$" in _sq_strip(e).replace("$?", ""):
                return False
        inner = _bashc_inner(e)
        if inner is not None:
            if not _inner_git_only(inner, depth + 1):
                return False
            any_git = True
        elif _git_head(e):
            if any(x in _q_strip(e) for x in (">", "<(")) or any(x in _sq_strip(e) for x in ("$(", "`", ">(")):
                return False
            any_git = True
        elif not _strict_readonly(e):
            return False
    return any_git


def _git_composite(cmd):
    """결정 ①: 안전한 bash -c 안쪽을 포함해 git 머리 구간이 하나 이상인가"""
    segs = _u3_segs(cmd)
    if not segs:
        return False
    if any(_git_head(s) for s in segs):
        return True
    return any((inner := _bashc_inner(s)) is not None and _inner_git_only(inner) for s in segs)


def _self_heredoc_mask(cmd):
    """비보호 파일에 쓰는 cat의 인용 heredoc 본문만 보수적으로 가린다."""
    lines = cmd.splitlines(True)
    out = []
    i = 0
    found = False
    vals = {}
    while i < len(lines):
        line = lines[i]
        m = re.fullmatch(r"^\s*cat\s+(?:>|>>|<<\s*(['\"])([A-Za-z_][A-Za-z0-9_]*)\1\s+>)\s*([^\s;&|<>]+)\s*<<\s*(['\"])([A-Za-z_][A-Za-z0-9_]*)\4\s*$", line.rstrip("\r\n"))
        # 표준형 cat > file <<'TAG' 및 cat <<'TAG' > file
        m1 = re.fullmatch(r"^\s*cat\s+(?:>|>>)[ \t]+([^\s;&|<>]+)[ \t]+<<[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2[ \t]*$", line.rstrip("\r\n"))
        m2 = re.fullmatch(r"^\s*cat[ \t]+<<[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\1[ \t]+(?:>|>>)[ \t]*([^\s;&|<>]+)[ \t]*$", line.rstrip("\r\n"))
        if m1 or m2:
            target = m1.group(1) if m1 else m2.group(3)
            tag = m1.group(3) if m1 else m2.group(2)
            for n in sorted(vals, key=len, reverse=True):
                target = re.sub(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (re.escape(n), re.escape(n)), vals[n], target)
            if "$" in target or "`" in target or "*" in target or "?" in target or _self_path(target):
                return None
            j = i + 1
            while j < len(lines) and lines[j].rstrip("\r\n") != tag:
                j += 1
            if j >= len(lines):
                return None
            out.append("date '+%F'\n")
            i = j + 1
            found = True
            continue
        out.append(line)
        for a in re.finditer(r"(?:^|[; \t])([A-Za-z_][A-Za-z0-9_]*)=([A-Za-z0-9_./:@%+,=-]+)", line):
            n, v = a.group(1), a.group(2)
            if not ASSIGN_DANGER_RE.match(n) and n not in os.environ:  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
                vals[n] = v
        i += 1
    return ("".join(out), found)


def _self_redirect_strip(seg, vals):
    """비보호 리터럴 파일로 향하는 출력 리다이렉트를 검증하고 제거한다."""
    pat = re.compile(r"(?<![<])(?:[0-9]+)?(?:>>|>|&>|>\|)[ \t]*([^\s;&|]+)")
    matches = list(pat.finditer(seg))
    for m in matches:
        target = m.group(1).strip("\"'")
        if "$" in target:
            for n, v in vals.items():
                target = re.sub(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (re.escape(n), re.escape(n)), v, target)
        if any(c in target for c in "$`*?[]") or _self_path(target):
            return None
    return pat.sub(" ", seg) if matches else seg


def _self_sed_read(tokens):
    """자기 보호 판정에서 주소 출력만 하는 sed 호출인가."""
    if not tokens or tokens[0] != "sed":
        return False
    allowed = {"-n", "-E", "-r"}
    scripts = []
    i = 1
    while i < len(tokens):
        t = tokens[i]
        if t in allowed:
            i += 1
            continue
        if t == "-e":
            if i + 1 >= len(tokens):
                return False
            scripts.append(tokens[i + 1])
            i += 2
            continue
        if t.startswith("-"):
            return False
        if not scripts:
            scripts.append(t)
            i += 1
            break
        break
    if "-n" not in tokens[1:] or not scripts:
        return False
    addr = r"(?:[0-9]+|\$|/(?:\\[^/;]|[^/;\\])*/)"
    print_only = re.compile(r"^(?:%s)(?:,(?:%s))?p$" % (addr, addr))
    if not all(print_only.fullmatch(script) for script in scripts):
        return False
    # 표현식 뒤에는 파일 경로만 허용하며, 옵션처럼 보이는 인자는 거부한다.
    return all(not arg.startswith("-") for arg in tokens[i:])


def _self_ext_ok(cmd, depth=0):
    """자기 보호 확장: 가드 비쓰기임이 증명된 구간만 통과시킨다."""
    if depth > 2:
        return False
    try:
        masked = _self_heredoc_mask(cmd)
        if masked is None:
            return False
        c, _had_heredoc = masked
        c = _commit_msg_literal(c)
        if _quote_ambiguous(c):
            return False
        segs = _segments(_strip_harmless(c))
        if not segs:
            return False
        names = set()
        for s in segs:
            n = _pure_assign_names(s)
            if n:
                names.update(n)
        if names and not _assign_refs_ok(segs, names):
            return False
        vals, any_git = {}, False
        for s in segs:
            if names and _pure_assign_names(s):
                for t in s.split():
                    k, v = t.split("=", 1); vals[k] = v
                continue
            e = s
            if names:
                for n in sorted(names, key=len, reverse=True):
                    if re.search(r"\$\{?%s(?![A-Za-z0-9_])" % re.escape(n), e):
                        if n not in vals:
                            return False
                        e = re.sub(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (re.escape(n), re.escape(n)), lambda _m, _v=vals[n]: _v, e)
                if "$" in _sq_strip(e).replace("$?", ""):
                    return False
            inner = _bashc_inner(e)
            if inner is not None:
                if not _self_ext_ok(inner, depth + 1):
                    return False
                any_git = True
                continue
            has_redirect = _self_redirect_strip(e, vals) != e
            if _git_head(e) and has_redirect and any(n in e.lower() for n in SELF_NAMES):
                return False
            redirected = _self_redirect_strip(e, vals)
            if redirected is None:
                return False
            if _git_head(redirected):
                try:
                    gt = shlex.split(redirected)
                except ValueError:
                    return False
                if any(x in _q_strip(redirected) for x in ("<(",)) or any(x in _sq_strip(redirected) for x in ("$(", "`", ">(")):
                    return False
                if len(gt) > 1 and gt[1] in ("checkout", "switch", "clean"):
                    return False
                any_git = True
                continue
            if _strict_readonly(redirected) or _pure_assign_names(redirected):
                continue
            try:
                t = shlex.split(redirected)
            except ValueError:
                return False
            if t and t[0] == "python3" and len(t) >= 3 and t[1:3] == ["-m", "json.tool"] and len(t[3:]) <= 1:
                continue
            if t and t[0] == "sed" and _self_sed_read(t):
                continue
            if t and t[0] == "awk" and _awk_read(redirected):
                for other in segs:
                    try:
                        ot = shlex.split(other)
                    except ValueError:
                        return False
                    if any(_self_path(x) for x in ot[1:]):
                        return False
                continue
            if t and t[0] == "cd" and len(t) <= 2:
                continue
            return False
        return True
    except Exception:
        return False


def _self_git_ok(cmd):
    """결정 ②(자기 보호): 모든 구간이 git 머리 구간(쓰기 리다이렉트·명령 치환 없음) 또는 엄격 읽기·cd 이고 git 구간이 하나 이상인가.
    비 git 쓰기 구간(git status; rm <가드 파일>)이나 git 구간의 리다이렉트 쓰기(git show … > <가드 파일>)는 종전대로 거짓."""
    segs = _u3_segs(cmd)
    if not segs:
        return False
    any_git = False
    for s in segs:
        if _git_head(s):
            if any(x in _q_strip(s) for x in (">", "<(")) or any(x in _sq_strip(s) for x in ("$(", "`", ">(")):
                return False
            any_git = True
        elif not _strict_readonly(s):
            return False
    return any_git


def main():
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    tool = inp.get("tool_name") or ""
    ti = inp.get("tool_input") or {}
    if not isinstance(ti, dict):
        return
    if tool not in BASH_TOOLS + WRITE_TOOLS + FILEOP_TOOLS:
        return
    who = "team:%s" % inp.get("agent_id") if inp.get("agent_id") else ("pipeline" if os.environ.get("PIPELINE_UUID") else "main")
    cmd, paths, content, wd = _strings(ti)
    cmd_n = _win2wsl(cmd)
    paths_n = [_win2wsl(p) for p in paths]

    # 1) 자기 보호 — 스위치·가드 파일 조작 (스위치 유효 여부와 무관하게 셸 조작은 항상 차단)
    if tool in BASH_TOOLS:
        if SWITCH_NAME.lower() in cmd.lower():
            if not _switch_name_read_only(cmd):
                _log("DENY self-switch who=%s cmd=%.200s" % (who, _mask(cmd)))
                _block_log("self-switch", "", who, tool, inp, cmd, paths_n)
                _deny("🚫 [운영 배포 가드] 비상 해제 스위치(%s)는 에이전트가 만들거나 지우거나 경로로 다룰 수 없다"
                      "(이름을 조회하는 엄격 읽기전용 명령만 통과). %s" % (SWITCH_NAME, HOLD_GUIDE))
                return
            _log("PASS self-switch-read who=%s cmd=%.200s" % (who, _mask(cmd)))
        if any(n in cmd.lower() for n in SELF_NAMES):
            if not _all_strict(cmd) and _all_strict_or_git_index(_commit_msg_literal(cmd)):
                _log("PASS self-git-index who=%s cmd=%.200s" % (who, _mask(cmd)))
            elif not _all_strict(cmd) and _self_git_ok(cmd):
                # unblock3 결정 ②(사용자 지시 2026-10-27 13:04 + 화면 결정 "자동 원복까지 해제"): git 구간만 연다
                _log("PASS self-git who=%s cmd=%.200s" % (who, _mask(cmd)))
            elif not _all_strict(cmd) and _self_ext_ok(cmd):
                _log("PASS self-ext who=%s cmd=%.200s" % (who, _mask(cmd)))
            elif not _all_strict(cmd):
                _log("DENY self-modify who=%s cmd=%.200s" % (who, _mask(cmd)))
                _block_log("self-modify", "", who, tool, inp, cmd, paths_n)
                _deny("🚫 [운영 배포 가드] 가드 파일(hook·코어·차단 목록 설정)을 언급하는 셸 명령은 엄격 읽기전용"
                      "(cat·grep·rg·wc·ls·git log/diff 등, 2>/dev/null·cd·bash -c 감싸기 허용)일 때만 통과한다. "
                      "읽기는 mcp__oio__file_read·Grep 도구를 쓴다. " + PROMOTE_GUIDE +
                      (" " + QUOTE_HINT if _amb_only_readonly(cmd, cmd) else ""))
                return
            _log("PASS self-read who=%s cmd=%.200s" % (who, _mask(cmd)))
    else:
        if any(_self_path(p) for p in paths_n) and _copy_out_ok(tool, ti):
            _log("PASS self-copy-out who=%s tool=%s paths=%s" % (who, tool, paths_n))
        elif any(_self_path(p) for p in paths_n) and not _switch_on():
            _log("DENY self-file who=%s tool=%s paths=%s" % (who, tool, paths_n))
            _block_log("self-file", "", who, tool, inp, cmd, paths_n)
            _deny("🚫 [운영 배포 가드] 가드 파일·비상 스위치는 파일 도구로 수정·삭제·이동할 수 없다. " + PROMOTE_GUIDE)
            return

    if _switch_on():
        _log("BYPASS switch who=%s tool=%s cmd=%.200s" % (who, tool, _mask(cmd)))
        return

    # unblock3 결정 ①(사용자 지시 2026-10-27 13:04 + 화면 결정 "결합 형태도 전부 해제"): git 머리 구간이 있으면 규칙 판정 생략
    if tool in BASH_TOOLS and _git_composite(cmd):
        _log("PASS git-composite who=%s cmd=%.200s" % (who, _mask(cmd)))
        return

    # 2) 설정 규칙 판정
    hit, what = _rule_hit(inp, tool, cmd, cmd_n, paths_n, content, wd)
    if hit:
        appr_note = ""
        if tool in BASH_TOOLS:   # 화면 승인(2026-10-24) — 셸 규칙 차단만. 자기 보호·스위치·파일 도구는 위에서 이미 끝났다
            if isinstance(ti, dict) and (ti.get("run_in_background") is True or "timeout" in ti):
                # 뒤 hook 이 막을 호출 형태 — 승인을 판정·소비하지 않고 차단 안내만 한다
                a_ok, a_code, a_tid = False, "bad_call_shape_no_consume", ""
            else:
                a_ok, a_code, a_tid = _approval(inp, ti, tool, cmd, hit)
            if a_ok:
                _log("PASS askq-approval tool_use_id=%s rule=%s who=%s cmd=%.200s" % (a_tid, hit["id"], who, _mask(cmd)))
                return
            appr_note = "\n   → " + APPROVAL_GUIDE + " (화면 승인 판정: %s)" % a_code
            if a_code == "bad_call_shape_no_consume":
                appr_note += ("\n   → run_in_background 는 쓸 수 없다. foreground 로 호출한다."
                              "\n   → timeout 은 ms 로 해석된다. timeout_ms=<밀리초> 를 쓴다."
                              "\n   → 장시간 배포는 ./deploy.sh --detach 로 분리 실행한다.")
        hint = ("\n   → " + QUOTE_HINT) if tool in BASH_TOOLS and _amb_only_readonly(cmd_n, cmd) else ""
        hint += appr_note
        _log("DENY rule=%s who=%s tool=%s conf=%s what=%.200s" % (hit["id"], who, tool, hit["src"], _mask(what)))
        _block_log("rule", hit["id"], who, tool, inp, cmd, paths_n)
        _deny("🚫 [운영 배포 가드] %s (규칙 %s, 설정 %s)\n"
              "   대상: %.200s\n"
              "   → 에이전트(메인·팀)는 운영 배포·승격·운영 데몬 조작을 실행할 수 없다. %s\n"
              "   → 환경변수로는 해제되지 않는다.%s"
              % (hit["reason"], hit["id"], hit["src"], what, HOLD_GUIDE, hint))
        return


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # 판정 오류는 기록만 — 아래 래퍼가 fail-closed 여부를 결정하지 않는다
        _log("ERROR %r" % (e,))
