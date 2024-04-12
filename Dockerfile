ARG DEBIAN_VERSION=bookworm
ARG PYTHON_VERSION=3.10

ARG MAPPROXY_VERSION=2.0.2
ARG MAPPROXY_HOME=/var/lib/mapproxy


FROM docker.io/library/python:${PYTHON_VERSION}-${DEBIAN_VERSION} AS BUILD

ARG MAPPROXY_HOME
ARG MAPPROXY_VERSION

WORKDIR ${MAPPROXY_HOME}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        build-essential libjpeg-dev zlib1g-dev gettext \
        libfreetype6-dev libgeos-dev libxml2-dev libxslt-dev && \
    apt-get autoremove && \
    rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

RUN python -m venv --prompt mapproxy venv && \
    source venv/bin/activate && \
    pip install --no-cache-dir \
        "Pillow==10.3.0" \
        "pyproj==3.6.1" \
        "PyYAML==6.0.1" \
        "shapely==2.0.3" \
        "lxml==5.2.1" \
        "requests==2.31.0" && \
    if [ "${MAPPROXY_VERSION}" = '1.15.1' ]; then pip install six; fi && \
    pip install --no-cache-dir --use-pep517 "uwsgi==2.0.24" && \
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

FROM docker.io/library/python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS RELEASE

ARG MAPPROXY_HOME

WORKDIR ${MAPPROXY_HOME}

RUN apt-get update && \
    apt-get install --yes --no-install-recommends --no-install-suggests \
        libjpeg62-turbo zlib1g libfreetype6 libgeos-c1v5 \
        libxml2 libxslt1.1 tini && \
    apt-get autoremove && \
    rm -rf /var/lib/apt/lists/*

COPY --from=BUILD ${MAPPROXY_HOME} .
COPY scripts/ /

RUN echo "source ${MAPPROXY_HOME}/venv/bin/activate" >> /etc/bash.bashrc && \
    chmod 755 /docker-entrypoint.sh /start.sh && \
    mkdir -p /var/lib/uwsgi && \
    mv uwsgi.conf /var/lib/uwsgi

VOLUME [ "${MAPPROXY_HOME}/config" ]

# ENV MAPPROXY_CONFIG_DIR=${MAPPROXY_HOME}/config

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