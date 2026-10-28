#!/bin/sh
# Smoke test of the image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/smoke-test.sh <image>). Starts the container as it runs in production
# (arbitrary UID, read-only root filesystem with a writable /tmp) with an empty, writable HOME, as the image
# has no configuration, waits for the healthcheck (uWSGI ping answered by a worker), checks that the
# /docker-entrypoint.d scripts ran and requests the WMS and WMTS capabilities of the base configuration they
# created through the WSGI application (port 8000 speaks the uwsgi protocol, not HTTP). Then checks that the
# base configuration is created with nothing written to the stdout of the container command, and that the
# container does not start with no configuration and a read-only HOME.
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
# Podman also fills a --tmpfs with what the image has at that path, unless notmpcopyup is given
TMPFS_OPTS=
if "$DOCKER" --version | grep -qi podman; then
    RUN_ARGS=--passwd=false
    TMPFS_OPTS=,notmpcopyup
fi

echo "## container (--user 12345:0, --read-only, empty writable HOME)"
# shellcheck disable=SC2086
"$DOCKER" run -d --name "$NAME" --user 12345:0 --read-only --tmpfs /tmp \
    --tmpfs "/var/lib/mapproxy/config:mode=0777$TMPFS_OPTS" $RUN_ARGS "$IMAGE" > /dev/null
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

# without a configuration (empty, writable HOME), 20-mapproxy.sh creates the base one; its messages and
# those of mapproxy-util go to stderr, as stdout belongs to the container command
echo "## base configuration created at start, stdout untouched"
errors=$(mktemp)
# shellcheck disable=SC2086
out=$("$DOCKER" run --rm --user 12345:0 --read-only --tmpfs /tmp \
    --tmpfs "/var/lib/mapproxy/config:mode=0777$TMPFS_OPTS" $RUN_ARGS "$IMAGE" \
    sh -c 'test -f "$HOME/mapproxy.yaml" && echo ok' 2> "$errors") || :
created=$(grep -c 'Creating one from template' "$errors") || :
rm -f "$errors"
[ "$out" = ok ] || fail "unexpected stdout of the container command: '$out'"
[ "$created" -gt 0 ] || fail "base configuration not created at start"

# no configuration and a read-only HOME: 20-mapproxy.sh stops the start with an error
echo "## no configuration, read-only HOME: start aborted"
errors=$(mktemp)
# shellcheck disable=SC2086
if "$DOCKER" run --rm --user 12345:0 --read-only --tmpfs /tmp $RUN_ARGS "$IMAGE" true 2> "$errors"; then
    rm -f "$errors"
    fail "container started with no configuration and a read-only HOME"
fi
aborted=$(grep -c 'could not create one' "$errors") || :
rm -f "$errors"
[ "$aborted" -gt 0 ] || fail "no error message for a read-only HOME without configuration"

# the NO_BINARY packages are compiled against the libraries of the base image: pyproj and shapely use the
# PROJ and GEOS of its libgdal, and do not load the copies bundled in their PyPI wheels (pyproj.libs and
# shapely.libs in site-packages). Pillow and lxml keep the PyPI wheels, with their own copies
echo "## native libraries"
"$DOCKER" run --rm -i --entrypoint python3 "$IMAGE" - << 'EOF' || fail "native libraries"
import sys

import pyproj
import shapely
from osgeo import ogr, osr

versions = {
    'PROJ (osgeo / pyproj)': (
        '.'.join(str(v) for v in (osr.GetPROJVersionMajor(), osr.GetPROJVersionMinor(), osr.GetPROJVersionMicro())),
        pyproj.proj_version_str,
    ),
    'GEOS (osgeo / shapely)': (
        '.'.join(str(v) for v in (ogr.GetGEOSVersionMajor(), ogr.GetGEOSVersionMinor(), ogr.GetGEOSVersionMicro())),
        shapely.geos_version_string,
    ),
}
failed = False
for name, (a, b) in versions.items():
    print(f'{name}: {a} / {b}')
    if a != b:
        print(f'{name} differ', file=sys.stderr)
        failed = True

# every shared library mapped into this process, after importing the compiled modules
loaded = sorted({line.split()[-1] for line in open('/proc/self/maps') if '.so' in line.split()[-1]})
bundled = [path for path in loaded if '/pyproj.libs/' in path or '/shapely.libs/' in path]
for path in bundled:
    print(f'bundled library loaded: {path}', file=sys.stderr)
    failed = True
sys.exit(failed)
EOF

echo "OK"
