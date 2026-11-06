# settings_changelog.md — hooks 변경 이력

> 정본 아님 — 기록은 /mnt/c/DATA/Project/AI/.claude/settings_changelog.md 에 남긴다(CLAUDE.md settings.json hooks 변경 정책).
> 이 파일은 2026-10-16 사이클191 까지의 과거 기록이다. 사이클196 AC-D1 경로 불일치(L-648) 재발 방지 안내.

## 2026-08-26 — orphan_scan.sh:161 오탐 제거 + orphan_guard.py 메시지 정정 (사이클42 T3)

- **사유**: 보호 경로(session-env)를 **읽기만** 하는 명령이 `ORPHAN_AGENTS_ALIVE` 로 차단되는
  오탐이 실재했다. 원인은 경로도 "읽기·삭제 혼합"도 아닌 **`orphan_scan.sh:161` 의
  `/dev/null[[:space:]]` 정규식**이었다. `cp /dev/null X`(내용 소거)를 잡으려던 패턴이,
  `2>/dev/null` 뒤에 파이프·`&&`·`||` 등 무엇이든 오면 전부 삭제성으로 오판했다.
  최소 트리거: `foo 2>/dev/null` PASS / `foo 2>/dev/null | head` **BLOCK**
  (find·ls·session-env 와 무관하게 재현된다).
- **왜 고쳤나 (트레이드오프가 아니다)**: 보수적 차단은 안전을 얻고 편의를 잃지만,
  이 오탐은 **삭제 의도가 0인 명령의 문자열 우연 일치**라 얻는 안전이 **0**이다.
  게다가 `.sh` 파일로 쓰면 그대로 실행돼 **실질 방어도 아니었다** — 비용만 남는다.
- **조치 층위**: 1순위(Hook) 내부 수정. 판정 로직 자체를 정밀화했다.
- **변경**
  - `hooks/lib/orphan_scan.sh:161` — 리다이렉션(`2>/dev/null` 등)을 `sed` 로 먼저 제거한 뒤 판정.
    `cp /dev/null X` 는 `/dev/null` 이 **인자 위치**라 정규화 후에도 남아 그대로 잡힌다.
    백업 `orphan_scan.sh.bak_c42-2_20260826_2315`.
  - `MCP-Servers/oio-mcp-server/orphan_guard.py` — 차단 메시지를 잔존수로 분기.
    최상위 경로 보호(`__ALWAYS__`)는 `cnt=0` 으로 차단하므로 종전에는
    **"팀에이전트 0건이 아직 살아있는데"** 라는 자기모순 문구가 나와 조사자를 오도했다.
    `cnt=0` 이면 "최상위 경로는 고아 유무와 무관하게 보호됩니다"로 바꾸고,
    고아가 없는데 `/oinit` 을 권하던 **틀린 안내**도 제거했다.
    두 분기 공통으로 **"읽기 명령과 삭제 명령을 같은 bash_exec 에 섞지 마세요"** 안내를
    `suggestion` 에 추가했다(막힌 그 순간 읽는 유일한 텍스트이므로 여기에 둔다).
    백업 `orphan_guard.py.bak_c42-2_20260826_2316`.
- **유지한 것**: `ls …; rm …` 처럼 읽기와 삭제가 **한 호출에 섞이면 통째 차단**되는 동작은
  원자 판정·우회 방지를 위한 **설계된 fail-closed 이며 그대로 둔다**(오탐이 아니다).
- **검증 결과**: 회귀 시험 **22/22 통과** — 진짜 양성 10건(`cp /dev/null`·`rm -rf`·`find -delete`·
  `mv`·`rmdir`·`rsync --delete`·`truncate`·`shutil.rmtree`·`cat /dev/null >`·읽기삭제혼합) **BLOCK 유지**,
  오탐 9건 **PASS 전환**, 기존 PASS 4건 **무회귀**. `bash -n` 구문 정상 · CR 0건(LF) ·
  symlink 경유 md5 일치. `orphan_guard.py` 는 `cnt=0`/`cnt=3` 양 분기 출력 실제 확인 + `py_compile` 통과.
  E2E: 실제로 차단됐던 `grep … 2>/dev/null | head` 가 수정 후 정상 실행됨.
- **적용 시점 주의**: `orphan_scan.sh` 는 매 호출 `subprocess.run(["bash", …])` 이라 **즉시 반영**되나,
  `orphan_guard.py` 는 oio 서버가 import 하므로 **이미 기동한 서버에는 반영되지 않는다**(재기동 필요).
- **못 잡는 것**: 변수 치환(`R=2>/dev/null`)·이스케이프·서브셸로 문자열을 감추면 정규화도 우회된다.
  본 함수는 **문자열 판정**이며 그 한계는 종전과 동일하다.
- **증적**: `Mars/.claude/evidence/c42_guard_falsepositive.md`

## 2026-08-20 — oio 서버: 조용히 실패하는 인프라 이상 3건 재발방지

- **사유**: 사이클16에서 "success 를 반환하는데 결과가 없는" 이상 2건이 실제 발생했고, 규명 중 3번째(원인)를 추가 발견했다.
  전부 호출자가 실패를 알 수 없는 형태라 조용히 갈라진다.
- **조치 층위**: 재발방지 우선순위상 1순위는 Hook 이지만, 3건 모두 **oio 서버(2순위)** 를 택했다.
  근거는 Hook 이 할 수 있는 일이 "차단"뿐이라는 점이다. 이상 A 를 hook 으로 막으면 정당한 symlink 편집까지
  전부 막혀 작업이 마비되고, 에이전트는 우회로(bash_exec)로 흘러 오히려 무력화된다. 서버에서 고치면
  **차단이 아니라 올바른 동작으로 교정**되므로 오탐 자체가 성립하지 않는다. 이상 B/C 는 hook 이 관측조차 못 하는
  서버 내부 로직이라 hook 층위가 물리적으로 불가능하다.

- **이상 A — `file_edit`/`file_write` 가 symlink 를 끊는다 (file_ops.py)**
  - 재현: scratchpad 사본으로 실증. 상대/절대 symlink 양쪽 모두 mode `120000` → 일반 파일로 전환되고
    실체 파일은 미변경. 원인은 원자적 쓰기의 `os.replace` 가 링크를 따라가지 않고 링크 자체를 대체하기 때문이다.
  - 위험: `ai` 정본을 10개 프로젝트가 공유한다. 링크가 끊기면 그 프로젝트만 정본에서 분리되어 이후 정본 변경이 도달하지 않는다.
    이번엔 파일이 커서 diffstat 700줄로 튀어 발견됐을 뿐, 작은 파일이었으면 못 잡았다.
  - 조치: `_resolve_symlink_for_write()` 신설. 쓰기 직전 `os.path.islink` 이면 `os.path.realpath` 실체 경로로 치환한다.
    링크는 건드리지 않으므로 유지된다. dangling 링크·예외는 원본 경로 반환(fail-safe, 기존 동작 유지).
  - 적용 지점: `file_write`/`file_edit` 의 `validate_path` 직후 1줄씩. `_impl` 이 아닌 진입점에 둬 lock/intent 게이트가 실체 경로 기준으로 걸리게 했다.

