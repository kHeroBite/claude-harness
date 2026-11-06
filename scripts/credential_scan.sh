#!/bin/bash
# 배포 repo 전체를 스캔해 자격증명·개인정보 유출을 탐지하는 게이트 스크립트
#
# 사용법:  credential_scan.sh [스캔대상경로]   (기본값: repo 루트)
# 종료코드: 0 = 발견 0건 / 1 = 1건 이상 발견 (커밋·push 차단)
#
# ★설계 원칙★
#   - 자격증명 "값" 자체는 절대 출력하지 않는다. 파일:줄번호 + 패턴 종류만 보고한다.
#   - 화이트리스트는 최소로 유지한다. 넓히면 진짜 유출이 새어 나간다.
#   - oUpload 스킬 Step 1 과 git pre-commit hook 이 이 스크립트를 공통 호출한다 (2중 물리 차단).

set -uo pipefail

# ── 스캔 대상 결정 ────────────────────────────────────────────────
# 기본값은 항상 배포 repo 루트(스크립트 자기 위치의 부모, scripts/의 상위)로 고정한다.
# git rev-parse --show-toplevel을 쓰면 상위 AI repo 전체가 잡혀(원본 세션 로그 등 포함)
# 무의미한 대량 오탐이 발생하므로 사용하지 않는다.
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  TARGET="$(dirname "$SCRIPT_DIR")"
fi

if [ ! -d "$TARGET" ]; then
  echo "[ERROR] 스캔 대상 디렉토리가 없습니다: $TARGET" >&2
  exit 1
fi

FAIL=0
HIT_TOTAL=0

# ── 오탐 화이트리스트 (최소 유지) ────────────────────────────────
#  - <your-...>, your_api_key, YOUR_TOKEN 형태 placeholder
#  - example.com / example.org 예제 도메인
#  - PLACEHOLDER / CHANGEME / REDACTED / xxxxx 형태
#  - 본 스크립트 자신의 패턴 정의 라인 (자기탐지 방지)
#  - 규칙문서/README 의 패턴 설명 문구
WHITELIST='<your|your_api_key|your-api-key|YOUR_|example\.com|example\.org|example\.net|PLACEHOLDER|placeholder|CHANGEME|CHANGE_ME|REDACTED|dummy|DUMMY|sk-xxx|ghp_xxx|xxxxxxxx|0\.0\.0\.0|127\.0\.0\.1|localhost|패턴 종류|탐지 패턴|스캔 대상|노출 금지|출력하지 않는다|noreply@anthropic\.com|noreply@'

# 제외 디렉토리/파일 (배열 — 단어분할 사고 방지)
EXCLUDES=(
  --exclude-dir=.git
  --exclude-dir=.venv
  --exclude-dir=venv
  --exclude-dir=node_modules
  --exclude-dir=__pycache__
  --exclude-dir=.pytest_cache
  --exclude='*.bak'
  --exclude='*.bak.*'
  --exclude='*.log'
  --exclude='*.pyc'
  --exclude='credential_scan.sh'
)

# ── 스캔 함수 ─────────────────────────────────────────────────────
# $1 = 패턴 라벨, $2 = 확장 정규식
scan() {
  _label="$1"
  _regex="$2"
  _hits=$(grep -rniIE "$_regex" "$TARGET" "${EXCLUDES[@]}" 2>/dev/null \
          | grep -vE "$WHITELIST" \
          | cut -d: -f1,2)
  if [ -n "$_hits" ]; then
    _count=$(printf '%s\n' "$_hits" | wc -l | tr -d ' ')
    echo "[FAIL] ${_label} — ${_count}건"
    printf '%s\n' "$_hits" | sed 's|^'"$TARGET"'/||' | head -30 | sed 's/^/        /'
    if [ "$_count" -gt 30 ]; then
      echo "        ... (${_count}건 중 상위 30건만 표시)"
    fi
    HIT_TOTAL=$((HIT_TOTAL + _count))
    FAIL=1
  fi
}

echo "🔍 자격증명 스캔 시작 — 대상: $TARGET"
echo "   (발견 시 파일:줄번호만 출력하며, 자격증명 값 자체는 출력하지 않습니다)"
echo ""

# 1) 평문 비밀번호 — password/passwd/pwd 뒤에 실제 값이 붙은 경우
#    ${VAR} / $VAR / <...> 로 시작하면 변수·placeholder 이므로 제외
scan "평문 비밀번호 (password/passwd/pwd)" \
     '(password|passwd|pwd|PASSWORD|PASSWD)[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'$<{)]{3,}'

# 2) API 키 / 토큰 / 시크릿
scan "API 키·토큰·시크릿 (api_key/apikey/token/secret)" \
     '(api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9_\-]{12,}'

# 3) 공급자별 키 접두어 (형태만으로 확정 가능한 것들)
scan "공급자 키 형태 (sk-/sk-ant-/ghp_/AKIA 등)" \
     '(sk-[A-Za-z0-9]{16,}|sk-ant-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk_live_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{10,})'

# 4) 사설·내부 IP (RFC1918 + 공인 IP 하드코딩)
scan "사설·내부 IP 주소" \
     '(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})'

# 5) 공인 IP 하드코딩 (운영 서버 주소 유출) — 버전문자열 오탐을 줄이려 4옥텟 전체 형태만
scan "공인 IP 하드코딩 (운영 서버 주소 의심)" \
     '(ssh|scp|rsync|host|HOST|server|SERVER|DB_HOST)[[:space:]]*[:=@ ]+[[:space:]]*["'"'"']?([0-9]{1,3}\.){3}[0-9]{1,3}'

# 6) 개인 경로 (홈 디렉토리 하드코딩)
scan "개인 경로 하드코딩 (/home/<사용자>, C:\\Users\\<사용자>)" \
     '(/home/[a-z][a-z0-9_-]{2,}/|/Users/[A-Za-z][A-Za-z0-9_-]{2,}/|C:\\\\Users\\\\[A-Za-z][A-Za-z0-9_-]{2,})'

# 7) 이메일 주소
scan "이메일 주소" \
     '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(com|net|org|co\.kr|kr|io|dev)'

# 8) SSH·PGP 사설키 본문
scan "사설키 본문 (PRIVATE KEY 블록)" \
     'BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY'

# 9) DB 접속 문자열 안의 자격증명
scan "DB 접속 문자열 내 자격증명" \
     '(mysql|postgres|postgresql|mongodb|redis)://[^:/[:space:]]+:[^@[:space:]]+@'

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 자격증명 스캔 통과 — 발견 0건"
else
  echo "🚫 자격증명 스캔 실패 — 총 ${HIT_TOTAL}건 발견. 커밋·push 를 차단합니다."
  echo "   조치: 해당 위치의 값을 환경변수 또는 <your-...> 형태 placeholder 로 교체하십시오."
  echo "   ※ '이번만 넘어가자' 는 금지입니다 (재발방지 정책 — 물리 차단)."
fi

exit "$FAIL"
