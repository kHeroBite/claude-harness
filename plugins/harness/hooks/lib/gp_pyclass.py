# gp_gate 가 부르는 python 단독 호출 분류기 — 쓰기 대상이 보호 파일이 아님이 정적으로 확실할 때만 SAFE 를 낸다(c214 R3)
#
# 사용  python3 -I -S gp_pyclass.py --hooks <hooks 디렉터리>  < 명령 원문(stdin)
#       python3 -I -S gp_pyclass.py --hooks <hooks 디렉터리> --code < 파이썬 코드(stdin, 시험용)
# 출력  첫 줄 SAFE 또는 UNSAFE <사유>. rc 는 항상 0(판정 실패도 UNSAFE). 파일 쓰기 없음.
#
# 명령 형태(하나라도 어기면 UNSAFE — 호출부 gp_gate 는 종전 판정으로 간다)
#   P1  python[3[.N]] [-IBSEsuOq…] -c '<코드>' [리터럴 인자…] [2>&1|2>/dev/null|>/dev/null]
#       큰따옴표 코드는 안에 $ ` \ " 가 없을 때만. 명령 전체가 이 한 호출이어야 한다(; && | 등 다른 명령 없음).
#   P2  python[3[.N]] [옵션…] [-] [리터럴 인자…] <<['"]W['"]  ⏎ 본문 ⏎ W   (인용 종결자만 — 비인용은 셸 전개가 있어 UNSAFE)
#       종결자 줄 뒤에는 빈 줄만 허용. 여는 줄에 다른 것이 없어야 한다.
#   리터럴 인자는 셸 메타 글자가 없고 보호 토큰·hooks 보호 디렉터리 글자를 품지 않아야 한다(코드가 argv 를 어디에 쓰는지 따지지 않는다).
#
# 코드 SAFE 조건(전부)
#   · ast 파싱 성공. 이름·속성 중 __ 로 시작하는 것 없음. exec·eval·compile·__import__·getattr·setattr·delattr·globals·locals·vars·
#     breakpoint 이름 없음.
#   · import 는 허용 목록 모듈만, as 별칭·* 없음. os·sys·pathlib 은 허용 속성만(os 의 쓰기·실행 함수는 makedirs·mkdir 외 전부 불허).
#   · (D-18) 정적 해석이 기대는 이름을 변조할 수 없어야 한다 — 속성 대입·삭제(어떤 대상이든), import 로 들인 이름의
#     재대입·재정의·del·인자·중복 import, 모듈 객체를 이름 밖으로 넘기기(x=os, f(os.path), y=path), 모듈을 거쳐 다른 모듈에
#     닿는 속성(glob.os·fnmatch.posixpath 등), 모듈 이름에 뿌리를 둔 첨자 대입·삭제가 하나라도 있으면 UNSAFE.
#   · 쓰기 지점 — open(경로, 모드)의 리터럴 모드에 w·a·x·+ 가 있거나, Path(경로).write_text·write_bytes·touch·mkdir·open(쓰기 모드),
#     os.makedirs·os.mkdir — 의 경로가 ★절대 경로 리터럴★ 이고 보호 토큰·hooks 보호 디렉터리·.. 를 품지 않으며, realpath 가
#     hooks 보호 디렉터리 아래가 아니다. 모드가 리터럴이 아니면 UNSAFE.
#   · 파괴·별칭 메서드(unlink·rename·rmdir·symlink_to·hardlink_to·chmod·lchmod·1인자 replace)는 UNSAFE.
#   · open·Path·write_text 등을 호출하지 않고 이름으로만 다루는 꼴(w=open)은 UNSAFE.
#   · 보호 표식(토큰·hooks 보호 디렉터리)을 품은 문자열 리터럴이 호출 인자로 쓰이면, 그 호출이 읽기 open·Path(…).읽기 메서드·
#     허용 조회 함수일 때만 허용한다(알 수 없는 호출로 보호 경로를 넘기는 꼴 차단).
#
# 한계(정직 고지) — 다른 해석기(perl·node 등)는 다루지 않는다(종전 판정). cwd 에 심은 모듈(json.py 등)을 import 가 읽는 2단계는
#   종전부터 같은 등급(스크립트 파일 실행 허용)이다. 판정은 정적 문자열·AST 기준이다.
import ast
import os
import re
import sys