- **이상 B — state 가 한쪽 base 에만 기록된다 (session_ops.py)**
  - 규명: 쓰기 실패가 아니었다. oio 는 `$CLAUDE_CONFIG_DIR/session-env`(격리 세션은 `/tmp/cc-*`)에 기록하는데,
    일부 호출자가 `state_write` 에 `$HOME/.claude/...` 를 하드코딩해 넘겨 **두 base 로 갈라진 것**이다.
    `$HOME` 은 `CLAUDE_CONFIG_DIR` 이 설정돼 있어도 그대로 확장되므로 갈라짐이 조용히 성립한다.
  - 실측: 현재 세션의 `state` 가 양쪽에 mtime 17:50(HOME, bash 우회분) / 18:06(CCD, oio분)으로 각각 존재했다.
  - 주의: 이 형태는 "기록 후 파일 실존 검증"으로는 **못 잡는다**. 파일은 실제로 존재하기 때문이다(다른 base 에).
    L-362 형 사후검증만으로는 불충분한 사례다.
  - 조치: `_mirror_state_bases()` + `_mirror_write()` 신설. 두 base 가 다를 때만 `state` 키를 양쪽에 기록한다.
    CAS 경로와 `force` 경로 모두 적용. 결과에 `bases_written` 을 실어 호출자가 확인 가능하게 했다.
    미러 실패는 무시한다(fail-soft) — 주 기록이 이미 성공한 뒤이므로 미러가 전체를 실패로 바꾸면 안 된다.
    비-state 키는 미러하지 않는다(범위 최소화).

- **이상 C — `IDLE → PLAN` 전이가 전면 거부된다 (session_ops.py, 신규 발견)**
  - 발견 경위: 이상 B 검증 중 첫 호출부터 실패했다. **백업본(무수정)으로 재현해 기존 결함임을 확인**했다.
  - 원인: L-431 로 stage 축에서 OK 가 제거되면서 `value="OK"` 를 `PLAN` 으로 선변환하는 코드는 들어갔는데,
    `_ALLOWED_TRANSITIONS["IDLE"]` 은 `{"OK"}` 로 남았다. 변환 후 `PLAN` 이 허용 목록에 없어 항상 거부된다.
  - 영향: oio 경유 `/ok` 파이프라인 진입이 전부 실패했고, 이 때문에 `bash -c state_write` 우회가 상시화되어
    **이상 B 의 base 분기를 실제로 유발한 원인**으로 보인다. B 와 C 는 별개가 아니라 인과로 연결돼 있다.
  - 조치: `"IDLE": {"PLAN", "OK"}` 로 수정. 나머지 전이는 점검 결과 이상 없음(`FINISH` 는 이미 양쪽 보유).

- **부수 발견**: `oio bash_exec` 는 `/bin/sh`(dash)로 실행된다. `source` 가 `not found` 로 실패하므로 `bash -c` 로 감싸야 한다. 실측 확인.

- **검증(전항목 PASS, 오탐 0)**
  - 이상 A: **15/15 PASS**. 위반 4종(상대/절대/write/2단chain) 전부 링크 유지 + 실체 반영.
    정상 6종(일반파일 edit·신규 write·덮어쓰기·`overwrite=false` 차단 유지·dangling·미존재 파일 에러 유지) 무회귀.
  - 이상 B/C: **19/19 PASS**. 진입(IDLE→OK) 성공 + 양쪽 base 동기 + 전체 파이프라인(PLAN→DEV→TEST→DONE→FINISH→IDLE) 각 단계 양쪽 동기.
    정상 7종(force·비-state 키·increment 누적·잘못된 전이 차단 유지·MISSING_PARAM·append) 무회귀.
  - 분기 없는 환경: **5/5 PASS**. `CLAUDE_CONFIG_DIR` 미설정 시 `bases_written=1` — 중복 쓰기 없음.
  - fail-safe: 보조 base 를 `chmod 500` 으로 막아도 주 기록 success + 파일 실존 확인.
  - `python3 -m py_compile` 2파일 통과 + 서버 venv(`$HOME/.venv/oio-mcp/bin/python`)로 `server` 포함 전체 import 무결성 확인.
- **백업**: `/mnt/c/DATA/Project/ai/.claude/backup_odevguard_20260820_181427/` (`file_ops.py`, `session_ops.py`)
- **활성 세션 반영**: 미반영. oio MCP 서버는 기동 시 모듈을 로드하므로 **재시작(`/mcp` 재연결) 후 적용**된다. 파일 수정만 완료.
- **settings.json 무접촉**: 동시 작업 중인 타 세션(odev-path)과의 충돌 회피를 위해 일절 건드리지 않았다.

## 2026-08-17
- **사유**: 고아 팀에이전트 5개 사고 재발방지. 재부팅 boot-stale이 메타파일만 지우고 프로세스는 살려둬
  "추적 근거 소멸 + 프로세스 생존" 상태가 성립했고, 모든 탐지 경로가 `agents/` 단일 의존이라 미탐지로 잔존했다.
  증적: `/mnt/c/DATA/Project/Mars/.claude/evidence/agent_orphan_cleanup_20260817.md`
- **lib/orphan_scan.sh (신규)**: `agents/` 무의존 고아 탐지 공용 라이브러리. `ps -eo pid=,args=` 단일 방식으로
  NUL 함정 회피(`/proc/{pid}/cmdline` 직접 grep은 공백 포함 인자 매칭 불가 — 실측 0건 오판정).
  메인 보호(L-213: `--agent-id` 없으면 제외) + 세션 격리(`--parent-session-id` 자기 UUID만) + 자기/조상 제외 내장.
  제공 함수: `orphan_scan_pids` / `_count` / `_detail` / `_reap`.
- **write_guard.sh (H-1)**: 173~212행에 `agents/`·`panes/` 삭제 전 잔존 0건 강제 블록 삽입.
  ★ 삽입 위치는 215행 `PIPELINE_UUID` 조기 exit 0 **앞** — 뒤에 두면 팀에이전트가 전부 우회로가 되어 무력화된다.
- **SessionStart.sh (H-2)**: boot-stale 117~139행에 `rm -f`(143행) **직전** 프로세스 회수 추가.
- **정책**: 검사 실패(라이브러리 부재/오류) → 통과(fail-open) / 검사 성공 + 잔존>0 → 차단(fail-closed).
  hook 오류로 세션이 멈추는 것이 고아 잔존보다 큰 사고이므로 fail-open을 기본으로 삼는다.
