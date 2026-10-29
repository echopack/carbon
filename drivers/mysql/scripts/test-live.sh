#!/usr/bin/env bash
#
# Run the blog example against a throwaway MySQL in Docker.
#
#   scripts/test-live.sh                      # mysql:8.0
#   IMAGE=mysql:8.4 scripts/test-live.sh      # another image
#   IMAGE=mariadb:11 scripts/test-live.sh
#
# The offline tests run too; the live ones are compiled in with --define live.

set -euo pipefail

IMAGE=${IMAGE:-mysql:8.0}
NAME=carbon-live-$$
PORT=${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}

cd "$(dirname "$0")/.."

docker run -d --rm --name "$NAME" \
    -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=blog -e MYSQL_USER=app -e MYSQL_PASSWORD=secret \
    -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=blog -e MARIADB_USER=app -e MARIADB_PASSWORD=secret \
    -p "127.0.0.1:$PORT:3306" "$IMAGE" >/dev/null
# -v: the server's data volume goes with it, or every run leaves one behind
trap 'docker rm -f -v "$NAME" >/dev/null 2>&1 || true' EXIT

# the entrypoint starts a temporary server (socket only) to initialise, then the real one: wait
# until a TCP login inside the container works
echo "waiting for $IMAGE on 127.0.0.1:$PORT"
CLIENT=mysql
for _ in $(seq 1 120); do
    if docker exec "$NAME" sh -c 'command -v mysql' >/dev/null 2>&1; then CLIENT=mysql; else CLIENT=mariadb; fi
    if docker exec "$NAME" "$CLIENT" -uroot -prootpw -h127.0.0.1 -e 'SELECT 1' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$NAME" "$CLIENT" -uroot -prootpw -h127.0.0.1 -e 'SELECT VERSION()' 2>/dev/null

# a fresh server has an empty caching_sha2_password cache, so the first login takes the full
# (RSA) path, which needs the server key over plain TCP
export CARBON_MYSQL_URL="mysql://app:secret@127.0.0.1:$PORT/blog?fetchServerKey=true"
echoc test --define live --timeout 120000 "$@"
