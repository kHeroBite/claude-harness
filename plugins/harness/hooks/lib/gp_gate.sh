#!/bin/bash
# 승격 경로 구성요소 보호 판정 모듈 — write_guard 가 source 해 gp_gate_check 로 F-GUARD-PROMOTE 를 판정한다(파일 쓰기 없음)
#
# ── 계약 (conv_179169722400 §2-3 · 검토 C1·C2·C4) ──────────────────────────────────────────────
#   입력  전역 TOOL_NAME · INPUT(원본 stdin JSON) · _GP_TI(jq -c '.tool_input // {}', 비면 모듈이 계산)
#   출력  gp_gate_check → 0 통과 / 2 차단(stdout 에 block JSON 1줄, 표식 [F-GUARD-PROMOTE])
#   금지  exit · set -e · 파일 쓰기(기록은 write_guard 의 log_hook_error 만) · write_guard 함수 의존
#   정의  gp_gate_check 와 _gpg_* 함수, _GPG_* 변수뿐이다. hooks 위치는 ${HARNESS_HOME:-$HOME/.harness}/current/hooks 기준이다.
#   이 모듈은 source 된다 — 승격기 카나리 변이체는 exit 가 아니라 return 으로 끝내야 한다.
#
# ── 보호 대상 (문자열 경로 + realpath, 대소문자 무시) ─────────────────────────────────────────────
#   hooks/lib/guard_promote.sh · hooks/lib/guard_promote.json(등록부) · hooks/lib/gp_gate.sh(이 모듈)
#   hooks/lib/guard_promote_boot.sh(부트, 부트 후 불변)
#   hooks/tests/test_pdg_readonly.sh · test_pdg_hook.sh · test_gp_self.sh · test_gp_gate.sh(고정 시험)
#   hooks/backup/guard_promote/** (보관소) · hooks/logs/guard_promote* (잠금·저널·지문·regsha·감사)
#
# ── 판정 ─────────────────────────────────────────────────────────────────────────────────────
#   파일 도구  대상·원본(이동·이름변경·삭제)·목적지(복사는 목적지만, 목적지가 디렉터리면 목적지/원본이름)가
#             보호 대상이면 차단. 심볼릭 링크는 링크 경로와 함께 .target(원본)도 본다 — 보호 대상으로 가는
#             별칭 생성 차단(C1). realpath 로 기존 별칭 경유 쓰기도 잡는다. dir_* 는 보호 대상의 상위까지 본다.
#   셸        ① 보호 토큰 + 쓰기 수단(토큰 목적지 리다이렉트·쓰기 명령·sed/perl -i·인터프리터·flock(C2)·
#               find -delete·git 쓰기 하위 명령(조건 4)). 따옴표·역슬래시·중괄호를 지운 뒤 토큰을 본다.
#             ② 토큰 없는 별칭(C1): 쓰기 수단이 있는 명령의 글로브·중괄호 단어를 실제로 전개하고, 심볼릭 링크
#               단어는 realpath 로 풀어 보호 대상이면 차단.
#               구간별 판정(conv_179172975200 항목2) — 명령을 따옴표 인식으로 구간·파이프 사슬·리다이렉트로 나눌 수 있고
#               ($·백틱·역슬래시·( ) { }·단어 첫 #·<<·<( >(·eval·source·exec·.·tee 가 없을 때) 읽기 전용 사슬(_gpg_read_seg 의
#               명령만으로 이뤄진 파이프 사슬)이면 피연산자 글로브를 펼치지 않고 쓰기 리다이렉트 대상만 본다. 명령에 소비자
#               (xargs·while·read·인터프리터·sed·find 등)가 있으면 리다이렉트가 있는 읽기 사슬도 종전처럼 전 단어를 펼친다.
#               그 밖 구간은 종전대로 전 단어 전개. 해석이 불확실하면 명령 전체를 종전 방식(전 단어 전개)으로 판정한다.
#               sort -o·--output 과 uniq 의 두 번째 인자(출력 파일)는 쓰기 수단이다(검토 R2).
#             ③ 재귀 파괴·트리 덮어쓰기: rm -r·rmdir·find -delete·mv 원본·cp -r/-a·rsync 목적지·tar x·unzip·
#               cpio 가 보호 대상이나 그 상위를 가리키면 차단. ln 의 인자가 보호 대상이면 차단(별칭 생성).
#               git 쓰기 하위 명령의 경로 인자가 hooks·hooks/{lib,tests,backup,logs} 이면 차단.
#   통과      조회(cat·grep·sha256sum·git log/show/diff/status/add/commit)와 승격기 실행
#             (bash …guard_promote.sh status|verify|promote|restore, 보관소 고정본 restore)은 통과한다.
#   자기 시험명 test_guard_promote*.sh · test_gp_boot*.sh 는 토큰 판정 전에 지운다(보호 대상 아님).
#   heredoc   인용 종결자('W'·"W"·\W)의 허용 3형태(git commit -F - · git commit -m "$(cat <<'W' …)" · cat 리다이렉트)만
#             본문 줄을 비우고 판정한다(_gpg_hd_mask). 비인용·인터프리터·파이프·보호 대상 리다이렉트는 현행 판정 그대로다.
#   커밋 메시지  git [-C 디렉터리|-c 설정]… commit 의 -m·-am·--message[=] 인용 인자 내용만 비운다(_gpg_msg_mask, D-2).
#             큰따옴표 안 $·백틱·\ 는 가리지 않는다. 다른 구간(&& cp … 등)은 그대로 판정한다.
#   tee       tee 가 유일한 쓰기 수단이고 _gpg_tee_safe 조건(검토 R1 — tee 출현 수 == tee 구간 수, 인터프리터·xargs·
#             -exec·-c·$·백틱 부재, 대상 비보호)을 채울 때만 규칙①에서 빼고, 대상은 _gpg_segment tee 분기가 판정한다(D-3).
#   c213      grep 과차단(conv_179301085868 §9) — 보호 파일을 읽기만 하는 grep/rg/git grep 이 패턴·따옴표 인자 속 쓰기 어휘로 막히던 것.
#             완화는 G3 읽기 전용 빠른 길에만 건다: ① $HOME·${HOME} 값 치환 사본 ② 전용 분해 모드(_gpg_units … 1 — 따옴표 안 << ·
#             eval/source/exec 글자로 분해를 포기하지 않음) ③ _GPG_RO=1 일 때 큰따옴표 안 grep 교대 \| 만 구분자에서 뺌(맨 ; | & 는 그대로
#             — GG-U10 유지) ④ 무해 리터럴 대입 단위(_gpg_unit_litassign, 실행 경로·조회 동작을 바꾸는 이름 제외) ⑤ _gpg_read_seg 에
#             git [-C 디렉터리|--no-pager]… grep(-O·--op…·--textc…·--ext-… 는 조회 아님).
#             차단 추가(①, 보호 이름 또는 hooks 보호 경로가 있을 때): 셸 표준입력 실행 파이프(| sh · | bash -s · | bash -c · | dash - ·
#             | source /dev/stdin 등)와 git grep 페이저 실행(-O<명령>·--open-files-in-pager·축약 --op…). 둘 다 종전 미탐이었다.
#             재실측 93건 기준 현행 불일치 19(과차단 11 + 미탐 8) → 후보 1(X21, 아래 잔존 한계).
#   c214 R3   해석기 과차단 — python 단독 호출(-c '<코드>' · 인용 종결자 heredoc)은 _gpg_py_safe 가 분류기 lib/gp_pyclass.py(등록부
#             gp_pyclass)에 맡겨, 쓰기 지점이 전부 절대 경로 리터럴이고 보호 표식·hooks 보호 디렉터리가 아니면 통과한다(D-7 비보호 JSON
#             쓰기 heredoc · 보호 등록부 json.load 읽기 · 임시 폴더 쓰기 + hooks 경로 읽기). 그 밖(형태 불일치·UNSAFE·분류기 부재·env
#             파라미터)은 종전 판정 그대로다. lib/gp_pyclass.py 경로는 보호 대상에 더한다. perl·node 등 다른 해석기는 종전 판정.
#   unblock3  git 허용(사용자 지시 2026-10-27 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라" + 화면 결정 ② "자동 원복까지 해제 —
#             git 으로 보호 파일을 직접 바꿀 수 있게"). git 머리 구간(_gpg_git_safe — 구간 첫 명령이 VAR=값·env·timeout N·nice·nohup·
#             command·exec·sudo·xargs·stdbuf·time·setsid 를 벗긴 뒤 git/git.exe 이고 $( · 백틱 · <( · >( 가 없음)은 하위 명령·옵션과
#             무관하게 쓰기 수단·실행 수단으로 세지 않는다 — 위 ①의 git 쓰기 하위 명령·③의 git 경로 인자·GG-G07 명령 전체 git 쓰기·
#             c213 git grep 페이저(-O) 차단과 c217 인덱스 전용 판정은 이 규칙으로 대체됐다. _gpg_read_seg 는 git 머리 구간을 조회와 같게 본다.
#             유지: 같은 명령의 비 git 쓰기(리다이렉트 대상·tee·cp·mv·sed -i·해석기·파일 도구), git 구간의 쓰기 리다이렉트 대상
#             (git show … > 보호 파일), 명령 치환이 든 git 구간, git 이 머리가 아닌 구간(echo git … · eval … 등 — bash -c '…' 안쪽은
#             따옴표를 지운 사본으로 보므로 git 머리로 셀 수 있다. 그 안의 비 git 쓰기는 종전대로 잡힌다).
#
#   overblock P1d  TODO-018·020 과차단 완화(사용자 방침 '과소차단보다 과대차단이 위험하다' — 새 능력이 생기지 않는 것만).
#             R-I  규칙① 단위가 cp 한 번(옵션 -p -f -v -n -a -r -R -L -H -P -u 와 --preserve·--no-clobber 등만)이고 목적지와
#                  목적지/원본이름이 모두 hooks 밖 절대 리터럴(_gpg_rx_tgt_ok)이면 그 단위는 보호 파일을 '읽는' 백업이다(_gpg_unit_cpout).
#                  -t·-T·-s·-l·-b·--target-directory·--link·--symbolic 등 목적지·별칭을 바꾸는 옵션은 종전 판정이다.
#                  (sed -i 비보호 파일 쓰기는 write_guard F-SEDI-1 이 셸에서 전면 차단하므로 이 모듈에서 풀어도 효과가 없어 두지 않았다)
#             R-K  c201 H(HOME 재대입 + $HOME 경로 + 쓰기 수단)는 tee·git 쓰기·$(·백틱·<(·>(·<< 가 없고 재해석 분해(_gpg_rx_scan, 깊이 3)에서
#                  모든 쓰기 대상·출력 리다이렉트 대상이 $ 없는 hooks 밖 절대 리터럴일 때 차단하지 않는다(_gpg_home_wr_ok).
#                  이때만 python 의 변수 경로 스크립트 실행(…/codex-harness/hooks/x.py)을 쓰기로 세지 않는다 — 보호 이름·hooks 보호
#                  디렉터리·.claude/hooks·.. 가 글자로 있으면 종전대로 센다(_gpg_rxh_pyvar). HOME 값이 쓰기 대상을 바꿀 수 없는 꼴만 푼다.
#             R-H  인용 heredoc 으로 hooks 밖 절대 리터럴 .py 파일을 쓰고 같은 명령에서 그 파일을 python 리터럴 스크립트로만 실행하면
#                  본문을 가린다(_gpg_hd_mask). file_write 로 쓴 뒤 따로 python3 로 실행하는 2단계(종전 통과)와 능력이 같다.
#                  변수 경로·bash·source·. 실행, -c·-m, 다른 명령의 피연산자로 다시 부르는 꼴은 종전 판정(R-D 유지).
#             R-F  명령 치환($(…)·백틱)이 있다는 것만으로 분해를 포기하지 않는다(사용자 결정 Q-1). 리터럴 치환(_gpg_lit_subst)은 짝 맞는
#                  $(…)·백틱을 건너뛰어 계속 진행하고(서브셸은 바깥 변수를 바꾸지 못한다), 재해석 분해(_gpg_rx_scan)는 치환 안 명령을
#                  같은 규칙으로 깊이+1 재귀 판정한 뒤 그 자리를 결과 미확정 표식 $(_) 로 둔다. 표식이 명령 자리·sh -c 스크립트·eval 인자에
#                  오면(동적 명령) 차단 쪽이고, 쓰기 대상에 오면 변수와 같게 미확정이다. 산술 $((…))·짝 없음·치환 안 백틱·역슬래시 든 백틱·
#                  case·<< 는 판정 불가로 종전대로 포기한다. 같은 분해에서 python -c 코드는 분류기(gp_pyclass)가 SAFE 일 때만 쓰기로 세지 않는다.
# ── 잔존 한계 (정직 고지) ─────────────────────────────────────────────────────────────────────
#   셸은 문자열 판정이다. 변수 간접화($X)·명령 치환 결과 경로·2단계 스크립트·하드 링크는 여기서 못 잡는다 → write_guard S1 지문
#   탐지가 사후에 기록한다(unblock3 이후 차단은 하지 않는다 — 점검은 guard_promote.sh verify). git 은 unblock3 로 허용 대상이다.
#   인용 heredoc 본문(M3)으로 비보호 파일에 스크립트를 써 두고 다른 명령에서 실행하는 2단계도 같은 등급이다 — file_write 로
#   같은 파일을 쓰는 것과 동등하다. 같은 명령 안에서 대상 이름을 다시 부르면 가리지 않는다. 커밋 메시지 가리기는 단순 인용
#   인자만 다룬다 — $( ${ $' 백틱·역슬래시·주석·리다이렉트가 섞이면 원문 판정이라 오탐이 남는다(그때는 git commit -F <파일>).
#   tee 완화는 $HOME 등 변수가 든 명령에는 적용하지 않는다(대상 경로가 문자열로 확정되지 않으므로 종전대로 차단 쪽).
#   읽기 전용 구간 완화는 같은 명령 안의 소비자만 본다 — 목록을 비보호 파일에 써 두고 ★다른 호출★에서 그 목록으로 쓰는
#   2단계는 위 2단계 스크립트와 같은 등급이다(S1 지문 탐지가 사후에 잡는다).
#   c206 G4 리터럴 치환(_gpg_lit_subst)은 리터럴 값을 정확히 한 번 머리 대입받은 변수만 풀어 준다 — 비리터럴 값($HOME·$(…) 포함)·
#   재대입·&& 가 있는 명령의 변수는 종전대로 명령 전체 판정이다. 큰따옴표 안 \" 는 원 명령에 && 가 없을 때만 bash 규칙으로 분해한다.
#   c213 셸 표준입력 실행 차단은 셸에 스크립트 파일 피연산자가 있는 꼴(… | bash x.sh — 그 파일 내용이 무엇인지 정적으로 모른다)과
#   앞붙이 명령이 목록 밖이거나 옵션 값을 따로 받는 꼴(nice -n 5 bash 등)은 잡지 못한다. git -c core.pager=…·저장소 설정으로 grep 이
#   명령을 실행하게 만드는 꼴은 기존 git 설정 한계와 같은 등급이다(grep 은 tty 가 아니면 페이저를 쓰지 않는다). find <hooks>/tests
#   -name '<인용 글로브>' -exec sed -i … (X21)는 grep 축이 아닌 기존 미탐으로 남는다(find -exec 판정 확장은 별도 설계 — 다음 사이클 후보).

_GPG_TOK='guard_promote|test_pdg_readonly|test_pdg_hook|gp_gate|test_gp_self|test_gp_gate'
_GPG_GITW='checkout|restore|reset|stash|apply|am|cherry-pick|revert|merge|pull|rebase|switch|mv|rm|clean|read-tree|checkout-index|update-index|worktree'
_GPG_B='(^|[^a-z0-9_.-])'     # 명령 이름 앞 경계(/bin/rm 의 / 는 허용)
_GPG_E='([^a-z0-9_./-]|$)'    # 명령 이름 뒤 경계

# 보호 대상 판정 — $1=경로 $2=0(대상 자체) | 1(대상 + 상위 디렉터리 전부) | 2(대상 + hooks 수준 디렉터리)
_gpg_prot() {
  local _x _l _h _hl _r
  [[ -n "$1" ]] || return 1
  _r=$(realpath -m -- "$1" 2>/dev/null)
  for _x in "$1" "$_r"; do
    [[ -n "$_x" ]] || continue
    _l="${_x,,}"
    while [[ "$_l" == *//* ]]; do _l="${_l//\/\//\/}"; done
    while [[ "$_l" == */./* ]]; do _l="${_l//\/.\//\/}"; done
    _l="${_l%/.}"; _l="${_l%/}"
    case "$_l" in
      */hooks/lib/guard_promote.sh|*/hooks/lib/guard_promote.json|*/hooks/lib/gp_gate.sh|*/hooks/lib/guard_promote_boot.sh|\
      */hooks/tests/test_pdg_readonly.sh|*/hooks/tests/test_pdg_hook.sh|*/hooks/tests/test_gp_self.sh|*/hooks/tests/test_gp_gate.sh|\
      */hooks/backup/guard_promote|*/hooks/backup/guard_promote/*|*/hooks/logs/guard_promote*) return 0 ;;
      */hooks/lib/gp_pyclass.py) return 0 ;;   # c214 R3: 해석기 분류기(이 모듈이 판정에 쓴다 — 등록부 gp_pyclass)
    esac
    if [[ "$2" == "1" || "$2" == "2" ]]; then
      case "$_l" in
        */hooks|*/hooks/lib|*/hooks/tests|*/hooks/backup|*/hooks/logs) return 0 ;;
      esac
    fi
    if [[ "$2" == "1" ]]; then
      for _h in "${HARNESS_HOME:-$HOME/.harness}/current/hooks" "$(realpath -m -- "${HARNESS_HOME:-$HOME/.harness}/current/hooks" 2>/dev/null)"; do
        [[ -n "$_h" ]] || continue
        _hl="${_h,,}"
        [[ "$_hl" == "$_l"/* || "$_hl" == "$_l" || -z "$_l" ]] && return 0
      done
    fi
  done
  return 1
}

# 상대 경로를 기준 디렉터리로 절대화 — $1=경로 $2=기준
_gpg_abs() {
  local _p="$1"
  [[ "$_p" == "~" ]] && _p="$HOME"
  [[ "$_p" == "~/"* ]] && _p="$HOME/${_p#\~/}"
  if [[ "$_p" == /* || -z "$2" ]]; then printf '%s' "$_p"; else printf '%s/%s' "${2%/}" "$_p"; fi
}

# ── 파일 도구 ────────────────────────────────────────────────────────────────────────────────
_gpg_file() {  # $1=file|dir → _GPG_HIT
  local _flag=0 _k _v _base="" _src="" _p _c _rows
  local -a _all=() _dst=() _lnk=() _new=()
  [[ "$1" == "dir" ]] && _flag=1
  _rows=$(jq -r 'to_entries[] | select((.value|type)=="string" and .value != "")
      | select(.key|IN("path","file_path","filepath","notebook_path","source","src","destination","dest","dst","target","to","new_name","name","new_path","link_path","link"))
      | "\(.key)\t\(.value|gsub("[\n\t]";" "))"' <<<"$_GPG_TI" 2>/dev/null)
  while IFS=$'\t' read -r _k _v; do
    [[ -n "$_k" && -n "$_v" ]] || continue
    case "$TOOL_NAME" in
      mcp__oio__file_copy)
        case "$_k" in
          source|src|path) [[ -z "$_src" ]] && _src="$_v" ;;           # 원본 읽기는 비대상
          destination|dest|dst|target|to) _dst+=("$_v") ;;
        esac ;;
      mcp__oio__file_symlink)
        case "$_k" in
          target|source|src) [[ -z "$_src" ]] && _src="$_v" ;;         # ★별칭의 원본(C1)
          link_path|link|dest|destination|path|file_path) _lnk+=("$_v") ;;
        esac ;;
      mcp__oio__file_rename)
        case "$_k" in
          path|file_path|filepath|source|src) [[ -z "$_src" ]] && _src="$_v"; _all+=("$_v") ;;
          new_name|name|new_path|to|destination|dest|dst|target) _new+=("$_v") ;;
        esac ;;
      mcp__oio__file_move|mcp__oio__dir_move)
        case "$_k" in
          source|src|path|file_path|filepath) [[ -z "$_src" ]] && _src="$_v"; _all+=("$_v") ;;
          *) _dst+=("$_v") ;;
        esac ;;
      mcp__oio__dir_rename)
        case "$_k" in
          path|file_path|filepath|source|src) [[ -z "$_src" ]] && _src="$_v"; _all+=("$_v") ;;
          *) _new+=("$_v") ;;
        esac ;;
      *) _all+=("$_v") ;;
    esac
  done <<<"$_rows"
  [[ -n "$_src" ]] && _src=$(_gpg_abs "$_src" "$PWD")
  _base="$_src"
  for _p in "${_all[@]}"; do
    _p=$(_gpg_abs "$_p" "${_base:+$(dirname -- "$_base")}")
    _gpg_prot "$_p" "$_flag" && { _GPG_HIT="$_p"; return 0; }
  done
  for _p in "${_dst[@]}"; do
    _p=$(_gpg_abs "$_p" "${_base:+$(dirname -- "$_base")}")
    _gpg_prot "$_p" "$_flag" && { _GPG_HIT="$_p"; return 0; }
    if [[ -n "$_src" && ( "$_p" == */ || -d "$_p" ) ]]; then
      _c="${_p%/}/$(basename -- "$_src")"
      _gpg_prot "$_c" "$_flag" && { _GPG_HIT="$_c"; return 0; }
    fi
  done
  for _p in "${_new[@]}"; do
    [[ "$_p" == /* || "$_p" == "~"* ]] || _p="$(dirname -- "${_src:-./x}")/$_p"
    _p=$(_gpg_abs "$_p" "")
    _gpg_prot "$_p" "$_flag" && { _GPG_HIT="$_p"; return 0; }
  done
  for _p in "${_lnk[@]}"; do
    _p=$(_gpg_abs "$_p" "$PWD")
    _gpg_prot "$_p" 0 && { _GPG_HIT="$_p"; return 0; }
    if [[ -n "$_src" ]]; then
      # 상대 원본은 링크가 놓일 디렉터리 기준으로 풀린다.
      if [[ "$_src" == /* ]]; then _c="$_src"; else _c="$(dirname -- "$_p")/$_src"; fi
      _gpg_prot "$_c" 0 && { _GPG_HIT="심볼릭 링크 별칭 원본 ${_c}"; return 0; }
    fi
  done
  if [[ ${#_lnk[@]} -eq 0 && -n "$_src" && "$TOOL_NAME" == "mcp__oio__file_symlink" ]]; then
    _gpg_prot "$_src" 0 && { _GPG_HIT="심볼릭 링크 별칭 원본 ${_src}"; return 0; }
  fi
  return 0
}

# ── 셸 ───────────────────────────────────────────────────────────────────────────────────────
# 문자열을 단어 배열로 — 구분자(;|&()<>`$ 와 개행)는 공백, $HOME·${HOME}·~ 는 실제 값으로 바꾼다.
_gpg_words() {  # $1=문자열 → _GPG_W
  local _s="$1"
  _s="${_s//\$\{HOME\}/$HOME}"; _s="${_s//\$HOME/$HOME}"
  _s="${_s//[;|&()<>\`\$]/ }"
  _s="${_s//$'\n'/ }"; _s="${_s//$'\t'/ }"
  read -r -a _GPG_W <<<"$_s"
}

# c205 D-14: 따옴표 안(홑·큰)·역슬래시로 감춘 글로브 문자 * ? [ 를 표식 \x03 \x04 \x05 로 바꾼다 — 셸은 이것을 전개하지 않는다.
#   _gpg_expand 가 표식을 글자로 되돌려 전개 없이 판정한다(따옴표 밖 글로브는 종전대로 전개).
#   명령 치환($( · 백틱)·$'…'·따옴표 불균형이 있으면 따옴표 경계를 확정할 수 없으므로 바꾸지 않는다(종전 동작 — 전개 유지).
#   따옴표 밖 단어 첫머리 # 는 줄 끝까지 주석이다 — 주석 내용은 비운다(# 만 남김, 아래 주석 분기 참조).
_gpg_qglob() {  # $1=명령 → stdout
  local _s="$1" _n _i _c _q="" _o="" _w=0
  if [[ "$_s" == *'$('* || "$_s" == *'`'* || "$_s" == *"\$'"* ]]; then printf '%s' "$_s"; return 0; fi
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ -n "$_q" ]]; then
      if [[ "$_q" == '"' && "$_c" == \\ ]]; then _o+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue; fi
      if [[ "$_c" == "$_q" ]]; then _q=""; _o+="$_c"; continue; fi
      case "$_c" in \*) _o+=$'\x03' ;; \?) _o+=$'\x04' ;; \[) _o+=$'\x05' ;; *) _o+="$_c" ;; esac
      continue
    fi
    case "$_c" in
      \'|\") _q="$_c"; _o+="$_c"; _w=1 ;;
      \\) case "${_s:_i+1:1}" in
            \*) _o+=$'\\\x03' ;; \?) _o+=$'\\\x04' ;; \[) _o+=$'\\\x05' ;; *) _o+="$_c${_s:_i+1:1}" ;;
          esac
          _i=$((_i+1)); _w=1 ;;
      \#) if [[ $_w -eq 0 ]]; then
            # 주석 내용은 실행되지 않으므로 비운다 — 주석 안 ' " 가 하류 판정(_gpg_seg_prep 등)의 따옴표 상태를 뒤집어
            #   다음 줄 명령을 따옴표 안으로 오인하는 과소 차단(live 실측: ls # it's<개행>cp x hooks/backup/* 통과)을 막는다.
            _o+="#"
            while [[ $_i -lt $_n && "${_s:_i:1}" != $'\n' ]]; do _i=$((_i+1)); done
            [[ $_i -lt $_n ]] && _o+=$'\n'
            _w=0
          else _o+="$_c"; fi ;;
      ' '|$'\t'|$'\n'|\;|\||\&|\(|\)|\<|\>) _o+="$_c"; _w=0 ;;
      *) _o+="$_c"; _w=1 ;;
    esac
  done
  if [[ -n "$_q" ]]; then printf '%s' "$_s"; return 0; fi
  printf '%s' "$_o"
}

# 단어 하나를 실제 경로 목록으로 — 중괄호(안전 문자일 때만)·글로브 전개, 상대 경로는 기준 디렉터리마다 푼다.
_gpg_expand() {  # $1=단어 → _GPG_X (경로 목록)
  local -; set -f
  local _w="$1" _c _e
  local -a _br=()
  _GPG_X=()
  [[ "$_w" =~ ^-*[A-Za-z_][A-Za-z0-9_-]*= ]] && _w="${_w#*=}"     # of=…, --target-directory=…
  [[ -n "$_w" && "$_w" != -* ]] || return 0
  [[ "$_w" == "~" || "$_w" == "~/"* ]] && _w=$(_gpg_abs "$_w" "")
  if [[ "$_w" == *"{"*"}"* && "$_w" =~ ^[A-Za-z0-9_./{},*?~+@%:=-]+$ ]]; then
    eval "_br=( $_w )" 2>/dev/null || _br=("$_w")
  else
    _br=("$_w")
  fi
  set +f
  for _w in "${_br[@]}"; do
    if [[ "$_w" == /* ]]; then _c=("/"); else _c=("${_GPG_CWD[@]}"); fi
    for _e in "${_c[@]}"; do
      local _p
      if [[ "$_w" == /* ]]; then _p="$_w"; else _p="${_e%/}/$_w"; fi
      if [[ "$_p" == *[\*\?\[]* ]]; then
        local _g _pg
        # c205 D-14: 따옴표 안 글로브 표식은 패턴 안에서도 글자로(역슬래시 이스케이프) 맞춘다
        _pg="${_p//$'\x03'/\\*}"; _pg="${_pg//$'\x04'/\\?}"; _pg="${_pg//$'\x05'/\\[}"
        while IFS= read -r _g; do [[ -n "$_g" ]] && _GPG_X+=("$_g"); done < <(compgen -G "$_pg" 2>/dev/null | head -512)
      else
        # c205 D-14: 따옴표 안 글로브 표식만 있으면 전개하지 않고 글자 그대로의 경로로 판정한다(보호 경로 글자 이름은 계속 걸린다)
        _p="${_p//$'\x03'/*}"; _p="${_p//$'\x04'/?}"; _p="${_p//$'\x05'/[}"
        _GPG_X+=("$_p")
      fi
    done
  done
  return 0
}

# 기준 디렉터리 후보 — 도구 입력의 cwd 류 + 명령 안의 cd·pushd·git -C 대상. 없으면 현재 디렉터리.
_gpg_cwds() {  # $1=정규화 명령(대소문자 보존) → _GPG_CWD
  local _c _s _t
  _GPG_CWD=()
  while IFS= read -r _c; do [[ -n "$_c" ]] && _GPG_CWD+=("$_c"); done < <(
    jq -r '[.tool_input.cwd,.tool_input.working_dir,.tool_input.workdir,.cwd] | map(select(type=="string" and . != ""))[]' <<<"$INPUT" 2>/dev/null)
  [[ ${#_GPG_CWD[@]} -gt 0 ]] || _GPG_CWD=("$PWD")
  _s="$1"
  while [[ "$_s" =~ (^|[^A-Za-z0-9_.-])(cd|pushd)[[:space:]]+([^[:space:]\;\&\|\)]+) || "$_s" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]\;\&\|\)]+) ]]; do
    _t="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
    _s="${_s/"${BASH_REMATCH[0]}"/ }"
    [[ "$_t" == "~"* ]] && _t=$(_gpg_abs "$_t" "")
    [[ "$_t" == /* ]] || _t="${_GPG_CWD[0]%/}/$_t"
    _GPG_CWD+=("$_t")
    [[ ${#_GPG_CWD[@]} -lt 8 ]] || break
  done
  return 0
}

# 경로 목록 판정 — $1=플래그, 나머지=단어. 전개 결과가 보호 대상이면 _GPG_HIT.
#   플래그 0 은 글로브 전개 결과·심볼릭 링크만 풀어 본다(이름이 드러난 경로는 토큰 규칙 몫).
_gpg_check_words() {
  local _f="$1" _w _x _d _rd _seen=""; shift
  for _w in "$@"; do
    _gpg_expand "$_w"
    for _x in "${_GPG_X[@]}"; do
      if [[ "$_f" != "0" ]]; then
        _gpg_prot "$_x" "$_f" && { _GPG_HIT="$_x"; return 0; }
        continue
      fi
      if [[ "$_w" == *[\*\?\[\{]* ]]; then
        _gpg_prot_s "$_x" && { _GPG_HIT="$_x (전개: $_w)"; return 0; }
        _d="${_x%/*}"
        if [[ "$_seen" != *"|$_d|"* ]]; then
          _seen+="|$_d|"
          _rd=$(realpath -m -- "$_d" 2>/dev/null)
          [[ -n "$_rd" && "$_rd" != "$_d" ]] && _gpg_prot_s "$_rd/${_x##*/}" && { _GPG_HIT="$_x (전개: $_w)"; return 0; }
        fi
      fi
      if [[ -L "$_x" ]]; then
        _gpg_prot "$_x" 0 && { _GPG_HIT="$_x (별칭 → $(realpath -m -- "$_x" 2>/dev/null))"; return 0; }
      fi
    done
  done
  return 1
}
_gpg_prot_s() {  # 문자열만(realpath 없이) — 글로브 전개 결과 대량 판정용
  local _l="${1,,}"
  case "$_l" in
    */hooks/lib/guard_promote.sh|*/hooks/lib/guard_promote.json|*/hooks/lib/gp_gate.sh|*/hooks/lib/guard_promote_boot.sh|\
    */hooks/tests/test_pdg_readonly.sh|*/hooks/tests/test_pdg_hook.sh|*/hooks/tests/test_gp_self.sh|*/hooks/tests/test_gp_gate.sh|\
    */hooks/backup/guard_promote|*/hooks/backup/guard_promote/*|*/hooks/logs/guard_promote*) return 0 ;;
  esac
  return 1
}

