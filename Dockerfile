ARG DEBIAN_VERSION=trixie
ARG PYTHON_VERSION=3.14

ARG MAPPROXY_VERSION=7.0.0
ARG MAPPROXY_HOME=/var/lib/mapproxy


FROM docker.io/library/python:${PYTHON_VERSION}-${DEBIAN_VERSION} AS build

ARG MAPPROXY_HOME
ARG MAPPROXY_VERSION

WORKDIR ${MAPPROXY_HOME}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        build-essential libjpeg-dev zlib1g-dev gettext \
        libfreetype6-dev libgeos-dev libgdal-dev libxml2-dev libxslt-dev && \
    apt-get autoremove && \
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
    if [ "${MAPPROXY_VERSION}" = '1.15.1' ]; then pip install six; fi && \
    pip install --no-cache-dir --use-pep517 "uwsgi==2.0.31" && \
    pip install --no-cache-dir "MapProxy==${MAPPROXY_VERSION}"

COPY src/ ./

ENV MAPPROXY_HOME=${MAPPROXY_HOME}

RUN source venv/bin/activate && \
    mkdir config && \
    chmod -R g=u ./config && \
    envsubst < uwsgi.conf.envsubst > uwsgi.conf && \
    envsubst < app.py.envsubst > app.py && \
    rm -rf *.envsubst && \
    chmod 644 app.py uwsgi.conf && \
    mapproxy-util create -t base-config ./config    


ARG DEBIAN_VERSION
ARG PYTHON_VERSION

FROM docker.io/library/python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS release

ARG MAPPROXY_HOME

WORKDIR ${MAPPROXY_HOME}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        libjpeg62-turbo zlib1g libfreetype6 libgeos-c1t64 libgdal36 \
        libxml2 libxslt1.1 tini && \
    apt-get autoremove && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build ${MAPPROXY_HOME} .

COPY scripts/ /

RUN echo "source ${MAPPROXY_HOME}/venv/bin/activate" >> /etc/bash.bashrc && \
    chmod 755 /docker-entrypoint.sh /start.sh && \
    mkdir -p /var/lib/uwsgi && \
    mv uwsgi.conf /var/lib/uwsgi

EXPOSE 8000

ENTRYPOINT [ "tini", "--", "/docker-entrypoint.sh" ]

CMD [ "/start.sh" ]


# FROM docker.io/nginxinc/nginx-unprivileged:1.25-bookworm as RELEASE-NGINX

# ARG MAPPROXY_HOME

# WORKDIR ${MAPPROXY_HOME}

# RUN apt-get update && \
#     apt-get install --yes --no-install-recommends --no-install-suggests \
#         libjpeg62-turbo zlib1g libfreetype6 libgeos-c1v5 \
#         libxml2 libxslt1.1 && \
#     apt-get autoremove && \
#     rm -rf /var/lib/apt/lists/*

# COPY --from=RELEASE-PY ${MAPPROXY_HOME} .
# COPY /docker-entrypoint.sh /start.sh /