- **긴급 정지 스위치**: `lib/orphan_scan.sh` 1개 파일만 지우면 H-1/H-2가 동시 무력화된다(의도된 설계).
- **검증(V1~V9 전항목 PASS)**: bash -n 3종 / H-1 위치 grep 증명 / 복붙 0건 / 스캐너 정확도 4항목(자기 UUID만 적중·
  메인 제외·타 세션 제외·자기 제외) / **fail-open 4단계 실증**(파손→통과, 삭제→통과, 원복, 차단 복귀) /
  차단 실증 4경로(dir_delete·file_delete·panes·bash_exec 전부 exit=2) / CRLF 0 / oio 도구 7종 무회귀 / 백업본 문법 검사.
- **⚠️ 검증 방법 주의(오탐 1건 기록)**: CRLF 판정에 `cat -A | grep '\^M'` 를 쓰면 **거짓 양성**이 난다.
  `cat -A` 가 한글 UTF-8 다바이트를 `M-...` 로 표기해 그 `M-` 조각이 매칭되기 때문이다(write_guard 88건 오탐).
  → **바이트 판정 `od -An -tx1 | grep -c '^0d$'` 가 정본**. 향후 hook 검증 시 이 방식을 쓸 것.

### 2026-08-17 (4차) — 잔존 우회로 4건 + 보호 범위 상향
- **판정 단일화 완료**: 경로 정규화·대상 판정·삭제수단 판정을 `lib/orphan_scan.sh` 의
  `orphan_target_uuid()` / `orphan_is_destructive_cmd()` / `check-path` 서브커맨드로 일원화.
  `orphan_guard.py` 자체 정규식 **0건**. hook·oio dir/file_ops·oio bash_exec 3계층이 같은 함수를 호출한다.
- **file_copy/file_symlink/file_write 추가**: 삭제만 막고 **덮어쓰기를 열어두면 우회로**가 된다.
  필드 우선순위를 `destination`·`link_path` **먼저**로 뒀다(복사·링크는 덮어써지는 쪽이 피해 대상).
- **★ 보호 범위 상향 — 경로별 차등 정책** (실측 조사 후 결정):
  ```
  ~/.claude 통째 / session-env 자체 → 무조건 차단 (정상 삭제 경로 grep 결과 0건, 80개 세션 소멸 위험)
  session-env/<uuid>                → 고아 조건부 유지 (ofinish 가 실제 사용)
  ```
  상위 2개는 고아 카운트를 보지 않는다 — 오탐으로 "0건" 오판정 시 80개 세션이 소멸할 수 있기 때문.
  단 라이브러리 부재 시에는 이 무조건 차단도 함께 해제된다(fail-open 유지, V30-⑧ 실증).
- **런타임 삭제 인식**: `shutil.rmtree` / `os.remove` / `pathlib unlink` / 언어런타임+unlink.
- **와일드카드는 의도적 미대응**: 전개되지 않은 `*` 를 UUID 로 해석하면 오탐 위험이 더 크다. fail-open 유지.
- **검증(V25~V32 전항목 PASS)**: 원본 write_guard 와 대조해 **내 보강이 새로 차단한 경로는 정확히 2개**
  (`session-env`, `~/.claude`)이고 나머지는 통과 유지임을 실증. `${HARNESS_HOME:-$HOME/.harness}/current/hooks` 차단은 **기존 F-NEW-1**(symlink
  traversal)이며 본 보강과 무관. V27 과잉차단 0건(프로세스 0건 가상세션 방식) / 3계층 판정 일치 / fail-open 8종.
- **⚠️ 다음 사이클 검토**: `ps` 매칭 오탐 가능성(무관 프로세스가 고아로 카운트). 최상위 보호는 카운트를
  보지 않아 영향 없으나 `session-env/<uuid>` 이하는 영향받는다. 방안만 제시하고 미구현.

### 2026-08-17 (추가) — oio 서버측 가드 (2순위, hook 우회로 봉쇄)
- **사유**: H-1(write_guard)은 Claude Code 도구 호출 경로만 검사한다. oio MCP 직접 호출은 hook 을 우회하므로
  `agents/` 가 삭제될 수 있었다. 사용자 판단으로 이 마지막 우회로를 봉쇄한다.
- **orphan_guard.py (신규)**: `MCP-Servers/oio-mcp-server/orphan_guard.py`.
  `hooks/lib/orphan_scan.sh` 를 subprocess 로 호출한다 — **검사 로직 복붙 없음**(NUL 함정 처리 단일 출처 유지).
- **적용 지점 4곳**: `dir_ops.dir_delete` / `dir_ops.dir_rename` / `dir_ops.dir_move`(source) / `file_ops.file_delete`.
  rename·move 도 `agents/` 를 치우면 추적 근거가 소멸하므로 삭제와 동일 취급했다.
- **★ fail-open 3중 보장**(oio 는 전 파일작업 관문이므로 H-1 보다 엄격):
  ① `orphan_guard.check_orphan_block` 최상위 try/except → 어떤 예외도 밖으로 안 나감
  ② `_check_orphan_guard` 래퍼가 import 실패까지 흡수
  ③ 스크립트 부재/실행실패/타임아웃(2초)/비정수 출력 → 전부 통과
- **범위 최소화**: `session-env/<uuid>/(agents|panes)` 정규식 1회 검사. 그 외 경로는 즉시 통과(오버헤드 0).
- **긴급 정지 스위치 공유**: `orphan_scan.sh` 삭제 시 H-1·H-2·oio 가드가 **동시** 무력화(V17 확인).
- **검증(V12~V17 전항목 PASS)**: 차단 실증 4경로(dir_delete·file_delete·dir_rename·dir_move 전부 `ORPHAN_AGENTS_ALIVE`) /
  fail-open 3단계(파손→통과, 삭제→통과, 원복→차단 복귀) / 범위 밖 정상 / 일상 함수 무회귀 /
  타임아웃 0.001s 강제 시 통과 / 잔존 0건 복귀 후 정상 삭제 성공 / py_compile 3파일 / CRLF 0.
- **⚠️ 미검증**: 실행 중 oio 서버는 L-404(Python import 시점 적재)에 따라 **재시작 전까지 옛 코드로 동작**한다.
  본 검증은 별도 프로세스에서 모듈을 직접 import 해 수행했다. **MCP 경유 실제 차단은 서버 재시작 후 확인 필요.**

## 2026-08-17 (사이클3 — 팀에이전트 보고 유실 재발방지 H1)
- **사유**: 같은 세션에서 팀에이전트 3건(verify-1 / diag-1 / odev-2)이 보고 내용을 **화면 텍스트로만 출력**하고
  SendMessage 도구를 호출하지 않은 채 턴을 종료했다. 화면 텍스트는 team-lead에게 전달되지 않으므로 보고가 유실됐다.
  LLM 의지에 의존하는 문서/프롬프트 보강만으로는 재발을 막지 못하므로 hook 물리 차단으로 승격했다.
  계획서: `/mnt/c/DATA/Project/Mars/plans/oplan_c3_report_hook.md`
