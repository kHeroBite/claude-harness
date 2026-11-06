#!/usr/bin/env bash
# auto 모드 안전분류기 거부(PermissionDenied) 시 특별/일반 작업을 판정해 안내를 내는 얇은 진입점 — 판정은 lib/permission_denied_judge.py
# 문서상 종료 코드·stderr 는 무시되므로 항상 rc 0. retry 는 내지 않는다(재시도 금지 정책).
_PD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I "${_PD_DIR}/lib/permission_denied_judge.py"
exit 0
