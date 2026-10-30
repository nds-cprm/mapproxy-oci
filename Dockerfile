# base images: ndscprm/gdal (Debian trixie + official Python + GDAL in /opt/geosgb),
# by full name. The defaults are the moving tags, rebuilt in place every week, for
# local builds; the CI passes the exact images the CI of gdal-oci has just
# published (dated tag and digest: <tag>-<YYYYMMDD>@sha256:...), all of the same
# build of the base
ARG GDAL_IMAGE_DEVEL=docker.io/ndscprm/gdal:3.12.4-py3.12-devel
ARG GDAL_IMAGE_PY=docker.io/ndscprm/gdal:3.12.4-py3.12

# default MapProxy version, also read by the CI workflow (keep this format)
ARG MAPPROXY_VERSION=7.0.0
ARG MAPPROXY_BASE_DIR=/var/lib/mapproxy


FROM ${GDAL_IMAGE_DEVEL} AS build

ARG MAPPROXY_BASE_DIR
ARG MAPPROXY_VERSION

WORKDIR ${MAPPROXY_BASE_DIR}

# envsubst (the devel image already has the compilers and -dev headers)
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        gettext-base && \
    rm -rf /var/lib/apt/lists/*

# Packages compiled from their sdist against the libraries of the base image
# instead of the PyPI wheels, which bundle their own copies (PROJ in pyproj,
# GEOS in shapely): the same PROJ and GEOS as the libgdal of the image, which
# get the fixes of the weekly rebuild of the base. Names only (comma-separated),
# each pinned in requirements.txt. Pillow and lxml keep the PyPI wheels, with
# their own copies of the libraries (see TODO.md).
# pyproj looks for the proj executable, which the devel image does not have
# (only the libproj-dev headers): PROJ_DIR and PROJ_VERSION, from pkg-config,
# replace it.
# Build dependencies (Cython, setuptools, numpy...) run in isolated
# environments that -c does not reach: --build-constraint pins there the
# packages the base image ships (numpy...) to its versions. LDFLAGS=-s strips
# what is compiled here, as the base image does (the release image has no strip)
ARG NO_BINARY=pyproj,shapely

# wheels of MapProxy and its dependencies (uwsgi, the NO_BINARY packages and
# any other sdist are built here, with the compilers); the release stage
# installs the same wheels. The packages of the base image are constraints, so
# no dependency replaces them
RUN --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    for name in $(echo "${NO_BINARY}" | tr ',' ' '); do \
        if ! spec=$(grep -io "^${name}==[^ ]*" /tmp/requirements.txt); then \
            echo "${name} (NO_BINARY) is not pinned in requirements.txt:" \
                "fix the name or remove it from NO_BINARY" >&2; \
            exit 1; \
        fi; \
        echo "building ${spec} from its sdist"; \
    done && \
    pip freeze --all > /tmp/base-constraints.txt && \
    PROJ_DIR=/usr PROJ_VERSION=$(pkg-config --modversion proj) \
    LDFLAGS=-s pip wheel --no-cache-dir --use-pep517 --wheel-dir /wheels \
        --no-binary "${NO_BINARY}" \
        -c /tmp/base-constraints.txt --build-constraint /tmp/base-constraints.txt \
        -r /tmp/requirements.txt -c /tmp/requirements.txt \
        "MapProxy==${MAPPROXY_VERSION}"

COPY src/ ./

# config/ is left empty: without a mapproxy.yaml, 20-mapproxy.sh creates the
# base config (for testing only) at start, or stops if HOME is read-only
RUN mkdir config && \
    envsubst '${MAPPROXY_BASE_DIR}' < uwsgi.conf.envsubst > uwsgi.conf && \
    envsubst '${MAPPROXY_BASE_DIR}' < app.py.envsubst > app.py && \
    rm -rf *.envsubst && \
    chmod 644 app.py uwsgi.conf && \
    chmod g=u ./config


FROM ${GDAL_IMAGE_PY} AS release

ARG MAPPROXY_BASE_DIR
ARG MAPPROXY_VERSION
# the base this image was built on: its tags (<version>, and the dated one) do
# not say
ARG GDAL_IMAGE_PY

# every key, or the labels of the ndscprm/gdal base would show through; created
# and revision are set by the CI, for each build
LABEL org.opencontainers.image.title="MapProxy" \
      org.opencontainers.image.description="MapProxy servido pelo uWSGI, sobre GDAL e Python" \
      org.opencontainers.image.version="${MAPPROXY_VERSION}" \
      org.opencontainers.image.vendor="SGB/CPRM" \
      org.opencontainers.image.authors="Carlos Eduardo Mota <carlos.mota@sgb.gov.br>" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.url="https://hub.docker.com/r/ndscprm/mapproxy" \
      org.opencontainers.image.documentation="https://github.com/nds-cprm/mapproxy-oci#readme" \
      org.opencontainers.image.source="https://github.com/nds-cprm/mapproxy-oci" \
      org.opencontainers.image.base.name="${GDAL_IMAGE_PY}"

WORKDIR ${MAPPROXY_BASE_DIR}

# MapProxy and uWSGI are installed into the base image venv by its own pip,
# from the wheels of the build stage and offline (--no-index), with the
# packages of the base image as constraints, so no dependency replaces them.
# Copying the build venv instead would mix two versions of a package whenever
# -devel and the release image differ (e.g. one of them stale), with no build
# error. pip check and the smoke test make a broken environment fail the build
RUN --mount=type=bind,from=build,source=/wheels,target=/wheels \
    --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    pip freeze --all > /tmp/base-constraints.txt && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        -c /tmp/base-constraints.txt \
        -r /tmp/requirements.txt -c /tmp/requirements.txt \
        "MapProxy==${MAPPROXY_VERSION}" && \
    rm /tmp/base-constraints.txt && \
    pip check && \
    python -c "import mapproxy.wsgiapp, shapely, pyproj, PIL, yaml, lxml, redis, requests" && \
    uwsgi --version

# the compiled pyproj has no PROJ data of its own and, unlike the libproj used
# by osgeo, does not look in /usr/share/proj (proj-data) by default
ENV PROJ_DATA=/usr/share/proj

COPY --from=build ${MAPPROXY_BASE_DIR} .

# sourced (not executed) by the base image /docker-entrypoint.sh, so the umask
# and HOME it sets reach the container command
COPY --chmod=644 docker-entrypoint.d/ /docker-entrypoint.d/

# health check command shared by every runtime (see HEALTHCHECK below)
COPY --chmod=755 docker/healthcheck /usr/local/bin/healthcheck

COPY LICENSE NOTICE /usr/share/doc/mapproxy-oci/

RUN echo "umask 002" >> /etc/bash.bashrc && \
    mkdir -p /var/lib/uwsgi && \
    mv uwsgi.conf /var/lib/uwsgi

ENV HOME=${MAPPROXY_BASE_DIR}/config

# UID 1000 is not in /etc/passwd on purpose: the base image nss_wrapper creates
# a virtual user for it at start (USER_NAME, default sgb), as it does for any
# arbitrary UID. Group 0 set explicitly, so writable paths (chmod g=u) work for
# arbitrary UIDs without depending on the base image passwd
USER 1000:0

EXPOSE 8000

# uWSGI ping (uwsgi protocol), answered by a worker: fails if no worker is
# serving. Only applied by Docker: Podman ignores it in OCI images and
# Kubernetes never uses it, so Compose, Quadlet and probes call the same script
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD [ "healthcheck" ]

# ENTRYPOINT inherited from the base image (/docker-entrypoint.sh): runs the
# /docker-entrypoint.d scripts, then the CMD
CMD [ "uwsgi", "--ini", "/var/lib/uwsgi/uwsgi.conf" ]
