#!/bin/bash

# group-writable files, so other UIDs of group 0 (e.g. OpenShift) can edit them
umask 002

# nss_wrapper (see Dockerfile): add a passwd entry for arbitrary UIDs
if ! getent passwd "$(id -u)" > /dev/null 2>&1; then
    # read-only root filesystem: use a writable copy in /tmp for this process tree
    if { [ ! -w "$NSS_WRAPPER_PASSWD" ] || [ ! -w "$NSS_WRAPPER_GROUP" ]; } && nss_dir=$(mktemp -d 2> /dev/null); then
        cp "$NSS_WRAPPER_PASSWD" "$nss_dir/passwd" && cp "$NSS_WRAPPER_GROUP" "$nss_dir/group" && \
            export NSS_WRAPPER_PASSWD="$nss_dir/passwd" NSS_WRAPPER_GROUP="$nss_dir/group"
    fi
    if [ -w "$NSS_WRAPPER_PASSWD" ] && [ -w "$NSS_WRAPPER_GROUP" ]; then
        echo "mapproxy:x:$(id -u):$(id -g):MapProxy:${HOME}:/bin/bash" >> "$NSS_WRAPPER_PASSWD"
        if ! getent group "$(id -g)" > /dev/null 2>&1; then
            echo "mapproxy:x:$(id -g):" >> "$NSS_WRAPPER_GROUP"
        fi
    else
        echo "WARNING: UID $(id -u) has no passwd entry and nss_wrapper files are not writable." >&2
    fi
fi

# create config files if they do not exist yet
if [ ! -f "$HOME/mapproxy.yaml" ]; then
    echo "No mapproxy configuration found. Creating one from template."
    mapproxy-util create -t base-config "$HOME"
    # templates are copied with their original mode (644), ignoring umask
    find "$HOME" -user "$(id -u)" -exec chmod g=u {} +
fi

exec "$@"
