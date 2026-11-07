# 머신 종류(wsl/linux)와 표시 이모지를 정하는 단일 규칙 모듈(statusline.py·set_terminal_title.sh 공용)
"""호스트 판정·이모지 단일 규칙.

판정 순서(host_tag):
  1. CLAUDE_HOST_TAG 가 유효하고 값이 wsl/linux 이면 그 값
  2. WSL_DISTRO_NAME 이 있거나 /proc/version 에 microsoft(대소문자 무시)가 있으면 wsl
  3. 그 밖은 linux

이모지(host_emoji):
  CLAUDE_HOST_EMOJI 가 유효하면 그 값, 아니면 기본값(wsl=🖥️, linux=🗄️).

환경변수 검증(두 변수 공통): 공백·제어문자·'#'·'%' 금지. CLAUDE_HOST_EMOJI 는 코드포인트 1~4개(ZWJ·VS16 포함),
CLAUDE_HOST_TAG 는 ^[A-Za-z0-9_-]{1,12}$ 를 만족해야 한다('linux' 가 5글자라 태그에는 4개 상한을 쓰지 않는다). 위반하면 자동 판정·기본 이모지로 폴백한다.

CLI: python3 -B host_label.py [tag|emoji]   (인자 없으면 emoji)
표준 라이브러리만 쓴다(python 3.10 호환).
"""
import os
import re
import sys

# 기본 이모지(2026-11-06 사용자 확정 '5번' — 🖥️ U+1F5A5 U+FE0F, 🗄️ U+1F5C4 U+FE0F)
DEFAULT_EMOJI = {
    'wsl': '\U0001F5A5️',
    'linux': '\U0001F5C4️',
}
_TAG_RE = re.compile(r'^[A-Za-z0-9_-]{1,12}$')
_MAX_CODEPOINTS = 4
PROC_VERSION = '/proc/version'  # 시험이 바꿔 끼울 수 있게 모듈 상수로 둔다


def _valid_env_value(value, max_len=_MAX_CODEPOINTS):
    """공통 검증 — 공백·제어문자·'#'·'%' 금지, 코드포인트 1~max_len 개(이모지 4, 태그는 정규식 상한 12)."""
    if not value or len(value) > max_len:
        return False
    for ch in value:
        if ch.isspace() or ch in '#%' or ord(ch) < 0x20 or ord(ch) == 0x7F:
            return False
    return True


def _is_wsl():
    if os.environ.get('WSL_DISTRO_NAME'):
        return True
    try:
        with open(PROC_VERSION, 'r', encoding='utf-8', errors='replace') as f:
            return 'microsoft' in f.read().lower()
    except OSError:
        return False


def host_tag():
    """'wsl' 또는 'linux'."""
    tag = os.environ.get('CLAUDE_HOST_TAG', '')
    if _valid_env_value(tag, 12) and _TAG_RE.fullmatch(tag):
        low = tag.lower()
        if low in DEFAULT_EMOJI:
            return low
    return 'wsl' if _is_wsl() else 'linux'


def host_emoji(tag=None):
    """표시 이모지. CLAUDE_HOST_EMOJI 유효값 우선, 아니면 호스트 기본값."""
    custom = os.environ.get('CLAUDE_HOST_EMOJI', '')
    if _valid_env_value(custom):
        return custom
    return DEFAULT_EMOJI.get(tag or host_tag(), DEFAULT_EMOJI['linux'])


def main(argv):
    what = argv[1] if len(argv) > 1 else 'emoji'
    if what == 'tag':
        out = host_tag()
    elif what == 'emoji':
        out = host_emoji()
    else:
        sys.stderr.write('사용법: host_label.py [tag|emoji]\n')
        return 2
    sys.stdout.buffer.write((out + '\n').encode('utf-8'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