# 따옴표를 존중해 구간 경계만 \x01 로 바꾼다 — 인용 안의 구분자(; | & 등)는 단어 내용으로 보존한다(따옴표 안 구분자 오차단 수정).
#   $HOME·${HOME} 는 먼저 실제 값으로 치환하고, 그 외 $·백틱·미인용 구분자·( )·개행을 \x01 로 만든다(기존 동작 + 따옴표 인식).
#   인용 안 구분자가 삼켜지지 않으므로, 그런 명령은 한 구간(첫 단어가 명령)으로 남아 뒤 단어가 명령으로 오인되지 않는다.
_gpg_seg_prep() {  # $1=원본 명령 → stdout: \x01 로 구분된 구간들(따옴표 제거)
  local _s="$1" _c _q="" _out="" _i _n _esc=0
  _s="${_s//\$\{HOME\}/$HOME}"; _s="${_s//\$HOME/$HOME}"
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ $_esc -eq 1 ]]; then _out+="$_c"; _esc=0; continue; fi
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q="" || _out+="$_c"; continue; fi
    if [[ "$_q" == '"' ]]; then
      case "$_c" in \") _q="" ;; \\) _esc=1 ;; *) _out+="$_c" ;; esac; continue
    fi
    case "$_c" in
      \') _q="'" ;;
      \") _q='"' ;;
      \\) _esc=1 ;;
      \;|\||\&|\(|\)|\`|\$|$'\n') _out+=$'\x01' ;;
      *) _out+="$_c" ;;
    esac
  done
  printf '%s' "$_out"
}

# 옵션 값 추출 — _a·_i(호출부 _gpg_segment 의 지역, bash 동적 스코프로 보인다)에서 옵션 값을 낸다.
_gpg_optval() {  # $@=옵션명(-C --directory …) → stdout: 값(-Oval·-O val·--long=val·--long val)
  local _n _j _o _val=""
  for (( _j=_i+1; _j<${#_a[@]}; _j++ )); do
    _o="${_a[$_j]}"
    for _n in "$@"; do
      if [[ "$_n" == --* ]]; then
        [[ "$_o" == "$_n="* ]] && { _val="${_o#*=}"; break 2; }
        [[ "$_o" == "$_n" ]] && { _val="${_a[$((_j+1))]:-}"; break 2; }
      else
        [[ "$_o" == "$_n" ]] && { _val="${_a[$((_j+1))]:-}"; break 2; }
        [[ "$_o" == "$_n"[!-]* ]] && { _val="${_o#"$_n"}"; break 2; }
      fi
    done
  done
  printf '%s' "$_val"
}

# 구간(;·&&·||·|·& 로 나뉜 명령 하나) 판정 — 재귀 파괴·트리 덮어쓰기·별칭 생성·git 경로
_gpg_segment() {  # $1=구간 문자열(대소문자 보존)
  local _v _i _o _rec=0 _dest="" _t=0 _x
  local -a _a=() _args=() _opts=()
  _gpg_words "$1"; _a=("${_GPG_W[@]}")
  _i=0
  while [[ $_i -lt ${#_a[@]} ]]; do                       # 앞쪽 래퍼·환경 대입 건너뛰기
    case "${_a[$_i]}" in
      sudo|command|nohup|exec|env|nice|setsid|time|xargs|builtin|stdbuf|ionice|chronic|-*) _i=$((_i+1)) ;;
      timeout) _i=$((_i+2)) ;;
      [A-Za-z_]*=*) _i=$((_i+1)) ;;
      *) break ;;
    esac
  done
  [[ $_i -lt ${#_a[@]} ]] || return 1
  _v="${_a[$_i]##*/}"; _v="${_v,,}"
  for _o in "${_a[@]:$((_i+1))}"; do
    case "$_o" in
      --target-directory=*) _dest="${_o#*=}" ;;
      -t) _t=1 ;;
      -*) _opts+=("$_o") ;;
      *) if [[ $_t -eq 1 ]]; then _dest="$_o"; _t=0; else _args+=("$_o"); fi ;;
    esac
  done
  case "$_v" in
    rm)
      for _o in "${_opts[@]}"; do [[ "$_o" =~ ^-[a-zA-Z]*[rR] || "$_o" == --recursive ]] && _rec=1; done
      [[ $_rec -eq 1 ]] && _gpg_check_words 1 "${_args[@]}" && return 0 ;;
    rmdir) _gpg_check_words 1 "${_args[@]}" && return 0 ;;
    tee)   # D-3 — tee 완화 시에도 대상(별칭·전개·realpath 포함)이 보호 대상이면 차단
      _gpg_check_words 0 "${_args[@]}" ${_dest:+"$_dest"} && return 0
      for _o in "${_args[@]}" ${_dest:+"$_dest"}; do
        _gpg_expand "$_o"
        for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && { _GPG_HIT="tee 대상 $_x"; return 0; }; done
      done ;;
    find)
      [[ " ${_opts[*]} " == *" -delete "* ]] && _gpg_check_words 1 "${_args[0]:-.}" && return 0 ;;
    sort|uniq)   # 검토 R2 — sort -o/--output 대상 · uniq 두 번째 인자(출력)가 보호 대상(별칭·전개·realpath 포함)이면 차단
      if [[ "$_v" == sort ]]; then _dest=$(_gpg_optval -o --output)
      else _dest=""; [[ ${#_args[@]} -ge 2 ]] && _dest="${_args[-1]}"; fi
      if [[ -n "$_dest" ]]; then
        _gpg_expand "$_dest"
        for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && { _GPG_HIT="$_v 출력 $_x"; return 0; }; done
      fi ;;
    mv|cp|rsync|install)
      if [[ -z "$_dest" && ${#_args[@]} -ge 2 ]]; then _dest="${_args[-1]}"; unset '_args[-1]'; fi
      # mv 원본은 보호 대상·그 상위를 옮겨 없애므로 상위까지 본다. 목적지는 아래 공통(덮어쓰기) 판정.
      [[ "$_v" == mv ]] && _gpg_check_words 1 "${_args[@]}" && return 0
      [[ "$_v" == rsync ]] && _rec=1
      [[ "$_v" != mv ]] && for _o in "${_opts[@]}"; do [[ "$_o" =~ ^-[a-zA-Z]*[rRa] || "$_o" == --recursive || "$_o" == --archive ]] && _rec=1; done
      if [[ -n "$_dest" ]]; then
        if [[ $_rec -eq 1 ]]; then _gpg_check_words 1 "$_dest" && return 0; fi
        _gpg_expand "$_dest"
        for _x in "${_GPG_X[@]}"; do
          _gpg_prot "$_x" 0 && { _GPG_HIT="$_x"; return 0; }
          if [[ -d "$_x" || "$_dest" == */ ]]; then
            for _o in "${_args[@]}"; do
              _gpg_prot "${_x%/}/${_o##*/}" 0 && { _GPG_HIT="${_x%/}/${_o##*/}"; return 0; }
            done
          fi
        done
      fi ;;
    ln)
      _gpg_check_words 0 "${_args[@]}" && return 0
      for _o in "${_args[@]}"; do
        _gpg_expand "$_o"
        for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && { _GPG_HIT="링크 원본·대상 $_x"; return 0; }; done
      done ;;
    tar)
      if [[ " ${_opts[*]} " =~ \ -[a-zA-Z]*x || " ${_opts[*]} " == *" --extract "* || "${_args[0]}" =~ ^[a-zA-Z]*x[a-zA-Z]*$ ]]; then
        # 해제 위치만 본다(c172_ext 오차단 수정): -C DIR / --directory=DIR 우선, 없으면 cwd 폴백.
        # 아카이브 인자(_args)는 해제 위치가 아니다. 상위 전부(1)가 아니라 hooks 수준(2)으로 좁힌다 —
        # 상위 디렉터리에서의 해제는 S1 지문 탐지가 사후에 맡는다(잔존 한계와 같은 등급).
        _dest=$(_gpg_optval -C --directory)
        if [[ -n "$_dest" ]]; then _gpg_check_words 2 "$_dest" && return 0
        else _gpg_check_words 2 "${_GPG_CWD[@]}" && return 0; fi
      fi ;;
    unzip)
      _dest=$(_gpg_optval -d)
      if [[ -n "$_dest" ]]; then _gpg_check_words 2 "$_dest" && return 0
      else _gpg_check_words 2 "${_GPG_CWD[@]}" && return 0; fi ;;
    cpio)
      _dest=$(_gpg_optval -D --directory)
      # 묶음 플래그(-idD DIR) — -D 가 다른 플래그와 묶이면 다음 비옵션 인자가 디렉터리다.
      if [[ -z "$_dest" ]]; then
        for _o in "${_opts[@]}"; do [[ "$_o" == -[a-zA-Z]*D ]] && { _dest="${_args[0]:-}"; break; }; done
      fi
      if [[ -n "$_dest" ]]; then _gpg_check_words 2 "$_dest" && return 0
      else _gpg_check_words 2 "${_GPG_CWD[@]}" && return 0; fi ;;
    git)
      # unblock3(사용자 지시 2026-10-27 13:04 + 화면 결정 ②): git 머리 구간의 경로 인자는 판정하지 않는다(git 으로 보호 파일 변경 허용).
      #   종전 판정(쓰기 하위 명령 경로가 hooks 수준이면 차단)은 걷어냈다. 쓰기 리다이렉트 대상은 호출부(①·②)가 그대로 본다.
      : ;;
  esac
  return 1
}

# heredoc 본문 가리기(conv_179171634229 항목6 · 검토 R1) — 본문이 글자 그대로 쓰이는 허용 3형태만 본문 줄을 비운다.
#   M1  [접두] git [-C 디렉터리] commit … -F - <<'W'                     (커밋 메시지를 표준 입력으로)
#   M2  [접두] git [-C 디렉터리] commit … -m "$(cat <<'W'  …  W  다음 줄이 )"
#   M3  [접두] cat <<'W' >[>] 경로   /   [접두] cat >[>] 경로 <<'W'
#   [접두] 는 따옴표·$·백틱·괄호·리다이렉트·# 없는 단순 명령 + 구분자(; && || &) 의 반복이다(cd … && 형태).
#   조건 — 하나라도 어기면 명령 전체를 원문 그대로 판정한다(fail-closed):
#     · 종결자가 '…' 또는 "…" 로 인용됐다. 비인용 본문의 $(…)·백틱은 bash 가 실행한다(R1 실측 X11·X12).
#     · 형태가 그 줄 끝에서 끝난다 — 종결자·경로 뒤에 ; && || & | 나 다른 명령이 없다. 여는 줄에 << 는 하나뿐이다.
#     · 여는 줄에 eval·source·.·exec·인터프리터 단어가 없다. 명령에 CR 이 없다.
#     · 본문 밖 다른 줄에 다른 heredoc(<<)·따옴표·백틱·역슬래시·괄호가 없다 — 앞줄에서 열린 따옴표·명령 치환 안의
#       가짜 여는 줄로 실행 줄을 가리는 우회를 막는다.
#     · 종결자 줄이 있다. 본문에 종결자로 시작하는 다른 줄이 없다(해석 차이 여지 제거).
#     · M3 대상 이름이 본문 밖에 다시 나오지 않고, 그때 본문 밖에 글로브 문자가 없다(써 놓고 실행하는 2단계 차단).
#   여는 줄·종결자 줄·본문 밖 줄은 그대로 판정한다. 대상이 보호 파일이면 여는 줄 판정으로 계속 차단된다.
# bashc ⑤: 한 줄 안에서 홑·겹따옴표 짝이 맞는가 — $1=줄 → rc 0 이면 줄 끝에서 따옴표가 닫혀 있다(역슬래시는 호출부가 먼저 거부)
_gpg_hd_qbal() {
  local _s="$1" _q="" _c _i
  for (( _i=0; _i<${#_s}; _i++ )); do
    _c="${_s:_i:1}"
    if [[ -n "$_q" ]]; then [[ "$_c" == "$_q" ]] && _q=""; continue; fi
    [[ "$_c" == "'" || "$_c" == '"' ]] && _q="$_c"
  done
  [[ -z "$_q" ]]
}
# bashc ⑤: 본문 밖 문자열($1)에서 python -m json.tool <경로 1개>(basename == $2, 뒤가 끝·구분자·리다이렉트)를 지운 사본
#   — 써 둔 JSON 을 검증만 하는 조회다. 출력 파일 인자(두 번째 피연산자)가 있으면 지우지 않는다(종전 재등장 판정).
_gpg_hd_jt() {
  local _s="$1" _o="" _m _a _re='python[0-9.]*[[:space:]]+-m[[:space:]]+json\.tool[[:space:]]+([^[:space:];|&<>]+)'
  while [[ "$_s" =~ $_re ]]; do
    _m="${BASH_REMATCH[0]}"; _a="${BASH_REMATCH[1]}"
    _o+="${_s%%"$_m"*}"; _s="${_s#*"$_m"}"
    if [[ "${_a##*/}" == "$2" && "$_s" =~ ^[[:space:]]*($|[\;\|\&\<\>$'\n']) ]]; then _o+=" "; else _o+="$_m"; fi
  done
  printf '%s' "$_o$_s"
}
_gpg_hd_mask() {  # $1=원본 명령 → stdout: 허용 형태 본문 줄을 비운 명령(조건 불충족이면 원본)
  local _s="$1" _i _j _k _n _l _t _w _dash _tgt _b _o="" _rest _hit _f _q='['\''"]'
  local -a _L=() _T=() _TF=() _RH=() _RHF=()   # [overblock P1d R-H] _TF=M3 대상 원문 · _RH/_RHF=python 실행만 허용한 이름/경로
  local _rh _rk _xt _o3 _xi
  local _A='[^][:space:]'\''"`$()|<>\;&#*?[]+'
  local _P='^[[:space:]]*([^]'\''"`$()|<>\;&#]*(&&|[|][|]|;|&)[[:space:]]*)*'
  # 종결자 인용 3형태 — '…' · "…" · \… (역슬래시 인용은 닫는 쪽이 비어야 짝이다, D-1). 짝 검사는 _DX 로 한다.
  local _D='<<-?[[:space:]]*('"$_q"'|\\)[A-Za-z_][A-Za-z0-9_]*('"$_q"')?'
  local _DX='<<(-?)[[:space:]]*('"$_q"'|\\)([A-Za-z_][A-Za-z0-9_]*)('"$_q"')?'
  local _G='git([[:space:]]+-C[[:space:]]+'"$_A"')*[[:space:]]+commit([[:space:]]+'"$_A"')*'
  local _M1="${_P}${_G}"'[[:space:]]*'"${_D}"'[[:space:]]*$'
  local _M1F='[[:space:]](-F[[:space:]]*-|--file(=|[[:space:]]+)-)([[:space:]]|<)'
  local _M2="${_P}${_G}"'[[:space:]]+-m[[:space:]]*"[$][(]cat[[:space:]]+'"${_D}"'[[:space:]]*$'
  local _M3a="${_P}"'cat[[:space:]]+'"${_D}"'[[:space:]]*>>?[[:space:]]*('"$_A"')[[:space:]]*$'
  local _M3b="${_P}"'cat[[:space:]]+>>?[[:space:]]*('"$_A"')[[:space:]]*'"${_D}"'[[:space:]]*$'
  local _RP='^[[:space:]]*[)]["][[:space:]]*$'
  local _BAD='(^|[^A-Za-z0-9_.-])(eval|source|exec|python[0-9.]*|perl|node|ruby|php|bash|sh|dash|zsh|ksh|awk|sed|xargs|busybox)([^A-Za-z0-9_.-]|$)|(^|[[:space:];&|])[.]([[:space:]]|$)'
  local _HX='(^|[^<])<<([^<]|$)' _QX='['\''"`\()]' _GX='[*?[]' _QX2='[`\()]' _o2
  [[ "$_s" == *"<<"* && "$_s" != *$'\r'* ]] || { printf '%s' "$_s"; return 0; }
  mapfile -t _L <<<"$_s"
  _n=${#_L[@]}; _i=0; _hit=0
  while [[ $_i -lt $_n ]]; do
    _l="${_L[$_i]}"; _f=""; _tgt=""
    if [[ "${_l#*<<}" != *"<<"* && ! "$_l" =~ $_BAD ]]; then
      if [[ "$_l" =~ $_M3a ]]; then _f=3; _tgt="${BASH_REMATCH[5]}"   # _P 2개 + _D 2개 그룹 다음
      elif [[ "$_l" =~ $_M3b ]]; then _f=3; _tgt="${BASH_REMATCH[3]}"
      elif [[ "$_l" =~ $_M2 ]]; then _f=2
      elif [[ "$_l" =~ $_M1 && "$_l" =~ $_M1F ]]; then _f=1
      fi
    fi
    if [[ -n "$_f" ]]; then
      [[ "$_l" =~ $_DX ]] || { printf '%s' "$_s"; return 0; }
      if [[ "${BASH_REMATCH[2]}" == '\' ]]; then
        [[ -z "${BASH_REMATCH[4]}" ]] || { printf '%s' "$_s"; return 0; }
      else
        [[ "${BASH_REMATCH[2]}" == "${BASH_REMATCH[4]}" ]] || { printf '%s' "$_s"; return 0; }
      fi
      _dash="${BASH_REMATCH[1]}"; _w="${BASH_REMATCH[3]}"
      _j=$((_i + 1)); _k=0
      while [[ $_j -lt $_n ]]; do
        _t="${_L[$_j]}"
        if [[ -n "$_dash" ]]; then while [[ "$_t" == $'\t'* ]]; do _t="${_t#$'\t'}"; done; fi
        [[ "$_t" == "$_w" ]] && { _k=1; break; }
        [[ "$_t" == "$_w"* ]] && break
        _j=$((_j + 1))
      done
      [[ $_k -eq 1 ]] || { printf '%s' "$_s"; return 0; }
      if [[ "$_f" == 2 ]]; then
        [[ $((_j + 1)) -lt $_n && "${_L[$((_j + 1))]}" =~ $_RP ]] || { printf '%s' "$_s"; return 0; }
      fi
      if [[ -n "$_tgt" ]]; then
        _b="${_tgt##*/}"; [[ -n "$_b" ]] || { printf '%s' "$_s"; return 0; }
        _T+=("$_b"); _TF+=("$_tgt")
      fi
      for (( _k = _i + 1; _k < _j; _k++ )); do _L[$_k]=""; done
      _hit=1
      _o+="${_l}"$'\n'"${_L[$_j]}"$'\n'
      if [[ "$_f" == 2 ]]; then _o+="${_L[$((_j + 1))]}"$'\n'; _i=$((_j + 2)); else _i=$((_j + 1)); fi
      continue
    fi
    if [[ "$_l" =~ $_HX ]]; then printf '%s' "$_s"; return 0; fi
    # bashc ⑤(odone B4): 본문 밖 줄의 따옴표는 그 줄 안에서 짝이 맞으면 허용한다(date '+%F' 등). 줄을 넘는 따옴표가 없으므로
    #   앞줄에서 열린 따옴표 안의 가짜 여는 줄로 실행 줄을 가리는 우회는 여전히 성립하지 않는다. 백틱·역슬래시·괄호는 종전대로 원문.
    if [[ "$_l" =~ $_QX ]]; then
      [[ "$_l" =~ $_QX2 ]] && { printf '%s' "$_s"; return 0; }
      _gpg_hd_qbal "$_l" || { printf '%s' "$_s"; return 0; }
    fi
    _o+="${_l}"$'\n'
    _i=$((_i + 1))
  done
  [[ $_hit -eq 1 ]] || { printf '%s' "$_s"; return 0; }
  if [[ ${#_T[@]} -gt 0 ]]; then
    [[ "$_o" =~ $_GX ]] && { printf '%s' "$_s"; return 0; }
    for _b in "${_T[@]}"; do
      _o2=$(_gpg_hd_jt "$_o" "$_b")              # bashc ⑤: python -m json.tool <대상> 1개(조회)는 재등장으로 세지 않는다
      _rest="${_o2//"$_b"/}"
      if [[ $(( (${#_o2} - ${#_rest}) / ${#_b} )) -gt 1 ]]; then
        # [overblock P1d R-H] 같은 이름의 M3 대상이 하나뿐이고, 여는 줄의 대상 리다이렉트 한 곳을 뺀 나머지 출현이 모두
        #   python 리터럴 스크립트 실행(_gpg_hd_pyrun_ok)이면 가림을 유지한다. 아니면 종전대로 원문(재등장 = 2단계 차단).
        _rh=0; _xt=""
        for (( _rk=0; _rk<${#_T[@]}; _rk++ )); do [[ "${_T[$_rk]}" == "$_b" ]] && { _rh=$((_rh + 1)); _xt="${_TF[$_rk]}"; }; done
        [[ $_rh -eq 1 && -n "$_xt" ]] || { printf '%s' "$_s"; return 0; }
        _o3="$_o"
        [[ "$_o3" =~ \>\>?[[:space:]]*"$_xt"([[:space:]]|$) ]] || { printf '%s' "$_s"; return 0; }
        _o3="${_o3/"${BASH_REMATCH[0]}"/ }"
        _gpg_hd_pyrun_ok "$_xt" "$_o3" || { printf '%s' "$_s"; return 0; }
        _RH+=("$_b"); _RHF+=("$_xt")
      fi
    done
  fi
  # [overblock P1c R-D] 본문을 가린 뒤, 본문 밖 줄에서 셸·해석기·source·. 가 실행하는 스크립트 단어(첫 비옵션 인자)에
  #   $·백틱이 있거나(실행 시점에 정해지는 경로 — for 변수 등) 써 둔 파일 이름이 들어 있으면 가리지 않는다(쓴 파일을 판정 없이 실행하는 꼴).
  #   -c 문자열·-m 모듈·- 는 다른 규칙이 본문으로 판정하므로 여기서 보지 않는다. 스크립트 뒤 인자의 $ 는 자료라 보지 않는다.
  local _xo="$_o" _xs _xb _xm _xp
  local _xr='(^|[^A-Za-z0-9_./-])(bash|sh|dash|zsh|ksh|ash|source|python[0-9.]*|perl|node|ruby|php)(([[:space:]]+-[^[:space:]]*)*)[[:space:]]+([^[:space:];|&<>-][^[:space:];|&<>]*)'
  local _xd='(^|[;&|(){}!'$'\n'']|[[:space:]])[.][[:space:]]+([^[:space:];|&<>]+)'
  while [[ "$_xo" =~ $_xr ]]; do
    _xm="${BASH_REMATCH[0]}"; _xp="${BASH_REMATCH[3]}"; _xs="${BASH_REMATCH[5]}"; _xi="${BASH_REMATCH[2]}"   # 아래 =~ 가 BASH_REMATCH 를 덮으므로 먼저 담는다
    if [[ ! "$_xp" =~ [[:space:]]-[A-Za-z]*[cm] ]]; then
      [[ "$_xs" == *[\$\`]* ]] && { printf '%s' "$_s"; return 0; }
      for _xb in "${_T[@]}"; do
        [[ "$_xs" == *"$_xb"* ]] || continue
        # [overblock P1d R-H] python 이 R-H 로 허용한 경로(전체 일치)를 그대로 실행하는 것은 재등장 차단에서 뺀다
        [[ "$_xi" =~ ^python[0-9.]*$ && ${#_RHF[@]} -gt 0 && " ${_RHF[*]} " == *" $_xs "* ]] && continue
        printf '%s' "$_s"; return 0
      done
    fi
    _xo="${_xo/"$_xm"/ }"
  done
  while [[ "$_xo" =~ $_xd ]]; do
    _xm="${BASH_REMATCH[0]}"; _xs="${BASH_REMATCH[2]}"
    [[ "$_xs" == *[\$\`]* ]] && { printf '%s' "$_s"; return 0; }
    for _xb in "${_T[@]}"; do [[ "$_xs" == *"$_xb"* ]] && { printf '%s' "$_s"; return 0; }; done
    _xo="${_xo/"$_xm"/ }"
  done
  local IFS=$'\n'
  printf '%s' "${_L[*]}"
}

# 커밋 메시지 가리기(conv_179172160300 D-2) — git [-C 디렉터리 | -c 설정]… commit 구간에서 -m·-am·--message·--message=
#   바로 뒤 인용 인자의 ★내용만★ 공백으로 바꾼다(따옴표·옵션·다른 구간은 그대로 판정).
#   인자 조건 — 작은따옴표 인자는 그대로 허용, 큰따옴표 인자는 안에 $·백틱·\ 가 없을 때만. 인자 전체가 따옴표 하나여야 한다.
#   해석 차이를 막는 fail-closed(하나라도 있으면 명령 전체 원문) — heredoc(<<) · 작은따옴표 밖 역슬래시·백틱 ·
#     $( ${ $' $" · 단어 첫머리 미인용 #(주석 — 주석 뒤 따옴표가 다음 줄 명령을 감싼 것처럼 보이는 우회) · 따옴표 불균형.
#   미인용 < > 가 있는 구간은 가리지 않는다(리다이렉트 대상을 메시지로 오인하지 않게).
#   명령이 git 이 아닌 구간(bash -c '…'·eval·xargs 등)은 가리지 않는다.
_gpg_msg_mask() {  # $1=명령 → stdout: 가린 명령(조건 불충족이면 원본)
  local _s="$1" _n _i _c _d _q="" _inw=0 _st=0 _fo=-1 _fc=-1 _seg=0 _k _f _j _t _w _a _b _sp _o
  local -a _WS=() _WE=() _WO=() _WC=() _WG=() _DIRTY=() _MA=() _MB=()
  [[ "$_s" == *commit* && "$_s" != *"<<"* ]] || { printf '%s' "$_s"; return 0; }
  _n=${#_s}
  for (( _i=0; _i<=_n; _i++ )); do
    if (( _i == _n )); then
      [[ -z "$_q" ]] || { printf '%s' "$_s"; return 0; }      # 따옴표 불균형
      _c=$'\n'
    else
      _c="${_s:_i:1}"
    fi
    if [[ "$_q" == "'" ]]; then
      if [[ "$_c" == "'" ]]; then _q=""; (( _fc < 0 )) && _fc=$_i; fi
      continue
    fi
    if [[ "$_q" == '"' ]]; then
      case "$_c" in
        \") _q=""; (( _fc < 0 )) && _fc=$_i ;;
        \\|\`) printf '%s' "$_s"; return 0 ;;
        \$) _d="${_s:_i+1:1}"; [[ "$_d" == [\(\{\'\"] ]] && { printf '%s' "$_s"; return 0; } ;;
      esac
      continue
    fi
    case "$_c" in
      \'|\")
        if [[ $_inw -eq 0 ]]; then _inw=1; _st=$_i; _fo=-1; _fc=-1; fi
        (( _fo < 0 )) && _fo=$_i
        _q="$_c" ;;
      \\|\`) printf '%s' "$_s"; return 0 ;;
      \$)
        _d="${_s:_i+1:1}"; [[ "$_d" == [\(\{\'\"] ]] && { printf '%s' "$_s"; return 0; }
        if [[ $_inw -eq 0 ]]; then _inw=1; _st=$_i; _fo=-1; _fc=-1; fi ;;
      \#)
        [[ $_inw -eq 1 ]] || { printf '%s' "$_s"; return 0; } ;;
      ' '|$'\t'|\;|\&|\||\(|\)|$'\n'|\<|\>)
        if [[ $_inw -eq 1 ]]; then
          _WS+=("$_st"); _WE+=("$_i"); _WO+=("$_fo"); _WC+=("$_fc"); _WG+=("$_seg"); _inw=0
        fi
        case "$_c" in
          \<|\>) _DIRTY[$_seg]=1 ;;
          ' '|$'\t') ;;
          *) _seg=$((_seg+1)) ;;
        esac ;;
      *)
        if [[ $_inw -eq 0 ]]; then _inw=1; _st=$_i; _fo=-1; _fc=-1; fi ;;
    esac
  done
  # 구간별로 git … commit … -m <인용> 을 찾는다
  _k=0
  while [[ $_k -lt ${#_WS[@]} ]]; do
    _f=$_k; _seg="${_WG[$_k]}"
    while [[ $_k -lt ${#_WS[@]} && "${_WG[$_k]}" == "$_seg" ]]; do _k=$((_k+1)); done   # [_f, _k) = 이 구간 단어
    [[ -z "${_DIRTY[$_seg]:-}" ]] || continue
    _w="${_s:${_WS[$_f]}:$(( ${_WE[$_f]} - ${_WS[$_f]} ))}"
    [[ "${_WO[$_f]}" -lt 0 && "${_w##*/}" == "git" ]] || continue
    _j=$((_f+1))
    while [[ $_j -lt $_k ]]; do
      _t="${_s:${_WS[$_j]}:$(( ${_WE[$_j]} - ${_WS[$_j]} ))}"
      if [[ "$_t" == "-C" || "$_t" == "-c" ]]; then _j=$((_j+2)); else break; fi
    done
    [[ $_j -lt $_k && "${_WO[$_j]}" -lt 0 ]] || continue
    _t="${_s:${_WS[$_j]}:$(( ${_WE[$_j]} - ${_WS[$_j]} ))}"
    [[ "$_t" == "commit" ]] || continue
    for (( _j=_j+1; _j<_k; _j++ )); do
      _t="${_s:${_WS[$_j]}:$(( ${_WE[$_j]} - ${_WS[$_j]} ))}"
      _a=-1
      if [[ "$_t" == "-m" || "$_t" == "-am" || "$_t" == "--message" ]]; then
        [[ $((_j+1)) -lt $_k ]] || continue
        _o=$((_j+1))
        [[ "${_WO[$_o]}" == "${_WS[$_o]}" && "${_WC[$_o]}" == "$(( ${_WE[$_o]} - 1 ))" ]] && { _a=${_WO[$_o]}; _b=${_WC[$_o]}; }
      elif [[ "${_WO[$_j]}" -ge 0 && "${_s:${_WS[$_j]}:$(( ${_WO[$_j]} - ${_WS[$_j]} ))}" == "--message=" \
              && "${_WC[$_j]}" == "$(( ${_WE[$_j]} - 1 ))" ]]; then
        _a=${_WO[$_j]}; _b=${_WC[$_j]}
      fi
      [[ $_a -ge 0 ]] || continue
      _t="${_s:_a+1:_b-_a-1}"
      if [[ "${_s:_a:1}" == '"' && "$_t" == *[\$\`\\]* ]]; then continue; fi
      _MA+=("$((_a+1))"); _MB+=("$_b")
    done
  done
  [[ ${#_MA[@]} -gt 0 ]] || { printf '%s' "$_s"; return 0; }
  _o="$_s"
  for _i in "${!_MA[@]}"; do
    _a=${_MA[$_i]}; _b=${_MB[$_i]}
    printf -v _sp '%*s' "$((_b-_a))" ''
    _o="${_o:0:_a}${_sp}${_o:_b}"
  done
  printf '%s' "$_o"
}

# tee 단독 완화 판정(conv_179172160300 D-3 · 검토 R1) — 0 이면 tee 를 규칙①의 쓰기 수단에서 뺀다.
#   조건(모두) — 명령에 $·백틱·<(·>( 가 없다 · eval·source·exec·.·인터프리터(bash·sh·dash·zsh·ksh)·xargs·busybox 단어와
#   -exec·-execdir·-ok·-okdir·-c 단어가 없다(따옴표 안·하위 명령 안의 tee 를 구간으로 못 보는 공허 참 차단) ·
#   tee 출현 수 == tee 를 명령으로 하는 구간 수 · 모든 tee 구간에 비옵션 인자가 1개 이상 · 그 인자 전부가 보호 토큰 미포함이고
#   전개·realpath 결과가 보호 대상이 아니다. 완화돼도 _gpg_segment 의 tee 분기가 대상을 다시 판정한다.
_gpg_tee_safe() {  # $1=가린 원본 $2=소문자·따옴표 제거본 → rc 0 완화 가능
  local _r="$1" _l="$2" _t _cnt=0 _segn=0 _seg _i _w _x _na _v
  local -a _segs=() _a=()
  [[ "$_r" == *[\$\`]* || "$_r" == *"<("* || "$_r" == *">("* ]] && return 1
  [[ "$_l" =~ (^|[^a-z0-9_.-])(eval|source|exec|bash|sh|dash|zsh|ksh|xargs|busybox)([^a-z0-9_.-]|$) ]] && return 1
  [[ "$_l" =~ (^|[[:space:]\;\&\|])[.]([[:space:]]|$) ]] && return 1
  [[ "$_l" =~ (^|[[:space:]])-(exec|execdir|ok|okdir|c)([[:space:]]|$) ]] && return 1
  _t="$_l"
  while [[ "$_t" =~ ${_GPG_B}tee${_GPG_E} ]]; do
    _cnt=$((_cnt+1)); _t="${_t/"${BASH_REMATCH[0]}"/ }"
    [[ $_cnt -lt 64 ]] || return 1
  done
  _t=$(_gpg_seg_prep "$_r")
  IFS=$'\x01' read -r -a _segs <<<"$_t"
  for _seg in "${_segs[@]}"; do
    [[ "$_seg" =~ [^[:space:]] ]] || continue
    _gpg_words "$_seg"; _a=("${_GPG_W[@]}")
    _i=0
    while [[ $_i -lt ${#_a[@]} ]]; do                       # _gpg_segment 와 같은 래퍼 건너뛰기
      case "${_a[$_i]}" in
        sudo|command|nohup|exec|env|nice|setsid|time|xargs|builtin|stdbuf|ionice|chronic|-*) _i=$((_i+1)) ;;
        timeout) _i=$((_i+2)) ;;
        [A-Za-z_]*=*) _i=$((_i+1)) ;;
        *) break ;;
      esac
    done
    [[ $_i -lt ${#_a[@]} ]] || continue
    _v="${_a[$_i]##*/}"; _v="${_v,,}"
    [[ "$_v" == "tee" ]] || continue
    _segn=$((_segn+1)); _na=0
    for _w in "${_a[@]:$((_i+1))}"; do
      [[ "$_w" == -* ]] && continue
      _na=$((_na+1))
      [[ "${_w,,}" =~ $_GPG_TOK ]] && return 1
      _gpg_expand "$_w"
      for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && return 1; done
    done
    [[ $_na -ge 1 ]] || return 1
  done
  [[ $_cnt -ge 1 && $_cnt -eq $_segn ]]
}

# 읽기 전용 구간 판정용 분해(conv_179172975200 항목2) — 따옴표를 존중해 구간·파이프 연결·쓰기 리다이렉트 대상을 나눈다.
#   출력  _GPG_RS[i]=구간 본문(리다이렉트 제거·따옴표 제거) · _GPG_RP[i]=1 이면 다음 구간으로 파이프 · _GPG_RT[i]=쓰기 대상(\x02 구분)
#   rc 1 = 해석 불확실(호출부가 종전 전 단어 전개로 판정) — $(HOME 외)·백틱·역슬래시·( ) { }·단어 첫 #·<<·<( >(·
#          따옴표 불균형·대상 없는 리다이렉트.
# c205 G1: $2 위치의 $ 가 특수 매개변수($? $# $$ $! $-)이고 그 뒤 글자가 영숫자·_·{ 가 아니면 rc 0
_gpg_sp_at() {  # $1=문자열 $2=위치
  local _p="${1:$2+1:1}" _a="${1:$2+2:1}"
  case "$_p" in \?|\#|\$|\!|-) ;; *) return 1 ;; esac
  [[ "$_a" =~ [A-Za-z0-9_{] ]] && return 1
  return 0
}
_gpg_rd_split() {  # $1=명령 → rc 0 분해 성공
  local _s="$1" _n _i _c _d _q="" _cur="" _rt="" _inw=0 _t _w _wr _dq="" _dqs=0 _dqe=0
  _GPG_RS=(); _GPG_RP=(); _GPG_RT=()
  [[ "$_s" =~ \$HOME[A-Za-z0-9_] ]] && return 1
  _s="${_s//\$\{HOME\}/$HOME}"; _s="${_s//\$HOME/$HOME}"
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q="" || _cur+="$_c"; continue; fi
    if [[ "$_q" == '"' ]]; then
      # c183 B8: 큰따옴표 안 \ 는 뒤 글자가 $ ` " \ 개행일 때만 이스케이프다(bash 규칙) — 그 밖(grep "a\|b" 의 \|)은 글자 그대로
      # c205 G1: \$ \` \\ 는 bash 규칙상 뒤 글자 그대로다 — 그 글자를 단어에 붙이고 건너뛴다(종전 rc1 → 분해 포기 과차단).
      #   \" 는 종전대로 rc1 — oio bash_exec 의 && 분할기(_split_and_commands)는 역슬래시를 무시하고 \" 에서 따옴표를 닫으므로
      #   bash 와 단위 경계가 달라진다(grep "a\" && cp x 보호파일 && echo \"" 가 분할돼 cp 실행 — GG-U10·GG-C205D14).
      #   개행·끝은 종전대로 rc1. 리다이렉트 대상 단어(아래 안쪽 while)는 종전 strict 유지.
      if [[ "$_c" == \\ ]]; then
        case "${_s:_i+1:1}" in
          \$|\`|\\) _cur+="${_s:_i+1:1}"; _i=$((_i+1)); continue ;;
          # c206 11-1: 원 명령에 && 가 없으면(_GPG_AND=0) oio 가 나누지 않으므로 \" 도 bash 규칙(글자 ")으로 읽는다.
          #   단 같은 큰따옴표 문자열에 구분자(; | & 개행)가 함께 있으면 종전 rc1 — 경계 오독 시 명령으로 보일 글자를 품은
          #   문자열은 다른 분해기와 어긋날 여지가 있으므로 완화하지 않는다(GG-U10 차단 유지).
          \") [[ "${_GPG_AND:-1}" == 0 && $_dqs -eq 0 ]] || return 1; _dqe=1; _cur+='"'; _i=$((_i+1)); continue ;;
          $'\n'|'') return 1 ;;
          # c213: 읽기 전용 빠른 길(_GPG_RO=1)에서만 grep 교대 \| 를 구분자로 세지 않는다(bash 에서 글자 그대로 — 맨 ; | & 는 종전대로 센다)
          \|) [[ "${_GPG_RO:-0}" == 1 ]] && { _cur+='\|'; _i=$((_i+1)); continue; }; _cur+="$_c"; continue ;;
          *) _cur+="$_c"; continue ;;
        esac
      fi
      # c205 G1: 특수 매개변수 $? $# $$ $! $- (뒤가 영숫자·_·{ 아님)는 숫자·플래그로만 전개돼 경로를 못 만든다 — 글자 그대로 둔다
      if [[ "$_c" == \$ ]] && _gpg_sp_at "$_s" "$_i"; then _cur+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue; fi
      case "$_c" in
        \;|\||\&|$'\n') _dqs=1; [[ $_dqe -eq 1 ]] && return 1 ;;   # c206: \" 와 구분자가 한 문자열에 — 종전 rc1
      esac
      case "$_c" in \") _q="" ;; \$|\`) return 1 ;; *) _cur+="$_c" ;; esac; continue
    fi
    _d="${_s:_i+1:1}"
    # c205 G1: 따옴표 밖 특수 매개변수도 같은 규칙(그 밖 $ 는 종전대로 rc1 — 변수 간접화 차단 유지)
    if [[ "$_c" == \$ ]] && _gpg_sp_at "$_s" "$_i"; then _cur+="$_c$_d"; _inw=1; _i=$((_i+1)); continue; fi
    case "$_c" in
      \') _q="'"; _inw=1 ;;
      \") _q='"'; _inw=1; _dqs=0; _dqe=0 ;;
      \$|\`|\\|\(|\)|\{|\}) return 1 ;;
      \#) [[ $_inw -eq 1 ]] || return 1; _cur+="$_c" ;;
      ' '|$'\t') _cur+=" "; _inw=0 ;;
      \;|$'\n') _gpg_rd_flush 0 ;;
      \|)
        if [[ "$_d" == "|" ]]; then _i=$((_i+1)); _gpg_rd_flush 0
        else [[ "$_d" == "&" ]] && _i=$((_i+1)); _gpg_rd_flush 1; fi ;;
      \&|\>|\<)
        if [[ "$_c" == "&" && "$_d" != ">" ]]; then
          [[ "$_d" == "&" ]] && _i=$((_i+1))
          _gpg_rd_flush 0; continue
        fi
        # 리다이렉트 — 앞에 붙은 fd 숫자 단어는 버린다(2> · 9<)
        _t="${_cur##* }"
        [[ $_inw -eq 1 && "$_t" =~ ^[0-9]+$ ]] && _cur="${_cur%"$_t"}"
        _wr=1; _dq=0
        if [[ "$_c" == "&" ]]; then _i=$((_i+1)); _d="${_s:_i+1:1}"; fi        # &> · &>>
        if [[ "$_c" == "<" ]]; then
          case "$_d" in
            \<|\() return 1 ;;
            \>) _i=$((_i+1)) ;;                                                 # <> 읽기·쓰기 열기 — 쓰기로 본다
            \&) _i=$((_i+1)); _wr=0; _dq=1 ;;
            *) _wr=0 ;;
          esac
        else
          [[ "$_d" == "(" ]] && return 1
          [[ "$_d" == ">" || "$_d" == "|" ]] && { _i=$((_i+1)); _d="${_s:_i+1:1}"; }
          [[ "$_d" == "&" ]] && { _i=$((_i+1)); _dq=1; }
        fi
        _i=$((_i+1))
        while [[ $_i -lt $_n && ( "${_s:_i:1}" == " " || "${_s:_i:1}" == $'\t' ) ]]; do _i=$((_i+1)); done
        _w=""
        while [[ $_i -lt $_n ]]; do
          _c="${_s:_i:1}"
          if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q="" || _w+="$_c"; _i=$((_i+1)); continue; fi
          if [[ "$_q" == '"' ]]; then
            case "$_c" in \") _q="" ;; \$|\`|\\) return 1 ;; *) _w+="$_c" ;; esac; _i=$((_i+1)); continue
          fi
          case "$_c" in
            \') _q="'" ;;
            \") _q='"' ;;
            \$|\`|\\|\(|\)|\{|\}) return 1 ;;
            ' '|$'\t'|\;|\||\&|\<|\>|$'\n') break ;;
            *) _w+="$_c" ;;
          esac
          _i=$((_i+1))
        done
        [[ -z "$_q" && -n "$_w" ]] || return 1
        _i=$((_i-1)); _inw=0; _cur+=" "
        [[ $_dq -eq 1 && "$_w" =~ ^([0-9]+|-)$ ]] && continue                 # >&2 · <&0 · >&- (fd 복제·닫기)
        [[ $_wr -eq 1 ]] || continue
        case "$_w" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty) continue ;; esac
        _rt+="${_rt:+$'\x02'}$_w" ;;
      *) _cur+="$_c"; _inw=1 ;;
    esac
  done
  [[ -z "$_q" ]] || return 1
  _gpg_rd_flush 0
  return 0
}
_gpg_rd_flush() {  # $1=다음 구간으로 파이프(0|1) — _gpg_rd_split 의 지역 _cur·_rt·_inw 를 구간으로 넘긴다(동적 스코프)
  _GPG_RS+=("$_cur"); _GPG_RP+=("$1"); _GPG_RT+=("$_rt")
  _cur=""; _rt=""; _inw=0
}

# 읽기 전용 명령 판정 — $1=구간 본문(_GPG_RS) → 0 이면 파일을 쓰거나 다른 명령을 실행할 수단이 없는 조회 명령
#   허용 래퍼는 command·builtin·time·timeout N 뿐이다(환경 대입·env·nohup 등은 판정 불가로 본다).
#   명령 이름에 / 가 있으면 /bin·/usr/bin 아래만 인정한다(./cat 같은 같은 이름 스크립트 차단).
#   find·awk·sed·jq 는 읽기 전용이 아니다(find -delete/-fprint · 실행 기능). sort 는 -o·--output·--compress-program 이 없을 때,
#   uniq 는 비옵션 인자 1개 이하일 때만 읽기 전용이다(sort -o · uniq 두 번째 인자 = 출력).
_gpg_read_seg() {
  local -a _a=()
  local _i=0 _v
  read -r -a _a <<<"$1"
  while [[ $_i -lt ${#_a[@]} ]]; do
    case "${_a[$_i]}" in
      command|builtin|time) _i=$((_i+1)) ;;
      timeout) _i=$((_i+2)) ;;
      *) break ;;
    esac
  done
  [[ $_i -lt ${#_a[@]} ]] || return 1
  _v="${_a[$_i]}"
  [[ "$_v" == *=* ]] && return 1
  if [[ "$_v" == */* ]]; then
    [[ "$_v" =~ ^/(usr/)?bin/[a-z0-9]+$ || "$_v" == "/usr/bin/[" ]] || return 1
    _v="${_v##*/}"
  fi
  case "$_v" in
    grep|egrep|fgrep|cat|head|tail|wc|ls|stat|sha256sum|sha1sum|md5sum|cmp|diff|cut|nl|du|readlink|realpath|basename|dirname|test|\[) return 0 ;;
    python|python[0-9]*) _gpg_pyscript_safe "$1" && return 0; return 1 ;;
    rg) [[ " $1 " == *" --pre"* ]] && return 1; return 0 ;;                       # --pre 는 명령 실행
    git)    # unblock3(사용자 지시 2026-10-27 13:04 + 화면 결정 ②): git 머리 구간은 하위 명령·옵션과 무관하게 조회와 같게 본다 —
      #   git 으로 보호 파일을 바꾸는 것을 허용한다. 쓰기 리다이렉트 대상(_GPG_RT)은 호출부가 따로 본다.
      #   (종전 c213: git [-C|--no-pager]… grep 만 조회, -O·--open-files-in-pager·textconv·ext-grep 거부 — 이 결정으로 대체)
      return 0 ;;
    file) [[ " $1 " =~ [[:space:]](-[a-zA-Z]*C|--compile)([[:space:]]|$) ]] && return 1; return 0 ;;
    sort)   # 출력(-o·--output)·압축 프로그램 실행(--compress-program) 옵션이 없을 때만 조회(사슬 하류 정렬 — cd;grep|sort 오차단)
      local _w
      for _w in "${_a[@]:$((_i+1))}"; do
        case "$_w" in --output*|--compress*) return 1 ;; --*) ;; -*o*) return 1 ;; esac
      done
      return 0 ;;
    uniq)   # 비옵션 인자 1개 이하(두 번째 인자 = 출력 파일)일 때만 조회
      # c205 R-1: 단독 - 는 옵션이 아니라 stdin 피연산자다 — uniq - <파일> 의 두 번째 피연산자 = 출력 파일(쓰기)
      local _w _na=0
      for _w in "${_a[@]:$((_i+1))}"; do [[ "$_w" == -?* ]] || _na=$((_na+1)); done
      [[ $_na -le 1 ]] && return 0; return 1 ;;
    # c205 G2: 출력·작업 디렉터리만 바꾸는 명령 — 파일 쓰기는 리다이렉트로만 가능하고 리다이렉트 대상은 호출부가 따로 본다
    echo|pwd|true) return 0 ;;
    cd)     # 비옵션 인자 1개 이하
      local _w _na=0
      for _w in "${_a[@]:$((_i+1))}"; do [[ "$_w" == -?* ]] || _na=$((_na+1)); done
      [[ $_na -le 1 ]] && return 0; return 1 ;;
    printf) # -v(셸 변수 대입 — 이후 단위의 ~·변수 전개를 바꿀 수 있다)가 있으면 조회가 아니다(검토 P-1)
      local _w
      for _w in "${_a[@]:$((_i+1))}"; do [[ "$_w" == -v* ]] && return 1; done
      return 0 ;;
    date)   # -s·--set(시스템 시각 변경)이 있으면 조회가 아니다 — 짧은 옵션 묶음(-us)도 본다
      local _w
      for _w in "${_a[@]:$((_i+1))}"; do
        case "$_w" in --set*) return 1 ;; --*) ;; -*s*) return 1 ;; esac
      done
      return 0 ;;
    bash)   # c205 G2: 승격기 조회 실행만 — 정확히 bash <H>/lib/guard_promote.sh verify | status [<id>]
      local _gp="${_a[$((_i+1))]}" _sub="${_a[$((_i+2))]}" _nr=$(( ${#_a[@]} - _i )) _h _hr
      _h="${HARNESS_HOME:-$HOME/.harness}/current/hooks"
      if [[ "$_gp" != "$_h/lib/guard_promote.sh" ]]; then
        _hr=$(readlink -f -- "$_h" 2>/dev/null) || return 1
        [[ -n "$_hr" && "$_gp" == "$_hr/lib/guard_promote.sh" ]] || return 1
      fi
      case "$_sub" in
        verify) [[ $_nr -eq 3 ]] && return 0 ;;
        status) [[ $_nr -eq 3 ]] && return 0
                [[ $_nr -eq 4 && "${_a[$((_i+3))]}" =~ ^[a-z0-9_]+$ ]] && return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

# 구간별 ② 판정 — _gpg_rd_split 결과로 파이프 사슬마다 읽기 전용이면 쓰기 리다이렉트 대상만, 아니면 전 단어를 전개해 본다.
#   $1=소비자 유무(1 이면 리다이렉트가 있는 읽기 사슬도 전 단어 전개) → rc 0 이면 차단(_GPG_HIT)
_gpg_rd_check() {
  local _cons="$1" _i _j _k _n=${#_GPG_RS[@]} _ex _t _x
  local -a _tg=()
  _i=0
  while [[ $_i -lt $_n ]]; do
    _j=$_i
    while [[ $_j -lt $((_n-1)) && "${_GPG_RP[$_j]}" == 1 ]]; do _j=$((_j+1)); done   # [_i, _j] = 파이프 사슬
    _ex=1
    for (( _k=_i; _k<=_j; _k++ )); do
      _gpg_read_seg "${_GPG_RS[$_k]}" || { _ex=0; break; }
      if [[ $_cons -eq 1 && -n "${_GPG_RT[$_k]}" ]]; then
        # unblock3: git 머리 구간은 소비자가 있어도 피연산자를 펼치지 않는다(쓰기 리다이렉트 대상만 본다)
        local -a _gw=(); read -r -a _gw <<<"${_GPG_RS[$_k]}"
        _gpg_git_safe "${_gw[@]}" || { _ex=0; break; }
      fi
    done
    for (( _k=_i; _k<=_j; _k++ )); do
      _tg=()
      [[ -n "${_GPG_RT[$_k]}" ]] && IFS=$'\x02' read -r -a _tg <<<"${_GPG_RT[$_k]}"
      if [[ $_ex -eq 1 ]]; then
        [[ ${#_tg[@]} -gt 0 ]] || continue
        _gpg_check_words 0 "${_tg[@]}" && return 0
        for _t in "${_tg[@]}"; do
          _gpg_expand "$_t"
          for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && { _GPG_HIT="리다이렉트 대상 $_x"; return 0; }; done
        done
      else
        _gpg_words "${_GPG_RS[$_k]}"
        _gpg_check_words 0 "${_GPG_W[@]}" "${_tg[@]}" && return 0
      fi
    done
    _i=$((_j+1))
  done
  return 1
}

# 쓰기 수단 정규식 — $1=소문자·따옴표 제거 문자열 → 0 이면 쓰기 수단 있음(tee·git 쓰기 하위 명령은 호출부가 따로 본다)
_gpg_wm_re() {
  local _nq="$1"
  [[ "$_nq" =~ ${_GPG_B}(touch|truncate|cp|mv|install|rsync|ln|dd|rm|rmdir|unlink|shred|flock|chmod|chown|chgrp|patch|sponge|mkfifo|tar|unzip|cpio)${_GPG_E} ]] \
     || [[ "$_nq" =~ ${_GPG_B}(sed|perl)([[:space:]][^\;\|\&]*)?[[:space:]]-[a-z]*i ]] \
     || [[ "$_nq" =~ ${_GPG_B}(python[0-9.]*|perl|node|ruby|php)${_GPG_E} ]] \
     || [[ "$_nq" =~ (^|[[:space:]])-delete([[:space:]]|$) ]] \
     || [[ "$_nq" =~ ${_GPG_B}sort([[:space:]][^\;\|\&]*)?[[:space:]](-[a-z]*o|--output) ]] \
     || [[ "$_nq" =~ ${_GPG_B}uniq([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-|[^-[:space:]\;\|\&\<\>][^[:space:]\;\|\&\<\>]*)[[:space:]]+[^-[:space:]\;\|\&\<\>] ]]
  # c205 R-1: uniq 첫 피연산자가 단독 -(stdin)여도 두 번째 피연산자는 출력 파일이다(uniq - 보호파일 = 쓰기 수단)
}

# 명령 단위 분해(c183 B8) — 따옴표를 존중해 ; && || & 개행에서 나눈다(파이프 | 는 같은 단위). → _GPG_U
#   rc 1 = 단위를 확정할 수 없다 — $·백틱·역슬래시·( )·<<·eval/source/exec·따옴표 불균형(호출부는 명령 전체로 판정)
#   c213: $2=1 은 읽기 전용 빠른 길(G3) 전용 — 따옴표 안 << · eval/source/exec 글자는 분해를 막지 않는다. 따옴표 밖 heredoc 은
#   _gpg_rd_split 이 rc1, eval/source/exec 가 구간 머리면 _gpg_read_seg 가 거부하므로 G3 는 여전히 불채택이다. ①이 쓰는 기본 모드는 종전 그대로.
_gpg_units() {  # $1=명령 $2=1 이면 G3 전용 모드
  local _s="$1" _n _i _c _d _q="" _cur="" _dqs=0 _dqe=0
  _GPG_U=()
  if [[ "${2:-0}" != 1 ]]; then
    [[ "$_s" == *'<<'* ]] && return 1
    [[ "${_s,,}" =~ ${_GPG_B}(eval|source|exec)${_GPG_E} ]] && return 1
  fi
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then _cur+="$_c"; [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_q" == '"' ]]; then
      # c199g D-4: 큰따옴표 안 \ 는 뒤 글자가 $ ` " \ 개행일 때만 이스케이프다(bash 규칙) — grep "a\|b" 의 \| 는 글자 그대로
      # c205 G1: \$ \` \\ 는 뒤 글자 그대로 — 두 글자를 단위에 붙이고 건너뛴다(종전 rc1). 개행·끝은 종전대로 rc1.
      #   \" 는 종전대로 rc1 — oio && 분할기가 \" 에서 따옴표를 닫아 bash 와 단위 경계가 달라진다(_gpg_rd_split 주석 참조).
      if [[ "$_c" == \\ ]]; then
        case "${_s:_i+1:1}" in
          \$|\`|\\) _cur+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue ;;
          # c206 11-1: 원 명령에 && 가 없으면(_GPG_AND=0) \" 도 두 글자를 단위에 붙이고 건너뛴다(oio 분할과 bash 분할이 같다)
          #   같은 큰따옴표 문자열에 구분자(; | & 개행)가 함께 있으면 종전 rc1(_gpg_rd_split 주석 참조 — GG-U10).
          \") [[ "${_GPG_AND:-1}" == 0 && $_dqs -eq 0 ]] || return 1; _dqe=1; _cur+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue ;;
          $'\n'|'') return 1 ;;
          \|) [[ "${_GPG_RO:-0}" == 1 ]] && { _cur+='\|'; _i=$((_i+1)); continue; } ;;   # c213: G3 전용 — grep 교대 \| 는 구분자 아님
        esac
        _cur+="$_c"; continue
      fi
      # c205 G1: 특수 매개변수 $? $# $$ $! $- 는 글자 그대로(그 밖 $ 는 종전 rc1)
      if [[ "$_c" == \$ ]] && _gpg_sp_at "$_s" "$_i"; then _cur+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue; fi
      case "$_c" in
        \;|\||\&|$'\n') _dqs=1; [[ $_dqe -eq 1 ]] && return 1 ;;   # c206: \" 와 구분자가 한 문자열에 — 종전 rc1
      esac
      case "$_c" in \") _q="" ;; \$|\`) return 1 ;; esac
      _cur+="$_c"; continue
    fi
    _d="${_s:_i+1:1}"
    # c205 G1: 따옴표 밖 특수 매개변수도 같은 규칙
    if [[ "$_c" == \$ ]] && _gpg_sp_at "$_s" "$_i"; then _cur+="$_c$_d"; _i=$((_i+1)); continue; fi
    case "$_c" in
      \') _q="'"; _cur+="$_c" ;;
      \") _q='"'; _cur+="$_c"; _dqs=0; _dqe=0 ;;
      \$|\`|\\|\(|\)) return 1 ;;
      \;|$'\n') _GPG_U+=("$_cur"); _cur="" ;;
      \&)
        if [[ "$_d" == "&" ]]; then _i=$((_i+1)); _GPG_U+=("$_cur"); _cur=""
        elif [[ "$_d" == ">" || "${_cur: -1}" == ">" || "${_cur: -1}" == "<" ]]; then _cur+="$_c"   # &> · >& · <& 리다이렉트
        else _GPG_U+=("$_cur"); _cur=""; fi ;;
      \|)
        if [[ "$_d" == "|" ]]; then _i=$((_i+1)); _GPG_U+=("$_cur"); _cur=""
        else _cur+="$_c"; fi ;;
      *) _cur+="$_c" ;;
    esac
  done
  [[ -z "$_q" ]] || return 1
  _GPG_U+=("$_cur")
  return 0
}

# c199g D-4: 단위 하나가 읽기 전용 사슬인가 — 분해 성공 + 모든 구간이 _gpg_read_seg + 쓰기 리다이렉트 대상 0
#   소비자(xargs·while·eval 등)는 구간 머리에 오면 _gpg_read_seg 가 거부하고, $·백틱·( ) 는 _gpg_rd_split 이 거부한다 —
#   인용 패턴 글자(grep "READ")를 소비자로 오인하지 않도록 단어 검색은 하지 않는다.
# c213: G3 에서 단위가 리터럴 값 대입 하나뿐인가(T=<경로> — 셸 변수만 바꾼다). 값은 따옴표 없음 또는 짝 맞는 홑·큰따옴표,
#   $ ` \ ; | & < > ( ) { } * ? # ! ~ ^ [ ] 없음. 실행 경로·조회 동작을 바꾸는 이름은 제외한다(검토 LOW-G3 — XDG_*·PERLLIB 추가).
_gpg_unit_litassign() {  # $1=단위 → rc 0 무해 대입
  local _re='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=('"'"'[^'"'"'$`\\]*'"'"'|"[^"$`\\]*"|[^][:space:]'"'"'"$`\\;|&<>(){}*?#!~^[]*)[[:space:]]*$'
  [[ "$1" =~ $_re ]] || return 1
  [[ "${BASH_REMATCH[1]}" =~ ^(PATH|HOME|PWD|OLDPWD|IFS|CDPATH|ENV|BASH.*|LD_.*|GLOBIGNORE|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|PYTHON.*|PERL5.*|PERLLIB|NODE_.*|RUBY.*|GIT_.*|GCONV_PATH|RIPGREP_.*|GREP_.*|LESS.*|PAGER|TMPDIR|LANG|LC_.*|TERM.*|POSIXLY_CORRECT|XDG_.*)$ ]] && return 1
  return 0
}
_gpg_unit_readonly() {  # $1=단위 → rc 0 읽기 전용
  local _k
  _gpg_rd_split "$1" || return 1
  [[ ${#_GPG_RS[@]} -gt 0 ]] || return 1
  for (( _k=0; _k<${#_GPG_RS[@]}; _k++ )); do
    [[ -z "${_GPG_RT[$_k]}" ]] || return 1
    _gpg_read_seg "${_GPG_RS[$_k]}" || return 1
  done
  return 0
}

# c206 S1b: 단위 하나에서 tee 가 보호 대상에 쓰지 않음이 확실한가 — $1=단위 원문 $2=소문자·따옴표 제거본 → rc 0 이면 확실
#   조건(모두) — eval·source·exec·xargs·busybox·parallel 단어와 -c·-exec·-execdir·-ok·-okdir 단어가 없다(tee 를 다른 명령의 인자로
#   숨기는 꼴 차단) · 분해 확실(_gpg_rd_split) · tee 출현 수 == tee 를 명령으로 하는 구간 수 · 모든 tee 구간에 비옵션 인자 1개 이상 ·
#   tee 인자와 쓰기 리다이렉트 대상이 전부 보호 토큰 미포함이고 전개·realpath 결과가 보호 대상이 아니다.
#   bash <스크립트> 실행은 내용을 정적으로 못 보는 2단계 등급이다(tee 없이 > 로 받는 꼴은 종전부터 통과 — 그와 같게 맞춘다).
_gpg_unit_tee_ok() {
  local _u="$1" _l="$2" _t _cnt=0 _segn=0 _k _i _v _w _x _na
  local -a _a=() _tg=()
  [[ "$_l" =~ ${_GPG_B}(eval|source|exec|xargs|busybox|parallel)${_GPG_E} ]] && return 1
  [[ "$_l" =~ (^|[[:space:]])-(c|exec|execdir|ok|okdir)([[:space:]]|$) ]] && return 1
  [[ ${#_GPG_CWD[@]} -gt 0 ]] || _gpg_cwds "${_keep:-$_u}"
  _gpg_rd_split "$_u" || return 1
  _t="$_l"
  while [[ "$_t" =~ ${_GPG_B}tee${_GPG_E} ]]; do
    _cnt=$((_cnt+1)); _t="${_t/"${BASH_REMATCH[0]}"/ }"
    [[ $_cnt -lt 64 ]] || return 1
  done
  for (( _k=0; _k<${#_GPG_RS[@]}; _k++ )); do
    if [[ -n "${_GPG_RT[$_k]}" ]]; then
      IFS=$'\x02' read -r -a _tg <<<"${_GPG_RT[$_k]}"
      for _w in "${_tg[@]}"; do
        [[ "${_w,,}" =~ $_GPG_TOK ]] && return 1
        _gpg_expand "$_w"
        for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && return 1; done
      done
    fi
    read -r -a _a <<<"${_GPG_RS[$_k]}"
    _i=0
    while [[ $_i -lt ${#_a[@]} ]]; do
      case "${_a[$_i]}" in command|builtin|time|nice|stdbuf|-*) _i=$((_i+1)) ;; timeout) _i=$((_i+2)) ;; *) break ;; esac
    done
    [[ $_i -lt ${#_a[@]} ]] || continue
    _v="${_a[$_i]##*/}"; _v="${_v,,}"
    [[ "$_v" == tee ]] || continue
    _segn=$((_segn+1)); _na=0
    for _w in "${_a[@]:$((_i+1))}"; do
      [[ "$_w" == -* ]] && continue
      _na=$((_na+1))
      [[ "${_w,,}" =~ $_GPG_TOK ]] && return 1
      _gpg_expand "$_w"
      for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && return 1; done
    done
    [[ $_na -ge 1 ]] || return 1
  done
  [[ $_cnt -ge 1 && $_cnt -eq $_segn ]]
}

# [overblock P1d R-I] 단위가 cp 한 번으로 보호 파일을 읽어 hooks 밖 절대 리터럴 목적지에 복사하는 꼴인가 — $1=단위 → rc 0 이면 쓰기 수단으로 세지 않는다.
#   단위에 따옴표·역슬래시·$·백틱·괄호·중괄호·<>·구분자·글로브·~·#·제어문자가 없어야 한다. 옵션은 허용 목록만, -- 와 그 밖 옵션은 rc 1.
#   목적지(마지막 피연산자)와 목적지/<각 원본 이름> 이 모두 _gpg_rx_tgt_ok(hooks 밖 절대 리터럴, realpath·보호 대상·.. 검사)여야 한다.
_gpg_unit_cpout() {
  local _u="$1" _w _dst _s
  local -a _a=() _ops=()
  [[ "$_u" != *[\'\"\\\$\`\(\)\{\}\<\>\|\;\&\*\?\[\]~#]* && "$_u" != *[$'\n\r\t\003\004\005']* ]] || return 1
  read -r -a _a <<<"$_u"
  [[ ${#_a[@]} -ge 3 ]] || return 1
  case "${_a[0]}" in cp|/bin/cp|/usr/bin/cp) ;; *) return 1 ;; esac
  for _w in "${_a[@]:1}"; do
    if [[ "$_w" == -* ]]; then
      [[ "$_w" =~ ^-[pfvnaRrLHPu]+$ || "$_w" =~ ^--(preserve(=[a-z,]+)?|no-preserve=[a-z,]+|no-clobber|force|verbose|recursive|archive|dereference|no-dereference|update)$ ]] || return 1
      continue
    fi
    _ops+=("$_w")
  done
  [[ ${#_ops[@]} -ge 2 ]] || return 1
  _dst="${_ops[-1]}"
  _gpg_rx_tgt_ok "$_dst" || return 1
  for _s in "${_ops[@]:0:${#_ops[@]}-1}"; do
    [[ "$_s" != *..* && -n "${_s##*/}" ]] || return 1
    _gpg_rx_tgt_ok "${_dst%/}/${_s##*/}" || return 1
  done
  return 0
}

# [overblock P1d R-F] $(…) 의 닫는 괄호 위치 — $1=문자열 $2=$ 위치 → _GPG_SE. 따옴표·역슬래시·중첩 괄호를 따진다.
#   짝이 없거나, 안에 백틱·case·<< 가 있으면(괄호 짝·본문 경계를 정적으로 확정할 수 없다) rc 1.
_gpg_sub_end() {
  local _s="$1" _i=$(( $2 + 2 )) _n=${#1} _dp=1 _q="" _c _in
  while (( _i < _n )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q=""; _i=$((_i + 1)); continue; fi
    case "$_c" in
      \\) _i=$((_i + 2)); continue ;;
      \`) return 1 ;;
      \") if [[ "$_q" == '"' ]]; then _q=""; else _q='"'; fi ;;
      \') [[ -z "$_q" ]] && _q="'" ;;
      \() [[ -z "$_q" ]] && _dp=$((_dp + 1)) ;;
      \)) if [[ -z "$_q" ]]; then
            _dp=$((_dp - 1))
            if (( _dp == 0 )); then
              _in="${_s:$2+2:_i-$2-2}"
              [[ "$_in" =~ (^|[^A-Za-z0-9_])case([^A-Za-z0-9_]|$) || "$_in" == *'<<'* ]] && return 1
              _GPG_SE=$_i; return 0
            fi
          fi ;;
    esac
    _i=$((_i + 1))
  done
  return 1
}

# [overblock P1d R-F] 백틱 치환의 닫는 백틱 위치 — $1=문자열 $2=여는 백틱 위치 → _GPG_SE. 안에 역슬래시가 있으면(중첩·이스케이프) rc 1.
_gpg_bq_end() {
  local _r="${1:$2+1}" _k
  [[ "$_r" == *'`'* ]] || return 1
  _k="${_r%%\`*}"
  [[ "$_k" != *\\* ]] || return 1
  _GPG_SE=$(( $2 + 1 + ${#_k} ))
}

# [overblock P1d R-F] _gpg_rx_scan 전용 — 치환 안 명령을 같은 규칙으로 깊이+1 판정한다. $1=문자열 $2=$ 또는 백틱 위치 $3=깊이
#   → rc 0 이면 안전, _GPG_SE=닫는 위치, _GPG_RXA=안에서 연산자로 본 && 수. 깊이 3 초과는 판정 불가(rc 1).
_gpg_rx_subst() {
  local _s="$1" _i="$2" _d="$3" _se _in
  (( _d < 3 )) || return 1
  if [[ "${_s:_i:1}" == '`' ]]; then
    _gpg_bq_end "$_s" "$_i" || return 1; _se=$_GPG_SE; _in="${_s:_i+1:_se-_i-1}"
  else
    _gpg_sub_end "$_s" "$_i" || return 1; _se=$_GPG_SE; _in="${_s:_i+2:_se-_i-2}"
  fi
  _GPG_RXA=0
  if [[ "$_in" =~ [^[:space:]] ]]; then _gpg_rx_scan "$_in" $((_d + 1)) || return 1; fi
  _GPG_SE=$_se
  return 0
}

# [overblock P1d R-F] _gpg_rx_seg 전용 — python -c 코드 구간을 분류기(gp_pyclass)로 판정한다. $1=코드 $2…=뒤 단어 → rc 0 이면 SAFE.
#   코드·인자에 작은따옴표·$·백틱·CR 이 없어야 한다. 출력 리다이렉트 대상은 _gpg_rx_tgt_ok, 입력 리다이렉트는 리터럴만.
_gpg_rx_pyc() {
  local _code="$1" _w _pc _rt
  shift
  [[ -n "$_code" && "$_code" != *[\'\$\`]* && "$_code" != *$'\r'* ]] || return 1
  _pc="python3 -c '$_code'"
  for _w in "$@"; do
    if [[ "$_w" =~ ^[0-9]*(\>\>?\|?|\&\>\>?)(.*)$ ]]; then
      _rt="${BASH_REMATCH[2]}"
      case "$_rt" in /dev/null|/dev/stdout|/dev/stderr|'&'[0-9]|'&-') continue ;; esac
      _gpg_rx_tgt_ok "$_rt" || return 1
      continue
    fi
    if [[ "$_w" =~ ^[0-9]*\<(.*)$ ]]; then _gpg_rx_lit "${BASH_REMATCH[1]}" || return 1; continue; fi
    [[ "$_w" != *[\'\$\`]* ]] || return 1
    _pc+=" '$_w'"
  done
  _gpg_py_safe "$_pc"
}

# [overblock P1d R-K] c201 H 전용 — python 스크립트 단어가 변수 경로지만 보호 대상을 글자로 가리키지 않는가. $1=단어 → rc 0 이면 쓰기로 세지 않는다.
#   .py 로 끝나고 $ 가 있으며, 백틱·$(·글로브·~·따옴표·역슬래시·괄호·<>·구분자·공백·#·.. 가 없고, 보호 이름·hooks/{lib,tests,backup,logs}·.claude/hooks 가 글자로 없어야 한다.
_gpg_rxh_pyvar() {
  local _p="$1" _l
  [[ "$_p" == *'$'* && "$_p" == *.py ]] || return 1
  [[ "$_p" != *[\`\*\?\[\]~\\\'\"\(\)\<\>\;\|\&\#[:space:]]* && "$_p" != *[$'\003\004\005']* && "$_p" != *..* ]] || return 1
  _l="${_p,,}"
  [[ "$_l" =~ $_GPG_TOK ]] && return 1
  [[ "$_l" =~ (^|/)hooks/(lib|tests|backup|logs)(/|$) || "$_l" =~ \.claude/hooks(/|$) ]] && return 1
  return 0
}

# [overblock P1d R-K] c201 H 전용 — HOME 재대입이 있어도 쓰기 대상이 HOME 값과 무관한가. $1=명령 $2=_tee $3=_gitw → rc 0 이면 c201 H 로 차단하지 않는다.
#   tee·git 쓰기·<(·>(·<< 가 없고, _gpg_rx_scan(깊이 0, _GPG_RXH=1 — 모든 구간의 출력 리다이렉트 대상까지 본다, $(…)·백틱 안은 R-F 재귀)이 통과해야 한다.
_gpg_home_wr_ok() {
  local _rv
  [[ "$2" == 0 && "$3" == 0 ]] || return 1
  [[ "$1" != *'<('* && "$1" != *'>('* && "$1" != *'<<'* ]] || return 1
  _GPG_RXH=1
  _gpg_rx_scan "$1" 0; _rv=$?
  _GPG_RXH=0
  return $_rv
}

# [overblock P1d R-H] _gpg_hd_mask 전용 — 인용 heredoc 으로 쓴 파일 이름($1, 리다이렉트 대상 원문)이 hooks 밖 절대 리터럴 .py 이고,
#   본문 밖 줄($2)에서 그 이름이 나오는 곳이 모두 python 리터럴 스크립트 실행 위치(python[0-9.]* [-옵션…] <이름> — -c·-m·- 없음)인가 → rc 0.
#   이름이 그 밖(다른 명령의 피연산자·bash·source·. 실행·리다이렉트 대상)에서 나오면 rc 1(종전 판정 — R-D 유지).
_gpg_hd_pyrun_ok() {
  local _n="$1" _o="$2" _r _m _pre _w
  [[ "$_n" == /*.py && "$_n" != *..* && "$_n" != *[\$\`\*\?\[\]\{\}~\\\'\"\(\)\<\>\;\|\&\#[:space:]]* ]] || return 1
  _gpg_rx_tgt_ok "$_n" || return 1
  [[ "$_o" == *"$_n"* ]] || return 1
  _r="$_o"
  while [[ "$_r" == *"$_n"* ]]; do
    _pre="${_r%%"$_n"*}"
    _r="${_r#*"$_n"}"
    [[ -z "$_r" || "${_r:0:1}" =~ [[:space:]\;\&\|] ]] || return 1
    _m="${_pre##*[;&|$'\n']}"
    read -r -a _w <<<"$_m"
    [[ ${#_w[@]} -ge 1 && "${_w[0]}" =~ ^python[0-9.]*$ ]] || return 1
    for _m in "${_w[@]:1}"; do
      [[ "$_m" =~ ^-[A-Za-z]+$ && "$_m" != *[cmWX]* ]] || return 1
    done
  done
  return 0
}

# 단위 중 토큰과 쓰기 수단(tee·git 쓰기 하위 명령 포함)이 함께 있는 것이 있는가 — _GPG_U 기준, 0 이면 있음
_gpg_units_hit() {
  local _u _l _q _b _t
  for _u in "${_GPG_U[@]}"; do
    _l="${_u,,}"; _q="${_l//[\'\"\\]/}"; _b="${_q//[\{\},]/}"; _t="$_b"
    while [[ "$_t" =~ (test_guard_promote|test_gp_boot)[a-z0-9_.-]*\.sh ]]; do _t="${_t/"${BASH_REMATCH[0]}"/ }"; done
    [[ "$_t" =~ $_GPG_TOK ]] || continue
    # [overblock P1c R-G] 토큰 글자가 든 단어가 모두 확정 절대 리터럴(/ 로 시작, $·백틱·글로브·중괄호·~·역슬래시·글로브 표식·.. 없음)이고
    #   실제 보호 경로(_gpg_prot 대상 1 — 보호 파일·hooks 보호 디렉터리, realpath 포함)가 아니면 이 단위는 토큰 단위로 보지 않는다
    #   (scratch 사본 …/cand/gp_gate.sh 를 인자로 넘기는 조회·검증). _gpg_tokdst_hit 의 리다이렉트 대상 기준과 같다.
    #   토큰 단어가 하나라도 변수·상대경로·옵션 붙은 꼴(--module=…)·구분자가 붙은 꼴(…gp_gate.sh;)이거나 실제 보호 경로면 종전대로 본다.
    #   단어는 따옴표를 공백으로 바꾸고 줄바꿈·탭도 공백으로 바꾼 뒤 나눈다(여러 줄 단위의 모든 줄을 본다).
    local _gw _gwl _gwt _gk=0 _gwok='^/[A-Za-z0-9_./@%+:,=-]+$'
    local -a _gws=()
    _gwt="${_u//[\'\"]/ }"; _gwt="${_gwt//[$'\n\t']/ }"
    read -r -a _gws <<<"$_gwt"
    for _gw in "${_gws[@]}"; do
      _gwl="${_gw,,}"; _gwl="${_gwl//[\{\},]/}"
      while [[ "$_gwl" =~ (test_guard_promote|test_gp_boot)[a-z0-9_.-]*\.sh ]]; do _gwl="${_gwl/"${BASH_REMATCH[0]}"/ }"; done
      [[ "$_gwl" =~ $_GPG_TOK ]] || continue
      if [[ "$_gw" =~ $_gwok && "$_gw" != *..* ]] && ! _gpg_prot "$_gw" 1; then continue; fi
      _gk=1; break
    done
    [[ $_gk -eq 1 ]] || continue
    # c199g D-4: 단위가 읽기 전용 사슬(_gpg_read_seg 명령만의 파이프, 쓰기 리다이렉트 대상 없음)이면 토큰은 조회 피연산자다 —
    #   인용 패턴 글자(grep "python3 -c" …)를 쓰기 수단으로 오인하지 않는다. 판정이 불확실하면(분해 실패) 종전대로 본다.
    _gpg_unit_readonly "$_u" && continue
    # [overblock P1d R-I] 보호 파일을 읽어 hooks 밖으로 복사하는 cp 단위
    _gpg_unit_cpout "$_u" && continue
    _gpg_wm_re "$(_gpg_git_mask "$( _gpg_py_mask "${_u//[\'\"\\]/}" )" 1)" && return 0   # unblock3: git 머리 구간(git rm·git mv 등)의 단어는 쓰기 수단으로 세지 않는다
    # c206 S1b: tee 가 이 단위의 유일한 쓰기 수단이고 tee 대상이 모두 비보호면(보호 이름이 실행 대상 스크립트 경로로만 쓰임 —
    #   bash <hooks>/tests/<고정 시험> … | tee <scratchpad>/x.log) 토큰과 쓰기 수단이 겹친 것이 아니다(_gpg_unit_tee_ok).
    [[ "$_q" =~ ${_GPG_B}tee${_GPG_E} ]] && ! _gpg_unit_tee_ok "$_u" "$_q" && return 0
    # unblock3: git 쓰기 하위 명령은 git 머리 구간이 아닐 때만(echo git … · eval … · 명령 치환 포함) 쓰기 수단으로 센다
    [[ "$_q" =~ ${_GPG_B}git([[:space:]][^\;\|\&]*)?[[:space:]](${_GPG_GITW})${_GPG_E} ]] && ! _gpg_gitw_all_safe "${_u//[\'\"\\]/}" && return 0
  done
  return 1
}

# c199g D-4: 분해 불확실 폴백의 구간별 판정 — $1=원본 명령 → rc 0 이면 차단(_GPG_HIT)
#   구간은 _gpg_seg_prep(따옴표 존중, 미인용 ;|&()`$ 개행 경계)으로 나눈다. 구간 안 > 뒤 단어를 쓰기 대상으로 떼어 내고,
#   나머지가 조회 명령(_gpg_read_seg)이면 대상만, 아니면 대상 포함 전 단어를 펼쳐 판정한다.
_gpg_fb_check() {
  local _r _seg _rest _t _x
  local -a _segs=() _tg=()
  _r=$(_gpg_seg_prep "$1")
  IFS=$'\x01' read -r -a _segs <<<"$_r"
  for _seg in "${_segs[@]}"; do
    [[ "$_seg" =~ [^[:space:]] ]] || continue
    _tg=(); _rest="$_seg"
    while [[ "$_rest" =~ [0-9]*\>\>?\|?[[:space:]]*([^[:space:]\<\>]*) ]]; do
      _t="${BASH_REMATCH[1]}"
      case "$_t" in ''|/dev/null|/dev/stdout|/dev/stderr|/dev/tty) ;; *) _tg+=("$_t") ;; esac
      _rest="${_rest/"${BASH_REMATCH[0]}"/ }"
    done
    if _gpg_read_seg "$_rest"; then
      [[ ${#_tg[@]} -gt 0 ]] || continue
      _gpg_check_words 0 "${_tg[@]}" && return 0
      for _t in "${_tg[@]}"; do
        _gpg_expand "$_t"
        for _x in "${_GPG_X[@]}"; do _gpg_prot "$_x" 0 && { _GPG_HIT="리다이렉트 대상 $_x"; return 0; }; done
      done
    else
      _gpg_words "$_rest"
      _gpg_check_words 0 "${_GPG_W[@]}" "${_tg[@]}" && return 0
    fi
  done
  return 1
}

# c206 G4(D-4·D-11): 리터럴 변수 치환 전처리 — 명령 안에서 리터럴 값을 정확히 한 번 대입받은 변수의 참조를 값 글자로 바꾼다.
#   변수 경유 경로가 글자로 드러나므로 단위 분해(_gpg_units)가 가능해지고(변수 때문에 명령 전체로 판정하던 과차단 해소),
#   보호 경로를 변수에 숨긴 쓰기(f=<hooks>/lib/<모듈>; cp x $f · f=gp; cp x lib/${f}_gate.sh)는 치환 결과에 토큰이 드러나 계속 막힌다.
#   대입 조건 — 구간 머리(명령 시작 · 따옴표 밖 ; 뒤 · 따옴표 밖 개행 뒤, 그 앞줄이 | & 로 끝나지 않음)의 순수 대입 NAME=<값>
#     (값 뒤에는 공백만 두고 ; · 개행 · 끝). 값은 따옴표 없음 또는 짝 맞는 작은·큰따옴표 하나이고, 안에
#     $ ` \ ( ) { } [ ] * ? ; | & < > # ! ~ ^ 따옴표·제어 문자가 없다. 특수 변수(HOME·PWD·OLDPWD·IFS·PATH·CDPATH·ENV·BASH*·
#     LD_*·GLOBIGNORE·SHELLOPTS·BASHOPTS·PS4·PROMPT_COMMAND)는 대상이 아니다(HOME 재대입 판정 c201 H 를 그대로 둔다).
#     그 이름은 명령 전체에서 대입 1곳 + $NAME·${NAME} 참조로만 나와야 한다 — 재대입·+=·read·unset·for·${NAME:-…}·인용 글자 등
#     다른 꼴이 하나라도 있으면 그 이름은 치환하지 않는다.
#   치환 — 대입 ★뒤★ 의, 작은따옴표 밖·이스케이프 안 된 $NAME(뒤가 영숫자·_ 아님)·${NAME} 만 바꾼다. 대입 구간은 남긴다(토큰 판정 유지).
#   명령 전체 불채택(원문 그대로 = 종전 판정) — && (oio bash_exec 분할기가 && 에서 나눠 따로 실행하므로 대입이 이어지지 않는다) ·
#     IFS · CR · 따옴표 밖 또는 큰따옴표 안의 백틱·$( · 따옴표 밖 $' · $" · 따옴표 밖 ( ) { }(${NAME}·${NAME:?}·${NAME?} 꼴 제외) ·
#     따옴표 불균형. 작은따옴표 안 내용(하네스 데이터 인자 등)은 실행되지 않으므로 이 검사에서 뺀다(NEW-O15).
#   따옴표 밖 제어 예약어(if then else elif fi while until for do done case esac select function coproc)를 본 뒤의 대입은 모으지 않는다
#     (S1b — 조건부·반복 안 대입을 머리 대입으로 오인하지 않는다. 그 앞 대입의 참조는 뒤에서도 치환한다).
#   heredoc(따옴표 밖 <<)이 있으면 그 줄 끝까지만 다룬다 — 본문과 그 뒤 줄은 원문 그대로(본문 줄을 대입으로 오인하지 않는다).
#   따옴표 밖 단어 첫 # 는 줄 끝까지 주석으로 건너뛴다.
# c206 S1b: 참조 치환 — $1=문자열 $2=이름 $3=값 → stdout. 작은따옴표 밖·이스케이프 안 된 $NAME(뒤가 영숫자·_ 아님)·${NAME} 만 바꾼다.
_gpg_ref_sub() {
  local _s="$1" _nm="$2" _v="$3" _n _i _c _q="" _o="" _m
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then _o+="$_c"; [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_c" == \\ ]]; then _o+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue; fi
    if [[ "$_c" == '"' ]]; then [[ "$_q" == '"' ]] && _q="" || _q='"'; _o+="$_c"; continue; fi
    [[ "$_q" != '"' && "$_c" == "'" ]] && { _q="'"; _o+="$_c"; continue; }
    if [[ "$_c" == '$' ]] && [[ "${_s:_i:258}" =~ ^\$\{$_nm\} || "${_s:_i:258}" =~ ^\$$_nm([^A-Za-z0-9_]|$) ]]; then
      _m="${BASH_REMATCH[0]}"; [[ "$_m" == *'}' ]] || _m="\$$_nm"
      _o+="$_v"; _i=$((_i + ${#_m} - 1)); continue
    fi
    _o+="$_c"
  done
  printf '%s' "$_o"
}

# c206 S1b: 리터럴 단어 목록 for 펼치기 — 명령에 따옴표 밖 예약어가 정확히 for · in · do · done 4개(이 순서)이고,
#   for 가 구간 머리(명령 시작 · ; · 개행 뒤)에 있고, 목록 단어가 모두 리터럴(_gpg_lit_subst 값 규칙)이며 16개 이하,
#   done 뒤가 끝·; ·개행뿐(리다이렉트·파이프 없음)이고, 반복 변수 이름이 본문 밖에 나오지 않으며 본문 안에서는 $NAME·${NAME} 참조로만
#   나올 때 — for NAME in W1 W2; do BODY; done 을 BODY[NAME=W1]⏎BODY[NAME=W2] 로 바꾼다(판정 전용 — 실행하지 않는다).
#   본문이 단어마다 한 번씩 실행되는 것과 같은 판정이다(break·continue 는 실행을 줄일 뿐이므로 펼친 쪽이 더 엄격하다).
#   heredoc·주석·따옴표 불균형·조건 불충족이면 원본 그대로.
_gpg_for_unroll() {  # $1=명령 → stdout
  local _s="$1" _n _i _c _q="" _ws=1 _pf _pi _pd _pe _pre _nm _wl _bd _suf _t _w _o="" _cnt
  local -a _kw=() _kp=() _ws_a=()
  local _VB='[][$`\\(){}*?;|&<>#!~^"'\''[:cntrl:]]'
  [[ "$_s" == *for* && "$_s" == *done* ]] || { printf '%s' "$_s"; return 0; }
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_q" == '"' ]]; then case "$_c" in \\) _i=$((_i+1)) ;; \") _q="" ;; esac; continue; fi
    case "$_c" in
      \'|\") _q="$_c"; _ws=0 ;;
      \\) _i=$((_i+1)); _ws=0 ;;
      ' '|$'\t'|$'\n'|\;|\||\&|\>) _ws=1 ;;
      \<) [[ "${_s:_i+1:1}" == "<" ]] && { printf '%s' "$_s"; return 0; }; _ws=1 ;;
      \#) [[ $_ws -eq 1 ]] && { printf '%s' "$_s"; return 0; }; _ws=0 ;;
      *) if [[ $_ws -eq 1 && "${_s:_i:10}" =~ ^(if|then|else|elif|fi|while|until|for|do|done|case|esac|select|function|coproc|in)([[:space:]\;]|$) ]]; then
           _kw+=("${BASH_REMATCH[1]}"); _kp+=("$_i")
         fi
         _ws=0 ;;
    esac
  done
  [[ -z "$_q" && ${#_kw[@]} -eq 4 && "${_kw[*]}" == "for in do done" ]] || { printf '%s' "$_s"; return 0; }
  _pf=${_kp[0]}; _pi=${_kp[1]}; _pd=${_kp[2]}; _pe=${_kp[3]}
  _pre="${_s:0:_pf}"; _t="${_pre%"${_pre##*[![:space:]]}"}"
  [[ -z "$_t" || "$_t" == *';' || "$_t" == *$'\n' ]] || { printf '%s' "$_s"; return 0; }
  _nm="${_s:_pf+3:_pi-_pf-3}"; _nm="${_nm//[[:space:]]/}"
  [[ "$_nm" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf '%s' "$_s"; return 0; }
  _wl="${_s:_pi+2:_pd-_pi-2}"; _wl="${_wl%"${_wl##*[![:space:]]}"}"
  [[ "$_wl" == *';' || "$_wl" == *$'\n' ]] || { printf '%s' "$_s"; return 0; }
  _wl="${_wl%?}"
  [[ "$_wl" =~ $_VB ]] && { printf '%s' "$_s"; return 0; }
  read -r -a _ws_a <<<"$_wl"
  [[ ${#_ws_a[@]} -ge 1 && ${#_ws_a[@]} -le 16 ]] || { printf '%s' "$_s"; return 0; }
  _bd="${_s:_pd+2:_pe-_pd-2}"
  [[ "$_bd" == [[:space:]]* ]] || { printf '%s' "$_s"; return 0; }
  _bd="${_bd%"${_bd##*[![:space:]]}"}"
  [[ "$_bd" == *';' || "$_bd" == *$'\n' ]] || { printf '%s' "$_s"; return 0; }
  _bd="${_bd%?}"
  _suf="${_s:_pe+4}"
  [[ "$_suf" =~ ^[[:space:]]*($|\;|$'\n') ]] || { printf '%s' "$_s"; return 0; }
  # 반복 변수 이름 — 본문 밖(앞·뒤)에는 없고, 본문에서는 참조 꼴로만
  _t="$_pre$_suf"
  [[ "$_t" =~ (^|[^A-Za-z0-9_])${_nm}([^A-Za-z0-9_]|$) ]] && { printf '%s' "$_s"; return 0; }
  _t="${_bd//\$\{$_nm\}/ }"
  while [[ "$_t" =~ \$${_nm}([^A-Za-z0-9_]|$) ]]; do _t="${_t/"${BASH_REMATCH[0]}"/" ${BASH_REMATCH[1]}"}"; done
  [[ "$_t" =~ (^|[^A-Za-z0-9_])${_nm}([^A-Za-z0-9_]|$) ]] && { printf '%s' "$_s"; return 0; }
  _o="$_pre"
  for _w in "${_ws_a[@]}"; do _o+="$(_gpg_ref_sub "$_bd" "$_nm" "$_w")"$'\n'; done
  printf '%s' "$_o$_suf"
}

# bashc ⑤: lit_subst 보조 — $1=명령 $2=<< 위치 $3=그 줄 끝(개행 위치 또는 길이) → rc 0 이면 인용 종결자 heredoc 이고 _HDE=종결자 줄 끝 위치
#   조건: << 바로 뒤가 [-][공백]'W' 또는 "W"(같은 따옴표 짝), 그 줄 나머지에 << 없음, 본문 뒤 종결자 줄(<<- 는 앞 탭 허용)이 있다.
_gpg_ls_hdskip() {
  local _s="$1" _i="$2" _k="$3" _r _dash _w _p _e _ln _n=${#1}
  _r="${_s:_i+2:_k-_i-2}"
  [[ "$_r" =~ ^(-?)[[:space:]]*([\'\"])([A-Za-z_][A-Za-z0-9_]*)([\'\"]) ]] || return 1
  [[ "${BASH_REMATCH[2]}" == "${BASH_REMATCH[4]}" ]] || return 1
  _dash="${BASH_REMATCH[1]}"; _w="${BASH_REMATCH[3]}"
  [[ "${_r:${#BASH_REMATCH[0]}}" != *'<<'* ]] || return 1
  [[ $_k -lt $_n ]] || return 1
  _p=$((_k+1))
  while [[ $_p -le $_n ]]; do
    _e=$_p
    while [[ $_e -lt $_n && "${_s:_e:1}" != $'\n' ]]; do _e=$((_e+1)); done
    _ln="${_s:_p:_e-_p}"
    if [[ -n "$_dash" ]]; then while [[ "$_ln" == $'\t'* ]]; do _ln="${_ln#$'\t'}"; done; fi
    [[ "$_ln" == "$_w" ]] && { _HDE=$_e; return 0; }
    [[ $_e -lt $_n ]] || return 1
    _p=$((_e+1))
  done
  return 1
}

_gpg_lit_subst() {  # $1=명령 → stdout: 치환한 명령(조건 불충족이면 원본)
  local _s="$1" _n _i _c _q="" _stop _head=1 _ws=1 _lnb="" _j _k _e _t _nm _v _o="" _cnt _m
  local -A _LV=() _LE=()
  local _VB='[][$`\\(){}*?;|&<>#!~^"'\''[:cntrl:]]'
  local _SP='^(HOME|PWD|OLDPWD|IFS|PATH|CDPATH|ENV|BASH[A-Z0-9_]*|LD_[A-Z0-9_]*|GLOBIGNORE|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND)$'
  # && · IFS · CR 은 따옴표와 무관하게 불채택(oio 분할기는 따옴표 안 && 에서도 나눌 수 있다). 백틱·$( ·$' ·$" ·예약어는
  #   작은따옴표 안 데이터(하네스 인자 등)에 있어도 실행되지 않으므로 1차 주사에서 따옴표 밖·큰따옴표 안일 때만 불채택한다(NEW-O15).
  # c217: && 가 있어도 치환을 시도한다 — 호출부(_gpg_shell)가 값 치환(A)·빈값 치환(B) 두 해석을 모두 통과해야 통과시킨다(_GPG_LS_BLANK).
  if [[ "$_s" != *'$'* || "$_s" == *IFS* || "$_s" == *$'\r'* ]]; then
    printf '%s' "$_s"; return 0
  fi
  # S1b(odev-6 17·18): source · . · eval 은 보이지 않는 대입(파일·문자열)으로 변수를 바꿀 수 있다 — 있으면 치환하지 않는다
  if [[ "$_s" =~ (^|[\;\&\|[:space:]\(])(source|eval)([[:space:]]|$) ]]; then printf '%s' "$_s"; return 0; fi
  # [overblock P1c R-C2] '.'(source) 는 명령 위치에서만 센다 — 인자 '.'(jq -c . · --project .)는 변수를 바꾸지 못한다.
  #   명령 위치 = 문자열 처음 또는 ; & | ( ) { } ! 개행 뒤, 또는 예약어·command·builtin·exec·time·coproc 뒤(사이 공백 허용). 그 밖의 '.' 단어는 인자다.
  local _DOT='(^|[;&|(){}!'$'\n'']|(^|[^A-Za-z0-9_])(then|do|else|elif|if|while|until|time|command|builtin|exec|coproc))[[:space:]]*[.]([[:space:]]|$)'
  if [[ "$_s" =~ $_DOT ]]; then printf '%s' "$_s"; return 0; fi
  local _kwseen=0                                 # S1b: 따옴표 밖 예약어를 본 뒤에는 머리 대입을 더 모으지 않는다(조건부·반복 안 대입)
  local -a _SKF=() _SKT=()                        # bashc ⑤: 건너뛸 인용 heredoc 본문 [여는 줄 끝 개행, 종결자 줄 끝)
  local _skx=0 _HDE
  # bashc ⑥ⓑ: 숫자 전용 산술 토큰. 안의 이름은 아래에서 숫자 대입만 받는지 검증한다.
  local -A _ARN=()
  local _ARX='^\$\(\(([A-Za-z0-9_ +*/%-]*)\)\)$' _ARC='^[A-Za-z0-9_ +*/%-]*$' _ART='\$\(\([A-Za-z0-9_ +*/%-]*\)\)'
  _n=${#_s}; _stop=$_n
  # 1차 — 구조 검사 + 구간 머리 순수 대입 수집
  for (( _i=0; _i<_stop; _i++ )); do
    # 여는 줄 끝 개행을 이스케이프 등으로 건너뛰었으면(줄 잇기) 본문 경계가 달라진다 — 그 위치에서 멈춘다(종전과 같은 판정)
    if [[ $_skx -lt ${#_SKF[@]} && $_i -gt ${_SKF[$_skx]} ]]; then _stop=${_SKF[$_skx]}; break; fi
    if [[ $_skx -lt ${#_SKF[@]} && $_i -eq ${_SKF[$_skx]} ]]; then
      [[ -z "$_q" ]] || { _stop=$_i; break; }     # 여는 줄 끝에서 따옴표가 열려 있으면 본문 경계를 확정할 수 없다 — 여기서 멈춘다
      _i=${_SKT[$_skx]}; _skx=$((_skx+1))
      [[ $_i -lt $_stop ]] || break
    fi
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_q" == '"' ]]; then
      case "$_c" in
        \\) _i=$((_i+1)) ;;
        \") _q="" ;;
        # [overblock P1d R-F] 큰따옴표 안 명령 치환은 짝을 찾아 건너뛴다(서브셸은 바깥 변수를 바꾸지 못한다). 판정 불가면 종전대로 포기
        \`) _gpg_bq_end "$_s" "$_i" || { printf '%s' "$_s"; return 0; }; _i=$_GPG_SE ;;
        \$) if [[ "${_s:_i+1:1}" == "(" ]]; then
              [[ "${_s:_i+2:1}" != "(" ]] && _gpg_sub_end "$_s" "$_i" || { printf '%s' "$_s"; return 0; }
              _i=$_GPG_SE
            fi ;;
      esac
      continue
    fi
    if [[ $_ws -eq 1 && "$_c" == [a-z] && "${_s:_i:10}" =~ ^(if|then|else|elif|fi|while|until|for|do|done|case|esac|select|function|coproc)([^A-Za-z0-9_./-]|$) ]]; then
      _kwseen=1
    fi
    if [[ $_head -eq 1 ]]; then
      case "$_c" in ' '|$'\t') continue ;; esac
      _head=0
      if [[ $_kwseen -eq 0 && "${_s:_i:256}" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        _nm="${BASH_REMATCH[1]}"; _j=$((_i + ${#_nm} + 1)); _e=-1; _t="${_s:_j:1}"
        if [[ "$_t" == "'" || "$_t" == '"' ]]; then
          _k=$((_j+1))
          while [[ $_k -lt $_n && "${_s:_k:1}" != "$_t" ]]; do _k=$((_k+1)); done
          if [[ $_k -lt $_n ]]; then _v="${_s:_j+1:_k-_j-1}"; _e=$((_k+1)); fi
        else
          _k=$_j
          while [[ $_k -lt $_n ]]; do case "${_s:_k:1}" in ' '|$'\t'|\;|$'\n') break ;; esac; _k=$((_k+1)); done
          _v="${_s:_j:_k-_j}"; _e=$_k
        fi
        if [[ $_e -ge 0 && ! "$_v" =~ $_VB && ! "$_nm" =~ $_SP ]]; then
          _k=$_e
          while [[ $_k -lt $_n && ( "${_s:_k:1}" == ' ' || "${_s:_k:1}" == $'\t' ) ]]; do _k=$((_k+1)); done
          if [[ $_k -ge $_n || "${_s:_k:1}" == ';' || "${_s:_k:1}" == $'\n' ]]; then
            # [overblock P1c R-C] 같은 이름의 머리 대입이 또 나와도 값이 같으면 치환을 유지한다(값이 다르면 종전대로 미치환)
            if [[ -n "${_LE[$_nm]+x}" ]]; then [[ "${_LV[$_nm]}" == "$_v" ]] || _LE[$_nm]=-1; else _LV[$_nm]="$_v"; _LE[$_nm]=$_e; fi
            _i=$((_e-1)); _ws=0; _lnb="="; continue
          fi
        fi
      fi
    fi
    case "$_c" in
      \'|\") _q="$_c"; _ws=0; _lnb="$_c" ;;
      \\) _i=$((_i+1)); _ws=0; _lnb="\\" ;;           # 이스케이프 — 다음 글자는 글자(\개행 = 줄 잇기, 머리 아님)
      \;) _head=1; _ws=1; _lnb=";" ;;
      $'\n') [[ "$_lnb" == "|" || "$_lnb" == "&" ]] || _head=1; _ws=1; _lnb=$'\n' ;;
      ' '|$'\t') _ws=1 ;;
      \`) _gpg_bq_end "$_s" "$_i" || { printf '%s' "$_s"; return 0; }; _i=$_GPG_SE; _ws=0; _lnb=")" ;;   # [overblock P1d R-F]
      \(|\)|\{|\}) printf '%s' "$_s"; return 0 ;;
      \$) if [[ "${_s:_i:2}" == '$(' && "${_s:_i:3}" != '$((' ]]; then   # [overblock P1d R-F] 명령 치환은 짝을 찾아 건너뛴다
            _gpg_sub_end "$_s" "$_i" || { printf '%s' "$_s"; return 0; }
            _i=$_GPG_SE; _ws=0; _lnb=")"; continue
          fi
          if [[ "${_s:_i:3}" == '$((' ]]; then
            _k="${_s:_i+3}"; _k="${_k%%'))'*}"
            [[ "${_s:_i+3+${#_k}:2}" == '))' && "$_k" =~ $_ARC ]] || { printf '%s' "$_s"; return 0; }
            for _j in ${_k//[^A-Za-z0-9_]/ }; do [[ "$_j" =~ ^[A-Za-z_] ]] && _ARN[$_j]=1; done
            _i=$((_i + 4 + ${#_k})); _ws=0; _lnb=")"; continue
          fi
          [[ "${_s:_i+1:1}" == "'" || "${_s:_i+1:1}" == '"' ]] && { printf '%s' "$_s"; return 0; }   # $'…' · $"…"
          if [[ "${_s:_i+1:1}" == "{" ]]; then
            # ${NAME} · ${NAME:?} · ${NAME?} (S1b — F-DESTROY-2 가 권장하는 빈 값 보장 꼴. 값이 비어 있지 않으면 값과 같다)
            [[ "${_s:_i:258}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*(:?\?)?\} ]] || { printf '%s' "$_s"; return 0; }
            _i=$((_i + ${#BASH_REMATCH[0]} - 1))
          fi
          _ws=0; _lnb="\$" ;;
      \#) if [[ $_ws -eq 1 ]]; then                    # 주석 — 줄 끝까지 건너뛴다(앞 _lnb 는 유지: | 뒤 주석 다음 줄은 사슬)
            while [[ $((_i+1)) -lt $_n && "${_s:_i+1:1}" != $'\n' ]]; do _i=$((_i+1)); done
          else _lnb="#"; fi
          _ws=0 ;;
      \<) if [[ "${_s:_i+1:1}" == "<" ]]; then
            _k=$_i
            while [[ $_k -lt $_n && "${_s:_k:1}" != $'\n' ]]; do _k=$((_k+1)); done
            # bashc ⑤: 인용 종결자 heredoc(줄에 << 하나)이면 본문은 셸 전개가 없는 데이터다 — 본문을 건너뛰고 뒤 줄도 치환한다(대상 리터럴화).
            #   비인용·<<< ·한 줄에 << 둘 이상·종결자 줄 없음은 종전대로 그 줄 끝에서 멈춘다.
            if [[ ${#_SKF[@]} -gt 0 && "${_SKF[-1]}" == "$_k" ]] || ! _gpg_ls_hdskip "$_s" "$_i" "$_k"; then
              [[ $_k -lt $_stop ]] && _stop=$_k
            else
              _SKF+=("$_k"); _SKT+=("$_HDE")
            fi
          fi
          _ws=1; _lnb="<" ;;
      \||\&|\>) _ws=1; _lnb="$_c" ;;
      *) _ws=0; _lnb="$_c" ;;
    esac
  done
  [[ -z "$_q" && ${#_LE[@]} -gt 0 ]] || { printf '%s' "$_s"; return 0; }
  # bashc ⑥ⓑ: 산술 안 이름은 머리에서 숫자 리터럴·같은 꼴 산술만 대입되고, 다른 문맥에 쓰이지 않아야 한다.
  local _apre _aval
  for _nm in "${!_ARN[@]}"; do
    _t="$_s"; _cnt=0
    while [[ $_cnt -lt 64 && "$_t" =~ (^|[^A-Za-z0-9_])${_nm}=([^[:space:]\;]*) ]]; do
      _cnt=$((_cnt+1)); _m="${BASH_REMATCH[0]}"; _aval="${BASH_REMATCH[2]}"
      _apre="${_t%%"$_m"*}${BASH_REMATCH[1]}"; _apre="${_apre%"${_apre##*[![:space:]]}"}"
      [[ "$_aval" =~ ^[0-9]+$ || "$_aval" =~ $_ARX ]] || { printf '%s' "$_s"; return 0; }
      [[ -z "$_apre" || "$_apre" == *';' || "$_apre" == *$'\n' || "$_apre" =~ (^|[[:space:]\;])(do|then|else)$ ]] || { printf '%s' "$_s"; return 0; }
      _t="${_t/"$_m"/"${BASH_REMATCH[1]}#"}"
    done
    while [[ "$_t" =~ $_ART ]]; do _t="${_t/"${BASH_REMATCH[0]}"/ }"; done
    _t="${_t//\$\{$_nm\}/ }"
    while [[ "$_t" =~ \$${_nm}([^A-Za-z0-9_]|$) ]]; do _m="${BASH_REMATCH[0]}"; _t="${_t/"$_m"/ ${BASH_REMATCH[1]}}"; done
    [[ "$_t" =~ (^|[^A-Za-z0-9_])${_nm}([^A-Za-z0-9_]|$) ]] && { printf '%s' "$_s"; return 0; }
  done
  # 이름별 출현 검사 — 대입 1곳 + $NAME·${NAME} 참조 외의 꼴이 있으면 그 이름은 치환하지 않는다
  for _nm in "${!_LE[@]}"; do
    [[ ${_LE[$_nm]} -ge 0 ]] || continue
    _t="${_s//\$\{$_nm\}/ }"; _t="${_t//\$\{$_nm:\?\}/ }"; _t="${_t//\$\{$_nm\?\}/ }"
    while [[ "$_t" =~ \$${_nm}([^A-Za-z0-9_]|$) ]]; do _m="${BASH_REMATCH[0]}"; _t="${_t/"$_m"/" ${BASH_REMATCH[1]}"}"; done
    # [overblock P1c R-C] NAME=<머리 대입과 같은 값> 꼴(재해석 인자 안 재대입 포함)은 모두 지운 뒤 남은 출현이 0 이어야 한다.
    #   값이 다른 대입·값 없는 대입·다른 꼴 출현이 하나라도 있으면 종전대로 미치환이다.
    local _rsv=0
    while [[ $_rsv -lt 8 && "$_t" =~ (^|[^A-Za-z0-9_])${_nm}=([^[:space:]\;\'\"\&\|]*) ]]; do
      [[ "${BASH_REMATCH[2]}" == "${_LV[$_nm]}" ]] || break
      _m="${BASH_REMATCH[0]}"; _t="${_t/"$_m"/"${BASH_REMATCH[1]}#"}"; _rsv=$((_rsv+1))
    done
    _cnt=0
    while [[ $_cnt -lt 8 && "$_t" =~ (^|[^A-Za-z0-9_])${_nm}([^A-Za-z0-9_]|$) ]]; do
      _cnt=$((_cnt+1)); _m="${BASH_REMATCH[0]}"; _t="${_t/"$_m"/"${BASH_REMATCH[1]}#${BASH_REMATCH[2]}"}"
    done
    if [[ $_rsv -ge 1 ]]; then [[ $_cnt -eq 0 ]] || _LE[$_nm]=-1; else [[ $_cnt -eq 1 ]] || _LE[$_nm]=-1; fi
  done
  # 2차 — 대입 뒤 참조를 값으로 바꾼다(작은따옴표 안·이스케이프·주석은 그대로)
  _q=""; _ws=1; _skx=0
  for (( _i=0; _i<_stop; _i++ )); do
    if [[ $_skx -lt ${#_SKF[@]} && $_i -eq ${_SKF[$_skx]} ]]; then   # bashc ⑤: 인용 heredoc 본문은 글자 그대로 옮긴다
      _o+="${_s:_i:${_SKT[$_skx]}-_i}"; _i=${_SKT[$_skx]}; _skx=$((_skx+1))
      [[ $_i -lt $_stop ]] || break
    fi
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then _o+="$_c"; [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_c" == \\ ]]; then
      _o+="$_c"; if (( _i + 1 < _stop )); then _o+="${_s:_i+1:1}"; _i=$((_i+1)); fi
      _ws=0; continue
    fi
    if [[ "$_q" == '"' ]]; then
      [[ "$_c" == '"' ]] && _q=""
      [[ "$_c" == '$' ]] || { _o+="$_c"; continue; }
    else
      case "$_c" in
        \'|\") _q="$_c"; _o+="$_c"; _ws=0; continue ;;
        \#) if [[ $_ws -eq 1 ]]; then
              while [[ $_i -lt $_stop && "${_s:_i:1}" != $'\n' ]]; do _o+="${_s:_i:1}"; _i=$((_i+1)); done
              _i=$((_i-1)); continue
            fi ;;
        ' '|$'\t'|$'\n'|\;|\||\&|\<|\>) _o+="$_c"; _ws=1; continue ;;
      esac
      _ws=0
      [[ "$_c" == '$' ]] || { _o+="$_c"; continue; }
    fi
    if [[ "${_s:_i:258}" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)(:?\?)?\} || "${_s:_i:258}" =~ ^\$([A-Za-z_][A-Za-z0-9_]*) ]]; then
      _m="${BASH_REMATCH[0]}"; _nm="${BASH_REMATCH[1]}"
      if [[ -n "${_LE[$_nm]+x}" ]] && [[ ${_LE[$_nm]} -ge 0 && $_i -ge ${_LE[$_nm]} ]] \
         && [[ "$_m" != *'?}' || -n "${_LV[$_nm]}" ]]; then
        if [[ "${_GPG_LS_BLANK:-0}" == 1 ]]; then _o+=""; else _o+="${_LV[$_nm]}"; fi   # c217 B 해석: 앞 구간 대입이 전달되지 않는 실행 — 빈 값
      else _o+="$_m"; fi   # ${X:?} 는 값이 있을 때만
      _i=$((_i + ${#_m} - 1)); continue
    fi
    _o+="$_c"
  done
  _o+="${_s:_stop}"
  printf '%s' "$_o"
}

# c206 S1b: 미확정 변수 보호 디렉터리 경로 판정 — $1=명령 → rc 0 이면 차단
#   따옴표 밖 ; | & 개행으로 구간을 나누고(따옴표·역슬래시 글자는 지운다 — 판정용), 구간에 동적 보호 경로 단어
#   ((hooks|..)/(lib|tests|backup|logs)/ 뒤에 $ · .claude/ 뒤 $ 가 든 디렉터리를 거쳐 /lib·tests·backup·logs)가 있고
#   그 구간이 쓰기 수단(_gpg_wm_re·tee·git 쓰기 하위 명령)이거나 그 단어가 쓰기 리다이렉트 대상이면 차단한다.
#   조회 구간(cat <hooks>/lib/$f > /tmp/o — 대상 비보호)은 통과한다.
# relpath(pd-a2 2026-11-08): ../lib · ../tests · ../backup · ../logs 가 hooks 보호 디렉터리일 수 없음이 확실하면 0 을 낸다.
#   종전 _hd·_gpg_dyn_check 는 ../(lib|tests|backup|logs) 를 실행 위치와 무관하게 hooks 보호 디렉터리로 봤다(hooks/candidates 탈출 대비).
#   그래서 저장소 안 ../../../logs/… 같은 상대 경로를 쓰는 해석기·리다이렉트 명령이 모두 막혔다.
#   ".. 가 hooks/<하위> 에서 출발할 수 없다" 가 확실할 때만 그 대안을 뺀다 — 조건(전부):
#   ① 명령에 hooks 단어가 없다. ② 기준 위치(tool_input.working_dir·cwd·workdir, 없으면 INPUT .cwd)가 절대 경로이고 realpath 가 hooks 성분을 품지
#   않으며 ${HARNESS_HOME:-$HOME/.harness}/current/hooks 아래가 아니다. ③ 명령의 cd·pushd 대상이 모두 리터럴(글자·숫자·_ . / @ % + : , = - 만, - 단독 제외)이거나
#   $NAME[/리터럴] 이고, 리터럴은 기준 위치로 붙인 realpath 가 ②와 같은 검사를 통과한다. $NAME 은 명령 안의 모든 NAME= 대입이 리터럴이고
#   각각 같은 검사를 통과해야 한다(대입이 없거나 하나라도 비리터럴이면 탈락). 어느 하나라도 어기면 종전 판정 그대로다.
#   한계: 미리 만든 심볼릭 링크로 hooks/<하위> 에 들어가 이름 없이 ../lib 를 지우는 2단계는 같은 uid 기존 한계와 같은 등급이다(realpath 가 이미 있는 링크는 푼다).
_gpg_dd_dir_ok() {  # $1=경로 $2=hooks realpath → 0: hooks 밖
  local _r
  _r=$(realpath -m -- "$1" 2>/dev/null) || return 1
  [[ -n "$_r" && "$_r" == /* ]] || return 1
  [[ "${_r,,}" =~ (^|/)hooks(/|$) ]] && return 1
  [[ -n "$2" && ( "$_r" == "$2" || "$_r" == "$2"/* ) ]] && return 1
  return 0
}
_gpg_dd_var_ok() {  # $1=명령 $2=이름 $3=기준 위치 $4=hooks realpath $5=접미 → 0: 모든 대입이 리터럴이고 hooks 밖
  local _s="$1" _v _n=0 _re="(^|[^A-Za-z0-9_])$2=([^[:space:];&|]*)"
  while [[ "$_s" =~ $_re ]]; do
    _v="${BASH_REMATCH[2]}"; _s="${_s/"${BASH_REMATCH[0]}"/ }"; _n=$((_n+1))
    _v="${_v//[\'\"]/}"
    [[ "$_v" =~ ^[A-Za-z0-9_./@%+:,=-]+$ ]] || return 1
    [[ "$_v" == /* ]] || _v="${3%/}/$_v"
    _gpg_dd_dir_ok "$_v$5" "$4" || return 1
    [[ $_n -lt 16 ]] || return 1
  done
  [[ $_n -ge 1 ]]
}
_gpg_dd_free() {  # $1=원본 명령 → 0: ../{lib,tests,backup,logs} 가 hooks 보호 디렉터리일 수 없다
  local _s="$1" _b _t _hr _nm _sx
  local _re='(^|[^A-Za-z0-9_.-])(cd|pushd)[[:space:]]+([^[:space:];&|)]+)'
  [[ "${1,,}" =~ (^|[^a-z0-9_])hooks([^a-z0-9_]|$) ]] && return 1
  _hr=$(realpath -m -- "${HARNESS_HOME:-$HOME/.harness}/current/hooks" 2>/dev/null)
  _b=$(jq -r '[.tool_input.working_dir,.tool_input.cwd,.tool_input.workdir,.cwd] | map(select(type=="string" and . != ""))[0] // empty' <<<"$INPUT" 2>/dev/null)
  [[ "$_b" == /* ]] || return 1
  _gpg_dd_dir_ok "$_b" "$_hr" || return 1
  while [[ "$_s" =~ $_re ]]; do
    _t="${BASH_REMATCH[3]}"; _s="${_s/"${BASH_REMATCH[0]}"/ }"
    _t="${_t//[\'\"]/}"
    [[ "$_t" == "-" ]] && return 1
    if [[ "$_t" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[A-Za-z0-9_./@%+:,=-]*)?$ ]]; then
      _nm="${BASH_REMATCH[1]}"; _sx="${BASH_REMATCH[2]}"
      _gpg_dd_var_ok "$1" "$_nm" "$_b" "$_hr" "$_sx" || return 1
      continue
    fi
    [[ "$_t" =~ ^[A-Za-z0-9_./@%+:,=-]+$ ]] || return 1
    [[ "$_t" == /* ]] || _t="${_b%/}/$_t"
    _gpg_dd_dir_ok "$_t" "$_hr" || return 1
  done
  return 0
}

# relpath(pd-a2 2026-11-08) R2: 해석기 쓰기 규칙의 hooks 조건에서 조회 구간 속 hooks 경로를 뺀다 — $1=_hn(소문자·따옴표 제거본) → stdout
#   구간(; & 개행 사이)이 조회 명령(grep·rg·ls·cat·head·tail·wc·sha256sum·md5sum·stat·du·diff·cmp) 하나이고 $·백틱·< > 가 없으며
#   (무해 리다이렉트 2>/dev/null·2>&1 은 먼저 지운다) 끝이 구간 구분자이거나 조회 꼬리(| head·tail·cut·sort·uniq·wc·grep)뿐이면 그 구간을 비운다.
#   해석기 본문·쓰기 구간 안의 hooks 경로는 그대로 남아 종전처럼 막힌다. 다른 규칙(토큰·미확정 변수·재해석)은 이 사본을 쓰지 않는다.
_gpg_hn_ro() {
  local _s="$1" _m _nl=$'\n'
  while [[ "$_s" =~ [0-9]*\>\>?[[:space:]]*(/dev/(null|stdout|stderr)|\&[0-9-]) ]]; do _s="${_s/"${BASH_REMATCH[0]}"/ }"; done
  local _ar="[^;|&<>\`\$${_nl}]*"
  local _re="(^|[;&${_nl}])[[:space:]]*(grep|egrep|fgrep|rg|ls|cat|head|tail|wc|sha256sum|md5sum|stat|du|diff|cmp)([[:space:]]${_ar})?(\|[[:space:]]*(head|tail|cut|sort|uniq|wc|grep)([[:space:]]${_ar})?)*([;&${_nl}]|$)"
  local _k=0
  while [[ "$_s" =~ $_re ]]; do
    _m="${BASH_REMATCH[0]}"; _s="${_s/"$_m"/"${BASH_REMATCH[1]} ; "}"
    _k=$((_k+1)); [[ $_k -lt 64 ]] || break
  done
  printf '%s' "$_s"
}

# relpath(pd-a2 2026-11-08) R3: '조회 단위들 ; python <<'W' … W' 꼴 — $1=원본 명령 → 0: 앞 단위가 모두 조회(G3 판정)이고 마지막 python heredoc 한 호출이
#   분류기(gp_pyclass) SAFE 다. 두 부분을 따로 실행한 것과 같다(조회는 쓰지 않고, python 쓰기 대상은 분류기가 비보호 절대 리터럴로 확정).
#   앞부분에 << 가 있거나, 분해가 불확실하거나, 조회가 아닌 단위가 하나라도 있으면 rc 1(종전 판정).
_gpg_pyhd_combo() {
  local _s="$1" _pre _py _u _nl=$'\n' _ok=1
  local _re="^(.*[;${_nl}])[[:space:]]*(python[0-9.]*([[:space:]]+-[A-Za-z]+)*([[:space:]]+-)?[[:space:]]*<<-?[[:space:]]*['\"][A-Za-z_][A-Za-z0-9_]*['\"][^${_nl}]*${_nl}.*)$"
  [[ "$_s" =~ $_re ]] || return 1
  _pre="${BASH_REMATCH[1]}"; _py="${BASH_REMATCH[2]}"
  _pre="${_pre%?}"
  [[ "$_pre" =~ [^[:space:]] && "$_pre" != *'<<'* ]] || return 1
  _gpg_py_safe "$_py" || return 1
  _GPG_RO=1
  if _gpg_units "$_pre" 1; then
    for _u in "${_GPG_U[@]}"; do
      [[ "$_u" =~ [^[:space:]] ]] || continue
      _gpg_unit_readonly "$_u" || _gpg_unit_litassign "$_u" || { _ok=0; break; }
    done
  else
    _ok=0
  fi
  _GPG_RO=0; _GPG_U=()
  [[ $_ok -eq 1 ]]
}

_gpg_dyn_check() {
  local _s="$1" _n _i _c _q="" _seg="" _l
  local -a _S=()
  local _dp='((hooks|\.\.)/(lib|tests|backup|logs)/[^[:space:]]*[$]|\.claude/[^[:space:]]*[$][^[:space:]]*/(lib|tests|backup|logs)([/[:space:]]|$))'
  local _dr='>>?\|?[[:space:]]*[^[:space:]]*((hooks|\.\.)/(lib|tests|backup|logs)/[^[:space:]]*[$]|\.claude/[^[:space:]]*[$][^[:space:]]*/(lib|tests|backup|logs)([/[:space:]]|$))'
  if [[ "${_GPG_DDF:-0}" == 1 ]]; then   # relpath(pd-a2 2026-11-08)
    _dp='(hooks/(lib|tests|backup|logs)/[^[:space:]]*[$]|\.claude/[^[:space:]]*[$][^[:space:]]*/(lib|tests|backup|logs)([/[:space:]]|$))'
    _dr='>>?\|?[[:space:]]*[^[:space:]]*(hooks/(lib|tests|backup|logs)/[^[:space:]]*[$]|\.claude/[^[:space:]]*[$][^[:space:]]*/(lib|tests|backup|logs)([/[:space:]]|$))'
  fi
  [[ "$_s" == *'$'* ]] || return 1
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q="" || _seg+="$_c"; continue; fi
    if [[ "$_q" == '"' ]]; then
      case "$_c" in \") _q="" ;; \\) _seg+="${_s:_i+1:1}"; _i=$((_i+1)) ;; *) _seg+="$_c" ;; esac; continue
    fi
    case "$_c" in
      \'|\") _q="$_c" ;;
      \\) _seg+="${_s:_i+1:1}"; _i=$((_i+1)) ;;
      \;|\||$'\n') _S+=("$_seg"); _seg="" ;;
      \&) if [[ "${_s:_i+1:1}" == ">" || "${_seg: -1}" == ">" || "${_seg: -1}" == "<" ]]; then _seg+="$_c"; else _S+=("$_seg"); _seg=""; fi ;;
      *) _seg+="$_c" ;;
    esac
  done
  _S+=("$_seg")
  # cd·pushd 로 hooks 보호 디렉터리(또는 hooks 자체)에 들어간 뒤에는 미확정 변수($NAME·${…})가 든 쓰기 구간도 막는다
  #   (cd <hooks>/lib; read f < x; cp y $f — 상대 이름이 변수에 숨는다).
  local _cdp=0 _cdr='^[[:space:]]*(cd|pushd)[[:space:]]+([^[:space:]]+)' _cdt='(^|/)hooks(/(lib|tests|backup|logs)(/guard_promote)?)?/?$'
  local _gg
  local -a _gw=()
  for _seg in "${_S[@]}"; do
    _l="${_seg,,}"
    if [[ "$_l" =~ $_cdr ]]; then [[ "${BASH_REMATCH[2]}" =~ $_cdt ]] && _cdp=1; continue; fi
    # unblock3: git 머리 구간은 쓰기 리다이렉트 대상만 본다(git 쓰기 하위 명령·rm·mv 단어는 쓰기 수단이 아니다)
    _gg=0; read -r -a _gw <<<"$_seg"; _gpg_git_safe "${_gw[@]}" && _gg=1
    if [[ $_cdp -eq 1 && "$_l" =~ [$][a-z_{] ]]; then
      [[ $_gg -eq 0 ]] && _gpg_wm_re "$_l" && return 0
      [[ ( $_gg -eq 0 && "$_l" =~ ${_GPG_B}tee${_GPG_E} ) || "$_l" =~ \>\>?\|?[[:space:]]*[^[:space:]]*[$][a-z_{] ]] && return 0
    fi
    [[ "$_l" =~ $_dp ]] || continue
    [[ "$_l" =~ $_dr ]] && return 0
    [[ $_gg -eq 1 ]] && continue
    _gpg_wm_re "$_l" && return 0
    [[ "$_l" =~ ${_GPG_B}tee${_GPG_E} ]] && return 0
    [[ "$_l" =~ ${_GPG_B}git([[:space:]][^\;\|\&]*)?[[:space:]](${_GPG_GITW})${_GPG_E} ]] && return 0
  done
  return 1
}

# c206 S1c: 따옴표 안 내용·이스케이프 글자를 공백으로 지운다 — 리다이렉트(>) 존재 판정용(따옴표 안 '9>>' 같은 글자는 리다이렉트가 아니다).
#   따옴표 밖 글자만 남으므로 진짜 미인용 > 만 보인다. odev-4 11:15 원문(grep -c '9>>' 가 _any 를 잘못 켜 ls 글로브가 걸림).
#   단 리다이렉트 ★대상★ 의 따옴표(> "경로")는 보존한다 — 대상은 실제 쓰기 경로이므로 토큰 판정에 필요하다(GG-D26 git commit -m >"보호").
#   리다이렉트 대기(_rp)는 따옴표 밖 > 뒤에 서고, 공백은 유지하며 다음 토큰(따옴표/비따옴표)을 대상으로 보존한 뒤 다음 글자에서 해제한다.
_gpg_unq() {  # $1=명령 → stdout(인자 따옴표 내용은 공백, 리다이렉트 대상 따옴표 내용은 보존)
  local _s="$1" _n=${#1} _i _c _q="" _o="" _rp=0
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then
      [[ "$_c" == "'" ]] && { _q=""; continue; }
      [[ $_rp -eq 1 ]] && _o+="$_c" || _o+=" "; continue
    fi
    if [[ "$_q" == '"' ]]; then
      case "$_c" in
        \\) [[ $_rp -eq 1 ]] && _o+=" ${_s:_i+1:1}" || _o+="  "; _i=$((_i+1)) ;;
        \") _q="" ;;
        *) [[ $_rp -eq 1 ]] && _o+="$_c" || _o+=" " ;;
      esac; continue
    fi
    case "$_c" in
      \') _q="'" ;;
      \") _q='"' ;;
      \\) _o+="  "; _i=$((_i+1)) ;;
      \>) _o+="$_c"; _rp=1 ;;
      ' '|$'\t') _o+="$_c" ;;                 # 공백은 리다이렉트 대기를 유지(> "경로")
      *) _o+="$_c"; _rp=0 ;;
    esac
  done
  printf '%s' "$_o"
}

# c214 R3: python 단독 호출 분류 — $1=명령 원문 → rc 0 이면 쓰기 대상이 보호 파일이 아님이 확정(SAFE)
#   분류기 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/gp_pyclass.py(등록부 gp_pyclass)가 명령 형태(python 한 호출뿐 — ; && | 다른 명령·따옴표 밖 $·
#   백틱·비인용 heredoc 없음)와 코드 AST(쓰기 지점 경로가 절대 경로 리터럴이고 보호 표식·hooks 보호 디렉터리 아님, 동적 실행·
#   허용 밖 import·별칭 없음)를 본다. env 파라미터가 있으면 쓰지 않는다. 판정 불가는 모두 rc 1(종전 판정).
_gpg_py_safe() {
  local _c="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/gp_pyclass.py" _py _o
  [[ -f "$_c" && ! -L "$_c" ]] || return 1
  [[ "$1" != *$'\r'* ]] || return 1
  _o=$(jq -r '[.env,.environ,.environment] | map(select(type=="object" and length>0)) | length' <<<"$_GPG_TI" 2>/dev/null)
  [[ "$_o" == 0 ]] || return 1
  _py=$(command -v python3 2>/dev/null) || return 1
  _o=$(printf '%s' "$1" | timeout 3 "$_py" -I -S "$_c" --hooks "${HARNESS_HOME:-$HOME/.harness}/current/hooks" 2>/dev/null) || return 1
  [[ "${_o%%$'\n'*}" == SAFE ]]
}

# bashc ④(odone B1, 2026-10-27): G3 단위 하나가 python -c '<코드>' 한 호출이면 그 단위만 분류기에 넘긴다 → rc 0 이면 조회 단위로 본다.
#   결합 명령(cd … && ls … ; python3 -c "json.load(open(등록부))" ; git …)에서 python 이 쓰기 수단으로 남던 과차단을 푼다.
#   위치 인자에 보호 경로가 있으면 분류기가 거부한다(종전 GG-U05·GG-T10·C214R3-D13 차단 유지). G3 의 따옴표 안 글로브 표식은 되돌려 넘긴다.
# K1(TODO-034, 2026-11-06 gp_pypipe): python -c 단위 뒤 파이프 꼬리 분리 — $1=단위 → rc 0 이면 _GPG_PYH = 첫 파이프 앞 python 부분.
#   첫 따옴표 밖 | (|| 아님) 뒤 꼬리가 엄격 읽기 전용 명령 사슬일 때만 성립한다. 꼬리 글자는 영숫자·_ . , : = + - 공백·| 뿐이다
#   ($ · 백틱 · 따옴표 · / · ~ · 글로브 · 리다이렉트 < > · ; & 없음 — 파일 쓰기·치환·경로 인자가 들어설 자리가 없다).
#   꼬리 명령은 head·tail·wc·cut·grep·jq 와, 옵션만 쓰는 uniq(두 번째 피연산자 = 출력 파일 차단), -o·--o… 옵션이 없는 sort 뿐이다.
#   tee·sh·bash·python·xargs·sed·awk 등 그 밖의 명령이 하나라도 있으면 rc 1(종전 판정). python 부분은 호출부가 분류기로 다시 본다.
_gpg_pytail_split() {
  local _s="$1" _n _i _c _q="" _t _seg _x
  local _tre='^[-A-Za-z0-9_.,:=+[:space:]|]*$'
  local -a _sg=() _w=()
  _GPG_PYH=""
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_q" == '"' ]]; then
      if [[ "$_c" == \\ ]]; then _i=$((_i+1)); continue; fi
      [[ "$_c" == '"' ]] && _q=""
      continue
    fi
    case "$_c" in
      \\) _i=$((_i+1)) ;;
      \'|\") _q="$_c" ;;
      \|) break ;;
    esac
  done
  [[ -z "$_q" && $_i -lt $_n && "${_s:_i+1:1}" != "|" ]] || return 1
  _t="${_s:_i+1}"
  [[ "$_t" =~ $_tre && "$_t" != *'||'* && "$_t" =~ [^[:space:]][[:space:]]*$ && "$_t" != *'|' ]] || return 1
  IFS='|' read -r -a _sg <<<"$_t"
  [[ ${#_sg[@]} -ge 1 ]] || return 1
  for _seg in "${_sg[@]}"; do
    read -r -a _w <<<"$_seg"
    [[ ${#_w[@]} -ge 1 ]] || return 1
    case "${_w[0]}" in
      head|tail|wc|cut|grep|jq) ;;
      uniq) for _x in "${_w[@]:1}"; do [[ "$_x" == -* ]] || return 1; done ;;
      sort) for _x in "${_w[@]:1}"; do [[ "$_x" == --o* || "$_x" =~ ^-[A-Za-z]*o ]] && return 1; done ;;
      *) return 1 ;;
    esac
  done
  _GPG_PYH="${_s:0:_i}"
  _GPG_PYH="${_GPG_PYH%"${_GPG_PYH##*[![:space:]]}"}"
  [[ -n "$_GPG_PYH" ]]
}

_gpg_unit_pysafe() {  # $1=단위 → rc 0 SAFE
  local _u="$1"
  _u="${_u#"${_u%%[![:space:]]*}"}"; _u="${_u%"${_u##*[![:space:]]}"}"
  [[ "$_u" =~ ^python[0-9.]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-c[[:space:]] ]] || return 1
  _u=$(printf '%s' "$_u" | tr '\003\004\005' '*?[')
  _gpg_py_safe "$_u" && return 0
  # K1(TODO-034): 읽기 전용 파이프 꼬리(| head -3 등)는 떼고 python 부분만 분류기에 넘긴다 — 꼬리 조건 불충족이면 종전 판정
  _gpg_pytail_split "$_u" || return 1
  _gpg_py_safe "$_GPG_PYH"
}

# bashc ⑥ⓑ(사용자 지시 2026-10-27 16:59 "승격기 보호 가드 git show 과차단도 풀어라"): 스크립트 파일 해석기 구간 판정.
#   $1=구간(따옴표 제거본 가능) → rc 0 이면 쓰기 지점이 전부 비보호 절대 리터럴인 python 스크립트 한 호출이다(쓰기 수단으로 세지 않는다).
#   형태: python[0-9.]* <절대경로 .py> [인자…] [2>&1 | 2>/dev/null | >/dev/null]. 앞 VAR=값 접두 없음, 인자에 $( · 백틱 · <( · >( · 리다이렉트가 없다.
#   명령 어디든 PYTHON*= 대입(import 경로 가로채기)이 있으면 판정하지 않는다.
#   스크립트: 정규 파일·심볼릭 아님·realpath 가 hooks 보호 디렉터리(lib·tests·backup·logs)와 보호 파일 밖·256KiB 이하.
#   판정: 내용을 인용 종결자 heredoc(python3 - <<'GPGSCRIPT')로 감싸 분류기(gp_pyclass, 무수정)에 넘겨 SAFE 일 때만 —
#   분류기는 쓰기 경로가 리터럴이 아니면(sys.argv 유래 포함) UNSAFE 를 낸다. 인자는 읽기 대상이라 보호 경로여도 된다.
#   잔존 한계: 판정 뒤 실행 전 스크립트 내용이 바뀌는 시간차, 스크립트 디렉터리에 심은 모듈 import 는 막지 못한다(같은 uid 2단계 등급).
_gpg_pyscript_safe() {
  local _s="$1" _sp _rp _sz _body _l _h _cmd _scan
  local _env_re='(^|[^a-z0-9_])(python[a-z0-9_]*|ld_[a-z0-9_]*|path|bash_env|env|ifs)[[:space:]]*='
  local _ctl_re='(^|[^a-z0-9_])(export|declare|typeset|local|readonly|set|env|read|mapfile|readarray|hash|enable|alias|source|eval|exec|function)([^a-z0-9_]|$)'
  local -a _w=()
  _cmd=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GPG_TI" 2>/dev/null)
  _scan="${_cmd//[\'\"\\]/}"
  _scan="${_scan,,}"
  [[ ! "$_scan" =~ $_env_re && ! "$_scan" =~ $_ctl_re ]] || return 1
  [[ "$_scan" != *'()'* ]] || return 1
  [[ ! "$_scan" =~ (^|[\;\|\&[:space:]])[[:space:]]*\.([[:space:]]|$) ]] || return 1
  [[ ! "$_scan" =~ (^|[^a-z0-9_])printf[[:space:]]+-v([^a-z0-9_]|$) ]] || return 1
  [[ "$_s" != *'$('* && "$_s" != *'`'* && "$_s" != *'<('* && "$_s" != *'>('* && "$_s" != *$'\n'* && "$_s" != *$'\r'* ]] || return 1
  _s="${_s#"${_s%%[![:space:]]*}"}"; _s="${_s%"${_s##*[![:space:]]}"}"
  # K11(D-15, 2026-11-06): 앞 'timeout [옵션] <시간>' 접두는 실행 시간 제한일 뿐이다 — 벗기고 같은 판정을 한다.
  #   옵션은 -k/--kill-after·-s/--signal(값은 숫자·영문)·--foreground·--preserve-status·-v 만, 시간은 숫자[smhd]. 그 밖 꼴은 종전 판정.
  local _tmo='^timeout([[:space:]]+(-k[[:space:]]*[0-9.]+[smhd]?|--kill-after=[0-9.]+[smhd]?|-s[[:space:]]*[A-Za-z0-9]+|--signal=[A-Za-z0-9]+|--foreground|--preserve-status|-v|--verbose))*[[:space:]]+[0-9.]+[smhd]?[[:space:]]+(python[0-9.]*[[:space:]].*)$'
  [[ "$_s" =~ $_tmo ]] && _s="${BASH_REMATCH[3]}"
  # import 경로 가로채기(PYTHONPATH·PYTHONHOME·PYTHONSTARTUP 등) 대입이 명령 어디에든 있으면 판정하지 않는다(접두 대입도 거부 — 아래 첫 단어 검사)
  [[ "$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GPG_TI" 2>/dev/null)" =~ PYTHON[A-Z_]*[[:space:]]*= ]] && return 1
  [[ "$_s" =~ ^(.*[^[:space:]])[[:space:]]+(2\>\&1|2\>/dev/null|\>/dev/null)$ ]] && _s="${BASH_REMATCH[1]}"
  [[ "$_s" != *[\<\>\;\|\&]* ]] || return 1
  read -r -a _w <<<"$_s"
  [[ ${#_w[@]} -ge 2 && "${_w[0]}" =~ ^python[0-9.]*$ ]] || return 1
  _sp="${_w[1]}"
  [[ "$_sp" == /*.py && "$_sp" != *'$'* && "$_sp" != *[\*\?\[\{~]* ]] || return 1
  [[ -f "$_sp" && ! -L "$_sp" ]] || return 1
  _rp=$(realpath -e -- "$_sp" 2>/dev/null) || return 1
  for _l in "$_sp" "$_rp"; do
    _h="${_l,,}"
    [[ "$_h" =~ (^|/)hooks/+(lib|tests|backup|logs)(/|$) ]] && return 1
    _gpg_prot "$_l" 1 && return 1
  done
  _sz=$(stat -c %s -- "$_rp" 2>/dev/null) || return 1
  [[ "$_sz" =~ ^[0-9]+$ && "$_sz" -le 262144 ]] || return 1
  _body=$(cat -- "$_rp" 2>/dev/null) || return 1
  [[ "$_body" != *$'\r'* ]] || return 1
  while IFS= read -r _l; do [[ "$_l" == GPGSCRIPT* ]] && return 1; done <<<"$_body"
  _gpg_py_safe "python3 - <<'GPGSCRIPT'"$'\n'"${_body}"$'\n'"GPGSCRIPT"$'\n'
}

# bashc ⑥ⓑ: 명령($1, 따옴표 제거·대소문자 보존)에서 _gpg_pyscript_safe 구간을 비운 사본 — 쓰기 수단 단어 판정(_gpg_wm_re)용.
#   구간 구분자(; | & 개행)는 보존한다. 판정이 불확실한 구간은 그대로 둔다(종전 판정).
# K11(D-15, 2026-11-06): 결합 명령의 python 구간 판정 — $1=원본 명령 → rc 0 이면 python 이 든 최상위 구간(; & 개행, 따옴표·괄호 깊이 존중)이
#   모두 분류기 SAFE 인 python -c 단위(_gpg_unit_pysafe — 읽기 전용 파이프 꼬리 포함)이거나 스크립트 한 호출(_gpg_pyscript_safe)이다.
#   python 이 명령 치환·괄호 안·다른 명령 인자 자리에 있거나, 큰따옴표 안 $( · 백틱, 따옴표·괄호 불균형이면 rc 1(종전 판정).
_gpg_pyc_allsafe() {
  local _s="$1" _n _i _c _q="" _d=0 _cur="" _any=0 _seg
  local -a _sg=()
  [[ "${_s,,}" == *python* && "$_s" != *$'\r'* ]] || return 1
  _n=${#_s}
  for (( _i=0; _i<_n; _i++ )); do
    _c="${_s:_i:1}"
    if [[ "$_q" == "'" ]]; then _cur+="$_c"; [[ "$_c" == "'" ]] && _q=""; continue; fi
    if [[ "$_c" == \\ ]]; then _cur+="$_c${_s:_i+1:1}"; _i=$((_i+1)); continue; fi
    if [[ "$_q" == '"' ]]; then
      [[ "$_c" == '`' || ( "$_c" == '$' && "${_s:_i+1:1}" == '(' ) ]] && return 1
      _cur+="$_c"; [[ "$_c" == '"' ]] && _q=""
      continue
    fi
    case "$_c" in
      \'|\") _q="$_c"; _cur+="$_c" ;;
      '`') return 1 ;;
      '(') _d=$((_d+1)); _cur+="$_c" ;;
      ')') _d=$((_d-1)); [[ $_d -ge 0 ]] || return 1; _cur+="$_c" ;;
      ';'|'&'|$'\n') if [[ $_d -eq 0 ]]; then _sg+=("$_cur"); _cur=""; else _cur+="$_c"; fi ;;
      *) _cur+="$_c" ;;
    esac
  done
  [[ -z "$_q" && $_d -eq 0 ]] || return 1
  _sg+=("$_cur")
  for _seg in "${_sg[@]}"; do
    [[ "${_seg,,}" == *python* ]] || continue
    _any=1
    _gpg_unit_pysafe "$_seg" || _gpg_pyscript_safe "$_seg" || return 1
  done
  [[ $_any -eq 1 ]]
}

# K11: $1(따옴표 제거본)에서 python[0-9.]* 명령 단어만 공백으로 바꾼다(_GPG_B·_GPG_E 와 같은 경계) — _gpg_pyc_allsafe 성립 때만 쓴다
_gpg_py_unword() {
  local _s="$1" _re='(^|[^a-zA-Z0-9_.-])python[0-9.]*([^a-zA-Z0-9_./-]|$)'
  while [[ "$_s" =~ $_re ]]; do _s="${_s/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"}"; done
  printf '%s' "$_s"
}

_gpg_py_mask() {
  local _s="$1" _o="" _seg _sep _nl=$'\n'
  local _sp="^([^;|&${_nl}]*)([;|&${_nl}]*)(.*)$"
  [[ "${_s,,}" == *python* ]] || { printf '%s' "$_s"; return 0; }
  while [[ -n "$_s" ]]; do
    [[ "$_s" =~ $_sp ]] || { _o+="$_s"; break; }
    _seg="${BASH_REMATCH[1]}"; _sep="${BASH_REMATCH[2]}"; _s="${BASH_REMATCH[3]}"
    if [[ "${_seg,,}" == *python* ]] && _gpg_pyscript_safe "$_seg"; then _o+=" $_sep"; continue; fi
    _o+="$_seg$_sep"
  done
  printf '%s' "$_o"
}

# bashc ⑥ⓐ(사용자 지시 2026-10-27 16:59 "승격기 보호 가드 git show 과차단도 풀어라"): 토큰 목적지 리다이렉트 판정 — $1=명령 → rc 0 이면 차단.
#   미인용 리다이렉트(> >> >|) 대상 단어에 보호 토큰 글자가 있을 때, 대상이 확정된 절대 리터럴(/ 로 시작, $ · 백틱 · 글로브 · 중괄호 · ~ ·
#   따옴표 · 글로브 표식 없음)이면 글자 대신 실제 경로(_gpg_prot 대상 1 — 보호 파일·hooks 보호 디렉터리, realpath 포함)로 판정한다
#   (git show HEAD:<보호 파일> > <scratch>/old_test_gp_gate.sh 통과). 대상이 미확정(변수·치환·상대 경로)이면 종전대로 글자 판정이다.
_gpg_tokdst_hit() {
  local _s _w _t
  _s=$(_gpg_unq "$1")
  while [[ "$_s" =~ \>\>?\|?[[:space:]]*([^[:space:]\;\|\&\<\>]*) ]]; do
    _w="${BASH_REMATCH[1]}"
    _s="${_s#*"${BASH_REMATCH[0]}"}"
    _t="${_w,,}"; _t="${_t//[\{\},]/}"
    while [[ "$_t" =~ (test_guard_promote|test_gp_boot)[a-z0-9_.-]*\.sh ]]; do _t="${_t/"${BASH_REMATCH[0]}"/ }"; done
    [[ "$_t" =~ $_GPG_TOK ]] || continue
    if [[ "$_w" == /* && "$_w" != *[\$\`\*\?\[\{\}~\'\"\\]* && "$_w" != *[$'\003\004\005']* ]]; then
      _gpg_prot "$_w" 1 && return 0
      continue
    fi
    return 0
  done
  return 1
}

# [overblock P1b] 재해석 규칙 전용 — 쓰기 대상 단어 하나가 hooks 밖 절대 리터럴인가. $1=단어 → rc 0 이면 안전.
#   / 로 시작하고 $·백틱·글로브·중괄호·~·따옴표·역슬래시·괄호·<>·; | & #·공백·글로브 표식·.. 가 없으며, 글자와 realpath 어디에도
#   hooks 성분이 없고 보호 파일·보호 디렉터리·그 상위(_gpg_prot 대상 1)가 아니어야 한다. 남은 $ 는 출신(이스케이프·작은따옴표)과 무관하게 거부한다.
_gpg_rx_tgt_ok() {
  local _t="$1" _r
  [[ "$_t" == /* ]] || return 1
  [[ "$_t" != *[\$\`\*\?\[\]\{\}~\\\'\"\(\)\<\>\;\|\&\#[:space:]]* && "$_t" != *[$'\003\004\005']* && "$_t" != *..* ]] || return 1
  [[ "${_t,,}" =~ (^|/)hooks(/|$) ]] && return 1
  _r=$(realpath -m -- "$_t" 2>/dev/null) || return 1
  [[ -n "$_r" && ! "${_r,,}" =~ (^|/)hooks(/|$) ]] || return 1
  _gpg_prot "$_t" 1 && return 1
  return 0
}

# [overblock P1b] 재해석 규칙 전용 — 쓰기 명령(cp·install·mv·ln·rename·tee) 구간의 대상이 모두 안전한가. $1=명령 이름 $2…=뒤 단어 → rc 0 이면 안전.
#   cp·install 은 목적지(마지막 피연산자), mv·ln·rename 은 피연산자 전부, tee 는 인자 전부를 본다. 출력 리다이렉트 대상도 안전해야 한다
#   (/dev/null·/dev/std*·&N 제외). 대상이 옵션으로 바뀌는 꼴(-t·--target-directory·install -d·--directory)·값 옵션 묶음·피연산자 부족은 rc 1.
_gpg_rx_wr_ok() {
  local _c="$1" _w _i=0 _n _rt _end=0 _t
  shift
  local -a _a=("$@") _ops=()
  _n=${#_a[@]}
  while (( _i < _n )); do
    _w="${_a[_i]}"; _i=$((_i + 1))
    if [[ "$_w" =~ ^[0-9]*(\>\>?\|?|\&\>\>?)(.*)$ ]]; then
      _rt="${BASH_REMATCH[2]}"
      case "$_rt" in /dev/null|/dev/stdout|/dev/stderr|'&'[0-9]|'&-') continue ;; esac
      _gpg_rx_tgt_ok "$_rt" || return 1
      continue
    fi
    [[ "$_w" =~ ^[0-9]*\< ]] && continue
    if (( _end == 0 )) && [[ "$_w" == -?* ]]; then
      if [[ "$_w" == -- ]]; then _end=1; continue; fi
      if [[ "$_w" == --* ]]; then
        case "$_w" in
          --target-directory*|--directory) return 1 ;;
          --suffix|--mode|--owner|--group) _i=$((_i + 1)) ;;
        esac
        continue
      fi
      [[ "$_w" == *t* ]] && return 1
      [[ "$_c" == install && "$_w" == *d* ]] && return 1
      if [[ "$_w" == *[Smog]* ]]; then
        [[ ${#_w} -eq 2 ]] || return 1
        _i=$((_i + 1))
      fi
      continue
    fi
    _ops+=("$_w")
  done
  case "$_c" in
    cp|install) (( ${#_ops[@]} >= 2 )) || return 1; _gpg_rx_tgt_ok "${_ops[-1]}" || return 1 ;;
    mv|ln) (( ${#_ops[@]} >= 2 )) || return 1
      for _t in "${_ops[@]}"; do _gpg_rx_tgt_ok "$_t" || return 1; done ;;
    rename) (( ${#_ops[@]} >= 1 )) || return 1
      for _t in "${_ops[@]}"; do _gpg_rx_tgt_ok "$_t" || return 1; done ;;
    tee) for _t in "${_ops[@]}"; do _gpg_rx_tgt_ok "$_t" || return 1; done ;;
    *) return 1 ;;
  esac
  return 0
}

# [overblock P1c R-A] 재해석 규칙 전용 — 단어가 변수·치환·글로브·따옴표·~·괄호·구분자·공백·.. 없는 리터럴인가. $1=단어 → rc 0 이면 리터럴.
_gpg_rx_lit() {
  local _t="$1"
  [[ -n "$_t" ]] || return 1
  [[ "$_t" != *[\$\`\*\?\[\]\{\}~\\\'\"\(\)\<\>\;\|\&\#[:space:]]* && "$_t" != *[$'\003\004\005']* && "$_t" != *..* ]]
}

# [overblock P1b] 재해석 규칙 전용 — 단순 명령 하나(단어 배열)를 판정한다. $1=깊이 $2…=단어 → rc 0 이면 이 구간은 쓰기 수단으로 세지 않는다.
#   앞붙이 { } ! do then else elif if while until done fi time nohup setsid(옵션) exec command builtin · NAME=값 · timeout [옵션] 시간 은 건너뛴다.
#   sh·bash·dash·zsh·ksh(·busybox 셸)의 -c 스크립트와 eval 인자는 같은 규칙으로 다시 분해한다(재해석 인자 안팎 무관, 깊이 3 까지).
#   쓰기 명령은 _gpg_rx_wr_ok, 그 밖의 명령은 종전 쓰기 단어 판정(_gpg_wm_re·tee 단어)에 걸리지 않을 때만 rc 0.
_gpg_rx_seg() {
  local _d="$1" _i=0 _n _w _c _cs=0 _sc="" _rest=""
  shift
  local -a _a=("$@")
  _n=${#_a[@]}
  (( _n > 0 )) || return 0
  while (( _i < _n )); do
    _w="${_a[_i]}"
    case "$_w" in
      '{'|'}'|'!'|do|then|else|elif|if|while|until|done|fi|time|nohup|exec|command|builtin) _i=$((_i + 1)); continue ;;
      setsid) _i=$((_i + 1)); while (( _i < _n )) && [[ "${_a[_i]}" == -* ]]; do _i=$((_i + 1)); done; continue ;;
      timeout)
        _i=$((_i + 1))
        while (( _i < _n )) && [[ "${_a[_i]}" == -* ]]; do _i=$((_i + 1)); done
        _i=$((_i + 1)); continue ;;
    esac
    [[ "$_w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && { _i=$((_i + 1)); continue; }
    break
  done
  (( _i < _n )) || return 0
  # [overblock P1d R-F] 명령 자리에 치환 결과가 오면(동적 명령 — $(echo rm) -f …) 판정할 수 없다
  [[ "${_a[_i]}" == *'$(_)'* ]] && return 1
  # [overblock P1d R-K] c201 H 판정(_GPG_RXH=1)에서는 이 구간의 출력 리다이렉트 대상도 모두 hooks 밖 절대 리터럴이어야 한다
  if [[ "${_GPG_RXH:-0}" == 1 ]]; then
    for _w in "${_a[@]}"; do
      if [[ "$_w" =~ ^[0-9]*(\>\>?\|?|\&\>\>?)(.*)$ ]]; then
        case "${BASH_REMATCH[2]}" in /dev/null|/dev/stdout|/dev/stderr|'&'[0-9]|'&-') continue ;; esac
        _gpg_rx_tgt_ok "${BASH_REMATCH[2]}" || return 1
      fi
    done
  fi
  _c="${_a[_i]##*/}"
  if [[ "$_c" == busybox && $((_i + 1)) -lt $_n && "${_a[_i+1]}" =~ ^(sh|ash|bash)$ ]]; then _i=$((_i + 1)); _c="${_a[_i]}"; fi
  case "$_c" in
    sh|bash|dash|zsh|ksh|ash)
      _i=$((_i + 1))
      while (( _i < _n )); do
        _w="${_a[_i]}"
        if [[ "$_w" == [-+]?* ]]; then
          case "$_w" in -o|+o|-O|+O) _i=$((_i + 2)); continue ;; esac
          [[ "$_w" != --* && "$_w" == *c* ]] && _cs=1
          _i=$((_i + 1)); continue
        fi
        break
      done
      if (( _cs )); then
        (( _i < _n )) || return 1
        _sc="${_a[_i]}"; _i=$((_i + 1))
        [[ "$_sc" == *'$(_)'* ]] && return 1   # [overblock P1d R-F] 치환 결과가 스크립트
        (( _d < 3 )) || return 1
        _gpg_rx_scan "$_sc" $((_d + 1)) || return 1
      fi
      _rest="${_a[*]:_i}"
      _gpg_wm_re "$_rest" && return 1
      [[ "${_rest,,}" =~ ${_GPG_B}tee${_GPG_E} ]] && return 1
      return 0 ;;
    eval)
      (( _d < 3 )) || return 1
      [[ "${_a[*]:_i+1}" == *'$(_)'* ]] && return 1   # [overblock P1d R-F] 치환 결과를 eval
      _gpg_rx_scan "${_a[*]:_i+1}" $((_d + 1))
      return $? ;;
    cp|install|mv|ln|rename|tee)
      _gpg_rx_wr_ok "$_c" "${_a[@]:_i+1}"
      return $? ;;
  esac
  # [overblock P1b · team-lead 결정 2026-11-05 17:05] 계획서 §1-1a '대상 추출 실패는 fail-closed' 의 예외 — 해석기(python)의 리터럴 스크립트 파일 실행 구간.
  #   재해석 없이 python3 <파일> <hooks 경로> 를 실행하는 것은 종전에도 통과하므로, 재해석 안에서 같은 꼴을 허용해도 새 능력이 생기지 않는다(같은 uid 2단계 기존 한계).
  #   스크립트 경로가 변수·치환·글로브·~ 없는 리터럴이고 .. 가 없으며 글자·realpath 어디에도 hooks 성분이 없고 보호 대상이 아닐 때만 뺀다(상대경로 허용).
  #   -c 코드 · - · -m 모듈 · 입력 리다이렉트 < · 스크립트 없음(표준입력)은 종전대로 센다. 출력 리다이렉트 대상은 _gpg_rx_tgt_ok 로 본다.
  if [[ "$_c" =~ ^python[0-9.]*$ ]]; then
    local _j=$((_i + 1)) _pw _ps="" _pr
    while (( _j < _n )); do
      _pw="${_a[_j]}"; _j=$((_j + 1))
      if [[ "$_pw" =~ ^[0-9]*(\>\>?\|?|\&\>\>?)(.*)$ ]]; then
        case "${BASH_REMATCH[2]}" in /dev/null|/dev/stdout|/dev/stderr|'&'[0-9]|'&-') continue ;; esac
        _gpg_rx_tgt_ok "${BASH_REMATCH[2]}" || return 1
        continue
      fi
      # [overblock P1c R-A] 깊이 0(재해석 인자 밖)에서는 리터럴 파일 표준입력(< 파일)을 자료로 본다. <<·<<<·<&·변수·치환·글로브는 종전대로 센다.
      if [[ "$_pw" =~ ^[0-9]*\<(.*)$ ]]; then
        (( _d == 0 )) && _gpg_rx_lit "${BASH_REMATCH[1]}" && continue
        return 1
      fi
      [[ -n "$_ps" ]] && continue
      case "$_pw" in
        -|-m*) return 1 ;;
        -W|-X) _j=$((_j + 1)) ;;
        --*) ;;
        -*) if [[ "$_pw" == *c* ]]; then
              # [overblock P1d R-F] -c 코드는 분류기(gp_pyclass)가 SAFE 일 때만 쓰기로 세지 않는다
              [[ "$_pw" =~ ^-[A-Za-z]*c$ ]] && _gpg_rx_pyc "${_a[@]:_j}" && return 0
              return 1
            fi ;;
        *) _ps="$_pw" ;;
      esac
    done
    [[ -n "$_ps" ]] || return 1
    # [overblock P1d R-K] c201 H 판정 전용 — 변수 경로 스크립트 실행은 그 자체로 쓰기가 아니다(재대입 없는 같은 꼴은 종전 통과)
    [[ "${_GPG_RXH:-0}" == 1 ]] && _gpg_rxh_pyvar "$_ps" && return 0
    [[ "$_ps" != *[\$\`\*\?\[\]\{\}~\\\'\"\(\)\<\>\;\|\&\#[:space:]]* && "$_ps" != *[$'\003\004\005']* && "$_ps" != *..* ]] || return 1
    # [overblock P1c R-A] 깊이 0(재해석 인자 밖)의 hooks 안 리터럴 스크립트 실행은 재해석이 없을 때와 같은 꼴이라 뺀다.
    #   재해석 인자 안(깊이 1 이상)은 종전대로 hooks 성분이 있으면 센다(P1v). 보호 대상(_gpg_prot 1)·..·변수 경로는 깊이와 무관하게 센다.
    if (( _d > 0 )); then
      [[ "${_ps,,}" =~ (^|/)hooks(/|$) ]] && return 1
      _pr=$(realpath -m -- "$_ps" 2>/dev/null) || return 1
      [[ -n "$_pr" && ! "${_pr,,}" =~ (^|/)hooks(/|$) ]] || return 1
    fi
    _gpg_prot "$_ps" 1 && return 1
    return 0
  fi
  _rest="${_a[*]:_i}"
  _gpg_wm_re "$(_gpg_git_mask "$(_gpg_py_mask "$_rest")")" && return 1
  [[ "${_rest,,}" =~ ${_GPG_B}tee${_GPG_E} ]] && return 1
  return 0
}

# [overblock P1b] 재해석 규칙 전용 — 명령 문자열을 따옴표를 존중해 단순 명령(; | & 개행 ( ) 경계)으로 나눠 _gpg_rx_seg 로 판정한다.
#   $1=문자열 $2=깊이 → rc 0 이면 쓰기 단어가 있는 구간이 모두 안전한 쓰기 구간이다(이 규칙의 쓰기 수단 없음).
#   리다이렉트는 연산자와 대상 단어를 한 단어로 붙인다. 따옴표 불균형·끝 역슬래시·대상 없는 리다이렉트는 rc 1.
#   깊이 0 에서는 원문의 && 가 모두 따옴표 밖 연산자여야 한다(oio 는 따옴표·역슬래시와 무관하게 && 에서 나눈다 — 분해 불일치 차단).
_gpg_rx_scan() {
  local _s="$1" _d="${2:-0}" _n _i=0 _c _q="" _w="" _hw=0 _nx _rop="" _amp=0 _x
  local -a _ws=()
  [[ "$_s" != *$'\r'* ]] || return 1
  _n=${#_s}
  while (( _i <= _n )); do
    if (( _i == _n )); then _c=$'\n'; else _c="${_s:_i:1}"; fi
    if [[ -n "$_q" ]]; then
      (( _i < _n )) || return 1
      if [[ "$_q" == "'" ]]; then
        [[ "$_c" == "'" ]] && _q="" || _w+="$_c"
      else
        case "$_c" in
          '"') _q="" ;;
          \\) _nx="${_s:_i+1:1}"
              case "$_nx" in '$'|'`'|'"'|\\) _w+="$_nx"; _i=$((_i + 1)) ;; $'\n') _i=$((_i + 1)) ;; *) _w+="\\" ;; esac ;;
          # [overblock P1d R-F] 큰따옴표 안 명령 치환 — 안 명령을 같은 규칙으로 재귀 판정하고 결과 자리는 미확정 표식 $(_) 로 둔다
          '$') if [[ "${_s:_i+1:1}" == '(' && "${_s:_i+2:1}" != '(' ]]; then
                 _gpg_rx_subst "$_s" "$_i" "$_d" || return 1
                 _amp=$((_amp + _GPG_RXA)); _w+='$(_)'; _i=$_GPG_SE
               else _w+="$_c"; fi ;;
          '`') _gpg_rx_subst "$_s" "$_i" "$_d" || return 1
               _amp=$((_amp + _GPG_RXA)); _w+='$(_)'; _i=$_GPG_SE ;;
          *) _w+="$_c" ;;
        esac
      fi
      _i=$((_i + 1)); continue
    fi
    case "$_c" in
      "'"|'"') _q="$_c"; _hw=1 ;;
      \\) (( _i + 1 < _n )) || return 1
          _nx="${_s:_i+1:1}"; [[ "$_nx" == $'\n' ]] || { _w+="$_nx"; _hw=1; }; _i=$((_i + 1)) ;;
      '#') if (( _hw )); then _w+="#"; else while (( _i < _n )) && [[ "${_s:_i:1}" != $'\n' ]]; do _i=$((_i + 1)); done; continue; fi ;;
      ' '|$'\t'|'>'|'<'|';'|'|'|'&'|$'\n'|'('|')')
        if [[ "$_c" == '&' && "${_s:_i+1:1}" == '>' ]] || [[ "$_c" == '>' || "$_c" == '<' ]]; then
          # 리다이렉트 연산자 — 앞 단어가 숫자뿐이면 fd 로 붙인다
          if (( _hw )) && [[ ! "$_w" =~ ^[0-9]+$ ]]; then
            if [[ -n "$_rop" ]]; then _ws+=("$_rop$_w"); _rop=""; else _ws+=("$_w"); fi
            _w=""; _hw=0
          fi
          [[ -z "$_rop" ]] || return 1
          _x="$_w"; _w=""; _hw=0
          while (( _i < _n )) && [[ "${_s:_i:1}" == [\<\>\&\|] ]]; do _x+="${_s:_i:1}"; _i=$((_i + 1)); done
          if [[ "$_x" == *'&' ]] && [[ "${_s:_i:1}" == [0-9-] ]]; then
            while (( _i < _n )) && [[ "${_s:_i:1}" == [0-9-] ]]; do _x+="${_s:_i:1}"; _i=$((_i + 1)); done
            _ws+=("$_x")
          else
            _rop="$_x"
          fi
          continue
        fi
        if (( _hw )); then
          if [[ -n "$_rop" ]]; then _ws+=("$_rop$_w"); _rop=""; else _ws+=("$_w"); fi
          _w=""; _hw=0
        fi
        if [[ "$_c" != ' ' && "$_c" != $'\t' ]]; then
          [[ -z "$_rop" ]] || return 1
          [[ "$_c" == '&' && "${_s:_i+1:1}" == '&' ]] && { _amp=$((_amp + 1)); _i=$((_i + 1)); }
          [[ "$_c" == '|' && "${_s:_i+1:1}" == '|' ]] && _i=$((_i + 1))
          _gpg_rx_seg "$_d" "${_ws[@]}" || return 1
          _ws=()
        fi ;;
      # [overblock P1d R-F] 따옴표 밖 명령 치환 — 재귀 판정 후 미확정 표식. 산술 $((…)) 는 종전대로 글자로 둔다
      '$') if [[ "${_s:_i+1:1}" == '(' && "${_s:_i+2:1}" != '(' ]]; then
             _gpg_rx_subst "$_s" "$_i" "$_d" || return 1
             _amp=$((_amp + _GPG_RXA)); _w+='$(_)'; _hw=1; _i=$_GPG_SE
           else _w+="$_c"; _hw=1; fi ;;
      '`') _gpg_rx_subst "$_s" "$_i" "$_d" || return 1
           _amp=$((_amp + _GPG_RXA)); _w+='$(_)'; _hw=1; _i=$_GPG_SE ;;
      *) _w+="$_c"; _hw=1 ;;
    esac
    _i=$((_i + 1))
  done
  if (( _d == 0 )); then
    _x="${_s//&&/}"
    (( (${#_s} - ${#_x}) / 2 == _amp )) || return 1
  fi
  _GPG_RXA=$_amp   # [overblock P1d R-F] 치환 재귀 호출부가 && 연산자 수를 더한다
  return 0
}

_gpg_shell_core() {  # → _GPG_HIT (c217: 호출부 _gpg_shell 이 && 명령에 한해 A·B 두 해석으로 두 번 부른다)
  local _raw _low _nq _nb _tok _keep _wm=0 _any=0 _r _seg
  local -a _segs=()
  _raw=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GPG_TI" 2>/dev/null)
  [[ -n "$_raw" ]] || return 0
  local _raw0="$_raw"                             # K11: 치환·마스킹 전 원본(python 구간 분류기 판정용)
  _GPG_DDF=0; _gpg_dd_free "$_raw0" && _GPG_DDF=1   # relpath(pd-a2 2026-11-08): ../{lib,tests,backup,logs} 가 hooks 일 수 없으면 1
  # K2(D-7, 2026-11-06): 명령 전체가 정확히 'for 이름 in <리터럴 목록·글로브>; do <구간 하나>; done' 한 줄이면 _GPG_FORGIT=1 —
  #   _gpg_git_safe 가 본문 첫 단어 do 를 벗겨 git 머리 구간(unblock3 git 허용)으로 본다(for p in …*gp_gate*.patch; do git apply "$p"; done).
  #   목록에 $ · 백틱 · 따옴표 · ; | & < > 가 없고 본문에 ; | & < > 백틱이 없으며 명령에 $( · 개행이 없을 때만이다.
  #   본문이 git 이 아니면(cp·echo >> 등) do 를 벗겨도 git 머리가 아니므로 종전 판정 그대로다(N4·P7 차단 유지).
  local _fgre="^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+[^;|&<>\$\`'\"]+;[[:space:]]*do[[:space:]]+[^;|&<>\`]+;[[:space:]]*done[[:space:]]*\$"
  _GPG_FORGIT=0
  [[ "$_raw" != *'$('* && "$_raw" != *$'\n'* && "$_raw" =~ $_fgre ]] && _GPG_FORGIT=1
  # c206 S1b ③: env 파라미터의 실행 경로 가로채기 변수 — 조회 명령이어도 임의 코드 실행이 되므로 무조건 차단한다
  #   (PATH=/tmp/evil 이면 cat 이 /tmp/evil/cat). 읽기 전용 통과(G3)보다 먼저 본다.
  local _hk0
  _hk0=$(jq -r '[.env,.environ,.environment] | map(select(type=="object"))[0] // {} | keys[]
          | select(test("^(PATH|LD_.*|BASH_ENV|ENV|IFS|PYTHON.*|PERL5.*|NODE_OPTIONS|NODE_PATH|RUBY.*|GIT_.*|GCONV_PATH|PS4|PROMPT_COMMAND|SHELLOPTS|BASHOPTS|BASH_FUNC_.*)$"))' \
          <<<"$_GPG_TI" 2>/dev/null | head -1)
  if [[ -n "$_hk0" ]]; then _GPG_HIT="셸 명령(env 파라미터 실행 경로 가로채기 변수 ${_hk0})"; return 0; fi
  # c214 R3: python 단독 호출(-c '<코드>' · 인용 종결자 heredoc)은 AST 분류기가 쓰기 대상이 보호 파일이 아님을 확정하면 통과한다
  #   (해석기 자체를 쓰기 수단으로 보던 규칙①·S1b② 과차단 해소 — D-7 비보호 JSON 쓰기·보호 등록부 읽기 전용 json.load).
  #   분류기가 없거나 UNSAFE·시간 초과·형태 불일치면 아래 종전 판정 그대로다(fail-closed).
  if [[ "${_raw,,}" == *python* ]] && _gpg_py_safe "$_raw"; then _GPG_HIT=""; return 0; fi
  if [[ "${_raw,,}" == *python* ]] && _gpg_pyhd_combo "$_raw"; then _GPG_HIT=""; return 0; fi   # relpath(pd-a2 2026-11-08) R3
  # c206 11-1: oio bash_exec 는 && 에서만 나누고 역슬래시를 무시한다 — && 가 없으면 명령 전체가 한 bash 에 가므로
  #   분해기가 큰따옴표 안 \" 를 bash 규칙(글자 ")으로 읽어도 단위 경계가 같다. && 가 있으면 종전 rc1(분할 불일치 우회 차단).
  _GPG_AND=1; [[ "$_raw" == *'&&'* ]] || _GPG_AND=0
  _raw=$(_gpg_lit_subst "$_raw")                  # c206 G4: 리터럴 대입 변수 참조를 값 글자로(D-4·D-11 — 분해 유지)
  # c206 S1b: 리터럴 목록 for 1개는 펼쳐 판정한다(&&·IFS 가 있으면 펼치지 않는다 — oio 분할기는 do/done 을 모른다)
  [[ $_GPG_AND -eq 0 && "$_raw" != *IFS* ]] && _raw=$(_gpg_for_unroll "$_raw")
  _raw=$(_gpg_hd_mask "$_raw")                    # 허용 형태 heredoc 본문만 비운다(인용 종결자 한정 — R1)
  _raw=$(_gpg_msg_mask "$_raw")                   # git commit -m 인용 메시지 내용만 비운다(D-2)
  _raw=$(_gpg_qglob "$_raw")                      # c205 D-14: 따옴표 안 글로브 문자는 전개하지 않도록 표식으로 바꾼다
  # c205 G3: 단위 분해가 확실하고 비어 있지 않은 모든 단위가 읽기 전용 사슬(_gpg_unit_readonly — 쓰기 리다이렉트 대상 0 ·
  #   조회 명령만의 파이프)이면 쓰기 수단이 없으므로 통과한다(인용 패턴 글자 tee·python3 오인 과차단 해소).
  #   하나라도 판정 불확실·쓰기 단위가 있으면 종전 ①②③ 판정으로 간다.
  # c213: G3 에서만 ① $HOME·${HOME} 을 값으로 바꾼 사본을 쓰고($HOME 뒤에 이름 글자가 붙은 꼴이 있으면 바꾸지 않는다 — _gpg_rd_split 과 같은 규칙)
  #   ② 전용 분해 모드(_gpg_units … 1)로 따옴표 안 << · eval/source/exec 글자를 분해 포기 사유로 보지 않으며 ③ _GPG_RO=1 로 큰따옴표 안
  #   grep 교대 \| 만 구분자에서 뺀다 ④ 무해 리터럴 대입 단위(_gpg_unit_litassign)를 조회와 같게 본다.
  #   이 길은 단위 하나라도 쓰기·실행이면 타지 않으므로 패턴 글자를 무시해도 쓰기가 숨을 자리가 없다. ①②③ 판정은 그대로다.
  local _ror="$_raw"
  if ! [[ "$_ror" =~ \$HOME[A-Za-z0-9_] ]]; then _ror="${_ror//\$\{HOME\}/$HOME}"; _ror="${_ror//\$HOME/$HOME}"; fi
  _GPG_RO=1
  if _gpg_units "$_ror" 1; then
    local _u3 _ro3=1 _ne3=0
    for _u3 in "${_GPG_U[@]}"; do
      [[ "$_u3" =~ [^[:space:]] ]] || continue
      _ne3=1
      _gpg_unit_readonly "$_u3" || _gpg_unit_litassign "$_u3" || _gpg_unit_pysafe "$_u3" || { _ro3=0; break; }   # bashc ④: python -c 단위
    done
    if [[ $_ne3 -eq 1 && $_ro3 -eq 1 ]]; then _GPG_RO=0; _GPG_HIT=""; return 0; fi
  fi
  _GPG_RO=0
  _keep="${_raw//[\'\"\\]/}"                     # 따옴표·역슬래시 제거(대소문자 보존 — 파일 시스템 전개용)
  _low="${_raw,,}"
  _nq="${_low//[\'\"\\]/}"
  _nb="${_nq//[\{\},]/}"                         # 중괄호·쉼표 제거 — gp_{gate,x}.sh 도 토큰으로 본다
  _tok="$_nb"
  while [[ "$_tok" =~ (test_guard_promote|test_gp_boot)[a-z0-9_.-]*\.sh ]]; do
    _tok="${_tok/"${BASH_REMATCH[0]}"/ }"
  done
  # c206 S1c: 토큰 목적지 리다이렉트 판정용 — 따옴표 안 내용을 공백으로 지운 사본(미인용 > 만 리다이렉트로 본다).
  #   따옴표 안 '9>>' 같은 grep 패턴이 뒤 보호 경로와 합쳐져 '>> …guard_promote.sh' 로 오인되던 과차단을 막는다(odev-4 11:15).
  local _tokv
  _tokv=$(_gpg_unq "$_raw"); _tokv="${_tokv,,}"; _tokv="${_tokv//[\{\},]/}"
  while [[ "$_tokv" =~ (test_guard_promote|test_gp_boot)[a-z0-9_.-]*\.sh ]]; do _tokv="${_tokv/"${BASH_REMATCH[0]}"/ }"; done

  # 쓰기 수단 판정(소문자·따옴표 제거본) — tee 는 따로 본다(D-3: tee 가 유일한 쓰기 수단이면 _gpg_tee_safe 로 완화)
  local _tee=0
  [[ "$_nq" =~ ${_GPG_B}tee${_GPG_E} ]] && _tee=1
  # K11(D-15): python 구간이 전부 분류기 SAFE 이면(원본 명령 기준) python 단어를 쓰기 수단으로 세지 않는다 — 다른 쓰기 수단 판정은 그대로
  local _kpy="$_keep"
  _gpg_pyc_allsafe "$_raw0" && _kpy=$(_gpg_py_unword "$_kpy")
  _gpg_wm_re "$(_gpg_git_mask "$(_gpg_py_mask "$_kpy")")" && _wm=1  # c217: 인덱스 전용 git 구간(rm --cached)은 rm 단어를 쓰기 수단으로 세지 않는다. sort -o · uniq 입력 출력(두 번째 인자) = 쓰기 수단(검토 R2)
  local _gitw=0
  if [[ "$_nq" =~ ${_GPG_B}git([[:space:]][^\;\|\&]*)?[[:space:]](${_GPG_GITW})${_GPG_E} ]]; then
    _gitw=1
    _gpg_gitw_all_safe "$_keep" && _gitw=0         # unblock3: git 쓰기 하위 명령이 든 구간이 모두 git 머리 구간이면 쓰기 수단이 아니다(종전 c217 인덱스 전용 판정을 대체)
  fi
  if [[ $_tee -eq 1 && $_wm -eq 0 ]]; then
    _gpg_cwds "$_keep"
    _gpg_tee_safe "$_raw" "$_nq" || _wm=1
  elif [[ $_tee -eq 1 ]]; then
    _wm=1
  fi

  # c206 S1b(④⑤): 재해석 실행(eval · bash/sh/dash/zsh/ksh/busybox … -c)의 인자에 실행 시점에야 풀리는 $(이스케이프 \$ ·
  #   작은따옴표 안 $)가 있으면 보호 이름이 글자로 드러나지 않는다(f=gp; eval "cp x <hooks>/lib/\${f}_gate.sh").
  #   그때 hooks 보호 디렉터리 경로(hooks/lib·tests·backup·logs · .claude/hooks)와 쓰기 수단(쓰기 명령·tee·git 쓰기·무해하지 않은
  #   리다이렉트)이 함께 있으면 이름 전체가 보이지 않아도 보수적으로 차단한다(차단 추가만 — 완화 없음).
  local _rx="${_GPG_B}eval${_GPG_E}" _rc="${_GPG_B}(bash|sh|dash|zsh|ksh|busybox)([[:space:]]+-[a-z]+)*[[:space:]]+-[a-z]*c"
  #   hooks 경로 판정에서 빼는 것 — 실행 위치(bash/sh/dash 바로 뒤)의 스크립트 경로(고정 시험·승격기를 실행만 함, S1b odev-4 원문)와
  #   hooks/candidates 아래 후보 경로(보호 대상 아님). hooks 디렉터리 자체(.claude/hooks 뒤 끝·공백·구분자)와 lib·tests·backup·logs 는 본다.
  #   ../lib·../tests·../backup·../logs 는 정규화 전 글자라 candidates/../lib · cd candidates 뒤 ../lib 로 빠져나갈 수 있으므로 함께 본다
  #   (odev-6 교차 검토 28·29).
  # c206 S1c: 실행 시점 변수 — 경로를 만들 수 있는 것만 본다. 특수 매개변수($? $! $$ $# $-)는 숫자·상태 값이라 경로 성분이 아니다.
  #   그래서 \$·작은따옴표 안 $ 가 ★이름·위치 인자·중괄호·명령치환·전체 인자★(A-Za-z0-9_ { ( @ *)로 이어질 때만 '실행 시점 변수'로
  #   센다. 위치 인자 $0~$9 는 bash -c 의 인자로 경로가 될 수 있어 포함한다(odev-6 Z01 "$0"_gate.sh). 특수 매개변수 $? $! $$ $# $- 만 제외.
  local _sqd="'[^']*[\$]([A-Za-z0-9_{(@*])[^']*'" _dvq='\\[\$]([A-Za-z0-9_{(@*])'
  local _hd='((hooks|\.\.)/(lib|tests|backup|logs)([/[:space:];|&]|$)|\.claude/hooks/?([[:space:];|&]|$))' _hn="$_nq"
  [[ "${_GPG_DDF:-0}" == 1 ]] && _hd='(hooks/(lib|tests|backup|logs)([/[:space:];|&]|$)|\.claude/hooks/?([[:space:];|&]|$))'   # relpath(pd-a2 2026-11-08)
  local _rr; _rr=$(_gpg_unq "$_raw"); _rr="${_rr,,}"   # c206 S1c: > 존재는 미인용 기준으로만 본다(따옴표 안 글자 제외)
  local _xp='(^|[^a-z0-9_.-])(bash|sh|dash)[[:space:]]+[^[:space:];|&<>-][^[:space:];|&<>]*hooks/(lib|tests)/[^[:space:];|&<>]*'
  while [[ "$_hn" =~ $_xp ]]; do _hn="${_hn/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}${BASH_REMATCH[2]} "}"; done
  # hooks/candidates 아래 후보 경로 단어도 뺀다 — 단 .. 가 든 단어는 빼지 않는다(candidates/../lib 탈출, odev-6 28)
  local _cw='(^|[[:space:]])[^[:space:];|&<>]*hooks/candidates/[^[:space:];|&<>]*'
  local _hn2="" _cwm
  while [[ "$_hn" =~ $_cw ]]; do
    _cwm="${BASH_REMATCH[0]}"; _hn2+="${_hn%%"$_cwm"*}"
    [[ "$_cwm" == *..* ]] && _hn2+="$_cwm" || _hn2+="${BASH_REMATCH[1]} "
    _hn="${_hn#*"$_cwm"}"
  done
  _hn="$_hn2$_hn"
  # S1b ②: 이름·경로 조각 — hooks 단어 · 보호 이름 조각(gp_ · _gate · guard_ · _promote · test_gp · test_pdg · pdg_).
  #   재해석 실행·해석기 문자열 이어붙이기로 경로를 조각내 숨기는 꼴(h=hooks; eval … \${h} · 'lib/'+'gp_'+'gate.sh')을 본다.
  # c206 S1d(Mars 회귀): 이름 조각(_gate·gp_·guard_ …)은 ac_gate.py·ac_records 같은 무관한 이름을 오탐한다 → hooks 단어로만 좁힌다.
  #   실제 보호 경로는 _hd(…/hooks/{lib,tests,backup,logs} · .claude/hooks)로 잡는다. hooks 글자를 분해 숨기는 꼴만 _fr(hooks 단어)로 본다.
  local _fr='(^|[^a-z0-9_])hooks([^a-z0-9_]|$)'
  while [[ "$_rr" =~ [0-9]*\>\>?[[:space:]]*(/dev/(null|stdout|stderr|tty)|\&[0-9-]) ]]; do _rr="${_rr/"${BASH_REMATCH[0]}"/ }"; done
  #   동적 표식에는 명령 치환($( · 백틱)도 넣는다 — eval "$(printf '… lib/gp_%s.sh' gate)" (odev-6 45)
  # [overblock P1] `bash -c '… "$0"' 인자 > /비보호/파일` 처럼 따옴표 밖 리다이렉트 대상이 hooks 밖 절대 리터럴이면 이 판정의 쓰기 수단으로 세지 않는다.
  #   대상이 따옴표로 시작하면 _gpg_unq 가 가려 다음 단어를 대상으로 오인할 수 있으므로 건너뛰지 않는다. 변수·치환 대상은 정규식에 맞지 않아 그대로 남는다.
  #   따옴표 안 쓰기와 _wm·_tee·_gitw 판정은 그대로다. 같은 명령에서 바깥 리다이렉트만 뺀 형태와 판정이 같아질 뿐이다.
  local _rrs="$_rr" _rrw _rrm
  # [overblock P1c R-E] 리다이렉트 대상이 따옴표 하나로 감싼 리터럴(글자·숫자·_ . / @ % + : , = - 만, 따옴표가 단어 전체)이면 벗긴 사본으로
  #   '따옴표 대상' 검사를 한다. 내용에 $·백틱·공백 등이 있거나 따옴표 뒤에 글자가 이어지면 종전대로 건너뛴다(쓰기 수단 유지).
  #   (정규식을 변수에 담으므로 > 는 [>] 로 쓴다 — 변수 안 \> 는 GNU 정규식의 단어 끝 표식이 된다)
  local _rawE="$_raw" _qe _qre1='([>][>]?[[:space:]]*)"([A-Za-z0-9_./@%+:,=-]+)"([[:space:];|&]|$)' _qre2="([>][>]?[[:space:]]*)'([A-Za-z0-9_./@%+:,=-]+)'([[:space:];|&]|\$)"
  while [[ "$_rawE" =~ $_qre1 || "$_rawE" =~ $_qre2 ]]; do
    _qe="${BASH_REMATCH[0]}"; _rawE="${_rawE/"$_qe"/"${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"}"
  done
  if ! [[ "$_rawE" =~ \>\>?[[:space:]]*[\'\"] ]]; then
    while [[ "$_rrs" =~ \>\>?[[:space:]]*([^[:space:]\;\|\&\<\>\$\`\(\)\*\?\[]+) ]]; do
      _rrm="${BASH_REMATCH[0]}"; _rrw="${BASH_REMATCH[1]}"   # 아래 =~ 가 BASH_REMATCH 를 덮으므로 먼저 담는다
      [[ "$_rrw" == /* && ! "$_rrw" =~ (^|/)hooks(/|$) ]] || break
      _gpg_prot_s "$_rrw" && break
      _rrs="${_rrs/"$_rrm"/ }"
    done
  fi
  # [overblock P1b] 쓰기 수단은 쓰기 대상이 모두 hooks 밖 절대 리터럴인 구간을 빼고 다시 센다(_gpg_rx_scan — 재해석 인자 안팎 무관).
  #   명령 치환·백틱·프로세스 치환이 있거나, 대상에 남은 $ 가 있거나, hooks 안·보호 대상이거나, 분해가 불확실하면 종전대로 센다(fail-closed).
  #   이 규칙에서만 쓴다. 재해석 존재·실행 시점 변수·hooks 경로 세 조건과 _gitw·바깥 리다이렉트(_rrs) 판정은 그대로다.
  local _wmx=$_wm _teex=$_tee
  # [overblock P1d R-F] $(…)·백틱은 _gpg_rx_scan 이 안 명령을 재귀 판정하므로 여기서 분해를 건너뛰는 조건에서 뺐다(<( >( 는 그대로)
  if [[ $_wm -eq 1 || $_tee -eq 1 ]] && [[ "$_raw" != *'<('* && "$_raw" != *'>('* ]] \
     && _gpg_rx_scan "$_raw" 0; then
    _wmx=0; _teex=0
  fi
  # [overblock P1c R-B] hooks 단어 판정(_fr)에서 '<성분>/hooks/<이름>' 은 뺀다 — 성분은 / 또는 공백 바로 뒤에서 시작하는 리터럴(첫 글자가 . 아님 →
  #   .claude·.·.. 제외, 앞에 $·} 가 붙은 변수 성분 제외), 이름은 리터럴이고 lib·tests·backup·logs 가 아니어야 한다(codex-harness/hooks/x.py 등).
  #   보호 경로 판정(_hd)과 다른 규칙(토큰·dyn_check·해석기 쓰기 API)은 그대로다. 이 규칙의 hooks 조건에서만 쓴다.
  local _hnb="" _hnr="$_hn" _hbm _hb1 _hb2 _hb3 _hbx='(^|[[:space:]/])([a-z0-9_-][a-z0-9_.-]*)/hooks/([a-z0-9_.-]+)'
  while [[ "$_hnr" =~ $_hbx ]]; do
    _hbm="${BASH_REMATCH[0]}"; _hb1="${BASH_REMATCH[1]}"; _hb2="${BASH_REMATCH[2]}"; _hb3="${BASH_REMATCH[3]}"
    _hnb+="${_hnr%%"$_hbm"*}"
    if [[ "$_hb3" =~ ^(lib|tests|backup|logs)$ ]]; then _hnb+="$_hbm"
    else _hnb+="${_hb1}${_hb2}/_h_/${_hb3}"; fi
    _hnr="${_hnr#*"$_hbm"}"
  done
  _hnb+="$_hnr"
  if [[ "$_nq" =~ $_rx || "$_nq" =~ $_rc ]] && [[ "$_raw" =~ $_dvq || "$_raw" =~ $_sqd || "$_raw" == *'$('* || "$_raw" == *'`'* ]] \
     && [[ "$_hn" =~ $_hd || "$_hnb" =~ $_fr ]] \
     && [[ $_wmx -eq 1 || $_teex -eq 1 || $_gitw -eq 1 || "$_rrs" == *">"* ]]; then
    _GPG_HIT="셸 명령(재해석 실행 + 실행 시점 변수 + hooks 보호 디렉터리 + 쓰기 수단)"; return 0
  fi
  # c206 S1b(odev-6 8·9·13~21·44): 보호 디렉터리 경로 안에 풀리지 않은 변수가 박힌 단어(…/hooks/lib/${f}_gate.sh ·
  #   …/.claude/${h}/lib/x)를 쓰기 명령 구간이 다루거나 리다이렉트 대상으로 삼으면 이름을 확정할 수 없으므로 보수적으로 차단한다.
  _gpg_dyn_check "$_raw" && { _GPG_HIT="셸 명령(보호 디렉터리 경로 안 미확정 변수 + 쓰기 수단)"; return 0; }
  # c206 S1b ②(odev-6 46): 해석기(python·perl·node·ruby·php·lua·deno·bun) 본문은 문자열 이어붙이기로 이름을 조각낼 수 있다 —
  #   hooks 경로·이름 조각(_hd·_fr, 실행 위치 스크립트·후보 경로 제외)과 쓰기 API(open 쓰기 모드·shutil·os.rename/remove/…·
  #   write_text·subprocess·fs.write… 등)가 함께 있으면 보수적으로 차단한다. 조회만 하는 해석기 호출은 통과한다.
  local _wapi='open[[:space:]]*\([^)]*,[[:space:]]*["'\''][^"'\'']*[wax+]|shutil\.|os\.(rename|replace|remove|unlink|symlink|link|truncate|chmod|chown|makedirs|mkdir|rmdir|removedirs|system|popen|exec|spawn|write)|\.write_(text|bytes)|\.(unlink|rename|replace|symlink_to|hardlink_to|touch|chmod|rmdir)[[:space:]]*\(|subprocess|copyfile|fs\.(write|append|copy|rename|unlink|symlink|rm|cp)|file\.(write|open|rename|delete)|fileutils|syswrite|(^|[^a-z_.])(unlink|rename|system|exec|symlink)[[:space:]]*\(|open[[:space:]]*\(?[[:space:]]*[a-z_]+[[:space:]]*,[[:space:]]*["'\'']?[>+]'
  # c206 S1d: 해석기 쓰기 규칙은 실제 보호 경로(_hd)만 본다 — 이름 조각으로 다른 프로젝트의 *_gate.py 를 오탐하지 않게(Mars ac_gate.py).
  #   문자열 이어붙이기(#46)도 쓰기 대상에 /hooks/lib/ 가 글자로 있어 _hd 가 잡는다.
  if [[ "$_nq" =~ ${_GPG_B}(python[0-9.]*|perl|node|ruby|php|lua|deno|bun)${_GPG_E} ]] && [[ "$(_gpg_hn_ro "$_hn")" =~ $_hd ]] \
     && [[ "$_low" =~ $_wapi ]]; then
    _GPG_HIT="셸 명령(해석기 쓰기 API + hooks 보호 경로)"; return 0
  fi
  # c206 S1b ③: bash_exec 의 env 파라미터(tool_input.env·environ·environment)는 명령 문자열 밖에서 변수를 주입한다.
  #   실행 경로 가로채기 변수(PATH·LD_*·BASH_ENV·ENV·IFS·PYTHON*·PERL5*·NODE_OPTIONS·NODE_PATH·RUBY*·GIT_*·GCONV_PATH·PS4·
  #   PROMPT_COMMAND·SHELLOPTS·BASHOPTS·BASH_FUNC_*)는 조회 명령이어도 무조건 차단한다. 경로성 변수(HOME·CDPATH·GLOBIGNORE·
  #   CLAUDE_CONFIG_DIR·BASH_*)는 명령의 쓰기 수단·보호 토큰·hooks 보호 경로와 함께 있을 때, 그 밖 이름은 값에 보호 토큰·hooks
  #   보호 경로·이름 조각이 있고 명령에 쓰기 수단이 있을 때 차단한다(판정 시점 해석을 믿을 수 없다).
  local _ej _ek _ev _ewm=0
  _ej=$(jq -r '[.env,.environ,.environment] | map(select(type=="object"))[0] // {} | to_entries[]
          | "\(.key)\t\(.value|tostring|gsub("[\n\t]";" "))"' <<<"$_GPG_TI" 2>/dev/null)
  if [[ -n "$_ej" ]]; then
    [[ $_wm -eq 1 || $_tee -eq 1 || $_gitw -eq 1 || "$_rr" == *">"* ]] && _ewm=1
    while IFS=$'\t' read -r _ek _ev; do
      [[ -n "$_ek" ]] || continue
      # (실행 경로 가로채기 변수는 _gpg_shell 맨 앞에서 무조건 차단한다 — 읽기 전용 통과(G3)보다 먼저)
      # 경로성 변수 — 쓰기 수단·보호 토큰·hooks 보호 경로가 함께 있을 때만
      if [[ "$_ek" =~ ^(HOME|CDPATH|GLOBIGNORE|CLAUDE_CONFIG_DIR|BASH_.*)$ ]] \
         && [[ $_ewm -eq 1 || "$_tok" =~ $_GPG_TOK || "$_nq" =~ $_hd ]]; then
        _GPG_HIT="셸 명령(env 파라미터 위험 이름 ${_ek} + 쓰기 수단·보호 경로)"; return 0
      fi
      # 값이 이름·경로 조각(_fr — hooks · gp_ · _gate …)이어도 명령 안에서 이어붙여 보호 경로를 만들 수 있다
      if [[ $_ewm -eq 1 ]] && { [[ "${_ev,,}" =~ $_GPG_TOK || "${_ev,,}" =~ $_hd || "${_ev,,}" =~ $_fr ]] || _gpg_prot "$_ev" 2; }; then
        _GPG_HIT="셸 명령(env 파라미터 ${_ek} 값의 보호 경로 + 쓰기 수단)"; return 0
      fi
    done <<<"$_ej"
  fi

  # ① 보호 토큰 + 쓰기 수단
  #   c183 B8: 명령을 확실히 단위(; && || & 개행 — 파이프는 한 단위)로 나눌 수 있으면 ★같은 단위★ 에 토큰과 쓰기 수단이
  #   함께 있을 때만 적용한다(등록부 jq 조회 ; chmod 후보 · register … && chmod 오차단 해소). $·백틱·역슬래시·( )·<<·
  #   eval/source/exec 가 있으면 단위를 확정할 수 없으므로 종전대로 명령 전체로 본다(변수 간접화 f=…; cp x $f 차단 유지).
  #   토큰 목적지 리다이렉트는 단위와 무관하게 항상 본다.
  # c213: 보호 이름 또는 hooks 보호 경로(_hd)가 있는 명령에서 아래 둘은 조회 결과·지정 명령을 실행하므로 쓰기 수단으로 보고 차단한다
  #   (차단 추가만 — 두 조건은 같은 대상 판정 _tok·_hn 을 쓴다, 검토 LOW-G2).
  #   (a) 파이프 뒤 셸이 표준입력을 스크립트로 읽는 꼴 — | sh · | bash -s · | bash -x · | dash - · | bash /dev/stdin · | bash -c …
  #       (옵션 묶음에 s·c 가 있으면 뒤 위치 인자가 있어도 차단 — 검토 LOW-G1) · | source /dev/stdin · | . -
  #       앞에 command·builtin·exec·nohup·nice·stdbuf·env·setsid·sudo·doas·timeout N·NAME=값 이 붙어도 같다. 미인용 사본(_tokv)으로 본다.
  #   (b) git grep 의 -O<명령>·--open-files-in-pager(장옵션 축약 --op… 포함, 검토 MEDIUM-G1) — 대소문자 보존본(_keep)으로 -o 와 구별.
  local _psh='(^|[^|])\|[[:space:]]*(((command|builtin|exec|nohup|nice|stdbuf|env|setsid|sudo|doas)([[:space:]]+-[^[:space:]]*)*|timeout([[:space:]]+-[^[:space:]]*)*[[:space:]]+[^[:space:]]+|[a-z_][a-z0-9_]*=[^[:space:]]*)[[:space:]]+)*([^[:space:];|&<>]*/)?(busybox[[:space:]]+)?(bash|sh|dash|zsh|ksh|mksh|ash)(([[:space:]]+-[^[:space:];|&<>]*)*[[:space:]]*($|[;|&)<>]|-([[:space:]]|$)|/dev/stdin|/proc/self/fd/0)|([[:space:]]+-[^[:space:];|&<>]*)*[[:space:]]+-[a-z]*[sc][a-z]*([[:space:]]|$))'
  local _pso='(^|[^|])\|[[:space:]]*(source|\.)[[:space:]]+(/dev/stdin|-|/proc/self/fd/0)([[:space:];|&)]|$)'
  local _pgr='(^|[^a-zA-Z0-9_.-])git([[:space:]][^;|&]*)?[[:space:]]grep([[:space:]][^;|&]*)?[[:space:]](-[A-Za-z]*O|--op)'
  if [[ "$_tok" =~ $_GPG_TOK || "$_hn" =~ $_hd ]]; then
    if [[ "$_tokv" =~ $_psh || "$_tokv" =~ $_pso ]]; then
      _GPG_HIT="셸 명령(승격 경로 이름 + 셸 표준입력 실행 파이프)"; return 0
    fi
    # unblock3: git 머리 구간을 비운 사본으로 본다 — git grep -O 는 허용(git 이 머리가 아닌 꼴만 남는다)
    if [[ "$(_gpg_git_mask "$_keep" 1)" =~ $_pgr ]]; then
      _GPG_HIT="셸 명령(승격 경로 이름 + git grep 페이저 실행)"; return 0
    fi
  fi
  if [[ "$_tok" =~ $_GPG_TOK ]]; then
    # (1) 최상위(미인용) 리다이렉트가 토큰으로 간다 — _tokv(따옴표 blanked). (2) 재해석 실행(eval·bash/sh -c …)이 있으면
    #   그 본문 안의 리다이렉트가 재실행되므로 _tok(따옴표 제거)로도 본다(NEW-T71 bash -c '… > test_gp_gate.sh').
    #   재해석이 없으면 따옴표 안 '9>>'(grep 패턴)는 리다이렉트가 아니다(odev-4 11:15).
    local _rex="${_GPG_B}eval${_GPG_E}|${_GPG_B}(bash|sh|dash|zsh|ksh|busybox)([[:space:]]+-[a-z]+)*[[:space:]]+-[a-z]*c"
    if _gpg_tokdst_hit "$_raw" \
       || { [[ "$_nq" =~ $_rex ]] && [[ "$_tok" =~ \>\>?\|?[[:space:]]*[^[:space:]\;\|\&\<\>]*($_GPG_TOK) ]]; }; then
      _GPG_HIT="셸 명령(승격 경로 이름 + 쓰기 수단)"; return 0
    fi
    local _uw=1
    if _gpg_units "$_raw" && ! _gpg_units_hit; then _uw=0; fi
    # git 쓰기 하위 명령(cherry-pick·stash 등)은 이름 없이 트리 전체를 바꾸므로 단위와 무관하게 명령 전체로 본다(GG-G07)
    #   unblock3: _gitw 는 git 이 머리가 아닌 꼴(eval·echo 인자·명령 치환 포함 git 구간)에서만 1 이다 — git 머리 구간은 허용.
    if [[ $_gitw -eq 1 ]]; then
      _GPG_HIT="셸 명령(승격 경로 이름 + git 쓰기 하위 명령)"; return 0
    fi
    if [[ $_uw -eq 1 && $_wm -eq 1 ]]; then
      _GPG_HIT="셸 명령(승격 경로 이름 + 쓰기 수단)"; return 0
    fi
  fi

  # ②·③ 토큰 없는 별칭·전개·재귀 — 쓰기 수단(무해 리다이렉트 제외)이 있을 때만 파일 시스템을 본다
  _r="$_nq"
  while [[ "$_r" =~ [0-9]*\>\>?[[:space:]]*(/dev/(null|stdout|stderr|tty)|\&[0-9-]) ]]; do
    _r="${_r/"${BASH_REMATCH[0]}"/ }"
  done
  # c206 S1c: > 존재는 미인용 사본(_gpg_unq)으로 본다 — 따옴표 안 '9>>'(grep 패턴 등)가 _any 를 켜지 않게 한다(odev-4 11:15)
  local _rv; _rv=$(_gpg_unq "$_raw"); _rv="${_rv,,}"
  while [[ "$_rv" =~ [0-9]*\>\>?[[:space:]]*(/dev/(null|stdout|stderr|tty)|\&[0-9-]) ]]; do _rv="${_rv/"${BASH_REMATCH[0]}"/ }"; done
  [[ $_wm -eq 1 || $_tee -eq 1 || $_gitw -eq 1 || "$_rv" == *">"* ]] && _any=1
  [[ $_any -eq 1 ]] || return 0
  # c201 H: $HOME 참조가 있는데 HOME 을 다시 대입하는 꼴(따옴표·역슬래시로 감춘 HO""ME= · H\OME= 포함)이 있으면
  #   판정 시점 HOME 으로 펼친 경로를 믿을 수 없으므로 쓰기 수단과 함께라면 차단한다(차단 추가만 — 완화 없음).
  #   _keep 은 따옴표·역슬래시를 지운 대소문자 보존본이라 감춘 꼴이 HOME 으로 복원된다.
  if [[ "$_keep" == *'$HOME'* || "$_keep" == *'${HOME}'* ]]; then
    local _hk="${_keep//\$\{HOME\}/}"
    _hk="${_hk//\$HOME/}"
    # c202 H: c201 의 "HOME 단어 잔존" 판정을 실제 대입 꼴(a~h)로 좁혔다 — 따옴표 안 메시지의 HOME 글자는 통과.
    #   감춘 꼴은 _keep 이 복원하므로 (a) 가 잡는다(GG-H123·H124). 한계: 따옴표 안 문구에 대입 꼴(HOME= · export HOME)
    #   자체가 들어 있으면 _keep 이 따옴표를 지우므로 여전히 막힌다. ${H}ME= 같은 변수 이어붙이기는 종전·이후 모두 못 잡는다.
    local _hB='(^|[^A-Za-z0-9_])' _hE='([^A-Za-z0-9_]|$)' _hT='([[:space:]]+[^;&|[:space:]]+)*'
    local _hre_a="${_hB}HOME(\[[^]]*\])?\+?="
    local _hre_b="${_hB}(export|readonly|declare|local|typeset)${_hT}[[:space:]]+HOME${_hE}"
    local _hre_c="${_hB}(declare|local|typeset)${_hT}[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=HOME${_hE}"
    local _hre_d="${_hB}read${_hT}[[:space:]]+HOME${_hE}"
    local _hre_e="${_hB}for[[:space:]]+HOME([[:space:]]|;|\$)"
    local _hre_f="${_hB}unset${_hT}[[:space:]]+HOME${_hE}"
    local _hre_g="${_hB}printf${_hT}[[:space:]]+-v[[:space:]]*HOME${_hE}"
    local _hre_h='\{HOME:?='
    if [[ "$_hk" =~ $_hre_a || "$_hk" =~ $_hre_b || "$_hk" =~ $_hre_c || "$_hk" =~ $_hre_d \
       || "$_hk" =~ $_hre_e || "$_hk" =~ $_hre_f || "$_hk" =~ $_hre_g || "$_hk" =~ $_hre_h ]]; then
      # [overblock P1d R-K] 모든 쓰기·출력 리다이렉트 대상이 $ 없는 hooks 밖 절대 리터럴이면(HOME 값이 쓰기 대상을 바꿀 수 없다) 이 규칙으로 막지 않는다
      _gpg_home_wr_ok "$_raw" "$_tee" "$_gitw" || { _GPG_HIT="셸 명령(HOME 재대입 + \$HOME 경로 + 쓰기 수단)"; return 0; }
    fi
  fi
  _gpg_cwds "$_keep"
  # 구간별 판정(항목2) — 전역 위험 단어(eval·source·exec·.·tee)가 없고 분해가 확실할 때만. 아니면 종전 전 단어 전개.
  local _cons=0 _kg
  _kg=$(_gpg_git_mask "$_keep" 1)                 # unblock3: git 머리 구간을 비운 사본(쓰기 리다이렉트 대상은 남긴다)
  [[ "${_kg,,}" =~ ${_GPG_B}(xargs|parallel|while|until|read|mapfile|readarray|bash|sh|dash|zsh|ksh|csh|tcsh|fish|busybox|python[0-9.]*|perl|node|ruby|php|lua|awk|gawk|mawk|nawk|sed|find|env|make|git)${_GPG_E} ]] && _cons=1
  if [[ $_tee -eq 0 ]] && ! [[ "$_nq" =~ ${_GPG_B}(eval|source|exec)${_GPG_E} ]] \
     && ! [[ "$_nq" =~ (^|[[:space:]\;\&\|])[.]([[:space:]]|$) ]] && _gpg_rd_split "$_raw"; then
    _gpg_rd_check "$_cons" && return 0
  elif [[ $_cons -eq 0 && "$_raw" != *'$('* && "$_raw" != *'`'* && "$_raw" != *'<('* && "$_raw" != *'>('* ]] \
       && ! [[ "$_nq" =~ ${_GPG_B}(eval|source|exec)${_GPG_E} ]] \
       && ! [[ "$_raw" =~ \>\>?\|?[[:space:]]*[\"\']?[\$\`] ]]; then   # 리다이렉트 대상이 변수·치환이면 대상 미확정 → 종전 전개(GG-C15)
    # c199g D-4: tee·$변수 때문에 분해가 불확실해도, 명령 치환·소비자가 없으면 구간마다 판정한다 —
    #   조회 명령 구간은 피연산자 글로브를 펼치지 않고 그 구간의 쓰기 리다이렉트 대상만 본다(grep -l x tests/*.sh | tee /tmp/o).
    #   그 밖 구간(쓰기 명령·대입·tee 등)은 종전대로 전 단어를 펼친다.
    _gpg_fb_check "$_raw" && return 0
  else
    _gpg_words "$_kg"                             # unblock3: git 머리 구간의 피연산자는 펼치지 않는다(그 구간의 쓰기 리다이렉트 대상은 남아 있다)
    if _gpg_check_words 0 "${_GPG_W[@]}"; then return 0; fi
  fi
  _r=$(_gpg_seg_prep "$_raw")
  IFS=$'\x01' read -r -a _segs <<<"$_r"
  for _seg in "${_segs[@]}"; do
    [[ "$_seg" =~ [^[:space:]] ]] || continue
    _gpg_segment "$_seg" && return 0
  done
  _GPG_HIT=""
  return 0
}

# unblock3(사용자 지시 2026-10-27 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라" + 화면 결정 ② "자동 원복까지 해제 — git 으로
#   보호 파일을 직접 바꿀 수 있게"): git 머리 구간 판정 — $@=한 구간의 단어들(따옴표 제거·대소문자 보존) → rc0 이면 git 머리 구간.
#   머리 = 앞쪽 VAR=값 · 접두 명령(env·nice·nohup·command·exec·sudo·xargs·stdbuf·time·setsid — 뒤 옵션 단어 포함, timeout 은 옵션 뒤
#   시간 인자 1개 더)을 벗긴 첫 단어의 basename 이 git 또는 git.exe. 하위 명령·옵션은 묻지 않는다(checkout·restore·reset --hard·
#   stash·clean·rm·mv·-c alias.x='!…'·grep -O 모두 허용). 단어에 $( · 백틱 · <( · >( 가 있으면 git 이 아닌 명령이 실행되므로 거짓.
#   (종전 c217 판정 — reset -- 경로 · restore --staged · rm --cached 인덱스 전용만 참 — 은 이 결정으로 대체됐다)
_gpg_git_safe() {
  local _all="$*" _i=0 _n=$# _x
  local -a _t=("$@")
  [[ "$_all" == *'$('* || "$_all" == *'`'* || "$_all" == *'<('* || "$_all" == *'>('* || "$_all" == *$'\n'* ]] && return 1
  # K2(D-7): 명령 전체가 for 루프 하나(_GPG_FORGIT=1, _gpg_shell_core 가 판정)일 때만 본문 첫 단어 예약어 do 를 벗긴다
  [[ "${_GPG_FORGIT:-0}" == 1 && $_n -ge 2 && "${_t[0]}" == do ]] && _i=1
  while [[ $_i -lt $_n ]]; do
    case "${_t[$_i]}" in
      [A-Za-z_]*=*) _i=$((_i+1)) ;;
      env|nice|nohup|command|exec|sudo|xargs|stdbuf|time|setsid)
        _i=$((_i+1)); while [[ $_i -lt $_n && "${_t[$_i]}" == -* ]]; do _i=$((_i+1)); done ;;
      timeout)
        _i=$((_i+1)); while [[ $_i -lt $_n && "${_t[$_i]}" == -* ]]; do _i=$((_i+1)); done; _i=$((_i+1)) ;;
      *) break ;;
    esac
  done
  [[ $_i -lt $_n ]] || return 1
  _x="${_t[$_i]##*/}"; _x="${_x,,}"
  [[ "$_x" == git || "$_x" == git.exe ]]
}

# 명령 문자열($1, 따옴표 제거·대소문자 보존)을 ; | & 개행으로 나눠, git 쓰기 하위 명령이 든 구간이 모두 git 머리 구간(_gpg_git_safe)이면 rc0
#   unblock3: 개행도 구분자로 본다(여러 줄 git 명령). 종전의 $ ( ) { } < > 글자 거부는 _gpg_git_safe 의 $( · 백틱 · <( · >( 거부로 좁혔다.
_gpg_gitw_all_safe() {
  local _sg _wd _nl=$'\n'
  local -a _w
  local _re="${_GPG_B}git([[:space:]][^\;\|\&]*)?[[:space:]](${_GPG_GITW})${_GPG_E}"
  while IFS= read -r -d $'\x01' _sg; do
    _wd="${_sg,,}"
    [[ "$_wd" =~ $_re ]] || continue
    read -r -a _w <<<"$_sg"
    _gpg_git_safe "${_w[@]}" || return 1
  done < <(printf '%s\x01' "${1//[;|&$_nl]/$'\x01'}")
  return 0
}

# c217: 명령 문자열($1, 따옴표 제거·대소문자 보존)에서 git 머리 구간(_gpg_git_safe)을 비운 소문자 사본을 낸다
#   (쓰기 수단 단어 판정 _gpg_wm_re 용 — git rm·git mv 의 rm·mv 가 쓰기 수단으로 오인되지 않게). 구간 구분자는 보존한다.
#   unblock3: 비운 git 구간 자리에는 그 구간의 쓰기 리다이렉트 조각(> 대상 · >> 대상)만 남긴다(git show … > 보호 파일 판정 유지).
#   개행도 구분자로 본다. $2=1 이면 git 구간만 비우고(승격기 자기 호출은 그대로) 대소문자를 보존한다(_pgr·소비자·전 단어 전개용).
_GPG_T21='^(.*[[:space:]])2>$'
_GPG_T21R='^1([[:space:]|;]|$)'
_gpg_git_mask() {
  local _s="$1" _o="" _seg _sep _pre _gm="${2:-0}" _rd _rr _nl=$'\n'
  local -a _w
  local _re="${_GPG_B}git([[:space:]][^\;\|\&]*)?[[:space:]](${_GPG_GITW})${_GPG_E}"
  local _sp="^([^;|&${_nl}]*)([;|&${_nl}]*)(.*)$"
  while [[ -n "$_s" ]]; do
    [[ "$_s" =~ $_sp ]] || { _o+="$_s"; break; }
    _seg="${BASH_REMATCH[1]}"; _sep="${BASH_REMATCH[2]}"; _s="${BASH_REMATCH[3]}"
    # unblock3: git 머리 구간 — 쓰기 리다이렉트 조각만 남기고 비운다($2=0 은 종전대로 git 쓰기 하위 명령 구간만, $2=1 은 모든 git 구간)
    if [[ "${_seg,,}" == *git* ]] && { [[ "$_gm" == 1 ]] || [[ "${_seg,,}" =~ $_re ]]; }; then
      read -r -a _w <<<"$_seg"
      if _gpg_git_safe "${_w[@]}"; then
        _rd=""; _rr="$_seg"
        while [[ "$_rr" =~ [0-9]*\>\>?\|?[[:space:]]*[^[:space:]\<\>]* ]]; do
          _rd+=" ${BASH_REMATCH[0]}"; _rr="${_rr/"${BASH_REMATCH[0]}"/ }"
        done
        _o+="$_rd $_sep"; continue
      fi
    fi
    [[ "$_gm" == 1 ]] && { _o+="$_seg$_sep"; continue; }
    # c218: 승격기 자기 호출 뒤 꼬리 '2>&1' 만 허용 — 구분자가 정확히 '&' 이고 구간 끝이 '2>' 이며 남은 문자열이 '1'+공백|파이프|;|끝일 때만.
    #   '1' 한 글자만 소비한다. 그 뒤 '> 파일'·'| tee'·'; cp' 는 남은 문자열로 두어 기존 판정이 받는다.
    if [[ "$_sep" == "&" && "$_seg" =~ $_GPG_T21 ]]; then
      _pre="${BASH_REMATCH[1]}"
      if [[ "$_s" =~ $_GPG_T21R && "${_pre,,}" == *guard_promote.sh* && "$_pre" != *[\$\`\(\)\{\}\<\>]* && "$_pre" != *$'\n'* ]]; then
        read -r -a _w <<<"$_pre"
        if [[ "${_w[0]:-}" == bash && "${_w[1]:-}" == */hooks/lib/guard_promote.sh ]]; then
          case "${_w[2]:-}" in register|promote|verify|status|restore) _o+=" $_sep"; _s="${_s#1}"; continue ;; esac
        fi
      fi
    fi
    if [[ "$_seg" != *[\$\`\(\)\{\}\<\>]* && "$_seg" != *$'\n'* ]]; then
      if [[ "${_seg,,}" == *guard_promote.sh* ]]; then
        # 승격기 자기 호출 — bash <hooks>/lib/guard_promote.sh register|promote|verify|status|restore … (인자의 python 같은 값 단어를 쓰기 수단으로 세지 않는다)
        read -r -a _w <<<"$_seg"
        if [[ "${_w[0]:-}" == bash && "${_w[1]:-}" == */hooks/lib/guard_promote.sh ]]; then
          case "${_w[2]:-}" in register|promote|verify|status|restore) _o+=" $_sep"; continue ;; esac
        fi
      fi
    fi
    _o+="$_seg$_sep"
  done
  if [[ "$_gm" == 1 ]]; then printf '%s' "$_o"; else printf '%s' "${_o,,}"; fi
}

# c217: && 이중 해석 — 리터럴 대입 변수가 뒤 구간에 전달된다고 보는 해석(A)과 전달되지 않는다고 보는 해석(B)을 모두 통과해야 통과한다.
#   종전에는 && 가 있으면 치환 자체를 포기해 $S·$H 가 글자 그대로 남았다. 이제 A(값 치환)·B(빈값 치환) 두 해석을 각각 판정하고
#   하나라도 차단이면 차단한다 — 통과는 두 해석이 모두 안전할 때뿐이라 실제 실행이 A·B 어느 쪽이어도 안전하다.
# K14(pd-49, 2026-11-06 gp_pypipe): 명령 전체가 정확히 bash -c '<본문>' 하나(앞뒤 공백만, 뒤 인자·다른 명령 없음, 본문에 작은따옴표 없음,
#   본문이 비어 있지 않음)이면 본문을 직접 실행한 것과 같다 — 본문을 명령으로 바꿔 종전 판정 전부(_gpg_shell_run)를 그대로 적용한다.
#   bash -c '…$HOME…' 처럼 작은따옴표 안 실행 시점 변수 때문에 '재해석 실행 + 실행 시점 변수' 규칙에 걸리던 읽기 전용 실행을 푼다.
#   본문 안 보호 쓰기는 펼친 본문에서 규칙①·리터럴 치환·HOME 판정이 그대로 잡는다. -l·-x 등 다른 옵션·sh·eval·인자 있는 꼴은 종전대로다.
# andsplit(pd-a2 2026-11-08): && 빈값 해석(B)이 실제 실행 의미일 수 있을 때만 0 을 낸다.
#   oio bash_exec(ad06123, 2026-10-16 이후)는 따옴표·괄호·중괄호 밖 && 에서만 나누고, 마지막이 아닌 구간에 변수 대입·셸 상태 변경이
#   있으면 나누지 않고 셸 하나로 실행한다(_needs_single_shell). 리터럴 대입 변수(_gpg_lit_subst 가 푸는 머리 순수 대입)는 그래서
#   뒤 구간에 전달된다. Bash 도구와 K14 bash -c '<본문>' 본문은 애초에 나누지 않는다.
#   B 는 oio 분할기와 판정 분해가 어긋날 수 있는 꼴 — heredoc(<<)·역슬래시 따옴표(\' \") — 에만 남긴다.
#   한계: 단일 셸 판정이 없는 2026-10-16 이전 oio 서버에서는 B 가 실제 의미일 수 있다(그런 서버를 운영하지 않는다는 전제).
_gpg_and_lossy() {  # $1=명령 → 0: B 해석 필요 / 1: 불필요
  [[ "${_GPG_NOSPLIT:-0}" == 1 || "$TOOL_NAME" == Bash ]] && return 1
  [[ "$1" == *'<<'* || "$1" == *"\\'"* || "$1" == *'\"'* ]] && return 0
  return 1
}

_gpg_shell() {
  local _w0 _ti0="$_GPG_TI" _b
  _GPG_NOSPLIT=0                                  # andsplit(pd-a2 2026-11-08): K14 본문 판정 중에만 1
  _w0=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GPG_TI" 2>/dev/null)
  if [[ "$_w0" =~ ^[[:space:]]*bash[[:space:]]+-c[[:space:]]+\'([^\']*)\'[[:space:]]*$ ]]; then
    _b="${BASH_REMATCH[1]}"
    if [[ "$_b" =~ [^[:space:]] ]]; then
      _GPG_TI=$(jq -c --arg c "$_b" '.command=$c | del(.cmd)' <<<"$_ti0" 2>/dev/null)
      if [[ -n "$_GPG_TI" ]]; then _GPG_NOSPLIT=1; _gpg_shell_run; _GPG_NOSPLIT=0; _GPG_TI="$_ti0"; return 0; fi
      _GPG_TI="$_ti0"
    fi
  fi
  _gpg_shell_run
}

_gpg_shell_run() {
  local _c0
  _c0=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GPG_TI" 2>/dev/null)
  _GPG_LS_BLANK=0
  if [[ "$_c0" == *'&&'* && "$_c0" == *'$'* ]] && _gpg_and_lossy "$_c0"; then
    _gpg_shell_core
    [[ -n "$_GPG_HIT" ]] && return 0
    _GPG_HIT=""; _GPG_U=(); _GPG_X=(); _GPG_W=(); _GPG_RO=0; _GPG_AND=1
    _GPG_LS_BLANK=1
    _gpg_shell_core
    _GPG_LS_BLANK=0
    [[ -n "$_GPG_HIT" ]] && _GPG_HIT="&& 구간 빈값 해석(앞 구간 변수 미전달 가정) — ${_GPG_HIT}"   # andsplit(pd-a2 2026-11-08)
    return 0
  fi
  _gpg_shell_core
}

gp_gate_check() {
  local _k=""
  _GPG_HIT=""; _GPG_AND=1                         # c206: && 유무 미확정이면 엄격(\" 분해 포기)
  case "$TOOL_NAME" in
    mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit|NotebookEdit|mcp__oio__file_delete|\
    mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_symlink|mcp__oio__dir_create) _k="file" ;;
    mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename) _k="dir" ;;
    Bash|mcp__oio__bash_exec) _k="shell" ;;
    *) return 0 ;;
  esac
  _GPG_TI="${_GP_TI:-$(jq -c '.tool_input // {}' <<<"$INPUT" 2>/dev/null)}"
  [[ -n "$_GPG_TI" ]] || return 0
  if [[ "$_k" == "shell" ]]; then _gpg_shell; else _gpg_file "$_k"; fi
  [[ -n "$_GPG_HIT" ]] || return 0
  if ! declare -F log_hook_error >/dev/null 2>&1 && [[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" ]]; then
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
  fi
  declare -F log_hook_error >/dev/null 2>&1 && \
    log_hook_error "HOOK_BLOCK_GUARD_PROMOTE" "$TOOL_NAME" "승격 경로 구성요소 변경 시도 — ${_GPG_HIT}" "$(jq -r '.session_id // "unknown"' <<<"$INPUT" 2>/dev/null)"
  local _j
  _j=$(printf '%s' "$_GPG_HIT" | tr '\003\004\005' '*?[' | tr '"\\\n\t' "''  ")   # c205 D-14: 글로브 표식은 글자로 되돌려 출력
  # c206 S1e: 판정 유형에 맞는 정식 대체 경로를 한 줄 덧붙인다(판정 rc 는 그대로 — 작업이 멈추지 않게 올바른 방법을 바로 알려준다).
  #   사용자 기준(2026-10-25): 과차단의 최종 목표는 작업 중단·진행 불가·auto 모드 질문을 없애는 것. 문구만 바꾸고 차단 규칙은 유지한다.
  # S1e 고정 표지: odev-5 redir 판정·고정 시험이 안내 줄을 식별하는 문자열(바꾸지 말 것) — "[대체경로]"
  local _alt="[대체경로] "
  case "$_GPG_HIT" in
    *조회*|*verify*|*status*)
      _alt+="→ 승격 상태·잠금 확인은 bash <hooks>/lib/guard_promote.sh status <id> 또는 verify 로, 전체 점검은 verify 로 한다." ;;
    *시험*|*test_*|*고정*)
      _alt+="→ 고정 시험은 bash <시험파일> [인자] 로 직접 실행한다(bash -c 래퍼·실행 시점 변수 없이)." ;;
    *해석기*|*재해석*|*env*|*HOME*|*미확정*)
      _alt+="→ 보호 파일 교체는 bash <hooks>/lib/guard_promote.sh promote <id> --core <후보> [--test <후보시험>] 로만 한다. 조회·시험은 해석기/변수/리다이렉트 없이 직접 명령으로 한다." ;;
    *)
      _alt+="→ 보호 파일 교체는 bash <hooks>/lib/guard_promote.sh promote <id> --core <후보> [--test <후보시험>], 복구는 restore <id>, 조회는 cat/grep/sha256sum·status·verify 로 한다." ;;
  esac
  echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-GUARD-PROMOTE] 승격 경로 구성요소(lib/guard_promote.sh · guard_promote.json · gp_gate.sh · guard_promote_boot.sh · 고정 시험 test_pdg_readonly·test_pdg_hook·test_gp_self·test_gp_gate · backup/guard_promote · logs/guard_promote*)는 guard_promote.sh 만 갱신한다 — 에이전트(메인·팀 공통)는 파일 도구·셸 쓰기·잠금 점유·별칭으로 바꿀 수 없다 — git 은 2026-10-27 사용자 결정으로 허용된다(${TOOL_NAME}: ${_j}). 교체는 bash <hooks>/lib/guard_promote.sh promote <id> --core <후보> [--test <후보시험>], 복구는 bash <hooks>/lib/guard_promote.sh restore <id> 로 한다. 실행·조회(status·verify, cat/grep/sha256sum, git log/diff/show)는 허용된다. 시험 로그 파일명에는 이 이름을 넣지 마라. ${_alt}\"}"
  return 2
}
