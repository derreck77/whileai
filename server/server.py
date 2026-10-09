"""WhileAI 群組 × 互相出題：原型後端。

只用 Python 標準函式庫（3.9+）與 SQLite。
    python3 server.py            # 預設 http://127.0.0.1:8787
環境變數：PORT、HOST、DB_PATH、PUBLIC_URL（產生邀請連結用）、TRUST_PROXY（在反向代理後方時設為 1）
部署到 Railway 時，PUBLIC_URL 會自動從 RAILWAY_PUBLIC_DOMAIN 推得。

隱私設計：votes 表記錄「誰答過」只為了防止重複回答；
任何 API 回應都只包含彙總數字，不會出現個人的選擇。
"""
import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
WEB_DIR = ROOT / "web"
DB_PATH = os.environ.get("DB_PATH", str(ROOT / "whileai.db"))

MIN_REVEAL = 3            # 至少幾人回答才公開結果
DEFAULT_HOURS = 24
HANDOFF_TTL = 120         # App → 網頁 的一次性登入碼有效秒數
INVITE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
MAX_BODY = 16 * 1024      # 請求內容上限（bytes）
TRUST_PROXY = os.environ.get("TRUST_PROXY") == "1" or bool(os.environ.get("RAILWAY_ENVIRONMENT"))

