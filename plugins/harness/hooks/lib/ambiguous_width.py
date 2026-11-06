#!/usr/bin/env python3
# East Asian Ambiguous 폭 기호(→ ★ ※ 등) 뒤에 공백 1칸을 넣어 터미널 글자 겹침을 막는 공용 보정 lib
"""사용법
  CLI   : printf '%s' "A→B" | python3 ambiguous_width.py        → "A→ B" (stdin 전체를 보정해 stdout, 개행 추가 없음)
          python3 ambiguous_width.py --check < 입력             → 보정이 필요하면 rc=1, 아니면 rc=0 (출력 없음)
  import: from ambiguous_width import pad_ambiguous, needs_pad, ambiguous_symbols

배경 (2026-10-11 사용자 보고)
  팀원 pane 제목 "승인 채널→자동검증 게이트 계획" 에서 → 다음 글자 '자' 가 → 와 겹쳐 그려졌다.
  → 는 Unicode East Asian Width = A(Ambiguous) 다. 문자 폭을 1칸으로 세는 쪽(tmux·Claude Code)과
  2칸으로 그리는 쪽(터미널 글꼴)이 어긋나면 뒤 글자가 기호 오른쪽 절반 위에 겹친다.
  기호 뒤에 공백 1칸을 두면 겹치는 자리가 공백이 되어 글자가 가려지지 않는다.

대상 문자 (모두 충족)
  - unicodedata.east_asian_width(c) == 'A'
  - 일반 범주가 So/Sm/Sk/Sc/Po/Pd (기호·일반 구두점). 여는/닫는 괄호·따옴표(Ps/Pe/Pi/Pf)는 제외 — “ 뒤 공백은 문장을 망친다.
  - 한글·영숫자·라틴 확장 문자는 범주가 L*/N* 이라 자연히 제외된다.
삽입 규칙
  - 대상 문자 바로 뒤가 공백류(isspace)·문자열 끝이면 그대로 둔다 → 멱등.
  - 바로 뒤가 ZWJ(U+200D)·이형 선택자(U+FE00~FE0F)·결합 문자(M*)면 그대로 둔다 (이모지 시퀀스 🏃‍♀️ 보호).
  - 바로 앞이 ZWJ 인 대상 문자(♀ 등 이모지 시퀀스 구성원)도 그대로 둔다.
"""
import sys
import unicodedata

_CATS = frozenset(("So", "Sm", "Sk", "Sc", "Po", "Pd"))
_ZWJ = "‍"


def is_ambiguous_symbol(ch):
    """폭 A 이면서 기호·일반 구두점 범주인 문자인가."""
    if not ch or ord(ch) < 0x80:
        return False
    return unicodedata.east_asian_width(ch) == "A" and unicodedata.category(ch) in _CATS


def _is_joiner(ch):
    """이모지 시퀀스를 잇는 문자(ZWJ·이형 선택자·결합 문자)인가."""
    if ch == _ZWJ:
        return True
    o = ord(ch)
    if 0xFE00 <= o <= 0xFE0F or 0xE0100 <= o <= 0xE01EF:
        return True
    return unicodedata.category(ch).startswith("M")


def _iter_targets(s):
    """공백을 넣어야 하는 위치(대상 문자의 인덱스)를 차례로 낸다."""
    n = len(s)
    for i, ch in enumerate(s):
        if not is_ambiguous_symbol(ch):
            continue
        if i > 0 and s[i - 1] == _ZWJ:
            continue
        if i + 1 >= n:
            continue
        nxt = s[i + 1]
        if nxt.isspace() or _is_joiner(nxt):
            continue
        yield i


def pad_ambiguous(s):
    """대상 기호 뒤에 공백이 없으면 공백 1칸을 넣은 문자열을 돌려준다(멱등)."""
    if not isinstance(s, str) or not s:
        return s
    idx = set(_iter_targets(s))
    if not idx:
        return s
    out = []
    for i, ch in enumerate(s):
        out.append(ch)
        if i in idx:
            out.append(" ")
    return "".join(out)


def needs_pad(s):
    """보정이 필요한 위치가 하나라도 있는가."""
    if not isinstance(s, str) or not s:
        return False
    for _ in _iter_targets(s):
        return True
    return False


def ambiguous_symbols(s):
    """보정이 필요한 기호 목록(중복 제거, 등장 순)."""
    seen = []
    if isinstance(s, str):
        for i in _iter_targets(s):
            if s[i] not in seen:
                seen.append(s[i])
    return seen


def _main(argv):
    data = sys.stdin.buffer.read().decode("utf-8", errors="surrogateescape")
    if "--check" in argv:
        return 1 if needs_pad(data) else 0
    sys.stdout.buffer.write(pad_ambiguous(data).encode("utf-8", errors="surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
