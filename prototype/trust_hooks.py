#!/usr/bin/env python3
"""信任 WhileAI 的 Codex hooks（等同在 Codex CLI 輸入 /hooks 後按信任）。

透過 Codex 官方的 app-server 協定操作：
  1. hooks/list         取得每個 hook 的 key、目前 hash 與信任狀態
  2. config/batchWrite  把 WhileAI 的 hook 寫入 hooks.state.<key>.trusted_hash

只會信任指令裡含有 WhileAI.app 的 hooks，其他工具的 hooks 不會碰。
    ./trust_hooks.py           信任
    ./trust_hooks.py --check   只檢查狀態，不寫入
"""
import json
import os
import shutil
import subprocess
import sys

CANDIDATES = [
    os.environ.get("CODEX_BIN", ""),
    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    shutil.which("codex") or "",
]


def find_codex():
    for c in CANDIDATES:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    sys.exit("找不到 Codex。可以用 CODEX_BIN=/path/to/codex 指定。")


class AppServer:
    def __init__(self, binary):
        self.p = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 0

    def request(self, method, params):
        self.next_id += 1
        rid = self.next_id
        self.p.stdin.write(json.dumps({"id": rid, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        for line in self.p.stdout:
            msg = json.loads(line)
            if msg.get("id") == rid and "method" not in msg:
                if "error" in msg:
                    raise RuntimeError(f"{method} 失敗：{msg['error']}")
                return msg.get("result")
        raise RuntimeError("Codex app-server 意外結束")

    def notify(self, method):
        self.p.stdin.write(json.dumps({"method": method}) + "\n")
        self.p.stdin.flush()

    def close(self):
        self.p.stdin.close()
        self.p.terminate()


def main():
    check_only = "--check" in sys.argv
    srv = AppServer(find_codex())
    try:
        srv.request("initialize", {"clientInfo": {"name": "whileai_installer", "title": "WhileAI Installer",
                                                  "version": "0.2.0"}, "capabilities": None})
        srv.notify("initialized")
        listing = srv.request("hooks/list", {"cwds": [os.path.expanduser("~")]})
        hooks = [h for entry in listing["data"] for h in entry["hooks"]
                 if h.get("handlerType") == "command" and "WhileAI.app" in h.get("command", "")]
        if not hooks:
            sys.exit("Codex 沒有找到 WhileAI 的 hooks，請先執行 ./install.sh")

        for h in hooks:
            print(f"  {h['eventName']:<18} {h['trustStatus']}")
        todo = [h for h in hooks if h["trustStatus"] in ("untrusted", "modified")]
        if check_only or not todo:
            print("全部已信任 ✓" if not todo else f"{len(todo)} 個 hook 尚未信任")
            return

        # 用 upsert 寫入 hooks.state 整個表，避免 key 裡的特殊字元被當成路徑分隔
        state = {h["key"]: {"trusted_hash": h["currentHash"]} for h in todo}
        srv.request("config/batchWrite", {
            "edits": [{"keyPath": "hooks.state", "value": state, "mergeStrategy": "upsert"}],
            "reloadUserConfig": True,
        })

        after = srv.request("hooks/list", {"cwds": [os.path.expanduser("~")]})
        status = {h["key"]: h["trustStatus"] for e in after["data"] for h in e["hooks"]}
        ok = all(status.get(h["key"]) == "trusted" for h in hooks)
        print(f"已信任 {len(todo)} 個 WhileAI hooks ✓" if ok else "寫入後仍有 hook 未信任，請改用 Codex CLI 的 /hooks")
        sys.exit(0 if ok else 1)
    finally:
        srv.close()


if __name__ == "__main__":
    main()