- **★ 이벤트는 `Stop` 이 아니라 `SubagentStop`**: 바이너리 2.1.233 실측 결과 hook 입력 조립부가
  `agent id 있음 → SubagentStop / 없음 → Stop` 으로 **상호 배타** 분기한다.
  Stop hook 으로 만들면 팀에이전트 종료 시 영원히 발화하지 않는다. 기존 `Stop.sh`(STALE-OK 롤백)는 무접촉.
- **lib/report_guard.sh (신규)**: 판정 단일 출처(L-457). `agent_transcript_path` JSONL 을 파싱해
  "마지막 턴에 도구를 썼는데 SendMessage 가 0건" 인 경우만 `BLOCK <턴> <도구수> <도구명>` 을 반환한다.
  턴 경계 = `type=="user"` AND `isMeta` 없음 AND content 가 tool_result 전용이 아닌 행.
  통과 예외: 첫턴(E2) / shutdown_request(E3) / 사용자중단(E4) / 로컬명령(E5) / TaskOutput·EndConversation(E6) / 도구0건.
  ★ E3~E5 는 실측 5건으로 확인한 **정상 종료** 형태다. 이 예외를 빼면 shutdown 받은 에이전트가 전부 block 되어
  8회 상한까지 헛돌다 강제 종료 → 4개 프로젝트 파이프라인 마비.
- **SubagentStop_report_guard.sh (신규)**: 얇은 호출부(stdin 파싱 → lib 호출 → 출력).
  차단 reason 에 **실제 도구명 목록 + 턴 번호**를 포함한다(L-478 — 원 정보를 가리지 않는다).
- **settings.json 4개 등록**: Mars / Jarvis / MaiX / know 에 `hooks.SubagentStop` 추가(절대경로, timeout 5).
  ★ `ai`/`AI` 저장소는 제외(현행 유지). 백업: `settings.json.bak-c3-20260817` 4건.
- **★ fail-open 9중**: `set -u` 만 사용(`set -e` 금지) / 모든 경로 기본 exit 0 / 차단은 단 한 곳 /
  `timeout 2` 격리 / lib 부재 통과 / jq·python3 부재 통과 / `BLOCK ` 정확 일치일 때만 차단(UNKNOWN=통과) /
  settings timeout 5 / 엔진 block 8회 상한.
- **긴급 정지 3중**: ① `touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_REPORT_GUARD` ② `mv lib/report_guard.sh *.disabled`
  ③ settings.json 블록 삭제(백업 복원). ①② 는 **settings.json 무수정** — 2026-05-02 활성 세션 캐시 사고 회피.
- **검증(V0~V7)**: 문법 2파일 PASS / V1 위반 차단 exit 2 + block JSON 유효 /
  V2 첫턴·V2b shutdown 3건·V2c 중단·로컬 2건·V2d stop_hook_active → 전부 exit 0 /
  V3 fail-open 5종(빈 stdin·깨진 JSON·없는 경로·잘린 JSONL·빈 파일) 전부 exit 0 /
  V6 긴급정지 ①② 무력화·복구 왕복 실증 / V7 평균 59ms(기준 500ms) / V5 JSON 4개 유효 + diff 는 추가분뿐.
- **⚠️ 미검증(정직 분리)**: V4 회귀는 실제 `subagents/agent-*.jsonl` **16건 전수 PASS(오차단 0)** 로 수행했으나,
  이 16건은 전부 단발 Explore/general-purpose 서브에이전트(첫턴 E2 통과)다.
  **다턴 팀에이전트 트랜스크립트는 코퍼스에 존재하지 않아 실데이터 회귀를 못 했다**(합성 케이스로만 차단 실증).
  또한 V5b(등록 후 실제 spawn 무차단)는 다음 팀에이전트 종료 시점에 확인이 필요하다.

## 2026-06-23
- sendmessage_ack_write.sh: 팀에이전트 일반 완료보고 evidence 기록 추가 (SendMessage team-lead 수신 시 agent_report_{이름}.json 갱신)
- full_task_team_guard.sh: 팀에이전트 하위 Agent spawn 물리차단 (L-299 — PIPELINE_UUID 환경변수 기반, 메인 정상 spawn 무영향)
- write_guard.sh: NTFS /plans/ 경로 차단 시 session-env/${UUID}/plans/ 경로 안내 메시지 추가 (P4 팀에이전트 + 파이프라인 활성 메인 차단 양쪽 적용)
- 검증: 각 hook bash -n 문법 통과 + fail-open 확인

## 2026-08-19 (F-COMMIT-1 역라우팅 정정 — odev-1)
- **사유**: otest-1 역라우팅으로 F-COMMIT-1(state DEV/TEST 중 git commit 차단)이 실환경에서 무력화됨이
  발견됨. 최초 구현(사이클14) 시 stdin 파이프 직접 실행으로만 검증해 "물리 차단됨"으로 오보고했으나,
  실제 `mcp__oio__bash_exec` 경로에서는 표준 `git commit --allow-empty` 조차 그대로 통과했다(3회 재현).
- **★ 원인 확정(실측 로깅)**: hook 자식 프로세스 환경변수에 **`PIPELINE_UUID`가 아예 주입되지 않는다**
  (`env | grep PIPELINE` → 빈 결과. `mcp__oio__bash_exec`가 실행하는 셸도 동일하게 unset 확인).
  기존 코드는 `.session_id`(hook stdin JSON) 우선 → 없으면 `PIPELINE_UUID` 폴백 순서였는데,
  `.session_id`는 팀에이전트 **자기 자신의 개별 세션 ID**(파이프라인 공유 UUID와 다름)라 항상 값이
  존재해 폴백이 발동하지 않았다. 그 UUID로 만든 state 경로는 파일 자체가 없어 `state_read`가
  "IDLE"을 반환 → DEV/TEST 매칭 실패 → 통과.
- **다른 블록 조사(범위 확대 여부)**: write_guard.sh 내 `.session_id` 단독 조회 블록이 2곳 더 있음
  (라인 58 탐색 도구 분기, 라인 391 메인 판정 분기). **둘 다 F-COMMIT-1과 달리 결함 없음** —
  두 블록 모두 최종 차단 판정 직전에 `[[ -n "${PIPELINE_UUID:-}" ]]` 를 게이트로 걸어 팀에이전트를
  무조건 통과시키므로, `.session_id` 오판정이 있어도 결과에 영향이 없는 구조. F-COMMIT-1만 이
  게이트 없이 `.session_id` 값 자체로 state를 조회해 팀에이전트에서 오작동했다.
