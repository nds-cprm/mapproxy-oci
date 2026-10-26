#!/bin/sh
# Smoke test of the image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/smoke-test.sh <image>). Starts the container as it runs in production
# (arbitrary UID, read-only root filesystem with a writable /tmp), waits for the healthcheck (uWSGI ping
# answered by a worker) and requests the WMS and WMTS capabilities of the configuration in the image
# through the WSGI application (port 8000 speaks the uwsgi protocol, not HTTP).
set -eu

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}
NAME=mapproxy-smoke-$$

cleanup() {
    "$DOCKER" rm -f "$NAME" > /dev/null 2>&1 || :
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    "$DOCKER" logs "$NAME" 2>&1 | tail -20 >&2 || :
    exit 1
}

[ "$("$DOCKER" image inspect "$IMAGE" --format '{{.Config.User}}')" = 1000:0 ] || fail "image user is not 1000:0"

echo "## container (--user 12345:0, --read-only)"
"$DOCKER" run -d --name "$NAME" --user 12345:0 --read-only --tmpfs /tmp "$IMAGE" > /dev/null
healthy=
for _ in $(seq 30); do
    if "$DOCKER" exec "$NAME" healthcheck > /dev/null 2>&1; then
        healthy=yes
        break
    fi
    sleep 2
done
[ -n "$healthy" ] || fail "healthcheck did not pass within 60 s"
"$DOCKER" exec "$NAME" healthcheck

echo "## WSGI requests"
"$DOCKER" exec -i "$NAME" python3 - << 'EOF' || fail "WSGI requests"
import runpy
import sys
from wsgiref.util import setup_testing_defaults

application = runpy.run_path('/var/lib/mapproxy/app.py')['application']


def get(path, query, expected):
    environ = {'PATH_INFO': path, 'QUERY_STRING': query}
    setup_testing_defaults(environ)
    status = []
    body = b''.join(application(environ, lambda s, headers, exc_info=None: status.append(s)))
    print(path, query, status[0], len(body), 'bytes')
    if not status[0].startswith('200') or expected not in body:
        sys.exit(f'{path}?{query}: {status[0]}, no {expected!r} in the response')


get('/service', 'SERVICE=WMS&REQUEST=GetCapabilities', b'<WMS_Capabilities')
get('/wmts/1.0.0/WMTSCapabilities.xml', '', b'<Capabilities')
EOF

echo "OK"
