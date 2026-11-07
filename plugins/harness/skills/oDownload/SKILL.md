---
name: oDownload
description: 옛 이름 별칭 스킬. 하네스 배포본 갱신은 이제 oUpdate 가 맡는다. 이 스킬은 직접 git pull·링크 재생성·install.sh 재실행을 하지 않고 /oUpdate 절차로 넘긴다. 사용자가 '/oDownload', '하네스 업데이트', '배포본 받기', '최신 하네스 동기화' 를 요청할 때 사용.
---

# oDownload — oUpdate 로 넘기는 별칭

## 이 스킬이 하는 일

`oDownload` 는 옛 이름이다. 하네스 갱신은 **`/oUpdate`** 가 한 경로로 처리한다.
이 스킬은 아무것도 직접 고치지 않고 `Skill('oUpdate')` 를 불러 그 절차를 그대로 따른다.

예전 절차(배포 repo 에서 `git pull`, `~/.local/bin` 링크 직접 재생성, `install.sh` 재실행)는 쓰지 않는다.
이유는 세 가지다.

- 새 레이아웃은 `<프로젝트홈>/AI/.harness/active → releases/<판>` 링크 하나를 원자적으로 바꾼다.
  손으로 `git pull` 하면 실행 중인 세션이 쓰는 파일이 섞인 상태가 될 수 있다.
- `~/.local/bin` 의 cc·ccc·lcc·lccc·claude-as·cas 는 `active/bin` 을 가리킨다.
  oUpdate 는 하네스가 만든 링크만 다시 걸고 다른 프로그램의 파일은 SKIP 한다.
- 필요 도구 점검(NEEDS), 큰 변경 확인(BREAKING), 마이그레이션, 갱신 뒤 할 일(post_actions)은 oUpdate 에만 있다.

## 절차

1. `Skill('oUpdate')` 를 호출하고 그 스킬의 절차를 끝까지 따른다. 먼저 `status` 를 보고, 그다음 `apply` 를 실행한다.
2. oUpdate 가 없는 옛 판이면(아래 두 경로에 `harness_update.py` 가 모두 없음) 아무것도 바꾸지 말고, 배포 repo 의 `install_harness.sh` 파일을 전달받아 `bash install_harness.sh` 로 설치하도록 사용자에게 안내한다(구 이름 `install-online.sh` 는 호환 래퍼).
   새 설치 스크립트가 기존 설치를 감지해 갱신으로 처리한다.

   확인 명령은 아래와 같다.

   ```bash
   bash -c 'H="${HARNESS_HOME:-$HOME/.harness}";
     for p in "$H/active/plugins/harness/scripts/harness_update.py" "$H/current/scripts/harness_update.py"; do
       [ -f "$p" ] && { echo "FOUND $p"; exit 0; }; done; echo "OUPDATE_MISSING"'
   ```

3. 정본(배포자) 머신이면 oUpdate 가 `OUPDATE REFUSE` 로 멈춘다. 그 머신에서는 `/oUpload` 로 배포한다.

## 금지 사항

- 이 스킬에서 직접 `git pull`·`git reset --hard`·`git checkout -f` 를 실행하지 않는다.
- 이 스킬에서 `~/.local/bin` 링크를 직접 만들거나 덮어쓰지 않는다.
- oUpdate 결과(NEEDS·BREAKING·PARTIAL·실패)를 숨기고 성공으로 보고하지 않는다.