- **★★ 인프라 차원 확인**: `PIPELINE_UUID` 환경변수는 팀에이전트 Claude Code 프로세스 자체에도
  주입되지 않는다(`/proc/{pid}/environ` 직접 확인 — 프롬프트로 전달된 텍스트일 뿐 OS 환경변수 아님).
  즉 `resolve_uuid()`의 `PIPELINE_UUID` 분기는 현재 실행 환경에서 사실상 항상 미스(unset)다.
  write_guard.sh의 다른 "팀에이전트 확정" 로직(P4, 750행)이 실제로 안전한 이유는 위와 동일하게
  `.session_id` 값 오판정이 있어도 그 값 자체가 최종 판정에 안전한 방식으로만 쓰이기 때문으로 보이며,
  근본적으로 `PIPELINE_UUID` env 주입 자체가 인프라 레벨에서 고쳐지지 않는 한 유사 패턴 신규 추가 시
  동일 함정이 재발할 수 있음 — **팀 리드/차기 작업에 별도 보고 필요**.
- **수정**: write_guard.sh F-COMMIT-1 블록의 UUID 결정 순서를
  ① `PIPELINE_UUID` 환경변수(향후 정상 주입 대비, 현재는 대개 unset)
  ② 프로세스 트리 조상을 `/proc/{pid}/stat` 4번째 필드(PPID)로 거슬러 올라가며
     `/proc/{pid}/cmdline`에서 `--parent-session-id <UUID>` 패턴을 파싱(최대 10단계) — 실측상
     신뢰 가능한 유일한 경로로 확인됨(otest-1/odev-1 프로세스에서 144be8b3-... 정확히 추출 성공)
  ③ `.session_id`(메인 전용 최후 폴백)
  순으로 재구성. 새 판별 방식 발명이 아니라 Claude Code가 이미 프로세스 인자로 노출하는
  `--parent-session-id`를 읽는 방식이며, `resolve_uuid()`가 의도했던 "팀에이전트=파이프라인 UUID"
  의미를 실측 가능한 경로로 구현한 것.
- **실환경 검증 4종 (mcp__oio__bash_exec 직접 호출, stdin 파이프 아님)**:
  ① 사고재현(state=DEV, 실제 git commit): **block 확인**(수정 전 3회 연속 통과 재현 → 수정 후 block)
  ② 정당경로(state=DONE으로 임시 전환 후 커밋): **통과 확인** → 즉시 `git reset --hard f9d1edea` +
     state 원복. DEV 재전환 후 재차단 재확인 완료.
  ③ 오탐(git status/diff/log/echo "commit" 문자열): **전부 통과 확인**, 오차단 0.
  ④ 대조군(F10-2 git stash): **여전히 정상 차단 확인**(본 수정이 F10-2 로직 무영향).
  검증 전 과정에서 push 없음, HEAD는 f9d1edea로 원상 복귀, 타 세션 state 파일(35ad247e/65400add) 무손상.
- **임시 디버그 로깅**: 원인 실측용으로 `$HOME/.claude/logs/fcommit_debug.log`에 임시 로깅 코드를
  2회 삽입/제거했음. 최종 코드에는 디버그 로깅 잔존 없음(제거 완료, read 검증됨).

---

## 2026-08-26 — 사이클41 H1/H1b: 세션 디렉토리 2중화 물리 차단 (Mars 전용)

**변경 사유**: 사이클40 에서 `/oto`(auto=ON, "질문 없이 끝까지 완주") 가 2회 연속 완주 실패.
근본 원인은 세션 디렉토리 경로 갈림이며, mtime 실측으로 사고를 정확히 재구성했다.

```
21:23:55  PreToolUse_oto_completion_guard.sh 발동 → BLOCK F-OTO-7b
          로그: "path_fallback=HOME"
실측 mtime:
  auto      HOME 21:27:09 / CCD 21:27:09  ← 차단 시각(21:23:55)에는 ★CCD 쪽 부재★
  goal.json CCD  15:29:41 / HOME ★부재★
⇒ guard 의 "auto 있는 쪽을 정본으로" 폴백(:63-68)이 HOME 을 선택
⇒ HOME 에는 goal.json·oralph_active 가 없음 → F-OTO-7b 차단
⇒ ★5시간 작업 후 종료 시점에야 완주 실패가 드러남★
```

**근본 원인 (코드 실측)**: oio 서버의 쓰기 경로 비대칭.
- `mcp__oio__session_state` → `session_ops.py:_mirror_state_bases()` 로 **양쪽 base 기록**
  (state·status·auto·classification·entry_tier 등 전 키, `bases_written=2`)
- `mcp__oio__file_write/edit` → `file_ops.py` 에 미러링 코드 **전무**(grep 0건) → **한쪽만**
  (goal.json·oralph_active 가 여기 해당)

**추가 조치 (본 변경에는 미포함 — 별도 필요)**: `file_ops.py` 미러링 이식이 항구적 해결.
본 hook 2건은 그 전까지의 탐지·차단 장치이며, 서버 수정 후에도 회귀 방지로 유효하다.

### 추가된 hook 2건 (절대경로 — 매크로/상대경로 미사용)

1. **PreToolUse / matcher `Skill`** → `${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_session_path_guard.sh`
   - auto=ON 세션에서 두 base 의 8개 파일을 **내용 해시**로 비교, 불일치 시 `block`(F-PATH-1).
   - 대상: state · status · auto · goal.json · oralph_active · team_name · classification · entry_tier
   - **block 채택(자동 정합 아님)**: ① 조용히 고치면 서버 결함이 영구 은폐됨
     ② 정본 판정 근거 부재(잘못된 정합이 갈림보다 위험) ③ hook 의 쓰기가 새 갈림 원천이 됨.
   - **hook 자신은 어느 쪽도 정본으로 고르지 않는다**(두 경로 대칭 비교). auto 판정만 양쪽 OR
     — AND 로 읽으면 이번 사고(한쪽에만 auto 존재)를 놓치기 때문.

2. **SessionStart / matcher `""`** → `${HARNESS_HOME:-$HOME/.harness}/current/hooks/SessionStart_path_unify.sh`
   - 세션 시작 시 동일 비교 후 **기록 + 경고만**. 차단·수정 없음. 자기 세션만(격리 §(a)).
   - 정합(복사)을 하지 않는 이유: 시작 시점에는 정본 판정 근거가 없어, 이행 완료된 옛 계약이
     새 세션 정본으로 되살아날 위험이 있다(ofinish 의 "locked=false 잔존" 경고와 동형).

### 검증 결과 (실제 발동 테스트 — 등록만 하고 넘기지 않음)

격리 픽스처(`/tmp/pathguard_test`)로 11 케이스 전수 실행, **전건 기대치 일치**:

| # | 케이스 | 기대 | 실측 |
|---|---|---|---|
| T1 | auto 부재(비 oto 세션) | 통과 | rc=0 ✅ |
| T2 | auto=ON 양쪽 + 전부 정합 | 통과 | rc=0 ✅ |
| T3 | goal.json 이 CCD 에만 (사이클40 재현) | **차단** | rc=2 ✅ |
| T4 | auto=HOME만 + goal=CCD만 (사고 시점 정확 재현) | **차단** | rc=2 ✅ |
| T5 | goal.json 양쪽 동일 | 통과 | rc=0 ✅ |
| T6 | goal.json 내용 상이 | **차단** | rc=2 ✅ |
| T7 | oralph_active 양쪽 부재 | 통과 | rc=0 ✅ |
| T8 | 팀에이전트(PIPELINE_UUID 불일치) | 통과 | rc=0 ✅ |
| T9 | 비상 스위치 존재 | 통과 | rc=0 ✅ |
| T10 | CLAUDE_CONFIG_DIR 미설정 | 통과 | rc=0 ✅ |
| T11 | auto=OFF | 통과 | rc=0 ✅ |

