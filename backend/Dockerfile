FROM python:3.9-slim

WORKDIR /app

# System deps for common Python packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# App source
COPY . /app

# Multi-worker: gunicorn + uvicorn workers (override: GUNICORN_WORKERS)
# --timeout 130: согласовано с nginx proxy_read_timeout 130s; session/prepare может ждать долго
# Согласовать с PostgreSQL max_connections: workers × (pool_size + max_overflow) < max_connections
ENV GUNICORN_WORKERS=8
CMD ["sh", "-c", "exec gunicorn main:app -w \"${GUNICORN_WORKERS:-8}\" -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 --timeout 130"]
