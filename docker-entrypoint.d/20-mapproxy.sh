# MapProxy setup, run by the base image /docker-entrypoint.sh after
# 10-enable-nss-wrapper.sh (passwd entry for arbitrary UIDs). Not executable on
# purpose: it is sourced (POSIX sh, under "set -e"), so the umask and HOME set
# here reach the container command, and "exit 1" aborts the container start.

# group-writable files, so other UIDs of group 0 (e.g. OpenShift) can edit them
umask 002

# HOME is the MapProxy configuration directory (see Dockerfile); fall back to
# the default one if it is unset or empty
export HOME="${HOME:-/var/lib/mapproxy/config}"

# create config files if they do not exist yet
if [ ! -f "$HOME/mapproxy.yaml" ]; then
    echo "No mapproxy configuration found. Creating one from template."
    if { [ -d "$HOME" ] && [ ! -w "$HOME" ]; } || ! mapproxy-util create -t base-config "$HOME"; then
        echo "ERROR: no $HOME/mapproxy.yaml and could not create one (is $HOME read-only?)." >&2
        echo "ERROR: provide a mapproxy.yaml or mount $HOME as a writable volume." >&2
        exit 1
    fi
    # templates are copied with their original mode (644), ignoring umask
    find "$HOME" -user "$(id -u)" -exec chmod g=u {} + || true
    # the base config uses ${server} and $layer as examples, which MapProxy
    # reads as environment variables (hence the "is not set" warnings)
    echo "NOTE: this base configuration is meant for testing only. Its \${server} and \$layer"
    echo "NOTE: placeholders are read as environment variables; unset ones trigger UserWarnings."
    echo "NOTE: in production, provide your own $HOME/mapproxy.yaml (volume or ConfigMap)."
fi