**테스트 중 발견·수정한 자체 결함 2건** (테스트를 안 했으면 무력한 hook 이 될 뻔했다):
- `_HOOK_DIR` 를 `$HOME` 기준으로 잡아 lib 미발견 시 **조용히 exit 0** → 스크립트 실경로 기준으로 변경.
  게이트가 no-op 이 되는 형태였다.
- 비상 스위치를 `_HOOK_DIR` 한쪽만 검사 → **HOME 측 touch 가 안 먹힘**(T9 rc=2).
  양쪽 검사로 수정. 비상 스위치가 비상 시 작동하지 않는 것은 그 자체로 사고다.

**회귀 확인**: 기존 hook 57건 → 59건(+2), 손실 0. JSON 유효성 통과.
비절대경로 2건(`bash "/abs/path"` 형식)은 **본 변경 이전부터 존재**하던 항목이며 무관.
Mars 프로젝트 settings.json 만 수정 — 타 프로젝트 무영향. 백업: `/tmp/settings.json.bak_c41`.

**활성 세션 캐시 주의**: 본 변경은 신규 세션부터 적용된다. 활성 세션 강제 재시작은 하지 않았다
(CLAUDE.md settings.json 변경 정책 — 22일 1,122회 silent fail 사고 이력).

## 2026-08-26 사이클41 odev-4 (analyst)
- **settings.json 무수정.** Stop hook 은 Mars/.claude/settings.json 에 이미 등록돼 있었다
  (Stop.sh → Stop_askq_guard.sh(timeout 5) → Stop_observation_guard.sh, 전부 절대경로).
- `hooks/Stop_askq_guard.sh` **역방향 확장(H2)**: auto=ON + 이번 턴 AskUserQuestion 존재 → block.
  auto 판정은 HOME/CCD **양쪽 OR** — PreToolUse_session_path_guard.sh(H1) 와 동일 로직.
  검증: auto없음/OFF=PASS, ON=block, E6 3회차 PASS, 정방향 회귀 block 유지.
- `scripts/team-cleanup.sh`: CLAUDE_CONFIG_DIR 반영 + 타 세션 미열거(§(c)) + agent-id 본체 우선 검사.
- `hooks/write_guard.sh` **F-GOAL-1 확장(작업4+3)**: settings.json 무수정.
  (A) 안쪽 case 에 bash_exec 누락 → sed/rm/mv/tee 로 locked goal.json 변경이 **실측 rc=0 통과**하던
      구멍 차단. 조회(cat/jq/grep)·무관파일은 통과(false positive 0).
  (B) 이행완료 unlock 3조건 AND 예외(①completed 사본 ②state=FINISH ③locked 단일필드).
      ③이 acceptance 동시 변조를 차단. 백업 write_guard.sh.bak_c41_odev4_20260826_215001.

---

## 2026-08-26 — 사이클41 (2차): F-OTO-0 진입 게이트 + Agent 바인딩 관측

### 추가 hook 2건 (절대경로)

3. **PreToolUse / matcher `mcp__oio__session_state`** → `${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_oto_entry_guard.sh`
   - key=state, value=**PLAN|DEV**(진입 전이)만 대상. auto=ON 세션 한정.
   - **F-OTO-0a** 경로 단일화(goal.json·oralph_active·status·auto 4파일) → 불일치 시 block
   - **F-OTO-0b** RALPH 게이트 생존(status RALPH 토큰 또는 oralph_active) → 부재 시 block
   - **설계 정당성**: 기존 F-OTO-7b 는 종료 시점(value=IDLE)에 같은 것을 잡는다. 사이클40 실측 —
     21:23:55 차단 시점에 **이미 5시간치 작업이 끝나 있었고 검증 루프는 한 번도 안 돌았다.**
     게이트는 정확했으나 **알려준 시점이 너무 늦었다.** F-OTO-0 이면 **작업 시작 전 30초**에 잡힌다.
   - 기존 completion_guard 와 **value 가 서로소**(IDLE vs PLAN|DEV)라 간섭 없음.

4. **PostToolUse / matcher `Agent`** → `${HARNESS_HOME:-$HOME/.harness}/current/hooks/PostToolUse_agent_bind_check.sh`
   - spawn **성공** 응답의 `agent_id` 팀명 ↔ `session-{UUID앞8자}` 대조. **차단 없음 — 기록·경고만.**
   - **왜 관측인가**: 런타임 세션 바인딩은 hook/파일/oinit 로 해소 불가(L-540 — /clear 또는 재시작만).
     차단하면 정상 작업까지 전면 중단되고 사용자에게 선택지가 없다. ⇒ **Hook 1순위 미적용이 아니라,
     hook 으로 구현하되 차단이 아닌 관측으로 설계한 것.**
   - **메우는 공백**: ok/SKILL.md L-NEW2 와 full_task_team_guard.sh 는 **spawn 실패**를 전제해 실패
     경로에만 감지가 붙어 있다. 사이클41 실측에서는 **spawn 이 성공**하고 옛 팀(session-e1c14841)에
     조용히 편입됐으며 `session_bind_mismatch.log` 가 **미생성**이었다. 성공이 실패보다 위험하다.
   - **SCAN 라인 상시 기록**: "탐지 0건"과 "관측이 안 돌았음"을 구분하기 위해서다. 응답 스키마가
     바뀌어 관측이 끊겨도 그것이 "정상"으로 위장하지 않게 한다.

### 검증 결과 (실제 발동 — false positive 포함)

**F-OTO-0 (12건 전건 통과)**
| # | 케이스 | 기대 | 실측 |
|---|---|---|---|
| E1 | auto 부재(비 oto) | 통과 | rc=0 ✅ |
| E2 | auto=ON + RALPH 없음 | **차단** | rc=2 ✅ |
| E3 | RALPH 있음 + 경로 정합 | 통과 | rc=0 ✅ |
| E4 | value=IDLE(대상 아님) | 통과 | rc=0 ✅ |
| E5 | key=classification | 통과 | rc=0 ✅ |
| E6 | value=DEV | 통과 | rc=0 ✅ |
| E7 | **goal.json CCD 에만 (사이클40 재현)** | **차단** | rc=2 ✅ |
| E8 | goal.json 정합 복구 | 통과 | rc=0 ✅ |
| E9 | **auto 가 HOME 에만 (사고 시점)** | **차단** | rc=2 ✅ |
| E10 | oralph_active 로만 RALPH 판정 | 통과 | rc=0 ✅ |
| E11 | 팀에이전트(PIPELINE≠) | 통과 | rc=0 ✅ |
| E12 | 비상 스위치 | 통과 | rc=0 ✅ |

