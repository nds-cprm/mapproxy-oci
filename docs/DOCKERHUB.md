# MapProxy

OCI image of [MapProxy](https://mapproxy.org), the tile cache and proxy for WMS, WMTS and TMS, served by uWSGI and maintained by the Geological Survey of Brazil (SGB/CPRM).

- **MapProxy 7** on Python 3.12, GDAL 3.12 and Debian trixie.
- **Production ready:** uWSGI speaking the uwsgi protocol, meant to run behind nginx.
- **Non-root:** runs as `1000:0` and accepts arbitrary UIDs, such as OpenShift's.
- **Read-only root filesystem:** only `/tmp` needs to be writable, plus your cache volume.
- **One geospatial stack:** `pyproj` and `shapely` are built from source against the PROJ and GEOS of the base image, the same ones GDAL uses.
- **Healthcheck that detects stuck workers.**
- **amd64 and arm64**, with SBOM and provenance attestations.

Source code, examples and documentation: <https://github.com/nds-cprm/mapproxy-oci>

## Tags

Each tag starts with the **MapProxy version** (`<version>` in the examples below), followed by an optional suffix:

| Suffix | Contents |
|---|---|
| none | The latest build of that MapProxy version. Moving: republished whenever the base image is updated, with the Debian and Python security fixes. Recommended for general use. |
| `-YYYYMMDD` | One specific build, identified by its date (UTC). Never overwritten: a second build on the same day gets `.2`, `.3`... Use it, preferably with its digest, to pin an exact image or to roll back. |

The available versions are listed in the Tags tab. There is no `latest` tag. The base image is [`ndscprm/gdal`](https://hub.docker.com/r/ndscprm/gdal), and the exact base of each build is recorded in the `org.opencontainers.image.base.name` label.

## Quick start

```sh
docker run -d --name mapproxy -p 8000:8000 docker.io/ndscprm/mapproxy:<version>
```

Port 8000 speaks the **uwsgi protocol, not HTTP**: put nginx in front of it.

```nginx
location / {
    include uwsgi_params;
    uwsgi_pass mapproxy:8000;
}
```

Without a configuration of its own, the container generates a sample one in `/var/lib/mapproxy/config`. **It is meant for testing only**: it has the `demo` page enabled and placeholders that produce warnings in the log.

Production-ready Compose examples (nginx in front, read-only root, resource limits, log rotation and seeding tasks) are in [examples/](https://github.com/nds-cprm/mapproxy-oci/tree/main/examples):

| Example | Tile cache |
|---|---|
| `cache-file` | Files on a volume; nginx serves the tiles straight from disk |
| `cache-couchdb` | CouchDB database; nginx keeps a cache of its own |

## Configuration

MapProxy reads `$HOME/mapproxy.yaml`, and in the image `HOME=/var/lib/mapproxy/config`. In production, provide your own `mapproxy.yaml` by mounting the file or the directory (volume, bind mount or ConfigMap). If the file is missing and the directory is not writable, the container exits with an error message explaining why.

MapProxy 7 replaces `$VAR` and `${VAR}` in YAML values with environment variables:

```yaml
globals:
  cache:
    base_dir: ${MAPPROXY_CACHE_DIR}
```

- There is **no default value** syntax (`${VAR:-default}` does not work). An undefined variable is left as literal text and logs a `UserWarning`.
- Only values are replaced, not keys.

Keep the tile cache on its own volume, set with `globals.cache.base_dir`, separate from the configuration. MapProxy recommends disabling the `demo` service in production.

Extra startup tasks can be added by mounting `.sh` scripts into `/docker-entrypoint.d`. Executable scripts run in a child process; non-executable ones are sourced, so the variables they export reach uWSGI. A failing script stops the container from starting.

## Reverse proxy, HTTPS and subpath

MapProxy builds the absolute URLs of its capabilities documents from the request:

| Scenario | What to do |
|---|---|
| TLS on nginx itself | Nothing: `uwsgi_params` sends `HTTPS=on`. |
| TLS terminator or load balancer in front of nginx | Send `X-Forwarded-Proto: https` and, if the `Host` changes, `X-Forwarded-Host` (with the port, if not the default). |
| Published under a subpath (`/mapproxy/`) | Send `X-Script-Name` with the prefix, as below. |

```nginx
location /mapproxy/ {
    # uwsgi_param in a location drops the inherited ones: include them again
    include uwsgi_params;
    uwsgi_param HTTP_X_SCRIPT_NAME /mapproxy;
    uwsgi_pass mapproxy;
}
```

## uWSGI and resources

The default `uwsgi.conf` is sized for **2 CPUs and 4 GB of memory**: up to 16 workers (cheaper mode, 4 at start), `reload-on-rss` at 256 MB, `max-requests` 5000 and `harakiri` 60 s. For another container size, mount your own file at `/var/lib/uwsgi/uwsgi.conf`. Variables such as `UWSGI_PROCESSES` do **not** override the values in the file.

To serve plain HTTP, mount a copy of `uwsgi.conf` with `http-socket = :8000` instead of `socket`, and replace `/usr/local/bin/healthcheck` too.

## Security and runtime

- **User:** `1000:0`. Arbitrary UIDs work as long as the GID is `0`: an nss_wrapper registers any UID missing from `/etc/passwd` at runtime.
- **Writable volumes** (configuration, cache) must allow writes to the container UID or to group `0`. On Kubernetes, use `securityContext.fsGroup`. Files created by the container are group-writable (`umask 002`).
- **Read-only root:** supported (`--read-only`, `read_only: true`, `readOnlyRootFilesystem: true`) as long as `/tmp` is writable (`tmpfs` or `emptyDir`). The nss_wrapper and POST bodies over 64 KB use it.
- **Healthcheck:** the `healthcheck` command sends a uwsgi-protocol ping that a worker must answer. Podman ignores `HEALTHCHECK` in OCI-format images and Kubernetes never uses it, so declare it in each runtime:

  | Runtime | Where |
  |---|---|
  | `docker run` | The image's `HEALTHCHECK` (automatic) |
  | Compose | `healthcheck: { test: ["CMD", "healthcheck"] }` |
  | Podman | `--health-cmd healthcheck --health-on-failure restart`, or `HealthCmd=healthcheck` in Quadlet |
  | Kubernetes and OpenShift | `exec` probes with `command: ["healthcheck"]` |

- **Vulnerability scanning:** every build is scanned with Trivy and Grype before it is tagged.
- **Known and accepted findings:** the `pip` from the base image bundles copies of `urllib3`, `msgpack` and `setuptools` with known CVEs. That code only runs when someone runs `pip`. MapProxy uses a separate, fixed `urllib3`. A derived image can remove `pip` if your policy requires it (instructions in the repository README).

## License

Apache-2.0. MapProxy is © Omniscale and contributors, also under the Apache License 2.0. As with any container image, this image also contains software under other licenses (Debian, Python, GDAL and their dependencies), and it is the user's responsibility to make sure their use complies with them.

This software is provided "as is", without warranty of any kind and without any commitment to maintenance, support or updates.
