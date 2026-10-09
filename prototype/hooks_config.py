#!/usr/bin/env python3
"""在 Codex 與 Claude Code 的設定檔中加入／移除 WhileAI 的 hooks。

    hooks_config.py install <WhileAI 執行檔路徑>
    hooks_config.py uninstall

只會新增或移除指令裡含有 WhileAI.app 的項目，其他工具的 hooks 與設定保持原樣。
修改前會先備份成 <檔名>.bak.whileai-<時間>。
"""
import json
import os
import shutil
import sys
import time

HOME = os.path.expanduser("~")

# (事件, matcher, timeout 秒數)
TARGETS = {
    "Codex": {
        "path": os.path.join(HOME, ".codex", "hooks.json"),
        "agent_arg": "",          # 維持既有指令不變：Codex 的信任 hash 綁定指令內容
        "hooks": [
            ("UserPromptSubmit", None, 3),
            ("PermissionRequest", None, 3),
            ("Stop", None, 3),
            ("Interrupt", None, 1),   # Codex 規定 Interrupt 最長 3 秒
        ],
    },
    "Claude Code": {
        "path": os.path.join(HOME, ".claude", "settings.json"),
        "agent_arg": " claude-code",
        "hooks": [
            ("UserPromptSubmit", None, 3),
            ("PermissionRequest", None, 3),
            ("Notification", "permission_prompt|elicitation_dialog|agent_needs_input", 3),
            ("Stop", None, 3),
            ("SessionEnd", None, 3),
        ],
    },
}


def is_whileai(handler):
    return "WhileAI.app" in handler.get("command", "")


def strip_whileai(hooks):
    for event in list(hooks):
        groups = hooks[event]
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", []) if not is_whileai(h)]
        hooks[event] = [g for g in groups if g.get("hooks")]
        if not hooks[event]:
            del hooks[event]


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read().strip()
    return json.loads(text) if text else {}


def save(path, cfg):
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.bak.whileai-{time.strftime('%Y%m%d%H%M%S')}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def install(binary):
    for name, t in TARGETS.items():
        cfg = load(t["path"])
        hooks = cfg.setdefault("hooks", {})
        strip_whileai(hooks)
        cmd = f'"{binary}" hook{t["agent_arg"]}'
        for event, matcher, timeout in t["hooks"]:
            group = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
            if matcher:
                group = {"matcher": matcher, **group}
            hooks.setdefault(event, []).append(group)
        save(t["path"], cfg)
        print(f"  {name}: {len(t['hooks'])} 個 hooks → {t['path'].replace(HOME, '~')}")


def uninstall():
    for name, t in TARGETS.items():
        if not os.path.exists(t["path"]):
            continue
        cfg = load(t["path"])
        if "hooks" in cfg:
            strip_whileai(cfg["hooks"])
            if not cfg["hooks"]:
                del cfg["hooks"]
        save(t["path"], cfg)
        print(f"  {name}: 已移除 WhileAI hooks")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "install":
        install(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "uninstall":
        uninstall()
    else:
        sys.exit(__doc__)
