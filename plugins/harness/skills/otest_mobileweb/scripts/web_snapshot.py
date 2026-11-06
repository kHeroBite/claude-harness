# 헤드리스 브라우저(playwright)로 지정 URL·시나리오를 실행해 핵심 요소/값을 정규화 JSON 으로 뽑는 범용 도구
"""
사용법:
  python3 web_snapshot.py --url <시작 URL> --scenarios <시나리오.json> --out <결과.json> [--viewport 390x844] [--timeout 15]
                          [--mobile] [--net-log] [--metrics]

시나리오 입력 JSON (프로젝트 고유값 없음 — 전부 입력으로 받는다):
{
  "scenarios": [
    {"id": "login-basic", "path": "/login",            # --url 기준 상대 경로(없으면 --url 그대로)
     "steps": [                                          # 선택, 순서대로 실행
        {"fill": "#id", "value": "77"}, {"click": "button.submit"}, {"wait": "#dashboard"},
        {"scroll": "#list", "by": 800, "times": 10, "pause_ms": 120},   # 요소 scrollTop 을 by 픽셀씩 times 번(선택)
        {"wait_ms": 500}],                                               # 고정 대기(선택)
     "extract": {"title": "h1", "rows": {"selector": "table tr", "all": true}}}   # 키 -> 셀렉터(문자열) 또는 {selector, all, attr}
  ]
}

출력 JSON: {"url":..., "viewport":..., "scenarios": {"<id>": {"title": "텍스트", "rows": ["..",".."]}}}
  → parity_check.py 의 --app-result/--web-result 와 같은 모양(점 경로 a.b.c, 리스트 [*])으로 비교된다.
  선택 옵션을 켜면 시나리오 결과에 밑줄 키가 추가된다(비교 필드와 겹치지 않게):
    --mobile  : 터치·모바일 컨텍스트(has_touch, is_mobile, device_scale_factor=3). 출력 "mobile": true
    --net-log : "_net" = {requests, encoded_bytes(응답 본문 크기 합, 알 수 없으면 제외), top5[{url,bytes}],
                          websockets[{url, frames_sent, frames_received}]}
    --metrics : "_metrics" = {navigation{dom_content_loaded_ms, load_event_end_ms, response_end_ms},
                              waits{셀렉터: 페이지 이동 시작부터 나타날 때까지 ms},
                              js_heap_used_bytes(크로미움 CDP Performance.getMetrics, 실패 시 null),
                              frames{count, p50_ms, p95_ms, drop_ratio(간격 > 25ms 비율)}}   # rAF 간격 샘플러

종료코드: 0=성공 1=시나리오 실행 실패 2=입력오류 3=N/A(URL 미정 또는 playwright 없음 — 사유 출력, PASS 아님)
"""
import argparse
import json
import sys
import time

OK, FAIL, INPUT, NA = 0, 1, 2, 3

# requestAnimationFrame 간격 샘플러 — 페이지 로드 전에 주입한다(측정 도구 쪽 코드, 대상 앱은 무수정)
_RAF_SAMPLER = """
(() => {
  if (window.__wsFrames) return;
  window.__wsFrames = [];
  let last = 0;
  const tick = (t) => { if (last) window.__wsFrames.push(t - last); last = t; requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
})();
"""
_FRAME_BUDGET_MS = 16.7 * 1.5


def _na(reason):
    print("N/A: " + reason)
    return NA