STARTER_QUESTIONS = [
    ("這週你主要用哪個 AI Coding Agent？", ["Codex", "Claude Code", "Cursor", "其他"]),
    ("Agent 最近一次完成的任務，結果直接可用嗎？", ["直接可用", "小改就能用", "要大改", "重來比較快"]),
    ("你會讓 Agent 直接 push 到 main 嗎？", ["絕對不會", "小專案會", "每天都在做"]),
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (               -- 一個使用者可有多組 token（App、網頁）
  token_hash TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS groups (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  invite_code TEXT UNIQUE NOT NULL,
  owner_id INTEGER NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS members (
  group_id INTEGER NOT NULL REFERENCES groups(id),
  user_id INTEGER NOT NULL REFERENCES users(id),
  joined_at INTEGER NOT NULL,
  muted INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (group_id, user_id)
);
CREATE TABLE IF NOT EXISTS questions (
  id INTEGER PRIMARY KEY,
  group_id INTEGER NOT NULL REFERENCES groups(id),
  author_id INTEGER REFERENCES users(id),      -- NULL = WhileAI 起手題
  text TEXT NOT NULL,
  options TEXT NOT NULL,                       -- JSON array
  created_at INTEGER NOT NULL,
  closes_at INTEGER NOT NULL,
  closed_at INTEGER                            -- 全員答完時提早寫入
);
CREATE TABLE IF NOT EXISTS votes (
  question_id INTEGER NOT NULL REFERENCES questions(id),
  user_id INTEGER NOT NULL REFERENCES users(id),
  option_index INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (question_id, user_id)
);
CREATE TABLE IF NOT EXISTS handoffs (
  code TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_questions_group ON questions(group_id);
CREATE INDEX IF NOT EXISTS idx_members_user ON members(user_id);
"""


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def now():
    return int(time.time())


def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def clean_text(value, field, lo, hi):
    if not isinstance(value, str):
        raise ApiError(400, f"{field} 必須是文字")
    value = re.sub(r"\s+", " ", value).strip()
    if not lo <= len(value) <= hi:
        raise ApiError(400, f"{field} 長度需介於 {lo}–{hi} 字")
    return value


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()

    # ---------- 使用者 ----------

    def create_user(self, name):
        name = clean_text(name, "暱稱", 1, 24)
        cur = self.db.execute("INSERT INTO users (name, created_at) VALUES (?, ?)", (name, now()))
        return self.issue_token(cur.lastrowid), self.user_by_id(cur.lastrowid)

    def issue_token(self, uid):
        token = secrets.token_urlsafe(32)
        self.db.execute("INSERT INTO tokens VALUES (?, ?, ?)", (hash_token(token), uid, now()))
        return token

    def auth(self, token):
        if not token:
            return None
        row = self.db.execute("SELECT user_id FROM tokens WHERE token_hash = ?", (hash_token(token),)).fetchone()
        return self.user_by_id(row["user_id"]) if row else None

    def user_by_id(self, uid):
        row = self.db.execute("SELECT id, name FROM users WHERE id = ?", (uid,)).fetchone()
        return dict(row) if row else None

    def rename_user(self, user, name):
        name = clean_text(name, "暱稱", 1, 24)
        self.db.execute("UPDATE users SET name = ? WHERE id = ?", (name, user["id"]))
        return self.user_by_id(user["id"])

    def create_handoff(self, user):
        code = secrets.token_urlsafe(16)
        self.db.execute("DELETE FROM handoffs WHERE expires_at < ?", (now(),))
        self.db.execute("INSERT INTO handoffs VALUES (?, ?, ?)", (code, user["id"], now() + HANDOFF_TTL))
        return code

    def redeem_handoff(self, code):
        """App → 網頁：一次性碼換一組新的網頁 token，App 的 token 不經過網址。"""
        row = self.db.execute("SELECT * FROM handoffs WHERE code = ? AND expires_at >= ?",
                              (code, now())).fetchone()
        if not row:
            raise ApiError(400, "登入連結已失效，請從 App 重新開啟")
        self.db.execute("DELETE FROM handoffs WHERE code = ?", (code,))
        return self.issue_token(row["user_id"]), self.user_by_id(row["user_id"])

    # ---------- 群組 ----------

    def new_invite_code(self):
        while True:
            code = "".join(secrets.choice(INVITE_ALPHABET) for _ in range(8))
            if not self.db.execute("SELECT 1 FROM groups WHERE invite_code = ?", (code,)).fetchone():
                return code

    def create_group(self, user, name):
        name = clean_text(name, "群組名稱", 1, 40)
        t = now()
        cur = self.db.execute("INSERT INTO groups (name, invite_code, owner_id, created_at) VALUES (?, ?, ?, ?)",
                              (name, self.new_invite_code(), user["id"], t))
        gid = cur.lastrowid
        self.db.execute("INSERT INTO members (group_id, user_id, joined_at) VALUES (?, ?, ?)", (gid, user["id"], t))
        for text, options in STARTER_QUESTIONS:
            self.db.execute(
                "INSERT INTO questions (group_id, author_id, text, options, created_at, closes_at) "
                "VALUES (?, NULL, ?, ?, ?, ?)",
                (gid, text, json.dumps(options, ensure_ascii=False), t, t + 48 * 3600))
        return gid

    def group_row(self, gid):
        row = self.db.execute("SELECT * FROM groups WHERE id = ?", (gid,)).fetchone()
        if not row:
            raise ApiError(404, "找不到群組")
        return row

    def membership(self, gid, user):
        return self.db.execute("SELECT * FROM members WHERE group_id = ? AND user_id = ?",
                               (gid, user["id"])).fetchone()

    def require_member(self, gid, user):
        m = self.membership(gid, user)
        if not m:
            raise ApiError(403, "你不是這個群組的成員")
        return m

    def member_count(self, gid):
        return self.db.execute("SELECT COUNT(*) FROM members WHERE group_id = ?", (gid,)).fetchone()[0]

    def invite_info(self, code):
        row = self.db.execute("SELECT * FROM groups WHERE invite_code = ?", (code.upper(),)).fetchone()
        if not row:
            raise ApiError(404, "邀請碼無效")
        return row

    def join(self, user, code):
        g = self.invite_info(code)
        self.db.execute("INSERT OR IGNORE INTO members (group_id, user_id, joined_at) VALUES (?, ?, ?)",
                        (g["id"], user["id"], now()))
        return g["id"]

    def set_muted(self, user, gid, muted):
        self.require_member(gid, user)
        self.db.execute("UPDATE members SET muted = ? WHERE group_id = ? AND user_id = ?",
                        (1 if muted else 0, gid, user["id"]))

    def group_view(self, row, user, base_url):
        m = self.membership(row["id"], user)
        return {
            "id": row["id"],
            "name": row["name"],
            "invite_code": row["invite_code"],
            "invite_url": f"{base_url}/j/{row['invite_code']}",
            "member_count": self.member_count(row["id"]),
            "is_owner": row["owner_id"] == user["id"],
            "muted": bool(m["muted"]) if m else False,
        }

    def my_groups(self, user, base_url):
        rows = self.db.execute(
            "SELECT g.* FROM groups g JOIN members m ON m.group_id = g.id WHERE m.user_id = ? ORDER BY m.joined_at",
            (user["id"],)).fetchall()
        return [self.group_view(r, user, base_url) for r in rows]

    # ---------- 題目 ----------

    def create_question(self, user, gid, text, options, hours):
        self.require_member(gid, user)
        text = clean_text(text, "問題", 5, 120)
        if not isinstance(options, list) or not 2 <= len(options) <= 4:
            raise ApiError(400, "選項需要 2–4 個")
        options = [clean_text(o, "選項", 1, 40) for o in options]
        if len(set(options)) != len(options):
            raise ApiError(400, "選項不能重複")
        try:
            hours = float(hours if hours is not None else DEFAULT_HOURS)
        except (TypeError, ValueError):
            raise ApiError(400, "截止時間格式錯誤")
        if not 1 <= hours <= 168:
            raise ApiError(400, "截止時間需介於 1 小時到 7 天")
        t = now()
        cur = self.db.execute(
            "INSERT INTO questions (group_id, author_id, text, options, created_at, closes_at) VALUES (?, ?, ?, ?, ?, ?)",
            (gid, user["id"], text, json.dumps(options, ensure_ascii=False), t, t + int(hours * 3600)))
        return cur.lastrowid

    def question_row(self, qid):
        row = self.db.execute("SELECT * FROM questions WHERE id = ?", (qid,)).fetchone()
        if not row:
            raise ApiError(404, "找不到題目")
        return row

    def answered_count(self, qid):
        return self.db.execute("SELECT COUNT(*) FROM votes WHERE question_id = ?", (qid,)).fetchone()[0]

    def vote(self, user, qid, option):
        q = self.question_row(qid)
        self.require_member(q["group_id"], user)
        if self.is_closed(q):
            raise ApiError(409, "這題已經截止")
        options = json.loads(q["options"])
        if not isinstance(option, int) or not 0 <= option < len(options):
            raise ApiError(400, "選項不存在")
        try:
            self.db.execute("INSERT INTO votes VALUES (?, ?, ?, ?)", (qid, user["id"], option, now()))
        except sqlite3.IntegrityError:
            raise ApiError(409, "你已經回答過這題")
        # 全員答完 → 提早開獎。群組不到 MIN_REVEAL 人時不提早，避免剛建群就把題目關掉
        members = self.member_count(q["group_id"])
        if members >= MIN_REVEAL and self.answered_count(qid) >= members:
            self.db.execute("UPDATE questions SET closed_at = ? WHERE id = ?", (now(), qid))

    @staticmethod
    def is_closed(q):
        return q["closed_at"] is not None or now() >= q["closes_at"]

    def question_view(self, q, user, group_name=None):
        qid = q["id"]
        options = json.loads(q["options"])
        answered = self.answered_count(qid)
        closed = self.is_closed(q)
        mine = self.db.execute("SELECT option_index FROM votes WHERE question_id = ? AND user_id = ?",
                               (qid, user["id"])).fetchone()
        author = self.user_by_id(q["author_id"]) if q["author_id"] else None
        view = {
            "id": qid,
            "group_id": q["group_id"],
            "group_name": group_name or self.group_row(q["group_id"])["name"],
            "author_name": author["name"] if author else "WhileAI 起手題",
            "is_mine": q["author_id"] == user["id"],
            "text": q["text"],
            "options": options,
            "created_at": q["created_at"],
            "closes_at": q["closes_at"],
            "closed": closed,
            "closed_at": (q["closed_at"] or q["closes_at"]) if closed else None,
            "answered_count": answered,
            "member_count": self.member_count(q["group_id"]),
            "my_vote": mine["option_index"] if mine else None,
            "results": None,
            "hidden_reason": None,
        }
        if closed:
            if answered >= MIN_REVEAL:
                counts = [0] * len(options)
                for r in self.db.execute("SELECT option_index, COUNT(*) c FROM votes WHERE question_id = ? "
                                         "GROUP BY option_index", (qid,)):
                    counts[r["option_index"]] = r["c"]
                view["results"] = counts
            else:
                view["hidden_reason"] = f"回答人數不足 {MIN_REVEAL} 人，未公開結果"
        return view

    def group_detail(self, user, gid, base_url):
        g = self.group_row(gid)
        self.require_member(gid, user)
        qs = self.db.execute("SELECT * FROM questions WHERE group_id = ? ORDER BY created_at DESC, id DESC",
                             (gid,)).fetchall()
        return {
            "group": self.group_view(g, user, base_url),
            "questions": [self.question_view(q, user, g["name"]) for q in qs],
        }

    def feed(self, user):
        """App 用：待答題（未靜音群組、未截止、我還沒答）與近 7 天開獎（我出的題或我答過的題）。"""
        pending, results = [], []
        rows = self.db.execute(
            "SELECT q.*, g.name AS group_name, m.muted FROM questions q "
            "JOIN groups g ON g.id = q.group_id "
            "JOIN members m ON m.group_id = q.group_id AND m.user_id = ? "
            "WHERE q.created_at >= ? ORDER BY q.created_at",
            (user["id"], now() - 14 * 86400)).fetchall()
        for q in rows:
            v = self.question_view(q, user, q["group_name"])
            if not v["closed"]:
                if v["my_vote"] is None and not q["muted"]:
                    pending.append(v)
            elif v["closed_at"] >= now() - 7 * 86400 and (v["my_vote"] is not None or v["is_mine"]):
                results.append(v)
        return {"pending": pending, "results": results}


# ---------- 頻率限制（記憶體內滑動視窗，以來源 IP 計算） ----------

class RateLimiter:
    def __init__(self):
        self.hits = defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, key, limit, window):
        t = time.monotonic()
        with self.lock:
            q = self.hits[key]
            while q and q[0] <= t - window:
                q.popleft()
            if len(q) >= limit:
                return False
            q.append(t)
            if len(self.hits) > 50_000:   # 避免記憶體無限成長
                self.hits = defaultdict(deque, {k: v for k, v in self.hits.items() if v})
            return True


LIMITER = RateLimiter()
GLOBAL_LIMIT = (300, 60)      # 每個 IP 每分鐘最多 300 個 API 請求

# ---------- HTTP ----------

ROUTES = []


def route(method, pattern, auth=True, limit=None):
    """limit = (名稱, 次數, 秒數)：同一個 IP 在時間窗內最多呼叫幾次。"""
    def deco(fn):
        ROUTES.append((method, re.compile("^" + pattern + "$"), auth, limit, fn))
        return fn
    return deco


@route("GET", "/healthz", auth=False)
def api_health(h, user, body):
    return {"ok": True}


@route("POST", "/api/users", auth=False, limit=("users", 20, 3600))
def api_create_user(h, user, body):
    token, u = h.store.create_user(body.get("name"))
    return {"token": token, "user": u}


@route("GET", "/api/me")
def api_me(h, user, body):
    return {"user": {"id": user["id"], "name": user["name"]}, "groups": h.store.my_groups(user, h.base_url())}


@route("PATCH", "/api/me")
def api_rename(h, user, body):
    return {"user": h.store.rename_user(user, body.get("name"))}


@route("POST", "/api/handoff", limit=("handoff", 60, 3600))
def api_handoff(h, user, body):
    code = h.store.create_handoff(user)
    return {"code": code, "url": f"{h.base_url()}/?handoff={code}"}


@route("POST", "/api/handoff/redeem", auth=False, limit=("redeem", 60, 3600))
def api_redeem(h, user, body):
    token, u = h.store.redeem_handoff(str(body.get("code", "")))
    return {"token": token, "user": u}


@route("POST", "/api/groups", limit=("groups", 20, 3600))
def api_create_group(h, user, body):
    gid = h.store.create_group(user, body.get("name"))
    return h.store.group_detail(user, gid, h.base_url())


@route("GET", r"/api/groups/(\d+)")
def api_group(h, user, body, gid):
    return h.store.group_detail(user, int(gid), h.base_url())


@route("POST", r"/api/groups/(\d+)/mute")
def api_mute(h, user, body, gid):
    h.store.set_muted(user, int(gid), bool(body.get("muted")))
    return {"ok": True}


@route("POST", r"/api/groups/(\d+)/questions", limit=("ask", 60, 3600))
def api_ask(h, user, body, gid):
    qid = h.store.create_question(user, int(gid), body.get("text"), body.get("options"), body.get("hours"))
    return h.store.question_view(h.store.question_row(qid), user)


@route("GET", r"/api/invites/([A-Za-z0-9]+)", auth=False, limit=("invite", 120, 3600))
def api_invite(h, user, body, code):
    g = h.store.invite_info(code)
    return {"name": g["name"], "member_count": h.store.member_count(g["id"])}


@route("POST", r"/api/invites/([A-Za-z0-9]+)/join", limit=("join", 60, 3600))
def api_join(h, user, body, code):
    gid = h.store.join(user, code)
    return h.store.group_detail(user, gid, h.base_url())


@route("POST", r"/api/questions/(\d+)/vote", limit=("vote", 600, 3600))
def api_vote(h, user, body, qid):
    h.store.vote(user, int(qid), body.get("option"))
    return h.store.question_view(h.store.question_row(int(qid)), user)


@route("GET", "/api/feed")
def api_feed(h, user, body):
    return h.store.feed(user)


class Handler(BaseHTTPRequestHandler):
    store = None
    server_version = "WhileAI/0.2"

    def base_url(self):
        env = os.environ.get("PUBLIC_URL")
        if env:
            return env.rstrip("/")
        if os.environ.get("RAILWAY_PUBLIC_DOMAIN"):
            return "https://" + os.environ["RAILWAY_PUBLIC_DOMAIN"]
        proto = self.headers.get("X-Forwarded-Proto", "http") if TRUST_PROXY else "http"
        return f"{proto}://{self.headers.get('Host', '127.0.0.1:8787')}"

    def client_ip(self):
        if TRUST_PROXY and self.headers.get("X-Forwarded-For"):
            return self.headers["X-Forwarded-For"].split(",")[0].strip()
        return self.client_address[0]

    def end_headers(self):
        # 所有回應都加上的安全標頭。no-referrer 也確保網址上的一次性登入碼不會外流到其他網站
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                         "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; "
                         "form-action 'self'")
        if self.base_url().startswith("https://"):
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        super().end_headers()

    def log_message(self, fmt, *args):
        # 不記錄網址參數，避免一次性登入碼出現在 log
        print(f"{self.command} {urlparse(self.path).path} -> {args[1] if len(args) > 1 else ''}")

    def send_json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def serve_static(self, path):
        if path.startswith("/static/"):
            f = (WEB_DIR / path[len("/static/"):]).resolve()
            if WEB_DIR.resolve() not in f.parents or not f.is_file():
                return self.send_json(404, {"error": "not found"})
        else:
            f = WEB_DIR / "index.html"   # SPA：/、/j/<code>、/g/<id> 都回同一頁
        types = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml"}
        data = f.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", types.get(f.suffix, "application/octet-stream") + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def dispatch(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/") and path != "/healthz":
            if self.command == "GET":
                return self.serve_static(path)
            return self.send_json(405, {"error": "method not allowed"})
        ip = self.client_ip()
        if not LIMITER.allow(("all", ip), *GLOBAL_LIMIT):
            return self.send_json(429, {"error": "請求太頻繁，請稍後再試"})
        for method, pattern, needs_auth, limit, fn in ROUTES:
            m = pattern.match(path)
            if not m or method != self.command:
                continue
            if limit and not LIMITER.allow((limit[0], ip), limit[1], limit[2]):
                return self.send_json(429, {"error": "操作太頻繁，請稍後再試"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length > MAX_BODY:
                    return self.send_json(413, {"error": "請求內容太大"})
                body = json.loads(self.rfile.read(length) or b"{}") if length else {}
                if not isinstance(body, dict):
                    raise ApiError(400, "請求格式錯誤")
                with self.store.lock:
                    auth = self.headers.get("Authorization", "")
                    user = self.store.auth(auth[7:] if auth.startswith("Bearer ") else "")
                    if needs_auth and not user:
                        raise ApiError(401, "請先設定暱稱")
                    result = fn(self, user, body, *m.groups())
                    self.store.db.commit()
                return self.send_json(200, result)
            except ApiError as e:
                self.store.db.rollback()
                return self.send_json(e.status, {"error": e.message})
            except json.JSONDecodeError:
                return self.send_json(400, {"error": "JSON 格式錯誤"})
        return self.send_json(404, {"error": "not found"})

    do_GET = do_POST = do_PATCH = dispatch


def main():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    Handler.store = Store(DB_PATH)
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8787"))
    print(f"WhileAI server on http://{host}:{port}  (db: {DB_PATH})")
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
