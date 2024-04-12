#!/bin/bash

source ./venv/bin/activate

# create config files if they do not exist yet
if [[ -e "$MAPPROXY_CONFIG_DIR" && -w "$MAPPROXY_CONFIG_DIR" ]] ; then
    if [ ! -f "$MAPPROXY_CONFIG_DIR/mapproxy.yaml" ]; then
    echo "No mapproxy configuration found. Creating one from template."
    mapproxy-util create -t base-config "$MAPPROXY_CONFIG_DIR"
    fi
fi

exec "$@"
