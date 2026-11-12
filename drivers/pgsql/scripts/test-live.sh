#!/usr/bin/env bash
#
# Run the blog example against a throwaway PostgreSQL in Docker.
#
#   scripts/test-live.sh                        # postgres:17
#   IMAGE=postgres:13 scripts/test-live.sh      # another image
#
# The offline tests run too; the live ones are compiled in with --define live.

set -euo pipefail

IMAGE=${IMAGE:-postgres:17}
NAME=carbon-live-pg-$$
PORT=${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}

cd "$(dirname "$0")/.."

docker run -d --rm --name "$NAME" \
    -e POSTGRES_USER=app -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=blog \
    -p "127.0.0.1:$PORT:5432" "$IMAGE" >/dev/null
# -v: the server's data volume goes with it, or every run leaves one behind
trap 'docker rm -f -v "$NAME" >/dev/null 2>&1 || true' EXIT

# the entrypoint starts a temporary server (socket only) to initialise, then the real one: wait
# until a TCP login inside the container works
echo "waiting for $IMAGE on 127.0.0.1:$PORT"
READY=
for _ in $(seq 1 120); do
    if docker exec "$NAME" pg_isready -h 127.0.0.1 -U app -d blog >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
if [ -z "$READY" ]; then
    echo "$IMAGE did not start within 120s" >&2
    docker logs "$NAME" 2>&1 | tail -20 >&2 || true
    exit 1
fi
docker exec "$NAME" psql -h 127.0.0.1 -U app -d blog -tAc 'SELECT version()'

export CARBON_PGSQL_URL="postgres://app:secret@127.0.0.1:$PORT/blog"
echoc test --define live --timeout 120000 "$@"
