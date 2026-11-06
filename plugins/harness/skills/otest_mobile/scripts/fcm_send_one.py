# FCM HTTP v1 으로 지정한 토큰 1개에만 테스트 알림을 직접 보내는 범용 스크립트(같은 계정의 다른 단말로 새지 않게)
"""
사용:
  python3 fcm_send_one.py --key <서비스계정키.json> --token <FCM 토큰> --title "[cNNNtest] 제목" --body "본문" \
      [--data k=v ...] [--channel <안드로이드 채널 id>] [--dry-run]

용도:
  - 단말 수신만 확인할 때 쓴다(otest_mobile "푸시 실수신" 절 경로 ①). 서버 발송 경로 검증은 이 스크립트가 아니다.
  - 토큰은 DB 에서 대상 단말 행 1개를 골라 넘긴다(기기명·등록 시각으로 행을 특정하고 증거에 행 ID 를 적는다).
  - 키 파일은 저장소에 두지 않는다. 경로·채널 id 같은 프로젝트값은 oinfra_{project} 에서 읽어 인자로 넘긴다.
출력: HTTP 상태와 응답 앞부분(메시지 name). rc=0 이면 FCM 이 수락한 것이다(단말 표시 여부는 별도 캡처로 판정).
의존: requests, PyJWT + cryptography (google-auth 없이 서명한다).
"""
import argparse, json, sys, time

import jwt
import requests


def access_token(info):
    now = int(time.time())
    claim = {"iss": info["client_email"], "scope": "https://www.googleapis.com/auth/firebase.messaging",
             "aud": info["token_uri"], "iat": now, "exp": now + 3600}
    assertion = jwt.encode(claim, info["private_key"], algorithm="RS256")
    r = requests.post(info["token_uri"], data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                                "assertion": assertion}, timeout=30)
    r.raise_for_status()
    return r.json()["access_token"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--body", default="")
    ap.add_argument("--data", nargs="*", default=[])
    ap.add_argument("--channel", default="")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if "test]" not in a.title:
        print("❌ 제목에 사이클 표식([cNNNtest])이 없다 — 테스트 알림은 표식 필수", file=sys.stderr)
        return 2
    info = json.load(open(a.key, encoding="utf-8"))
    data = dict(kv.split("=", 1) for kv in a.data)
    android = {"priority": "high"}
    if a.channel:
        android["notification"] = {"channel_id": a.channel}
    msg = {"message": {"token": a.token, "notification": {"title": a.title, "body": a.body},
                       "data": data, "android": android}}
    if a.dry_run:
        print(json.dumps(msg, ensure_ascii=False)[:500])
        return 0
    r = requests.post(f"https://fcm.googleapis.com/v1/projects/{info['project_id']}/messages:send",
                      headers={"Authorization": f"Bearer {access_token(info)}"}, json=msg, timeout=30)
    print("FCM", r.status_code, r.text[:300])
    return 0 if r.status_code == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
