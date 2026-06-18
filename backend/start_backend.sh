#!/bin/bash
cd /opt/grani/backend
# Load .env variables
export \
# Start backend: single uvicorn (default) or gunicorn with uvicorn workers
if [ "${USE_GUNICORN}" = "1" ]; then
  WORKERS="${GUNICORN_WORKERS:-4}"
  exec python3 -m gunicorn main:app -w "$WORKERS" -k uvicorn.workers.UvicornWorker -b 0.0.0.0:8000 --timeout 90
else
  exec python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
fi
