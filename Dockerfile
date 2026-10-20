ARG DEBIAN_VERSION=trixie
ARG PYTHON_VERSION=3.14

# default MapProxy version, also read by the CI workflow (keep this format)
ARG MAPPROXY_VERSION=7.0.0
ARG MAPPROXY_BASE_DIR=/var/lib/mapproxy


FROM docker.io/library/python:${PYTHON_VERSION}-${DEBIAN_VERSION} AS build

ARG MAPPROXY_BASE_DIR
ARG MAPPROXY_VERSION

WORKDIR ${MAPPROXY_BASE_DIR}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        build-essential libjpeg-dev zlib1g-dev gettext \
        libfreetype6-dev libgeos-dev libgdal-dev libxml2-dev libxslt-dev && \
    rm -rf /var/lib/apt/lists/*

RUN python -m venv --prompt mapproxy venv

ENV PATH=${MAPPROXY_BASE_DIR}/venv/bin:${PATH}

COPY requirements.txt /tmp/

RUN pip install --no-cache-dir --use-pep517 -r /tmp/requirements.txt && \
    pip install --no-cache-dir -c /tmp/requirements.txt "MapProxy==${MAPPROXY_VERSION}"

COPY src/ ./

RUN mkdir config && \
    envsubst '${MAPPROXY_BASE_DIR}' < uwsgi.conf.envsubst > uwsgi.conf && \
    envsubst '${MAPPROXY_BASE_DIR}' < app.py.envsubst > app.py && \
    rm -rf *.envsubst && \
    chmod 644 app.py uwsgi.conf && \
    mapproxy-util create -t base-config ./config && \
    chmod -R g=u ./config

FROM docker.io/library/python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS release

ARG MAPPROXY_BASE_DIR
ARG MAPPROXY_VERSION

# description and url are set by the CI (docker/metadata-action); the title is
# repeated there to override the default one, so keep both in sync
LABEL org.opencontainers.image.title="MapProxy" \
      org.opencontainers.image.version="${MAPPROXY_VERSION}" \
      org.opencontainers.image.source="https://github.com/nds-cprm/mapproxy-oci" \
      org.opencontainers.image.licenses="Apache-2.0"

WORKDIR ${MAPPROXY_BASE_DIR}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        libjpeg62-turbo zlib1g libfreetype6 libgeos-c1t64 libgdal36 \
        libxml2 libxslt1.1 libnss-wrapper tini && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build ${MAPPROXY_BASE_DIR} .

COPY --chmod=755 scripts/ /

COPY LICENSE NOTICE /usr/share/doc/mapproxy-oci/

RUN echo "umask 002" >> /etc/bash.bashrc && \
    mkdir -p /var/lib/uwsgi && \
    mv uwsgi.conf /var/lib/uwsgi

# nss_wrapper: arbitrary UIDs (e.g. OpenShift) get a passwd entry from the
# entrypoint. Set at image level so it also applies to "podman exec" processes.
# The files are world-writable on purpose: setuid binaries ignore LD_PRELOAD,
# so they only affect name lookups of unprivileged processes.
RUN ln -s "$(dpkg -L libnss-wrapper | grep '/libnss_wrapper\.so$')" /usr/lib/libnss_wrapper.so && \
    mkdir -p /var/lib/nss_wrapper && \
    cp /etc/passwd /etc/group /var/lib/nss_wrapper/ && \
    chmod 666 /var/lib/nss_wrapper/passwd /var/lib/nss_wrapper/group

ENV LD_PRELOAD=/usr/lib/libnss_wrapper.so \
    NSS_WRAPPER_PASSWD=/var/lib/nss_wrapper/passwd \
    NSS_WRAPPER_GROUP=/var/lib/nss_wrapper/group \
    HOME=${MAPPROXY_BASE_DIR}/config \
    VIRTUAL_ENV=${MAPPROXY_BASE_DIR}/venv \
    PATH=${MAPPROXY_BASE_DIR}/venv/bin:${PATH}

USER 55000:0

EXPOSE 8000

# uWSGI ping (uwsgi protocol), answered by a worker: fails if no worker is serving
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD [ "uwsgi", "--socket", "127.0.0.1:8000", "--nagios" ]

ENTRYPOINT [ "tini", "--", "/docker-entrypoint.sh" ]

CMD [ "/start.sh" ]
