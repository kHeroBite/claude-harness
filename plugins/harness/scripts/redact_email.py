#!/usr/bin/env python3
# 표준입력의 이메일 주소와 ntfy 토픽 값을 가려서 표준출력으로 내보내는 출력 필터
"""사용법: <명령> | python3 -I -B redact_email.py

- 이메일 주소(ASCII) -> [이메일 가림]
- topic=값 / topic: 값 / ntfy.sh/값 -> 값 부분만 [토픽 가림]
- 가릴 것이 없는 입력은 바이트 단위로 그대로 통과한다(줄 단위 처리, 인코딩 가정 없음).
"""
import re
import sys

_EMAIL = re.compile(rb"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+")
_TOPIC_KV = re.compile(rb"(?i)(\btopic\s*[=:]\s*[\"']?)[^\s\"'&,;<>]+")
_NTFY_URL = re.compile(rb"(?i)(ntfy\.sh/)[^\s\"'?#<>]+")


def redact(line: bytes) -> bytes:
    line = _EMAIL.sub("[이메일 가림]".encode("utf-8"), line)
    line = _TOPIC_KV.sub(rb"\1" + "[토픽 가림]".encode("utf-8"), line)
    line = _NTFY_URL.sub(rb"\1" + "[토픽 가림]".encode("utf-8"), line)
    return line


def main() -> int:
    src = sys.stdin.buffer
    dst = sys.stdout.buffer
    for line in src:
        dst.write(redact(line))
    dst.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
