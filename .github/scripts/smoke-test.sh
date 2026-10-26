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

# Podman adds the UID to /etc/passwd by default, so the nss_wrapper of the base image would not be used;
# --passwd=false keeps the passwd of the image, as Docker and OpenShift do
RUN_ARGS=
if "$DOCKER" --version | grep -qi podman; then
    RUN_ARGS=--passwd=false
fi

echo "## container (--user 12345:0, --read-only)"
# shellcheck disable=SC2086
"$DOCKER" run -d --name "$NAME" --user 12345:0 --read-only --tmpfs /tmp $RUN_ARGS "$IMAGE" > /dev/null
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

# the /docker-entrypoint.d scripts ran (none of them is skipped silently, e.g. if the directory were not
# readable by the UID): checked on PID 1 (uWSGI), as "docker exec" does not go through the entrypoint.
# Not through /proc/1/environ, which uWSGI overwrites when it renames its processes (auto-procname)
echo "## entrypoint scripts"
"$DOCKER" exec "$NAME" sh -c '
    grep -q libnss_wrapper /proc/1/maps && grep -q "^sgb:x:12345:0:" /tmp/nss_wrapper.*/passwd' \
    || fail "nss_wrapper (10-enable-nss-wrapper.sh) not active in uWSGI"
"$DOCKER" exec "$NAME" grep -q '^Umask:[[:space:]]*0002$' /proc/1/status \
    || fail "uWSGI umask is not 002 (20-mapproxy.sh)"

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
