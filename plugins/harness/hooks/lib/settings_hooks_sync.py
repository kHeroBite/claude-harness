#!/usr/bin/env python3
# 정본 settings.json 의 hooks 키만 대상 settings.json 에 반영하는 동기화 스크립트
"""사용법: settings_hooks_sync.py [--check] [--force] [--retire] <canonical> <target>

- canonical 의 hooks 키만 target 에 반영한다 (다른 키는 불변).
- 변경이 있을 때만 tmp+os.replace 로 쓰고, <target>.bak-sync-<ts> 를 보관한다 (최근 3개).
- 파싱 실패/부재 시 exit 0, 무변경.
- --check: 차이만 출력. 차이 있으면 exit 1, 없으면 exit 0. 대상에만 있는 hook 이 있으면 함께 출력한다.
- [사이클182 L-616] hooks 키를 통째로 덮어쓰므로, 대상에만 있는 hook((이벤트, 스크립트명) 기준)이 있으면
  덮어쓰지 않고 거부한다(exit 3). 그 hook 을 정본에 먼저 넣거나, 삭제가 의도임을 확인한 뒤 --force 로 실행한다.
  같은 스크립트의 옛 명령 형태(예: time_budget 경유 전)는 대상 전용으로 보지 않는다.
- [사이클219 묘비] 정본에서 의도적으로 뺀 hook 은 .claude/settings_hooks_retired.json(또는 환경변수
  SETTINGS_HOOKS_RETIRED)에 {"retired":[{"event","script","since"}]} 로 기록한다. 대상 전용 hook 중 묘비에 있는 것은
  거부 사유에서 제외하고 함께 제거한다. 묘비에 없는 대상 전용은 종전대로 거부한다(L-616 보호 유지).
- [사이클220 --retire] 정본에서 hook 을 뺀 뒤 대상(매니페스트·사본)을 갱신할 때 쓴다. 묘비에 없는 대상 전용 hook 을
  묘비에 {"event","script","since"(오늘)} 로 먼저 등록(중복 없음, tmp+os.replace)한 뒤 갱신하고 exit 0 을 낸다.
  묘비 쓰기에 실패하면 대상은 바꾸지 않고 exit 3 을 낸다.
"""
import glob
import json
import os
import re
import sys
import time


def _load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _scripts(hooks):
    """{(이벤트, 스크립트명)} — 명령 문자열의 마지막 .sh/.py 파일명, 없으면 명령 앞 40자"""
    out = set()
    if not isinstance(hooks, dict):
        return out
    for ev, arr in hooks.items():
        for slot in arr if isinstance(arr, list) else []:
            for h in slot.get("hooks", []) if isinstance(slot, dict) else []:
                c = h.get("command", "") if isinstance(h, dict) else ""
                m = re.findall(r"[\w./-]+\.(?:sh|py)", c)
                out.add((ev, m[-1].split("/")[-1] if m else c[:40]))
    return out


def _retired_path():
    """묘비 파일 경로 — SETTINGS_HOOKS_RETIRED 또는 이 스크립트 실경로 기준 ../../settings_hooks_retired.json"""
    return os.environ.get("SETTINGS_HOOKS_RETIRED") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))), "settings_hooks_retired.json")


def _retire_add(pairs):
    """[사이클220] (이벤트, 스크립트명) 들을 묘비에 등록한다(이미 있으면 건너뜀). 성공 True"""
    p = _retired_path()
    d = _load(p) if os.path.exists(p) else {"_comment": "정본(~/.claude/settings.json)에서 의도적으로 제거한 hook 목록(묘비).", "retired": []}
    if d is None or not isinstance(d.get("retired", []), list):
        return False
    lst = d.setdefault("retired", [])
    have = {(e.get("event"), e.get("script")) for e in lst if isinstance(e, dict)}
    today = time.strftime("%Y-%m-%d")
    for ev, name in pairs:
        if (ev, name) not in have:
            lst.append({"event": ev, "script": name, "since": today})
            have.add((ev, name))
    rest = {k: v for k, v in d.items() if k != "retired"}
    body = (json.dumps(rest, ensure_ascii=False, indent=2)[:-2].rstrip() + ",\n") if rest else "{\n"
    body += '  "retired": [\n' + ",\n".join(
        "    " + json.dumps(e, ensure_ascii=False) for e in lst) + "\n  ]\n}\n"
    try:
        tmp = "%s.tmp-retire-%d" % (p, os.getpid())
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        os.replace(tmp, p)
        return True
    except Exception as e:
        print("묘비 등록 실패: %s" % e, file=sys.stderr)
        return False


def _retired():
    """{(이벤트, 스크립트명)} — 묘비 파일(_retired_path) 기준"""
    d = _load(_retired_path())
    out = set()
    for e in (d or {}).get("retired", []):
        if isinstance(e, dict) and e.get("event") and e.get("script"):
            out.add((e["event"], e["script"]))
    return out


def main(argv):
    check = "--check" in argv
    force = "--force" in argv
    retire = "--retire" in argv
    args = [a for a in argv if a not in ("--check", "--force", "--retire")]
    if len(args) != 2:
        print("usage: settings_hooks_sync.py [--check] [--force] [--retire] <canonical> <target>", file=sys.stderr)
        return 0
    canon_p, target_p = args
    canon = _load(canon_p)
    target = _load(target_p)
    if canon is None or target is None or "hooks" not in canon:
        return 0
    if target.get("hooks") == canon["hooks"]:
        return 0
    all_extra = _scripts(target.get("hooks")) - _scripts(canon["hooks"])
    tomb = sorted(all_extra & _retired())
    extra = sorted(all_extra - set(tomb))
    if check:
        print("hooks 차이 있음: %s <- %s" % (target_p, canon_p))
        for ev, name in extra:
            print("  대상에만 있는 hook: %s %s" % (ev, name))
        for ev, name in tomb:
            print("  묘비 항목(동기화 시 제거): %s %s" % (ev, name))
        return 1
    if extra and retire and not force:
        if not _retire_add(extra):
            print("hooks 동기화 거부: 묘비 등록 실패로 대상을 바꾸지 않았다(%s)" % _retired_path(), file=sys.stderr)
            return 3
        print("묘비 등록 %d건: %s" % (len(extra), ", ".join("%s %s" % x for x in extra)))
        tomb, extra = sorted(set(tomb) | set(extra)), []
    if extra and not force:
        print("hooks 동기화 거부: %s 에만 있는 hook %d건 — 덮어쓰면 지워진다. 정본에 먼저 넣거나, 삭제 의도를 확인한 뒤 --force 로 실행하라."
              % (target_p, len(extra)), file=sys.stderr)
        for ev, name in extra:
            print("  %s %s" % (ev, name), file=sys.stderr)
        return 3
    new = dict(target)
    new["hooks"] = canon["hooks"]
    try:
        ts = time.strftime("%Y%m%d-%H%M%S")
        bak = "%s.bak-sync-%s" % (target_p, ts)
        with open(target_p, "rb") as f:
            raw = f.read()
        with open(bak, "wb") as f:
            f.write(raw)
        tmp = "%s.tmp-sync-%d" % (target_p, os.getpid())
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(new, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, target_p)
        for old in sorted(glob.glob(target_p + ".bak-sync-*"))[:-3]:
            try:
                os.remove(old)
            except OSError:
                pass
        print("hooks 동기화 완료: %s%s" % (target_p, " (--force: 대상 전용 %d건 제거)" % len(extra) if extra else "") + (" (묘비 %d건 제거)" % len(tomb) if tomb else ""))
    except Exception as e:
        print("hooks 동기화 실패(무시): %s" % e, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
