#!/usr/bin/env python3
# 파이프라인 활성 중 사용자 입력 원문을 자기 세션 scope_markers/_user.json 에 자동 기록해 팀원에게 1회 전달되게 하는 스크립트 (L-1195 보강2)
"""scope_marker_autowrite.py <session_dir>   (stdin = 사용자 프롬프트 원문)

호출: UserPromptSubmit.sh — 메인 세션(팀원 아님) + state ∈ PLAN|DEV|TEST|DONE 일 때만.
기록: <session_dir>/scope_markers/_user.json (tmp + os.replace 원자 쓰기)
  {"type":"info","suspected":"stop|scope|none","message":원문(최대 2000자),"by":"auto-UserPromptSubmit","created_at":ISO8601}
설계:
  - type 은 항상 info 다. stop 자동 판정은 하지 않는다 — "중지 기능을 구현하라" 같은 문장을 stop 으로 오분류하면
    리드가 지울 때까지 팀원 전원의 쓰기가 막힌다(오분류 비용이 너무 크다). 대신 stop_marker_gate 가 info 도
    미확인 시 1회 보류 + 원문 전달을 하므로 지시는 반드시 팀원에게 닿는다. suspected 는 전달 문구 강조용 힌트다.
  - 리드가 쓰는 _all.json / <팀원>.json 과 파일을 분리한다 — 자동 기록이 리드의 stop 마커를 info 로 덮어쓰면
    중지가 해제되는 역효과가 나기 때문이다.
  - 세션 격리 불변식 (a): 인자로 받은 자기 세션 디렉토리에만 쓴다(호출부가 session_id 일치를 검증).
실패는 조용히 무시한다(사용자 입력 처리를 막지 않는다).
"""
import json
import os
import re
import sys
import time

# 영단어는 앞뒤가 영문자가 아닐 때만 — "TaskStop·" 같은 도구명(붙여넣은 hook 문구)에 걸리던 오분류 수정(2026-10-10 c174)
STOP_RX = re.compile(r"중지|중단|멈춰|멈추|그만|정지|하지\s*마|(?<![A-Za-z_])(?:stop|abort|halt)(?![A-Za-z_])", re.I)
SCOPE_RX = re.compile(r"범위|축소|제외|빼고|말고|만\s*(?:해|하|진행|테스트)|대상에서|건드리지|금지", re.I)


def main():
    if len(sys.argv) != 2:
        return
    sdir = sys.argv[1]
    if not os.path.isdir(sdir):
        return
    text = sys.stdin.read().strip()
    if not text:
        return
    suspected = "stop" if STOP_RX.search(text) else ("scope" if SCOPE_RX.search(text) else "none")
    mdir = os.path.join(sdir, "scope_markers")
    os.makedirs(mdir, exist_ok=True)
    payload = {"type": "info", "suspected": suspected, "message": text[:2000],
               "by": "auto-UserPromptSubmit", "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    path = os.path.join(mdir, "_user.json")
    tmp = "%s.tmp%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
