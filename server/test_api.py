"""後端 API 流程測試：python3 test_api.py（自動用暫存資料庫啟動伺服器）"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PORT = 18787
BASE = f"http://127.0.0.1:{PORT}"


def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def check(cond, msg):
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond:
        check.failed += 1


check.failed = 0


def main():
    db = tempfile.mktemp(suffix=".db")
    env = dict(os.environ, PORT=str(PORT), DB_PATH=db)
    srv = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "server.py")],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(BASE + "/")
                break
            except Exception:
                time.sleep(0.1)

        print("A. 建立與加入群組")
        _, a = call("POST", "/api/users", {"name": "小林"})
        _, b = call("POST", "/api/users", {"name": "阿凱"})
        _, c = call("POST", "/api/users", {"name": "美玲"})
        _, d = call("POST", "/api/users", {"name": "旁觀者"})
        A, B, C, D = a["token"], b["token"], c["token"], d["token"]
        check(call("GET", "/api/me")[0] == 401, "沒有 token 不能存取")
        s, g = call("POST", "/api/groups", {"name": "後端組"}, A)
        gid, code = g["group"]["id"], g["group"]["invite_code"]
        check(s == 200 and len(code) == 8, f"建立群組，邀請碼 {code}")
        check(len(g["questions"]) == 3, "新群組自動附 3 題起手題")
        s, info = call("GET", f"/api/invites/{code}")
        check(s == 200 and info["name"] == "後端組", "不用登入就能看邀請資訊")
        call("POST", f"/api/invites/{code}/join", {}, B)
        call("POST", f"/api/invites/{code.lower()}/join", {}, C)
        s, _ = call("POST", f"/api/invites/{code}/join", {}, C)
        check(s == 200, "重複加入不報錯")
        _, me = call("GET", "/api/me", token=C)
        check(me["groups"][0]["member_count"] == 3, "重複加入不會被算兩次（3 人）")
        check(call("GET", f"/api/groups/{gid}", token=D)[0] == 403, "非成員看不到群組")

        _, solo = call("POST", "/api/users", {"name": "獨行俠"})
        _, sg = call("POST", "/api/groups", {"name": "一人群組"}, solo["token"])
        _, sv = call("POST", f"/api/questions/{sg['questions'][0]['id']}/vote", {"option": 0}, solo["token"])
        check(not sv["closed"], "群組只有 1 人時，回答起手題不會提早開獎")

        print("B. 出題")
        s, err = call("POST", f"/api/groups/{gid}/questions", {"text": "要不要換工具呢？", "options": ["要"]}, A)
        check(s == 400, f"只有 1 個選項會被拒絕：{err['error']}")
        s, err = call("POST", f"/api/groups/{gid}/questions", {"text": "要換嗎要換嗎", "options": ["要", "要"]}, A)
        check(s == 400, "重複選項會被拒絕")
        s, q = call("POST", f"/api/groups/{gid}/questions",
                    {"text": "下個 sprint 要不要統一改用 Codex？", "options": ["要", "不要", "先試一週"], "hours": 24}, A)
        qid = q["id"]
        check(s == 200 and q["author_name"] == "小林" and q["is_mine"], "成員可以出題")
        check(call("POST", f"/api/groups/{gid}/questions", {"text": "我不是成員喔", "options": ["a", "b"]}, D)[0] == 403,
              "非成員不能出題")

        print("C. 回答")
        _, feed = call("GET", "/api/feed", token=B)
        check(any(p["id"] == qid for p in feed["pending"]), "阿凱的待答題裡有這題")
        check(call("POST", f"/api/questions/{qid}/vote", {"option": 2}, B)[1]["my_vote"] == 2, "阿凱回答")
        check(call("POST", f"/api/questions/{qid}/vote", {"option": 0}, B)[0] == 409, "同一題不能答兩次")
        check(call("POST", f"/api/questions/{qid}/vote", {"option": 9}, C)[0] == 400, "不存在的選項會被拒絕")
        _, feed = call("GET", "/api/feed", token=B)
        check(all(p["id"] != qid for p in feed["pending"]), "答過的題目從待答題消失")
        call("POST", f"/api/groups/{gid}/mute", {"muted": True}, C)
        _, feed = call("GET", "/api/feed", token=C)
        check(feed["pending"] == [], "靜音群組的題目不會出現在待答題")
        call("POST", f"/api/groups/{gid}/mute", {"muted": False}, C)

        print("D. 開獎與隱私")
        _, view = call("GET", f"/api/groups/{gid}", token=A)
        qv = next(x for x in view["questions"] if x["id"] == qid)
        check(qv["answered_count"] == 1 and qv["results"] is None, "未截止前只看得到進度 1/3，看不到結果")
        call("POST", f"/api/questions/{qid}/vote", {"option": 2}, C)
        s, last = call("POST", f"/api/questions/{qid}/vote", {"option": 0}, A)
        check(last["closed"] and last["results"] == [1, 0, 2], "全員答完提早開獎：[1, 0, 2]")
        raw = json.dumps(call("GET", f"/api/groups/{gid}", token=A)[1], ensure_ascii=False)
        check("阿凱" not in raw and "美玲" not in raw, "群組 API 回應裡不會出現回答者的名字")
        _, feed = call("GET", "/api/feed", token=B)
        check(any(r["id"] == qid for r in feed["results"]), "回答者的 feed 收到開獎")

        # 回答不足 3 人：把截止時間調到過去來模擬
        _, q2 = call("POST", f"/api/groups/{gid}/questions", {"text": "只有兩個人會回答的題目", "options": ["A", "B"]}, A)
        call("POST", f"/api/questions/{q2['id']}/vote", {"option": 0}, A)
        call("POST", f"/api/questions/{q2['id']}/vote", {"option": 1}, B)
        import sqlite3
        con = sqlite3.connect(db)
        con.execute("UPDATE questions SET closes_at = ? WHERE id = ?", (int(time.time()) - 1, q2["id"]))
        con.commit()
        con.close()
        _, v2 = call("GET", f"/api/groups/{gid}", token=A)
        v2 = next(x for x in v2["questions"] if x["id"] == q2["id"])
        check(v2["closed"] and v2["results"] is None and v2["hidden_reason"], f"不足 3 人不公開：{v2['hidden_reason']}")
        check(call("POST", f"/api/questions/{q2['id']}/vote", {"option": 0}, C)[0] == 409, "截止後不能再回答")

        print("E. App → 網頁 一次性登入")
        _, h = call("POST", "/api/handoff", {}, A)
        s, red = call("POST", "/api/handoff/redeem", {"code": h["code"]})
        check(s == 200 and red["user"]["name"] == "小林" and red["token"] != A, "一次性碼換到同一位使用者的新 token")
        check(call("POST", "/api/handoff/redeem", {"code": h["code"]})[0] == 400, "一次性碼不能重複使用")
        check(call("GET", "/api/me", token=A)[0] == 200, "App 原本的 token 仍然有效")

        print("F. 上線防護")
        check(call("GET", "/healthz") == (200, {"ok": True}), "健康檢查 /healthz")
        with urllib.request.urlopen(BASE + "/") as r:
            check(r.headers.get("X-Frame-Options") == "DENY" and "frame-ancestors 'none'" in
                  r.headers.get("Content-Security-Policy", ""), "網頁有安全標頭（CSP、禁止被嵌入）")
            check(r.headers.get("Referrer-Policy") == "no-referrer", "Referrer-Policy: no-referrer")
        s, _ = call("POST", f"/api/groups/{gid}/questions", {"text": "x" * 20000, "options": ["a", "b"]}, A)
        check(s == 413, "超過 16KB 的請求會被拒絕")
        codes = [call("POST", "/api/users", {"name": f"u{i}"})[0] for i in range(25)]
        check(codes.count(429) > 0 and codes[0] == 200, f"同一 IP 大量建立身分會被限制（{codes.count(429)} 次 429）")
    finally:
        srv.terminate()
        os.path.exists(db) and os.remove(db)

    print("\n" + ("全部通過" if not check.failed else f"{check.failed} 項失敗"))
    sys.exit(1 if check.failed else 0)


if __name__ == "__main__":
    main()