TOK = re.compile(r"guard_promote|test_pdg_readonly|test_pdg_hook|gp_gate|test_gp_self|test_gp_gate", re.I)
HDIR = re.compile(r"(^|/)hooks/+(lib|tests|backup|logs)(/|$)", re.I)

ALLOWED_MODULES = {
    "json", "sys", "os", "os.path", "re", "hashlib", "pathlib", "glob", "datetime", "time", "collections", "itertools",
    "math", "base64", "textwrap", "string", "functools", "statistics", "csv", "operator", "fnmatch", "difflib", "pprint",
    "unicodedata", "struct", "binascii", "typing", "enum", "secrets", "random", "decimal", "fractions", "uuid",
}
OS_ATTRS = {
    "path", "environ", "getcwd", "listdir", "scandir", "stat", "lstat", "walk", "sep", "linesep", "getenv", "getpid",
    "cpu_count", "access", "readlink", "fspath", "R_OK", "F_OK", "W_OK", "X_OK", "name", "curdir", "pardir",
    "makedirs", "mkdir",
}
SYS_ATTRS = {
    "argv", "exit", "stdout", "stderr", "stdin", "version", "version_info", "platform", "maxsize", "executable",
    "getsizeof", "byteorder", "getdefaultencoding", "getfilesystemencoding",
}
PATHLIB_ATTRS = {"Path", "PurePath", "PurePosixPath", "PosixPath"}
BANNED_NAMES = {"exec", "eval", "compile", "__import__", "getattr", "setattr", "delattr", "globals", "locals", "vars",
                "breakpoint", "memoryview"}
WRITE_METHODS = {"write_text", "write_bytes", "touch", "mkdir"}
DESTROY_METHODS = {"unlink", "rename", "rmdir", "symlink_to", "hardlink_to", "chmod", "lchmod"}
PATH_READ_METHODS = {"read_text", "read_bytes", "exists", "is_file", "is_dir", "stat", "lstat", "open", "resolve",
                     "iterdir", "glob", "rglob", "is_symlink", "readlink", "absolute"}
SAFE_FUNCS = {"print", "len", "str", "repr", "sorted", "list", "set", "tuple", "frozenset", "dict", "bool", "hash"}
SAFE_MOD_FUNCS = {("glob", "glob"), ("glob", "iglob"), ("os", "listdir"), ("os", "stat"), ("os", "lstat"),
                  ("os", "scandir"), ("os", "walk"), ("os", "access"), ("os", "readlink"), ("re", "search"),
                  ("re", "match"), ("re", "fullmatch"), ("re", "findall"), ("re", "finditer"), ("re", "split"),
                  ("re", "sub"), ("fnmatch", "fnmatch")}
STR_METHODS = {"startswith", "endswith", "find", "rfind", "count", "index", "rindex", "split", "rsplit", "join",
               "strip", "lstrip", "rstrip", "format", "encode", "partition", "rpartition", "lower", "upper"}


class Unsafe(Exception):
    pass


def marked(s):
    return bool(TOK.search(s) or HDIR.search(s))


