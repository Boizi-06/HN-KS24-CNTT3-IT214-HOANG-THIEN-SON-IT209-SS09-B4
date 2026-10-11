#!/usr/bin/env bash
set -Eeuo pipefail

# Bài 4: Custom Docker Network + Named Volume + PostgreSQL persistence
# Demo credentials only; do not use these credentials in production.
NETWORK="app-net"
VOLUME="db-data"
DB_CONTAINER="db-server"
APP_CONTAINER="app-container"
APP_IMAGE="session10-ex4-backend:local"
HOST_PORT="8090"

DB_NAME="appdb"
DB_USER="appuser"
DB_PASSWORD="appdemo123"

command -v docker >/dev/null 2>&1 || {
  echo "Lỗi: chưa tìm thấy Docker CLI."
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "Lỗi: Docker Engine chưa chạy. Hãy mở Docker Desktop rồi chạy lại."
  exit 1
}

# Tạo network và volume nếu chưa tồn tại.
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"

# Xóa các container demo cũ nếu có, nhưng tuyệt đối không xóa named volume.
docker rm -f "$APP_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true

# Tạo source tạm để build một Backend API Python nhỏ kết nối PostgreSQL.
BUILD_DIR="$(mktemp -d)"
cleanup_build_dir() {
  rm -rf "$BUILD_DIR"
}
trap cleanup_build_dir EXIT

cat > "$BUILD_DIR/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-alpine
RUN apk add --no-cache iputils \
    && pip install --no-cache-dir Flask 'psycopg[binary]'
WORKDIR /app
COPY app.py /app/app.py
EXPOSE 8080
CMD ["python", "/app/app.py"]
DOCKERFILE

cat > "$BUILD_DIR/app.py" <<'PYTHON'
import os
import time
from flask import Flask, jsonify, request
import psycopg

app = Flask(__name__)

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "db-server"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "dbname": os.getenv("DB_NAME", "appdb"),
    "user": os.getenv("DB_USER", "appuser"),
    "password": os.getenv("DB_PASSWORD", "appdemo123"),
    "connect_timeout": 3,
}

def connect_db():
    return psycopg.connect(**DB_CONFIG)

@app.get("/health")
def health():
    try:
        with connect_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        return jsonify(status="ok", database_host=DB_CONFIG["host"]), 200
    except Exception as exc:
        return jsonify(status="error", message=str(exc)), 503

@app.get("/items")
def list_items():
    try:
        with connect_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT id, name FROM persistence_items ORDER BY id")
                rows = cur.fetchall()
        return jsonify(items=[{"id": row[0], "name": row[1]} for row in rows]), 200
    except Exception as exc:
        return jsonify(error=str(exc)), 503

@app.post("/items")
def create_item():
    body = request.get_json(silent=True) or {}
    name = body.get("name")
    if not isinstance(name, str) or not name.strip():
        return jsonify(error="JSON body must include a non-empty name"), 400
    try:
        with connect_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO persistence_items (name) VALUES (%s) RETURNING id, name",
                    (name.strip(),),
                )
                row = cur.fetchone()
        return jsonify(id=row[0], name=row[1]), 201
    except Exception as exc:
        return jsonify(error=str(exc)), 503

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
PYTHON

echo "==> Build Backend API image"
docker build -t "$APP_IMAGE" "$BUILD_DIR"

echo "==> Start PostgreSQL container"
docker run -d \
  --name "$DB_CONTAINER" \
  --network "$NETWORK" \
  --network-alias "$DB_CONTAINER" \
  -e POSTGRES_DB="$DB_NAME" \
  -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -v "$VOLUME":/var/lib/postgresql/data \
  postgres:15-alpine

echo "==> Wait for PostgreSQL to become ready"
ready=0
for _ in $(seq 1 40); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  echo "Lỗi: PostgreSQL chưa sẵn sàng. Xem log bằng: docker logs $DB_CONTAINER"
  exit 1
fi

echo "==> Create table and insert a persistence test row (only if absent)"
docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL'
CREATE TABLE IF NOT EXISTS persistence_items (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL
);
INSERT INTO persistence_items (id, name)
VALUES (1, 'persistence-check')
ON CONFLICT (id) DO NOTHING;
SELECT id, name FROM persistence_items ORDER BY id;
SQL

echo "==> Start Backend API container"
docker run -d \
  --name "$APP_CONTAINER" \
  --network "$NETWORK" \
  -p "${HOST_PORT}:8080" \
  -e DB_HOST="$DB_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_NAME="$DB_NAME" \
  -e DB_USER="$DB_USER" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  "$APP_IMAGE"

echo "==> Wait for API"
api_ready=0
for _ in $(seq 1 30); do
  if curl --silent --fail "http://localhost:${HOST_PORT}/health" >/dev/null 2>&1; then
    api_ready=1
    break
  fi
  sleep 2
done
if [ "$api_ready" -ne 1 ]; then
  echo "Lỗi: API chưa sẵn sàng. Xem log bằng: docker logs $APP_CONTAINER"
  exit 1
fi

echo
echo "==> Network and volume"
docker network ls | grep "$NETWORK" || true
docker volume ls | grep "$VOLUME" || true
docker network inspect "$NETWORK"

echo
echo "==> DNS resolution test from Backend container"
docker exec "$APP_CONTAINER" ping -c 2 "$DB_CONTAINER"

echo
echo "==> Backend API health check"
curl --fail "http://localhost:${HOST_PORT}/health"
echo
echo "==> Data before deleting DB container"
curl --fail "http://localhost:${HOST_PORT}/items"
echo

echo
echo "==> Remove DB container only (keep volume db-data)"
docker rm -f "$DB_CONTAINER"

echo "==> Recreate DB container with the SAME named volume"
docker run -d \
  --name "$DB_CONTAINER" \
  --network "$NETWORK" \
  --network-alias "$DB_CONTAINER" \
  -e POSTGRES_DB="$DB_NAME" \
  -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -v "$VOLUME":/var/lib/postgresql/data \
  postgres:15-alpine

echo "==> Wait for recreated PostgreSQL"
ready=0
for _ in $(seq 1 40); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  echo "Lỗi: PostgreSQL mới chưa sẵn sàng. Xem log bằng: docker logs $DB_CONTAINER"
  exit 1
fi

echo
echo "==> Verify data directly in recreated DB container"
docker exec "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT id, name FROM persistence_items ORDER BY id;"

echo
echo "==> Verify API can still reach DB using hostname db-server"
curl --fail "http://localhost:${HOST_PORT}/health"
echo
curl --fail "http://localhost:${HOST_PORT}/items"
echo

echo
echo "==> Final status"
docker ps --filter "name=${APP_CONTAINER}" --filter "name=${DB_CONTAINER}"
echo
echo "Hoàn thành: network app-net, volume db-data, DNS và kiểm tra data persistence."
echo "API URL: http://localhost:${HOST_PORT}/health"
echo "Danh sách dữ liệu: http://localhost:${HOST_PORT}/items"
echo
echo "Khi muốn dọn dẹp container demo: docker rm -f app-container db-server"
echo "Giữ volume db-data nếu cần giữ dữ liệu; KHÔNG chạy docker volume rm db-data nếu muốn bảo toàn dữ liệu."
