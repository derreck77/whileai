# WhileAI 後端：Railway 會自動用這個 Dockerfile 建置
FROM python:3.12-slim
WORKDIR /app
COPY server/server.py ./server.py
COPY server/web ./web
# Railway 會注入 PORT；資料庫放在掛載的磁碟 /data（需在 Railway 加一個 Volume，掛到 /data）
ENV HOST=0.0.0.0 DB_PATH=/data/whileai.db PYTHONUNBUFFERED=1 TRUST_PROXY=1
# 邀請頁顯示的安裝來源；換 repo 時改這裡，或在 Railway 的 Variables 設定 INSTALL_URL
ENV INSTALL_URL=https://github.com/derreck77/whileai
CMD ["python", "server.py"]