class Classifier:
    def __init__(self, hooks, env=None):
        self.hooks_real = os.path.realpath(hooks) if hooks else ""
        self.hooks_raw = hooks or ""
        self.mods = {}          # 지역 이름 → 모듈 이름(import 로 들인 것)
        self.fromnames = {}     # 지역 이름 → (모듈, 원래 이름)
        self.parents = {}
        self.env = dict(env or {})  # K2: 명령 앞 환경 대입(리터럴 절대 경로) — os.environ['X'] 정적 해석용
        self.env_ok = False
        self.consts = {}        # K2: 모듈 최상위에서 한 번만 묶이는 이름 → 대입 값 노드

    # ── K2(D-7): 쓰기 경로 정적 해석 ──
    def collect_consts(self, tree):
        """모듈 최상위 단일 대입(NAME = 값)이면서 프로그램 전체에서 그 이름이 단 한 번만 묶이는 것만 상수 후보로 둔다."""
        cnt = {}

        def b(name, k=1):
            cnt[name] = cnt.get(name, 0) + k
        for n in ast.walk(tree):
            if isinstance(n, ast.Name) and not isinstance(n.ctx, ast.Load):
                b(n.id)
            elif isinstance(n, ast.arg):
                b(n.arg)
            elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                b(n.name)
            elif isinstance(n, (ast.Global, ast.Nonlocal)):
                for x in n.names:
                    b(x, 2)
            elif isinstance(n, ast.ExceptHandler) and n.name:
                b(n.name)
            elif isinstance(n, (ast.Import, ast.ImportFrom)):
                for a in n.names:
                    b((a.asname or a.name).split(".")[0])
            else:
                for f in ("name", "rest"):           # match 패턴(MatchAs·MatchStar·MatchMapping)의 묶음 이름
                    v = getattr(n, f, None) if type(n).__name__.startswith("Match") else None
                    if isinstance(v, str):
                        b(v)
        for st in tree.body:
            if isinstance(st, ast.Assign) and len(st.targets) == 1 and isinstance(st.targets[0], ast.Name) \
                    and cnt.get(st.targets[0].id) == 1:
                self.consts[st.targets[0].id] = st.value

    def is_environ(self, node):
        return isinstance(node, ast.Attribute) and node.attr == "environ" and isinstance(node.value, ast.Name) \
            and self.mods.get(node.value.id) == "os"

    def check_environ(self, tree):
        """os.environ 이 읽기(os.environ['K'] 적재·os.environ.get('K'))로만 쓰일 때만 환경 접두 값을 믿는다."""
        for n in ast.walk(tree):
            if self.is_environ(n):
                par = self.parents.get(n)
                if isinstance(par, ast.Subscript) and par.value is n and isinstance(par.ctx, ast.Load):
                    continue
                if isinstance(par, ast.Attribute) and par.attr == "get":
                    gp = self.parents.get(par)
                    if isinstance(gp, ast.Call) and gp.func is par:
                        continue
                return
            if isinstance(n, ast.Name) and self.fromnames.get(n.id, ("",))[0] == "os":
                return                              # from os import environ·getenv 류 — 해석하지 않는다
        self.env_ok = True

    # ── D-18: 정적 해석에 쓰는 이름(os·os.path·join·environ 과 그 from-import 이름)의 변조 차단 ──
    @staticmethod
    def chain_root(node):
        while isinstance(node, (ast.Attribute, ast.Subscript, ast.Call, ast.Starred)):
            node = node.func if isinstance(node, ast.Call) else node.value
        return node.id if isinstance(node, ast.Name) else None

    def check_mutation(self, tree):
        """속성 대입·삭제, import 이름 재바인딩, 모듈 객체 유출, 모듈 경유 모듈 접근이 있으면 해석을 포기하고 UNSAFE(D-18)."""
        guarded = set(self.mods) | set(self.fromnames)
        if set(self.mods) & set(self.fromnames):
            raise Unsafe("import 이름 충돌")
        seen = {}
        for n in ast.walk(tree):
            if isinstance(n, (ast.Import, ast.ImportFrom)):
                for a in n.names:
                    k = (a.asname or a.name).split(".")[0]
                    v = (getattr(n, "module", None) or "", a.name.split(".")[0] if isinstance(n, ast.Import) else a.name)
                    if seen.setdefault(k, v) != v:
                        raise Unsafe("같은 이름을 다른 대상으로 import " + k)
        bound = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Name) and not isinstance(n.ctx, ast.Load):
                bound.add(n.id)
            elif isinstance(n, ast.arg):
                bound.add(n.arg)
            elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                bound.add(n.name)
            elif isinstance(n, (ast.Global, ast.Nonlocal)):
                bound.update(n.names)
            elif isinstance(n, ast.ExceptHandler) and n.name:
                bound.add(n.name)
            elif type(n).__name__.startswith("Match"):
                for f in ("name", "rest"):
                    v = getattr(n, f, None)
                    if isinstance(v, str):
                        bound.add(v)
        hit = bound & guarded
        if hit:
            raise Unsafe("import 이름 재대입·재정의 " + ",".join(sorted(hit)))
        modlike = {"os", "sys", "posixpath", "genericpath", "ntpath", "builtins", "modules", "importlib"}
        for n in ast.walk(tree):
            par = self.parents.get(n)
            is_base = isinstance(par, (ast.Attribute, ast.Subscript)) and par.value is n
            if isinstance(n, ast.Attribute):
                if not isinstance(n.ctx, ast.Load):
                    raise Unsafe("속성 대입·삭제 " + n.attr)
                v = n.value
                direct_os = isinstance(v, ast.Name) and self.mods.get(v.id) == "os" and n.attr in ("path", "environ")
                if n.attr.lstrip("_") in modlike and not direct_os:
                    raise Unsafe("모듈 경유 모듈 접근 " + n.attr)
                if direct_os and n.attr == "path" and not (isinstance(par, ast.Attribute) and par.value is n):
                    raise Unsafe("os.path 모듈 객체 유출")
            elif isinstance(n, ast.Subscript) and not isinstance(n.ctx, ast.Load):
                if self.chain_root(n) in guarded:
                    raise Unsafe("모듈 이름에 뿌리를 둔 첨자 대입·삭제")
            elif isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load):
                called = isinstance(par, ast.Call) and par.func is n
                if n.id in self.mods and not (isinstance(par, ast.Attribute) and par.value is n):
                    raise Unsafe("모듈 객체 유출 " + n.id)
                if n.id in self.fromnames and not called and not is_base:
                    raise Unsafe("from-import 이름 유출 " + n.id)

    def resolve(self, node, depth=0):
        """쓰기 경로 노드 → 정적으로 확정되는 문자열(리터럴·단일 대입 이름·os.path.join·환경 접두 os.environ) 또는 None."""
        if depth > 16 or node is None:
            return None
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name) and node.id in self.consts:
            return self.resolve(self.consts[node.id], depth + 1)
        if isinstance(node, ast.Subscript) and self.env_ok and self.is_environ(node.value):
            k = node.slice
            if isinstance(k, ast.Constant) and isinstance(k.value, str):
                return self.env.get(k.value)
            return None
        if isinstance(node, ast.Call) and not node.keywords and node.args \
                and not any(isinstance(a, ast.Starred) for a in node.args):
            ce = self.callee(node.func)
            if ce == ("mod", "os.path", "join"):
                parts = [self.resolve(a, depth + 1) for a in node.args]
                return None if any(x is None for x in parts) else os.path.join(*parts)
            if self.env_ok and ce[0] == "meth" and ce[1] == "get" and self.is_environ(ce[2]) and len(node.args) == 1:
                k = node.args[0]
                if isinstance(k, ast.Constant) and isinstance(k.value, str):
                    return self.env.get(k.value)
        return None

    # ── 보조 ──
    def path_ok(self, node, why):
        p = self.resolve(node)
        if p is None:
            raise Unsafe(why + ": 쓰기 경로가 리터럴이 아님")
        if not p.startswith("/"):
            raise Unsafe(why + ": 쓰기 경로가 절대 경로가 아님")
        if ".." in p.split("/") or marked(p):
            raise Unsafe(why + ": 쓰기 경로에 보호 표식")
        rp = os.path.realpath(p)
        if marked(rp):
            raise Unsafe(why + ": 쓰기 경로 realpath 가 보호 대상")
        for base in {self.hooks_real, self.hooks_raw}:
            if base and (rp + "/").startswith(base.rstrip("/") + "/"):
                rel = rp[len(base.rstrip("/")) + 1:]
                if re.match(r"(lib|tests|backup|logs)(/|$)", rel, re.I):
                    raise Unsafe(why + ": 쓰기 경로가 hooks 보호 디렉터리 아래")

    @staticmethod
    def lit_mode(node):
        if node is None:
            return "r"
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        raise Unsafe("open 모드가 리터럴이 아님")

    def callee(self, func):
        """호출 대상을 ('builtin', 이름) · ('mod', 모듈, 속성) · ('path',) · ('meth', 속성, 수신자) · ('other',) 로."""
        if isinstance(func, ast.Name):
            if func.id in self.fromnames:
                m, n = self.fromnames[func.id]
                if m == "pathlib" and n in PATHLIB_ATTRS:
                    return ("path",)
                return ("mod", m, n)
            if func.id in ("Path", "PurePath", "PosixPath", "PurePosixPath"):
                return ("other",)            # import 없이 쓴 Path — 정의 출처를 모른다
            return ("builtin", func.id)
        if isinstance(func, ast.Attribute):
            base = func.value
            if isinstance(base, ast.Name) and base.id in self.mods:
                m = self.mods[base.id]
                if m == "pathlib" and func.attr in PATHLIB_ATTRS:
                    return ("path",)
                return ("mod", m, func.attr)
            if isinstance(base, ast.Attribute) and isinstance(base.value, ast.Name) and self.mods.get(base.value.id) == "os" \
                    and base.attr == "path":
                return ("mod", "os.path", func.attr)
            return ("meth", func.attr, base)
        return ("other",)

    def is_path_ctor(self, node):
        return isinstance(node, ast.Call) and self.callee(node.func) == ("path",)

    def kw(self, call, name, pos):
        for k in call.keywords:
            if k.arg == name:
                return k.value
            if k.arg is None:
                raise Unsafe("**kwargs 호출")
        return call.args[pos] if len(call.args) > pos else None

    # ── 판정 ──
    def run(self, code):
        if "\r" in code:
            raise Unsafe("CR 포함")
        try:
            tree = ast.parse(code)
        except SyntaxError as e:
            raise Unsafe("파싱 실패 %s" % e.msg)
        for n in ast.walk(tree):
            for c in ast.iter_child_nodes(n):
                self.parents[c] = n
        for n in ast.walk(tree):
            if isinstance(n, (ast.Import, ast.ImportFrom)):
                self.imp(n)
        self.collect_consts(tree)
        self.check_mutation(tree)
        self.check_environ(tree)
        for n in ast.walk(tree):
            self.node(n)

    def imp(self, n):
        if isinstance(n, ast.Import):
            for a in n.names:
                if a.name not in ALLOWED_MODULES:
                    raise Unsafe("허용 밖 import " + a.name)
                if a.asname and a.asname != a.name:
                    raise Unsafe("import 별칭 " + a.name)
                self.mods[a.name.split(".")[0]] = a.name.split(".")[0]
        else:
            if n.level or not n.module or n.module not in ALLOWED_MODULES:
                raise Unsafe("허용 밖 from-import %s" % n.module)
            for a in n.names:
                if a.name == "*" or (a.asname and a.asname != a.name):
                    raise Unsafe("from-import * 또는 별칭")
                self.attr_ok(n.module, a.name)
                self.fromnames[a.name] = (n.module, a.name)

    @staticmethod
    def attr_ok(mod, attr):
        if attr.startswith("_"):
            raise Unsafe("밑줄 속성 %s.%s" % (mod, attr))
        allow = {"os": OS_ATTRS, "sys": SYS_ATTRS, "pathlib": PATHLIB_ATTRS}.get(mod)
        if allow is not None and attr not in allow:
            raise Unsafe("허용 밖 속성 %s.%s" % (mod, attr))

    def node(self, n):
        if isinstance(n, ast.Name):
            if n.id.startswith("__") or n.id in BANNED_NAMES:
                raise Unsafe("금지 이름 " + n.id)
            par = self.parents.get(n)
            called = isinstance(par, ast.Call) and par.func is n
            if n.id in ("open", "Path") and not called and n.id not in self.mods:
                raise Unsafe("호출 아닌 %s 참조(별칭)" % n.id)
            if n.id in self.fromnames and self.fromnames[n.id][0] == "pathlib" and not called:
                raise Unsafe("호출 아닌 Path 참조(별칭)")
        elif isinstance(n, ast.Attribute):
            if n.attr.startswith("__"):
                raise Unsafe("던더 속성 " + n.attr)
            if isinstance(n.value, ast.Name) and n.value.id in self.mods:
                self.attr_ok(self.mods[n.value.id], n.attr)
            par = self.parents.get(n)
            called = isinstance(par, ast.Call) and par.func is n
            if n.attr in WRITE_METHODS | DESTROY_METHODS and not called:
                raise Unsafe("호출 아닌 %s 참조(별칭)" % n.attr)
        elif isinstance(n, ast.Call):
            self.call(n)
        elif isinstance(n, ast.Constant) and isinstance(n.value, str) and marked(n.value):
            self.marked_const(n)

    def open_call(self, call, path_node, mode_node, why):
        mode = self.lit_mode(mode_node)
        if re.search(r"[wax+]", mode):
            self.path_ok(path_node, why)
        elif not re.fullmatch(r"[rbt]*", mode):
            raise Unsafe("알 수 없는 open 모드 " + mode)
        for k in call.keywords:
            if k.arg in ("opener", None):
                raise Unsafe("open opener/**kwargs")

    def call(self, c):
        ce = self.callee(c.func)
        sensitive = ce in (("builtin", "open"), ("path",)) or (ce[0] == "mod" and ce[1] == "os") \
            or (ce[0] == "meth" and ce[1] in WRITE_METHODS | {"open"})
        if sensitive and (any(isinstance(a, ast.Starred) for a in c.args) or any(k.arg is None for k in c.keywords)):
            raise Unsafe("쓰기 가능 호출에 *args/**kwargs")
        if ce == ("builtin", "open"):
            if not c.args and not any(k.arg == "file" for k in c.keywords):
                raise Unsafe("open 경로 없음")
            self.open_call(c, self.kw(c, "file", 0), self.kw(c, "mode", 1), "open")
        elif ce[0] == "mod" and ce[1] == "os" and ce[2] in ("makedirs", "mkdir"):
            self.path_ok(self.kw(c, "name" if ce[2] == "makedirs" else "path", 0), "os." + ce[2])
        elif ce[0] == "meth":
            attr, recv = ce[1], ce[2]
            if attr in DESTROY_METHODS:
                raise Unsafe("파괴·별칭 메서드 " + attr)
            if attr == "replace" and len(c.args) + len(c.keywords) < 2:
                raise Unsafe("1인자 replace(Path.replace 가능)")
            if attr in WRITE_METHODS or attr == "open":
                if not (self.is_path_ctor(recv) and len(recv.args) == 1 and not recv.keywords):
                    if attr == "open":
                        raise Unsafe(".open 수신자가 Path(리터럴) 아님")
                    raise Unsafe("%s 수신자가 Path(리터럴) 아님" % attr)
                if attr == "open":
                    self.open_call(c, recv.args[0], self.kw(c, "mode", 0), "Path.open")
                else:
                    self.path_ok(recv.args[0], "Path." + attr)

    def marked_const(self, n):
        par = self.parents.get(n)
        if not isinstance(par, ast.Call) or par.func is n:
            if isinstance(par, ast.keyword):
                par = self.parents.get(par)
                if not isinstance(par, ast.Call):
                    return
            else:
                return          # 대입·비교·컨테이너 등 — 쓰기 지점은 리터럴만 받으므로 여기서 쓰일 수 없다
        ce = self.callee(par.func)
        if ce == ("builtin", "open"):
            return              # 쓰기 모드면 open_call 이 막는다
        if ce == ("path",):
            g = self.parents.get(par)
            gg = self.parents.get(g)
            if isinstance(g, ast.Attribute) and g.value is par and g.attr in PATH_READ_METHODS \
                    and isinstance(gg, ast.Call) and gg.func is g:
                return          # Path(보호).read_text() 류 — open 이면 call() 이 모드를 본다
            raise Unsafe("보호 경로 Path 를 읽기 메서드 밖에서 사용")
        if ce[0] == "builtin" and ce[1] in SAFE_FUNCS:
            return
        if ce[0] == "mod" and (ce[1] == "os.path" or (ce[1], ce[2]) in SAFE_MOD_FUNCS):
            return
        if ce[0] == "mod" and ce[1] in ("hashlib", "json"):
            return              # 내용 처리 — json.dump 의 파일 인자는 이미 검사된 open 이다
        if ce[0] == "meth" and (ce[1] in STR_METHODS | {"write", "writelines", "write_text", "write_bytes"} or (ce[1] == "replace" and len(par.args) >= 2)):
            return
        raise Unsafe("보호 표식 리터럴을 알 수 없는 호출에 전달")