def _pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = min(len(sorted_vals) - 1, max(0, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return round(sorted_vals[k], 2)


def main():
    ap = argparse.ArgumentParser(description="헤드리스 브라우저 시나리오 스냅샷")
    ap.add_argument("--url", help="대상 시작 URL(없으면 N/A)")
    ap.add_argument("--scenarios", help="시나리오 JSON 경로")
    ap.add_argument("--out", help="결과 JSON 경로(없으면 stdout)")
    ap.add_argument("--viewport", default="390x844", help="WxH (기본 390x844)")
    ap.add_argument("--timeout", type=float, default=15.0, help="요소 대기 초")
    ap.add_argument("--mobile", action="store_true", help="터치·모바일 컨텍스트(DPR 3)")
    ap.add_argument("--net-log", action="store_true", help="요청 수·전송 크기·WebSocket 프레임 수 기록")
    ap.add_argument("--metrics", action="store_true", help="Navigation Timing·대기 시각·JS 힙·rAF 프레임 간격 기록")
    args = ap.parse_args()

    if not args.url or not args.url.strip() or args.url.strip().lower() in ("미정", "tbd", "none"):
        return _na("대상 URL 미정(웹 미구축 또는 --url 미지정)")
    try:
        from playwright.sync_api import sync_playwright  # noqa: WPS433
    except ImportError:
        return _na("python playwright 모듈 없음")
    if not args.scenarios:
        print("입력오류: --scenarios 필요")
        return INPUT
    try:
        with open(args.scenarios, encoding="utf-8-sig") as f:
            scen = json.load(f).get("scenarios", [])
        w, h = (int(x) for x in args.viewport.lower().split("x"))
    except (OSError, ValueError) as e:
        print("입력오류: %s" % e)
        return INPUT

    ms = int(args.timeout * 1000)
    result = {"url": args.url, "viewport": args.viewport, "scenarios": {}}
    if args.mobile:
        result["mobile"] = True
    failed = 0
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True)
            for sc in scen:
                sid = str(sc.get("id", ""))
                ctx_opts = {"viewport": {"width": w, "height": h}}
                if args.mobile:
                    ctx_opts.update({"has_touch": True, "is_mobile": True, "device_scale_factor": 3})
                ctx = browser.new_context(**ctx_opts)  # 시나리오마다 세션 격리
                if args.metrics:
                    ctx.add_init_script(_RAF_SAMPLER)
                page = ctx.new_page()
                page.set_default_timeout(ms)
                reqs, sockets = [], []
                if args.net_log:
                    page.on("requestfinished", lambda r: reqs.append(r))

                    def _on_ws(ws):
                        rec = {"url": ws.url, "frames_sent": 0, "frames_received": 0}
                        sockets.append(rec)
                        ws.on("framesent", lambda _p, rec=rec: rec.__setitem__("frames_sent", rec["frames_sent"] + 1))
                        ws.on("framereceived", lambda _p, rec=rec: rec.__setitem__("frames_received", rec["frames_received"] + 1))
                    page.on("websocket", _on_ws)
                out = {}
                waits = {}
                t0 = time.perf_counter()
                try:
                    target = args.url.rstrip("/") + sc["path"] if sc.get("path") else args.url
                    t0 = time.perf_counter()
                    page.goto(target)
                    for st in sc.get("steps", []):
                        if "fill" in st:
                            page.fill(st["fill"], str(st.get("value", "")))
                        elif "click" in st:
                            page.click(st["click"])
                        elif "wait" in st:
                            page.wait_for_selector(st["wait"])
                            waits.setdefault(st["wait"], round((time.perf_counter() - t0) * 1000, 1))
                        elif "scroll" in st:
                            for _ in range(int(st.get("times", 1))):
                                page.eval_on_selector(st["scroll"], "(el, by) => { el.scrollTop += by; }", int(st.get("by", 600)))
                                page.wait_for_timeout(int(st.get("pause_ms", 120)))
                        elif "wait_ms" in st:
                            page.wait_for_timeout(int(st["wait_ms"]))
                    for key, spec in sc.get("extract", {}).items():
                        sel, many, attr = (spec, False, None) if isinstance(spec, str) else (
                            spec["selector"], bool(spec.get("all")), spec.get("attr"))
                        els = page.query_selector_all(sel) if many else [page.query_selector(sel)]
                        vals = []
                        for el in els:
                            if el is None:
                                vals.append(None)
                            else:
                                vals.append(el.get_attribute(attr) if attr else (el.inner_text() or "").strip())
                        out[key] = vals if many else vals[0]
                    if args.metrics:
                        out["_metrics"] = _collect_metrics(page, ctx, waits)
                    if args.net_log:
                        out["_net"] = _collect_net(reqs, sockets)
                except Exception as e:  # 시나리오 단위 실패 — 다음 시나리오 계속
                    out = {"_error": "%s: %s" % (type(e).__name__, str(e)[:200])}
                    failed += 1
                finally:
                    ctx.close()
                result["scenarios"][sid] = out
            browser.close()
    except Exception as e:
        print("브라우저 실행 실패: %s: %s" % (type(e).__name__, str(e)[:200]))
        return FAIL

    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text + "\n")
    else:
        print(text)
    return FAIL if failed else OK


def _collect_metrics(page, ctx, waits):
    nav = page.evaluate("""() => {
        const n = performance.getEntriesByType('navigation')[0];
        if (!n) return null;
        return {dom_content_loaded_ms: n.domContentLoadedEventEnd, load_event_end_ms: n.loadEventEnd, response_end_ms: n.responseEnd};
    }""")
    heap = None
    try:
        cdp = ctx.new_cdp_session(page)
        cdp.send("Performance.enable")
        for m in cdp.send("Performance.getMetrics").get("metrics", []):
            if m.get("name") == "JSHeapUsedSize":
                heap = int(m.get("value", 0))
        cdp.detach()
    except Exception:
        heap = None  # 크로미움 외 또는 CDP 불가 — 값 없음으로 둔다
    gaps = page.evaluate("() => (window.__wsFrames || []).slice()") or []
    gaps_sorted = sorted(float(g) for g in gaps)
    frames = {
        "count": len(gaps_sorted),
        "p50_ms": _pct(gaps_sorted, 50),
        "p95_ms": _pct(gaps_sorted, 95),
        "drop_ratio": round(sum(1 for g in gaps_sorted if g > _FRAME_BUDGET_MS) / len(gaps_sorted), 4) if gaps_sorted else None,
    }
    return {"navigation": nav, "waits": waits, "js_heap_used_bytes": heap, "frames": frames}


def _collect_net(reqs, sockets):
    total, sized = 0, []
    for r in reqs:
        try:
            b = int(r.sizes().get("responseBodySize", -1))
        except Exception:
            b = -1
        if b >= 0:
            total += b
            sized.append({"url": r.url, "bytes": b})
    sized.sort(key=lambda x: -x["bytes"])
    return {"requests": len(reqs), "encoded_bytes": total, "top5": sized[:5], "websockets": sockets}


if __name__ == "__main__":
    sys.exit(main())
