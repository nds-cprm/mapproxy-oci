ARG DEBIAN_VERSION=trixie
ARG PYTHON_VERSION=3.14

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

SHELL ["/bin/bash", "-c"]

RUN python -m venv --prompt mapproxy venv && \
    source venv/bin/activate && \
    pip install --no-cache-dir \
        "Pillow==12.1.0" \
        "pyproj==3.7.2" \
        "PyYAML==6.0.3" \
        "redis==7.1.0" \
        "shapely==2.1.2" \
        "lxml==6.0.2" \
        "requests==2.32.5" && \
    pip install --no-cache-dir --use-pep517 "uwsgi==2.0.31" && \
    pip install --no-cache-dir "MapProxy==${MAPPROXY_VERSION}"

COPY src/ ./

RUN source venv/bin/activate && \
    mkdir config && \
    envsubst '${MAPPROXY_BASE_DIR}' < uwsgi.conf.envsubst > uwsgi.conf && \
    envsubst '${MAPPROXY_BASE_DIR}' < app.py.envsubst > app.py && \
    rm -rf *.envsubst && \
    chmod 644 app.py uwsgi.conf && \
    mapproxy-util create -t base-config ./config && \
    chmod -R g=u ./config

FROM docker.io/library/python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS release

ARG MAPPROXY_BASE_DIR

WORKDIR ${MAPPROXY_BASE_DIR}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        libjpeg62-turbo zlib1g libfreetype6 libgeos-c1t64 libgdal36 \
        libxml2 libxslt1.1 libnss-wrapper tini && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build ${MAPPROXY_BASE_DIR} .

COPY scripts/ /

RUN echo "source ${MAPPROXY_BASE_DIR}/venv/bin/activate" >> /etc/bash.bashrc && \
    chmod 755 /docker-entrypoint.sh /start.sh && \
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
    HOME=${MAPPROXY_BASE_DIR}/config

EXPOSE 8000

ENTRYPOINT [ "tini", "--", "/docker-entrypoint.sh" ]

CMD [ "/start.sh" ]
