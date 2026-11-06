#!/usr/bin/env python3
# 온디맨드 에이전트가 .mcp.json 에 정의된 MCP 서버를 자격증명 노출 없이 띄우는 래퍼
"""사용법: python3 mcp_ondemand.py <.mcp.json 서버명>

에이전트 정의(.claude/agents/*.md)의 인라인 mcpServers 는 저장소에 커밋되므로
API 키 같은 값을 직접 적을 수 없다. 이 래퍼는 커밋되지 않는 저장소 루트의
.mcp.ondemand.json(기본 OFF 서버 정의)을 먼저 읽고, 없거나 그 서버가 없으면
.mcp.json 에서 같은 이름의 서버 정의(command·args·env)를 찾아 그대로 exec 한다.
값은 출력하지 않는다. 서버가 없으면 rc=2 로 끝난다.
"""
import json
import os
import sys


def 저장소_루트() -> str:
    # 이 파일은 <루트>/.claude/scripts/ 에 있다.
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main() -> int:
    if len(sys.argv) != 2:
        print("사용법: mcp_ondemand.py <서버명>", file=sys.stderr)
        return 2
    이름 = sys.argv[1]
    정의 = None
    # 온디맨드 정의 파일 우선, 없으면 .mcp.json 폴백
    for 파일명 in (".mcp.ondemand.json", ".mcp.json"):
        경로 = os.path.join(저장소_루트(), 파일명)
        if not os.path.isfile(경로):
            continue
        try:
            with open(경로, encoding="utf-8") as f:
                정의 = json.load(f).get("mcpServers", {}).get(이름)
        except (OSError, ValueError) as e:
            print(f"[mcp_ondemand] {파일명} 읽기 실패: {type(e).__name__}", file=sys.stderr)
            continue
        if 정의:
            break
    if not 정의 or not 정의.get("command"):
        print(f"[mcp_ondemand] .mcp.ondemand.json·.mcp.json 에 '{이름}' 정의 없음", file=sys.stderr)
        return 2
    환경 = dict(os.environ)
    환경.update({k: str(v) for k, v in (정의.get("env") or {}).items()})
    명령 = [정의["command"], *[str(a) for a in (정의.get("args") or [])]]
    os.execvpe(명령[0], 명령, 환경)
    return 0  # 도달하지 않음


if __name__ == "__main__":
    sys.exit(main())
