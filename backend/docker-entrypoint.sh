#!/bin/sh
# Apply migrations, then hand PID 1 to uvicorn. Extra args are passed to uvicorn.
set -eu

alembic upgrade head

exec uvicorn app.main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --proxy-headers \
    --forwarded-allow-ips "${FORWARDED_ALLOW_IPS:-*}" \
    "$@"