# K2(D-7, 2026-11-06): 명령 앞 환경 대입 접두 — 이름=절대 경로 리터럴만(값에 $ ` 따옴표 공백 글로브 없음). 위험 이름은 extract 가 거부한다.
_ENVP = r"((?:[A-Za-z_][A-Za-z0-9_]*=/[A-Za-z0-9_./@%+:,-]*[ \t]+)*)"
ENV_DENY = re.compile(r"\A(PYTHON.*|LD_.*|PATH|HOME|GCONV_PATH|BASH_ENV|ENV|IFS|TMPDIR|PWD|OLDPWD|SHELLOPTS|BASHOPTS|PS4)\Z")
_PY = r"(?:/usr(?:/local)?/bin/)?python(?:3(?:\.\d+)?)?"
_OPT = r"(?:[ \t]+-[IBSEsuOq]+)*"
_LIT = r"(?:[ \t]+(?:[A-Za-z0-9_./:=,+@%-]+|'[^'\n]*'))"
_RED = r"(?:[ \t]+(?:2>&1|2>/dev/null|>/dev/null|1>/dev/null))*"
RE_C = re.compile(r"\A[ \t]*" + _ENVP + _PY + _OPT + r"[ \t]+-c[ \t]+(?:'([^']*)'|\"([^\"$`\\]*)\")(" + _LIT + r"*)" + _RED + r"[ \t]*\Z", re.S)
# heredoc 은 스크립트 인자가 없거나 '-' 일 때만 표준 입력이 코드다 — '-' 앞 위치 인자(스크립트·-m 모듈)는 받지 않는다
RE_H = re.compile(r"\A[ \t]*" + _ENVP + _PY + _OPT + r"(?:[ \t]+-(" + _LIT + r"*))?[ \t]*<<(-?)[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\4" + _RED + r"[ \t]*\Z")


