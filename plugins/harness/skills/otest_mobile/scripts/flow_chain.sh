#!/bin/bash
# 시나리오 흐름 골격 — 프로젝트별 화면 흐름(등록·삭제 등)을 이 틀에 채워 acct_chain.sh 단계로 쓴다
# 사용: flow_chain.sh <TAG>   환경변수: madb.sh 와 동일 + (acct_chain 경유 시) ACCT_* · STEP_OUT
# 이 파일은 복사해서 쓰는 템플릿이다. 아래 "흐름" 블록만 바꾸고 헬퍼(T·dmp·xy·tapx·waitlog·fail)는 그대로 둔다.
export LC_ALL=C.UTF-8
HERE=$(cd "$(dirname "$0")" && pwd); M="bash $HERE/madb.sh"; TAPX="bash $HERE/tapx.sh"
TAG=${1:-${ACCT_TAG:-x}}; OUT=${OUT:-./otest_mobile_out}; D=${STEP_OUT:-$OUT/$TAG}; mkdir -p "$D"
T() { echo "$(date '+%F %T') [flow $TAG] $*" | tee -a "$D/timeline.txt"; }
dmp() { $M dump > "$D/_chk.txt"; }
xy() { grep -aE "$1" "$D/_chk.txt" | head -1 | sed -E 's/^\S+ +\(([0-9]+),([0-9]+)\).*/\1 \2/'; }
tapx() { $TAPX "$1" "${2:-3}" || { T "못 찾음: $1"; return 1; }; }
# waitlog <정규식> [간격초=2] [횟수=20] — 앱 로그에 완료 신호가 나올 때까지 대기(화면 추정 대신 로그 신호로 판정)
waitlog() { for _i in $(seq 1 "${3:-20}"); do /bin/sleep "${2:-2}"; [ "$($M log "$1" 1 | wc -l)" -ge 1 ] && return 0; done; T "로그 대기 초과 '$1'"; return 1; }
fail() { T "실패: $*"; $M shot "flow_${TAG}_fail" >/dev/null; exit 1; }

# 0) 하위 화면에 남아 있으면 BACK 으로 루트까지 (탭 재탭은 루트로 안 돌아가는 앱이 있다)
for _b in 1 2 3 4 5; do dmp; grep -qa "'' 'Navigate up'" "$D/_chk.txt" || break; $M key 4; /bin/sleep 3; done

# ── 흐름 (프로젝트별로 교체) ─────────────────────────────
# 예) $M logc; tapx "Button.*'저장'" 3 || fail "저장 버튼"
#     waitlog '저장 완료 로그 정규식' 2 15 || fail "저장 로그"
#     본문에 테스트 표식(예: [cNNNtest] $TAG)을 반드시 넣어 사후 잔여 0 실측이 가능하게 한다.
# ─────────────────────────────────────────────────────────
T "흐름 골격 — 교체 필요"