**바인딩 관측 (3건 전건 통과)** — B1 실제 사고 재현(`odev-c41-2@session-e1c14841`) → 경고 출력 + rc=0(차단 없음) /
B2 일치 → 무출력 rc=0 / B3 agent_id 부재 → 조용히 통과. SCAN·MISMATCH 로그 양쪽 base 기록 확인.

**회귀**: hook 59 → 61건(+2), 손실 0, JSON 유효. 백업 `/tmp/settings.json.bak_c41b`, `_c41c`.

---

## 2026-08-26 — 사이클41 (3차): ★oio 서버 file_ops.py session-env 미러링★ (근본 원인 제거)

> ⚠️ **settings.json 변경 아님. oio MCP 서버 코드 변경이라 전 세션에 영향.**
> **서버 재시작 후에야 적용된다** (실행 중 서버는 14:31/14:48 기동, 코드 수정 21:52).

**진범**: 쓰기 경로의 비대칭. `session_ops.py:_mirror_state_bases()` 는 전 키를 양 base 에 기록하는데
(`bases_written=2`), `file_ops.py` 에는 미러링 코드가 **전무**했다(grep 0건).
⇒ `auto`·`status`·`state` 는 양쪽 / `goal.json`·`oralph_active` 는 한쪽 ⇒ **이것이 비대칭의 전부.**

**신규 모듈** `session_mirror.py` — `file_ops.py` 6개 도구 8개 지점에 적용
(write / edit / delete / rename×2 / move×2 / copy).

**판단이 필요했던 4건 (지시서 ⚠️ 항목)**
- **①세션 격리 §(a)**: `mirror_targets()` 가 **자기 UUID 일 때만** 미러. `PIPELINE_UUID`/`CLAUDE_SESSION_ID`
  로 자기 UUID 를 구하지 못하면 **미러하지 않는다(fail-closed)** — 자기 것임을 증명 못 하면 안 건드린다.
- **②회귀 금지**: 경로에 `/session-env/<36자 uuid>/` 가 없으면 **즉시 빈 리스트** → 그 외 전 경로는
  문자열 검사 1회 외 오버헤드 0. 실측 확인 — `/tmp/regression_c41_check.txt` 쓰기 결과에
  `bases_written`/`mirror_warning` 미출현.
- **③file_copy**: **destination 만 미러**한다. copy 의 부작용은 "destination 에 파일이 생긴다" 뿐이며,
  ofinish pre_cleanup_3c 가 `goal_{id}_completed.json` 사본을 만들 때 한쪽에만 생기면 **증적 보관이
  목적인 작업이 새 갈림을 만드는 자기모순**이 된다. source 는 읽기만 하므로 미러하면 "읽었을 뿐인데
  반대편이 덮어써지는" 예기치 않은 쓰기가 되어 제외.
- **④실패 정책**: **fail-loud** 채택. `session_ops.py` 는 fail-soft 지만, **조용한 실패가 정확히
  사이클40 의 사고 형태**였다(한쪽에만 기록 → 아무도 모름 → 5시간 뒤 발각). 미러 실패 시
  `result["mirror_warning"]` 으로 즉시 노출한다. 단 **원본 작업을 실패로 뒤바꾸지는 않는다** —
  원본은 이미 성공했고 되돌리면 더 큰 사고다.

**검증**: 격리 유닛테스트 14 assertion 전건 통과 — 자기 UUID 미러 / **타 세션 미러 0건(§(a))** /
session-env 밖 무영향 / 36자 아닌 세그먼트 거부 / 디렉토리 제외 / write·delete 미러 동작 /
`success=False` 는 미러 생략 / **UUID 불명 시 fail-closed** / 두 base 동일 시 no-op.
실서버 venv(`$HOME/.venv/oio-mcp/bin/python`) import 정상, base 해석 정상.

**백업**: `/tmp/file_ops.py.bak_c41_215034`
**미적용 상태**: 서버 재시작 필요 — 사용자 고지 대상.

## 2026-10-08 — 사이클172 B9(C26): 실업무 쓰기 스냅샷 gate + 사용자 중지/범위 마커 gate 등록 (odev-10)