def env_prefix(s):
    """K2: 명령 앞 'NAME=/절대경로 ' 접두 → dict. 위험 이름·.. 성분·보호 표식 값이면 Unsafe."""
    env = {}
    for w in (s or "").split():
        k, v = w.split("=", 1)
        if ENV_DENY.match(k):
            raise Unsafe("위험 환경 대입 " + k)
        if ".." in v.split("/") or marked(v) or marked(os.path.realpath(v)):
            raise Unsafe("환경 대입 값에 보호 표식")
        env[k] = v
    return env


def extract(cmd):
    """명령 원문 → (코드, 인자 문자열, 환경 접두 dict). 형태 불일치면 Unsafe."""
    if "\r" in cmd or "\x00" in cmd:
        raise Unsafe("제어 문자")
    m = RE_C.match(cmd)
    if m:
        return (m.group(2) if m.group(2) is not None else m.group(3)), m.group(4), env_prefix(m.group(1))
    lines = cmd.split("\n")
    m = RE_H.match(lines[0])
    if not m:
        raise Unsafe("명령 형태가 python 단독 호출 아님")
    args, dash, word = m.group(2) or "", m.group(3), m.group(5)
    env = env_prefix(m.group(1))
    body = []
    for i, ln in enumerate(lines[1:], 1):
        t = ln.lstrip("\t") if dash else ln
        if t == word:
            if any(x.strip() for x in lines[i + 1:]):
                raise Unsafe("heredoc 종결자 뒤에 다른 명령")
            return "\n".join(body), args, env
        body.append(t)
    raise Unsafe("heredoc 종결자 없음")


def classify(text, hooks, code_only=False):
    try:
        env = {}
        if code_only:
            code = text
        else:
            code, args, env = extract(text)
            if marked(args):
                raise Unsafe("인자에 보호 표식")
        Classifier(hooks, env).run(code)
        return "SAFE"
    except Unsafe as e:
        return "UNSAFE " + str(e)
    except RecursionError:
        return "UNSAFE 재귀 한도"
    except Exception as e:          # 판정 실패는 항상 UNSAFE(fail-closed)
        return "UNSAFE 내부 오류 %s" % type(e).__name__


def main():
    a = sys.argv[1:]
    hooks = ""
    if "--hooks" in a:
        i = a.index("--hooks")
        hooks = a[i + 1] if i + 1 < len(a) else ""
    data = sys.stdin.read()
    print(classify(data, hooks, "--code" in a))


if __name__ == "__main__":
    main()
