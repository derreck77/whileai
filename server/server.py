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
MAX_BODY = 64 * 1024      # 請求內容上限（bytes）；畫圖題的筆畫資料最大約 40KB
TRUST_PROXY = os.environ.get("TRUST_PROXY") == "1" or bool(os.environ.get("RAILWAY_ENVIRONMENT_NAME"))

KINDS = ("choice", "multi", "scale", "text", "draw")
MAX_OPTIONS = 6
MAX_TEXT_ANSWER = 140
# 畫圖題：回答是一組筆畫。座標是 0–1000 的整數（畫布寬 1000、高 700），不存圖片
DRAW_COLORS = 6
DRAW_WIDTHS = (1, 2)
MAX_STROKES = 300
MAX_DRAW_POINTS = 4000

# 新群組的起手題：(問題, 題型, 選項, 評分兩端的說明)
STARTER_QUESTIONS = [
    ("這週你主要用哪個 AI Coding Agent？", "choice", ["Codex", "Claude Code", "Cursor", "其他"], None),
    ("這週工作順不順？", "scale", None, {"low": "很卡", "high": "很順"}),
    ("Agent 最近做過最蠢的一件事是什麼？", "text", None, None),
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


def clean_drawing(answer):
    """檢查畫圖題的回答：[{c: 顏色編號, w: 粗細, p: [x1, y1, x2, y2, ...]}, ...]"""
    if not isinstance(answer, list) or not 1 <= len(answer) <= MAX_STROKES:
        raise ApiError(400, "請先畫點東西")
    strokes, total = [], 0
    for st in answer:
        if not isinstance(st, dict):
            raise ApiError(400, "畫作格式錯誤")
        c, w, p = st.get("c"), st.get("w"), st.get("p")
        if type(c) is not int or not 0 <= c < DRAW_COLORS or type(w) is not int or w not in DRAW_WIDTHS:
            raise ApiError(400, "畫作格式錯誤")
        if not isinstance(p, list) or len(p) < 2 or len(p) % 2 or any(type(v) is not int or not 0 <= v <= 1000 for v in p):
            raise ApiError(400, "畫作格式錯誤")
        total += len(p) // 2
        strokes.append({"c": c, "w": w, "p": p})
    if total > MAX_DRAW_POINTS:
        raise ApiError(400, "畫得太複雜了，請簡化一點再送出")
    return strokes


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SCHEMA)
        self.migrate()
        self.lock = threading.Lock()

    def migrate(self):
        """舊資料庫補上新欄位（題型、匿名／具名、即時結果、各題型的回答內容）。"""
        wanted = {
            "questions": [("kind", "TEXT NOT NULL DEFAULT 'choice'"), ("anonymous", "INTEGER NOT NULL DEFAULT 1"),
                          ("live", "INTEGER NOT NULL DEFAULT 0"), ("config", "TEXT")],
            "votes": [("answer", "TEXT")],   # JSON：單選／評分是索引、多選是索引陣列、文字題是字串
        }
        for table, cols in wanted.items():
            have = {r["name"] for r in self.db.execute(f"PRAGMA table_info({table})")}
            for name, ddl in cols:
                if name not in have:
                    self.db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}")
        self.db.commit()

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
        # 新群組一開始只有 1–2 人，匿名題（需滿 3 人）永遠不會開獎，所以起手題用具名＋回答後立刻看結果
        for text, kind, options, config in STARTER_QUESTIONS:
            self.insert_question(gid, None, text, kind, options, config, False, True, t, 72)
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

    def insert_question(self, gid, author_id, text, kind, options, config, anonymous, live, t, hours):
        if kind == "scale":
            options = ["1", "2", "3", "4", "5"]
        elif kind in ("text", "draw"):
            options = []
        cur = self.db.execute(
            "INSERT INTO questions (group_id, author_id, text, options, created_at, closes_at, kind, anonymous, live, config) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (gid, author_id, text, json.dumps(options, ensure_ascii=False), t, t + int(hours * 3600), kind,
             1 if anonymous else 0, 1 if live else 0, json.dumps(config, ensure_ascii=False) if config else None))
        return cur.lastrowid

    def create_question(self, user, gid, text, options, hours, kind="choice", anonymous=True, live=False, config=None):
        self.require_member(gid, user)
        text = clean_text(text, "問題", 2, 120)
        if kind not in KINDS:
            raise ApiError(400, "不支援的題型")
        if kind in ("choice", "multi"):
            if not isinstance(options, list) or not 2 <= len(options) <= MAX_OPTIONS:
                raise ApiError(400, f"選項需要 2–{MAX_OPTIONS} 個")
            options = [clean_text(o, "選項", 1, 40) for o in options]
            if len(set(options)) != len(options):
                raise ApiError(400, "選項不能重複")
        clean_config = None
        if kind == "scale" and isinstance(config, dict):
            clean_config = {k: clean_text(config[k], "評分說明", 1, 12)
                            for k in ("low", "high") if isinstance(config.get(k), str) and config[k].strip()}
        try:
            hours = float(hours if hours is not None else DEFAULT_HOURS)
        except (TypeError, ValueError):
            raise ApiError(400, "截止時間格式錯誤")
        if not 0.25 <= hours <= 168:
            raise ApiError(400, "截止時間需介於 15 分鐘到 7 天")
        return self.insert_question(gid, user["id"], text, kind, options, clean_config or None,
                                    bool(anonymous), bool(live), now(), hours)

    def question_row(self, qid):
        row = self.db.execute("SELECT * FROM questions WHERE id = ?", (qid,)).fetchone()
        if not row:
            raise ApiError(404, "找不到題目")
        return row

    def answered_count(self, qid):
        return self.db.execute("SELECT COUNT(*) FROM votes WHERE question_id = ?", (qid,)).fetchone()[0]

    def vote(self, user, qid, answer):
        q = self.question_row(qid)
        self.require_member(q["group_id"], user)
        if self.is_closed(q):
            raise ApiError(409, "這題已經截止")
        options = json.loads(q["options"])
        kind = q["kind"]
        if kind in ("choice", "scale"):
            if not isinstance(answer, int) or isinstance(answer, bool) or not 0 <= answer < len(options):
                raise ApiError(400, "選項不存在")
        elif kind == "multi":
            if (not isinstance(answer, list) or not answer or len(set(answer)) != len(answer)
                    or any(not isinstance(i, int) or isinstance(i, bool) or not 0 <= i < len(options) for i in answer)):
                raise ApiError(400, "請至少選一個選項")
            answer = sorted(answer)
        elif kind == "draw":
            answer = clean_drawing(answer)
        else:
            answer = clean_text(answer, "回答", 1, MAX_TEXT_ANSWER)
        try:
            self.db.execute(
                "INSERT INTO votes (question_id, user_id, option_index, created_at, answer) VALUES (?, ?, ?, ?, ?)",
                (qid, user["id"], answer if isinstance(answer, int) else 0, now(),
                 json.dumps(answer, ensure_ascii=False, separators=(",", ":"))))
        except sqlite3.IntegrityError:
            raise ApiError(409, "你已經回答過這題")
        # 全員答完 → 提早開獎。群組不到 MIN_REVEAL 人時不提早，避免剛建群就把題目關掉
        members = self.member_count(q["group_id"])
        if members >= MIN_REVEAL and self.answered_count(qid) >= members:
            self.db.execute("UPDATE questions SET closed_at = ? WHERE id = ?", (now(), qid))

    def require_author(self, user, qid):
        q = self.question_row(qid)
        self.require_member(q["group_id"], user)
        if q["author_id"] != user["id"]:
            raise ApiError(403, "只有出題者可以這樣做")
        return q

    def close_question(self, user, qid):
        """出題者提前開獎。"""
        q = self.require_author(user, qid)
        if not self.is_closed(q):
            self.db.execute("UPDATE questions SET closed_at = ? WHERE id = ?", (now(), qid))

    def delete_question(self, user, qid):
        """出題者撤回題目，連同所有回答一起刪除。"""
        self.require_author(user, qid)
        self.db.execute("DELETE FROM votes WHERE question_id = ?", (qid,))
        self.db.execute("DELETE FROM questions WHERE id = ?", (qid,))

    @staticmethod
    def is_closed(q):
        return q["closed_at"] is not None or now() >= q["closes_at"]

    @staticmethod
    def decode_answer(row):
        return json.loads(row["answer"]) if row["answer"] is not None else row["option_index"]

    def question_view(self, q, user, group_name=None):
        qid = q["id"]
        kind = q["kind"]
        anonymous = bool(q["anonymous"])
        live = bool(q["live"])
        options = json.loads(q["options"])
        config = json.loads(q["config"]) if q["config"] else {}
        answered = self.answered_count(qid)
        closed = self.is_closed(q)
        mine = self.db.execute("SELECT answer, option_index FROM votes WHERE question_id = ? AND user_id = ?",
                               (qid, user["id"])).fetchone()
        my_answer = self.decode_answer(mine) if mine else None
        author = self.user_by_id(q["author_id"]) if q["author_id"] else None
        is_mine = q["author_id"] == user["id"]
        view = {
            "id": qid,
            "group_id": q["group_id"],
            "group_name": group_name or self.group_row(q["group_id"])["name"],
            "author_name": author["name"] if author else "WhileAI 起手題",
            "is_mine": is_mine,
            "text": q["text"],
            "kind": kind,
            "anonymous": anonymous,
            "live": live,
            "options": options,
            "scale_low": config.get("low"),
            "scale_high": config.get("high"),
            "created_at": q["created_at"],
            "closes_at": q["closes_at"],
            "closed": closed,
            "closed_at": (q["closed_at"] or q["closes_at"]) if closed else None,
            "answered_count": answered,
            "member_count": self.member_count(q["group_id"]),
            "my_answered": mine is not None,
            "my_vote": my_answer if kind in ("choice", "scale") and mine else None,
            "my_votes": my_answer if kind == "multi" and mine else None,
            "my_text": my_answer if kind == "text" and mine else None,
            "results": None,      # 各選項票數（單選／多選／評分）
            "voters": None,       # 具名題：各選項的回答者暱稱
            "texts": None,        # 文字題：回答列表
            "drawings": None,     # 畫圖題：每個人的筆畫
            "hidden_reason": None,
        }
        # 什麼時候看得到結果：截止後；或「即時」題在自己回答之後（出題者隨時可看）
        if not (closed or (live and (mine is not None or is_mine))):
            return view
        # 匿名題：不足 MIN_REVEAL 人時不公開，避免從結果推回個人
        if anonymous and answered < MIN_REVEAL:
            view["hidden_reason"] = (f"回答人數不足 {MIN_REVEAL} 人，未公開結果" if closed
                                     else f"已有 {answered} 人回答，滿 {MIN_REVEAL} 人後顯示結果")
            return view
        rows = self.db.execute(
            "SELECT v.answer, v.option_index, u.name FROM votes v JOIN users u ON u.id = v.user_id "
            "WHERE v.question_id = ? ORDER BY v.created_at, v.user_id", (qid,)).fetchall()
        if kind == "text":
            texts = [{"text": self.decode_answer(r), "name": None if anonymous else r["name"]} for r in rows]
            if anonymous:   # 不依回答時間排序，避免從順序猜出是誰
                texts.sort(key=lambda t: hashlib.sha256(f"{qid}:{t['text']}".encode()).hexdigest())
            view["texts"] = texts
            return view
        if kind == "draw":
            drawings = [{"strokes": self.decode_answer(r), "name": None if anonymous else r["name"]} for r in rows]
            if anonymous:   # 不依回答時間排序，避免從順序猜出是誰
                drawings.sort(key=lambda d: hashlib.sha256(
                    f"{qid}:{json.dumps(d['strokes'], separators=(',', ':'))}".encode()).hexdigest())
            view["drawings"] = drawings
            return view
        counts = [0] * len(options)
        voters = [[] for _ in options]
        for r in rows:
            a = self.decode_answer(r)
            for i in (a if isinstance(a, list) else [a]):
                if isinstance(i, int) and 0 <= i < len(options):
                    counts[i] += 1
                    voters[i].append(r["name"])
        view["results"] = counts
        if not anonymous:
            view["voters"] = voters
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
        """App 用：待答題（未靜音群組、未截止、我還沒答）、近 7 天開獎（我出的題或我答過的題）、我出的進行中題目。"""
        pending, results, mine = [], [], []
        rows = self.db.execute(
            "SELECT q.*, g.name AS group_name, m.muted FROM questions q "
            "JOIN groups g ON g.id = q.group_id "
            "JOIN members m ON m.group_id = q.group_id AND m.user_id = ? "
            "WHERE q.created_at >= ? ORDER BY q.created_at",
            (user["id"], now() - 14 * 86400)).fetchall()
        for q in rows:
            v = self.question_view(q, user, q["group_name"])
            if not v["closed"]:
                if not v["my_answered"] and not q["muted"]:
                    pending.append(v)
                if v["is_mine"]:
                    mine.append(v)
            elif v["closed_at"] >= now() - 7 * 86400 and (v["my_answered"] or v["is_mine"]):
                results.append(v)
        return {"pending": pending, "results": results, "mine": mine}


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
    qid = h.store.create_question(user, int(gid), body.get("text"), body.get("options"), body.get("hours"),
                                  kind=body.get("kind") or "choice", anonymous=body.get("anonymous", True),
                                  live=body.get("live", False), config=body.get("config"))
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
    # "option" 是舊版 App 送的欄位名稱
    h.store.vote(user, int(qid), body.get("answer", body.get("option")))
    return h.store.question_view(h.store.question_row(int(qid)), user)


@route("POST", r"/api/questions/(\d+)/close")
def api_close(h, user, body, qid):
    h.store.close_question(user, int(qid))
    return h.store.question_view(h.store.question_row(int(qid)), user)


@route("DELETE", r"/api/questions/(\d+)")
def api_delete(h, user, body, qid):
    h.store.delete_question(user, int(qid))
    return {"ok": True}


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

    do_GET = do_POST = do_PATCH = do_DELETE = dispatch


def main():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    Handler.store = Store(DB_PATH)
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8787"))
    print(f"WhileAI server on http://{host}:{port}  (db: {DB_PATH})")
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
