# bash_exec stdout/stderr 출력 필터 훅 (1~2단계: 항상 no-op)
"""
oio_output_filter_design.md 기반 구현. 이번 사이클 범위는 게이트 1~3만이며
필터 카탈로그가 비어 있으므로 어떤 게이트를 통과해도 항상 원문(response)을
그대로 반환한다 — 완전 no-op.

게이트 순서 (maybe_apply):
  1. OIO_OUTPUT_FILTER_ENABLED != "1"        → 원문 반환 (설계 §5-4 opt-in)
  2. response["exit_code"] != 0              → 원문 반환 (설계 §5-1 하드 룰,
                                                bash_exec.py 삽입 지점 자체가
                                                이미 exit_code==0 전용이지만
                                                방어적 이중 체크)
  3. len(stdout)+len(stderr) < MIN_FILTER_BYTES → 원문 반환 (설계 §5-2)
  4. 필터 카탈로그 로드 → 매칭 필터 없음(이번 사이클 항상 없음) → 원문 반환

실제 필터 적용(카탈로그 로드/매칭/압축/원문 백업)은 다음 사이클(4단계 이후)
에서 이 모듈에 추가한다. 이번 사이클은 게이트 1~3의 통과 여부만 검증 가능하게
만드는 것이 목적이다.
"""
import os

# 설계 §5-2 — 이 크기 미만이면 필터를 타지 않는다 (Headroom min_tokens_to_compress 개념 이식)
MIN_FILTER_BYTES = 4096


def _load_catalog():
    """필터 카탈로그 로드. 이번 사이클은 항상 빈 카탈로그.

    설계 계획서 §D(카탈로그는 매 호출 로드) 준수 — 캐시하지 않는다.
    다음 사이클에서 filters/*.toml을 매 호출 시 로드하도록 이 함수를 확장한다.
    """
    return []


def maybe_apply(command: str, response: dict) -> dict:
    """bash_exec 정상 종료 반환 직전 훅. 실패 시 항상 원문(response) 그대로 반환한다."""
    if os.environ.get("OIO_OUTPUT_FILTER_ENABLED") != "1":
        return response

    if response.get("exit_code") != 0:
        return response

    stdout = response.get("stdout", "") or ""
    stderr = response.get("stderr", "") or ""
    if len(stdout) + len(stderr) < MIN_FILTER_BYTES:
        return response

    catalog = _load_catalog()
    if not catalog:
        return response

    # 이번 사이클 범위 밖 — 카탈로그가 항상 비어 있으므로 여기 도달하지 않는다.
    return response
