"""端到端測試：真的啟動後端與 WhileAI.app，用模擬的 Codex hook 事件驅動。

    ./build.sh && python3 test_e2e.py

使用暫存資料庫與暫存資料夾，不會動到 ~/.whileai。
App 的卡片無法用程式點擊，因此回答改用 API 代替，驗證的是「何時顯示哪張卡片」。
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "build/WhileAI.app/Contents/MacOS/WhileAI")
SERVER = os.path.join(HERE, "../server/server.py")
PORT = 18788
BASE = f"http://127.0.0.1:{PORT}"
failed = 0


def call(method, path, body=None, token=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body or {}).encode())
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def hook(event):
    subprocess.run([APP, "hook"], input=json.dumps({"hook_event_name": event, "session_id": "s",
                                                    "prompt": "機密內容不應被讀取"}).encode(), check=True)


def events(data_dir):
    p = os.path.join(data_dir, "events.jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def wait_last(data_dir, pred, timeout=15):
    """輪詢到最後一筆事件符合條件為止；回傳最後一筆事件（逾時就回傳當下的最後一筆）。"""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        ev = events(data_dir)
        last = ev[-1] if ev else None
        if last and pred(last):
            break
        time.sleep(0.25)
    return last or {}


def check(cond, msg):
    global failed
    print(("  ✓ " if cond else "  ✗ ") + msg)
    failed += 0 if cond else 1


def main():
    tmp = tempfile.mkdtemp()
    data = os.path.join(tmp, "data")
    os.makedirs(data)
    srv = subprocess.Popen([sys.executable, SERVER], env=dict(os.environ, PORT=str(PORT), DB_PATH=f"{tmp}/t.db"),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = None
    try:
        time.sleep(1)
        lin = call("POST", "/api/users", {"name": "小林"})
        kai = call("POST", "/api/users", {"name": "阿凱"})
        mei = call("POST", "/api/users", {"name": "美玲"})
        g = call("POST", "/api/groups", {"name": "後端組"}, lin["token"])["group"]
        for u in (kai, mei):
            call("POST", f"/api/invites/{g['invite_code']}/join", token=u["token"])
        q = call("POST", f"/api/groups/{g['id']}/questions",
                 {"text": "下個 sprint 要不要統一改用 Codex？", "options": ["要", "不要", "先試一週"]}, kai["token"])
        json.dump({"token": lin["token"], "name": "小林", "server": BASE}, open(os.path.join(data, "identity.json"), "w"))

        app = subprocess.Popen([APP], env=dict(os.environ, WHILEAI_DATA_DIR=data, WHILEAI_SERVER=BASE,
                                               WHILEAI_DELAY="2", WHILEAI_GAP="0"),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)

        print("1. 短任務：1 秒內結束不顯示")
        hook("UserPromptSubmit"); time.sleep(1); hook("Stop"); time.sleep(2.5)
        check(not events(data), "沒有任何卡片")

        print("2. 長任務：顯示待答題 → Codex 完成 → 收起")
        hook("UserPromptSubmit")
        last = wait_last(data, lambda e: e["type"] == "shown")
        check(last.get("type") == "shown", f"顯示了待答題（題目 #{last.get('question', '-')}）")
        hook("Stop")
        last = wait_last(data, lambda e: e["type"] == "agent_done_while_shown")
        check(last.get("type") == "agent_done_while_shown", "Codex 完成時記錄並收起")
        time.sleep(3.5)   # 等卡片收起

        print("3. 三人都回答 → 下一次等待先看到開獎")
        for u in (kai, mei, lin):
            r = call("POST", f"/api/questions/{q['id']}/vote", {"option": 2}, u["token"])
        check(r["closed"] and r["results"] == [0, 0, 3], "全員答完提早開獎")
        hook("UserPromptSubmit")
        last = wait_last(data, lambda e: e["type"] == "result_shown")
        check(last.get("type") == "result_shown" and last.get("question") == q["id"], "開獎卡片優先於待答題")
        state = json.load(open(os.path.join(data, "state.json")))
        check(q["id"] in state["seenResults"], "記住這次開獎已經看過")

        print("4. Codex 需要權限 → 卡片立刻收起")
        hook("PermissionRequest")
        last = wait_last(data, lambda e: e["type"] == "agent_needs_you")
        check(last.get("type") == "agent_needs_you", "收起並記錄")
        hook("Stop"); time.sleep(1)

        print("5. 同一個開獎不會再出現")
        hook("UserPromptSubmit")
        last = wait_last(data, lambda e: e["type"] == "shown")
        check(last.get("type") == "shown" and last.get("question") != q["id"], "這次顯示的是待答題，不是舊開獎")
        hook("Stop"); time.sleep(3)

        print("6. 隱私")
        raw = open(os.path.join(data, "events.jsonl")).read() + open(os.path.join(data, "state.json")).read()
        check("機密" not in raw, "hook 送進來的 prompt 沒有出現在任何本機檔案")
    finally:
        if app:
            app.terminate()
        srv.terminate()

    print("\n" + ("全部通過" if not failed else f"{failed} 項失敗"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
