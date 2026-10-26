# base images: ndscprm/gdal (Debian trixie + official Python + GDAL in /opt/geosgb)
ARG GDAL_VERSION=3.12.4
ARG PYTHON_VERSION=3.12

# default MapProxy version, also read by the CI workflow (keep this format)
ARG MAPPROXY_VERSION=7.0.0
ARG MAPPROXY_BASE_DIR=/var/lib/mapproxy


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION}-devel AS build

ARG MAPPROXY_BASE_DIR
ARG MAPPROXY_VERSION

WORKDIR ${MAPPROXY_BASE_DIR}

# envsubst (the devel image already has the compilers and -dev headers)
RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        gettext-base && \
    rm -rf /var/lib/apt/lists/*

# wheels of MapProxy and its dependencies (uwsgi and any other sdist are built
# here, with the compilers); the release stage installs the same wheels. They
# are also installed here, as mapproxy-util creates the base config below
RUN --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    pip wheel --no-cache-dir --use-pep517 --wheel-dir /wheels \
        -r /tmp/requirements.txt -c /tmp/requirements.txt \
        "MapProxy==${MAPPROXY_VERSION}" && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        -r /tmp/requirements.txt -c /tmp/requirements.txt \
        "MapProxy==${MAPPROXY_VERSION}"

COPY src/ ./

RUN mkdir config && \
    envsubst '${MAPPROXY_BASE_DIR}' < uwsgi.conf.envsubst > uwsgi.conf && \
    envsubst '${MAPPROXY_BASE_DIR}' < app.py.envsubst > app.py && \
    rm -rf *.envsubst && \
    chmod 644 app.py uwsgi.conf && \
    mapproxy-util create -t base-config ./config && \
    chmod -R g=u ./config


FROM docker.io/ndscprm/gdal:${GDAL_VERSION}-py${PYTHON_VERSION} AS release

ARG MAPPROXY_BASE_DIR
ARG MAPPROXY_VERSION

# description and url are set by the CI (docker/metadata-action); the title is
# repeated there to override the default one, so keep both in sync
LABEL org.opencontainers.image.title="MapProxy" \
      org.opencontainers.image.version="${MAPPROXY_VERSION}" \
      org.opencontainers.image.source="https://github.com/nds-cprm/mapproxy-oci" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR ${MAPPROXY_BASE_DIR}

# MapProxy and uWSGI are installed into the base image venv by its own pip,
# from the wheels of the build stage and offline (--no-index). Copying the
# build venv instead would mix two versions of a package whenever -devel and
# the release image differ (e.g. one of them stale), with no build error.
# pip check and the smoke test make a broken environment fail the build
RUN --mount=type=bind,from=build,source=/wheels,target=/wheels \
    --mount=type=bind,source=requirements.txt,target=/tmp/requirements.txt \
    pip install --no-cache-dir --no-index --find-links /wheels \
        -r /tmp/requirements.txt -c /tmp/requirements.txt \
        "MapProxy==${MAPPROXY_VERSION}" && \
    pip check && \
    python -c "import mapproxy.wsgiapp, shapely, pyproj, PIL, yaml, lxml, redis, requests" && \
    uwsgi --version

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