- **등록(PreToolUse, 절대경로)**: `matcher "*"` 블록에 `PreToolUse_stop_marker_gate.sh`(timeout 10) 추가(L-1195) · 신규 `matcher "Bash|mcp__oio__bash_exec|mcp__mysql__execute|mcp__mysql__query"` 블록에 `PreToolUse_snapshot_gate.sh`(timeout 10) 추가(L-1200). 정본 `AI/.claude/settings.json` 수정 후 `lib/settings_hooks_sync.py` 로 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`·활성 cas 프로파일에 동기화(`--check` rc=0). 백업 `settings.json.bak_c172_odev10`.
- **검증**: `tests/test_c172_snapshot_gate.sh` 21/21 · `tests/test_c172_stop_marker_gate.sh` 36/36 rc=0, hook_lint 통과, test_c170_settings_sync 40/40, 평균 지연 19~23ms. ⚠️ 등록 직후 실행 중 세션에 **즉시 반영**됨을 실측(자기 테스트 실행이 .sh 픽스처 SQL 로 차단 → .sh 내용 스캔 제외로 수정, N13 회귀 추가). 스위치 `hooks/DISABLE_SNAPSHOT_GATE`·`hooks/DISABLE_STOP_MARKER_GATE`(팀원 조작은 차단, 사용자·리드 전용).
- **부수(⑤)**: `phase_batches_immutable_guard.sh:49-54` UUID 해석을 session_id 우선 → 대상 경로 session-env/<UUID> 우선으로 수정(팀원 세션ID 로 플래그를 찾아 oplan 정당 쓰기 차단하던 결함, 구판 rc=2 / 신판 rc=0 재현). 백업 `.bak_c172_odev10`.
- **보강(리드 지시 — 점수 7/10 미달)**: ① `otest_make/scripts/verify_crud_executed.py` emit_from_goal 에 실업무 행 스냅샷 선행 게이트(`_snapshot_violations` — 미충족 시 make_partial, `live_rows:false` 면제) + 회귀 k11~k16(58/58). ② `UserPromptSubmit.sh`(백업 `.bak_c172_odev10`)가 PLAN~DONE 중 메인 사용자 입력을 자기 세션 `scope_markers/_user.json`(type=info)에 자동 기록(`lib/scope_marker_autowrite.py`), `stop_marker_gate` 가 info 1회 전달. stop 자동 판정은 오분류 비용 때문에 하지 않음. settings 등록 변경 없음.
- **오차단 2건 추가 실측·수정**: snapshot_gate 가 `.py` 를 언급만 하는 grep 과 SQL 픽스처 문자열만 있는 테스트 .py 실행을 차단 → "실행되는 파일만 + 줄 첫머리 import" 로 축소(N14/N15).

## 2026-10-16 — 사이클191 ⑥: 로컬 웹서버 루프백 바인드 가드 신설(F-HTTP-BIND, L-1311) — 등록 예정 (odev-3)

- **신규 hook**: `hooks/PreToolUse_http_server_bind_guard.sh`(LF, 판정 코어 내장 python). Bash·`mcp__oio__bash_exec` 의 command(oio `cmd` 별칭 포함)에서 `python* -m http.server|SimpleHTTPServer`(--bind/-b)·`http-server`(-a/--address)·`serve`(-l/--listen)·`php -S <addr>`·`ruby -run -e httpd`(--bind-address)를 루프백(127.x·localhost·::1) 지정 없이 띄우면 `permissionDecision=deny`. 따옴표 안·heredoc 본문·주석은 제외, `bash -c`/`eval`/셸 heredoc 은 재귀 판정. fail-open(timeout 4·예외 무출력). 스위치 `hooks/.http_server_bind_guard_off`, `HSB_MODE=warn`.
- **등록 예정(odev-4·5 담당, 이 기록 시점 미등록)**: 5사본 `PreToolUse` matcher `"Bash|mcp__oio__bash_exec"` 블록에 `${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/time_budget.sh 2.5 open ${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_http_server_bind_guard.sh`, timeout 5.
- **검증**: `tests/test_http_server_bind_guard.sh` 50/50 rc=0(차단 24·통과 22·메시지 형식·warn·OFF 스위치·깨진 입력 fail-open), 평균 지연 50ms. guard_promote 등록부(`lib/guard_promote.json`) 비대상(신규 파일, 등록부에 경로 없음 확인).

## 2026-10-18 — 사이클182 (conv_179228490855): F-ORPHAN-2 sweep 다중 근거·fail-safe + agent_lifecycle post 폴백 등록 (odev-1·odev-2)

- **원인(실측)**: 09:56:41 시스템 정체(load=1000‰)로 PreToolUse `agent_lifecycle.sh` 가 time_budget 2.5초를 넘겨(ms=4290, overrun) `pre_spawn_oplan-4.txt` 를 남기지 못했고, PostToolUse 도 등록 파일을 쓰지 못했다. `Stop_orphan_agent_sweep.sh` 조건 3 은 "agents/ 파일 없음" 하나로 `unregistered_orphan` 을 확정해 09:57:50 살아 있는 팀원 pane %126 을 kill 했다. 그 순간 팀 config 에는 oplan-4 가 isActive=true·tmuxPaneId=%126 으로 있었다. 상세는 session-env `plans/rootcause_c182_A.md`.
- **sweep 변경(odev-1)**: 조건 3 을 `_sweep_registered_evidence` 로 교체했다. agents 파일·pane_index 행·팀 config 활성 멤버(agentId·tmuxPaneId 일치, isActive!=false, leadSessionId 는 보지 않음)·프로세스 etimes < 유예(ROSTER_GRACE_SEC, 기본 900초) 중 하나라도 맞으면 kill 하지 않는다(`SKIP_REGISTERED evidence=<근거>`). jq 실패·config 파싱 실패·etimes 판독 실패는 `WARN_UNCERTAIN` 로그만 남기고 kill 하지 않는다. 팀 config 근거로 살아남았는데 agents 파일이 없으면 자기 세션 `agents/<이름>`(source=sweep_heal)·pane_index 를 다시 쓴다(`HEALED`). dead_process·idle_state·SKIP_OTHER_SESSION·화이트리스트·no_kill·메인 pane 방어·roster 정리는 무변경이다.
- **sweep 시험**: `tests/test_orphan_sweep_multi_evidence.sh` C1~C15 PASS=15 FAIL=0(가짜 tmux·ps, 실 pane 접촉 없음). 원본에 같은 시험을 돌리면 FAIL=7 로 시험이 결함을 잡는 것을 확인했다. 백업 `hooks/backup/c182/Stop_orphan_agent_sweep.sh.orig`(sha256 6866eebe…).
- **agent_lifecycle 변경(odev-2)**: post 단계가 pre_spawn 파일이 없을 때 흔적 없이 `exit 0` 하던 것을 고쳤다. 이제 ps 인자(`--agent-id <이름>@` + `--parent-session-id <자기 UUID>` 둘 다 정확히 일치)로 pane 을 찾아 agents/<이름> 을 등록한다(source=post_fallback). 못 찾으면 `.failed`(PRE_MISSING_NO_PANE)와 hook_debug `SPAWN_UNVERIFIED` 를 남긴다. 시험 `tests/test_agent_lifecycle_register_fallback.sh` L1~L6 PASS=8 FAIL=0이다(원본 대상 FAIL=6). 백업은 `hooks/backup/c182/agent_lifecycle.sh.orig`(sha256 f03354b6…)다. (출처: odev-2 결과 파일 work/odev-2_result.json — SendMessage 회신이 없어 대체했다)
- **settings.json 무변경**. 두 hook 은 guard_promote 등록부(`lib/guard_promote.json`) 비대상(grep 0건 확인)이라 백업 후 직접 수정했다.

## 2026-10-22 — 사이클194 C-20 (odev-7): Stop hook 등록 상태 확인(settings.json 무변경) + write_guard 분기 D 보수 (C-19)

- **C-20 결론**: 이월 문구 "teammate idle 정리용 Stop hook 미등록"은 현재 사실과 다르다. `settings.json` `hooks.Stop` 에 `Stop_orphan_agent_sweep.sh` 가 절대경로(`${HARNESS_HOME:-$HOME/.harness}/current/hooks/Stop_orphan_agent_sweep.sh`, async, timeout 10)로 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`·AI 원본 두 파일 모두에 이미 등록돼 있고(Stop 7개·TeammateIdle 3개 중), 이 세션 `logs/orphan_agent_sweep.log` 에 사이클194 발동 SWEEP_DONE 기록이 있다(증거 `_tmp_c194/odev7/C-20_stop_hook_fire.log`). 따라서 settings.json 은 바꾸지 않았다. 이월 원기록에 대상 hook 이름이 없어 이 hook 으로 특정한 것은 추정이다(확정 아님).
- **C-19 (write_guard.sh 분기 D)**: `/tmp/` 가 들어 있고 `/mnt/[c-z]/` 가 없으면 무조건 허용하던 분기를, 쓰기성 명령(rm·mv·cp·tee·touch·sed -i·리다이렉트 등)이면서 `/tmp/` 밖 절대경로·`~`·`$HOME`·`../` 토큰이 있을 때는 통과시키지 않고 기존 상태 판정으로 넘기도록 보수했다. 읽기 전용 명령은 종전대로 허용. 시험 `tests/test_c193_boot_stale_pane_guard.sh` 섹션 5(WG-D 6건) + C-21 보존 사례 추가, 전체 PASS=50 FAIL=0.
