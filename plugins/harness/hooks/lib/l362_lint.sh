#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# l362_lint.sh — session_manager.py 수정 시 L-362 위반 정적 검사
# 호출: write_guard.sh가 session_manager.py (또는 oio-mcp-server/*.py) 대상 write 감지 시
# 구현: Python 3 내장 ast 모듈만 사용 (외부 의존성 금지)
# 출처: oplan_final_v2.md §4 F11 + debate_3_v2.md §5.3
set -e
TARGET="${1:?target file required}"
[ -f "$TARGET" ] || exit 0

python3 - "$TARGET" <<'PY'
import sys, ast
path = sys.argv[1]
try:
    src = open(path, encoding='utf-8').read()
except OSError as e:
    print(f"[l362_lint] OSError: {e}", file=sys.stderr); sys.exit(0)
try:
    tree = ast.parse(src)
except SyntaxError as e:
    print(f"[l362_lint] SyntaxError: {e}", file=sys.stderr); sys.exit(0)

# L-362 금지 함수: lock 보유 중 blocking I/O 차단.
# 원칙 (CLAUDE.md L-362): "lock 안 목록만 수집, I/O는 lock 밖".
# 허용 (blocking 없음): os.listdir, os.scandir, os.path.exists, Path.iterdir, Path.glob, Path.exists
# 차단 (blocking file I/O): open, read, write, rename, replace, remove, stat, shutil.copy/move, Path.read_*/write_*
FORBIDDEN = {
    ('open',),                               # builtin 파일 열기
    ('os', 'stat'),                          # stat: NTFS/SMB에서 blocking
    ('os', 'remove'), ('os', 'rename'), ('os', 'replace'),
    ('os', 'open'), ('os', 'read'), ('os', 'write'), ('os', 'close'),
    ('os', 'makedirs'), ('os', 'mkdir'), ('os', 'rmdir'), ('os', 'unlink'),
    ('shutil', 'copy'), ('shutil', 'copy2'), ('shutil', 'copyfile'),
    ('shutil', 'move'), ('shutil', 'rmtree'),
    ('Path', 'read_text'), ('Path', 'write_text'),
    ('Path', 'read_bytes'), ('Path', 'write_bytes'),
    ('json', 'load'), ('json', 'dump'),
}
# Path-like 체인 호출(`Path("x").read_text()`)은 receiver가 Call이라 2-tuple 매칭이 안 되므로,
# attribute name 단독 매칭용 1-tuple 셋을 별도 유지.
FORBIDDEN_ATTR_ONLY = {
    ('read_text',), ('write_text',), ('read_bytes',), ('write_bytes',),
}

violations = []

class V(ast.NodeVisitor):
    def __init__(self):
        self.in_lock = 0

    def visit_With(self, node):
        enter_lock = False
        for item in node.items:
            ctx = item.context_expr
            name = ''
            # `with _fs_lock:` → Name
            if isinstance(ctx, ast.Name):
                name = ctx.id
            # `with _fs_lock(...):` → Call(func=Name|Attribute)
            elif isinstance(ctx, ast.Call):
                f = ctx.func
                if isinstance(f, ast.Name):
                    name = f.id
                elif isinstance(f, ast.Attribute):
                    name = f.attr
            # `with self._fs_lock:` → Attribute
            elif isinstance(ctx, ast.Attribute):
                name = ctx.attr
            # 변수명 whitelist: `_fs_lock` 정확 일치 또는 `*_fs_lock`로 끝나는 식별자만
            if name == '_fs_lock' or name.endswith('_fs_lock'):
                enter_lock = True
        if enter_lock:
            self.in_lock += 1
        self.generic_visit(node)
        if enter_lock:
            self.in_lock -= 1

    def visit_AsyncWith(self, node):
        # async with도 동일 처리
        self.visit_With(node)

    def visit_Call(self, node):
        if self.in_lock > 0:
            f = node.func
            sig = None
            if isinstance(f, ast.Name):
                sig = (f.id,)
            elif isinstance(f, ast.Attribute):
                if isinstance(f.value, ast.Name):
                    sig = (f.value.id, f.attr)
                else:
                    sig = (f.attr,)
            if sig:
                if sig in FORBIDDEN:
                    violations.append((node.lineno, '.'.join(sig)))
                elif len(sig) == 1 and sig in FORBIDDEN_ATTR_ONLY:
                    violations.append((node.lineno, f".{sig[0]}"))
        self.generic_visit(node)

V().visit(tree)

if violations:
    for ln, sym in violations:
        print(
            f"[l362_lint] VIOLATION {path}:{ln} — {sym}() inside _fs_lock block",
            file=sys.stderr,
        )
    sys.exit(1)
PY
