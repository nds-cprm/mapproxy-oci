# TODO

Pendências do projeto, levantadas em 20/10/2026 e revisadas em 23/10/2026 (commit `36f1936`, branch `change-base-image`, imagem base `ndscprm/gdal:3.12.4-py3.12`).

Legenda: 🔴 alta · 🟠 média · ⚪ baixa

## Imagem

- [ ] 🔴 **Config montada é ignorada com rootfs somente leitura (Docker/Kubernetes).** O `10-enable-nss-wrapper.sh` da imagem base troca o `HOME` para `/tmp` quando ele não é gravável. Como o `HOME` é o diretório de configuração, o `20-mapproxy.sh` gera a configuração de teste em `/tmp` e o MapProxy a serve no lugar do `mapproxy.yaml` montado. Acontece quando a UID não está no `/etc/passwd` (Docker, Kubernetes, OpenShift) e o diretório de config não é gravável: o exemplo do Compose no Docker (`read_only: true`) e ConfigMaps montados como diretório. Reproduzido com `podman run --passwd=false --read-only --tmpfs /tmp -v ./docker/mapproxy.yaml:/var/lib/mapproxy/config/mapproxy.yaml:ro`; o Podman padrão não é afetado (ele acrescenta a UID ao passwd). Opções:
  - na imagem base: trocar o `HOME` só quando ele estiver vazio ou for `/` (sem a condição `! -w "$HOME"`);
  - neste projeto: separar o diretório de configuração do `HOME` (ex.: `ENV MAPPROXY_CONFIG_DIR`, lido pelo `app.py` e pelo `20-mapproxy.sh`), o que muda a interface documentada no README.
- [ ] ⚪ **Configuração de exemplo gerada no build.** O `mapproxy-util create` do Dockerfile já deixa um `mapproxy.yaml` na imagem, então num `docker run` sem config o entrypoint não gera nada e não imprime as notas `NOTE:` de "só para testes". O README diz que o container gera a configuração na inicialização. Ou remover a geração do build, ou ajustar o texto.
- [ ] ⚪ **`USER 1000` sem grupo.** Hoje o GID fica 0 porque a imagem base não tem a UID 1000 no passwd; `USER 1000:0` deixa isso explícito e não depende da base.

## CI

- [ ] 🟠 **Enviar o `concurrency` do workflow.** Já está no commit `36f1936`, mas a branch não foi enviada nem mesclada na `main`. Até lá, um disparo manual no dia 1 pode rodar em paralelo com o rebuild agendado.
- [ ] 🟠 **Healthcheck da imagem publicada no Podman.** O buildx publica com media types OCI, e o Podman ignora o `Healthcheck` dessas imagens (`podman healthcheck run` → "has no defined healthcheck"). O Docker o aplica normalmente. Escolher uma opção:
  - documentar no README que, no Podman, é preciso usar `--health-cmd 'uwsgi --socket 127.0.0.1:8000 --nagios'` ou definir o healthcheck no Compose ou no Quadlet; hoje o texto fala só de builds locais com `--format docker`;
  - ou publicar com media types Docker (`outputs: type=image,oci-mediatypes=false` no `build-push-action`). Precisa de teste, porque as attestations de proveniência dependem do índice OCI e podem exigir `provenance: false`.
- [ ] ⚪ **Dependabot e actions por SHA.** As actions usam tags móveis (`@v7`, `@v4`, `@v1`), e não há `.github/dependabot.yml`. Criar um com os ecossistemas `github-actions`, `docker` e `pip`; opcionalmente, fixar as actions por SHA de commit.

## Documentação (README)

- [ ] ⚪ **Docker não reinicia containers `unhealthy`.** No Docker e no Compose o healthcheck só marca o container; o `restart` só age quando o processo termina. Acrescentar uma frase na seção do healthcheck (o uWSGI já se recupera com `harakiri`, e o container termina se o master morrer).
- [ ] ⚪ **HTTPS e proxy na frente do nginx.** Documentar que, com `X-Forwarded-Proto: https` vindo de um terminador TLS externo, o MapProxy gera URLs `https://` sem configuração extra; que, com TLS no próprio nginx, o `uwsgi_params` já envia `HTTPS`; e o uso de `X-Script-Name` para publicar num subcaminho (`/mapproxy/`).
- [x] ⚪ **Texto sobre o `pip` datado.** Trocado "a versão mais recente" pela data da verificação.

## Build

- [ ] ⚪ **Reprodutibilidade.** Dependências transitivas sem pin (numpy, certifi, Werkzeug e outras) e imagens base fixadas por tag, não por digest. A `ndscprm/gdal` é republicada com a mesma tag.
- [ ] ⚪ **Atualizações disponíveis** (sem CVEs nas versões atuais): Pillow 13.0.0 (major), pyproj 3.8.0, shapely 2.2.0, redis 8.1.0 (major). O Dependabot automatizaria o aviso.
- [x] ⚪ **`requirements.txt` copiado duas vezes no estágio de build.** Removido o `COPY`; o arquivo chega só pelo `--mount=type=bind`.

## Exemplo (Compose / nginx)

- [ ] ⚪ **Nível de log do `limit_conn`.** Cada rejeição gera uma linha `[error]` no log do nginx; acrescentar `limit_conn_log_level warn;` ao `docker/nginx.conf`.

## Verificado em 23/10/2026 (Podman 6.1.4, arm64)

- Build local em ~30 s; o `--mount=type=bind` do `requirements.txt` funciona.
- Exemplo do Compose com a imagem local: MapProxy `healthy`, GetCapabilities WMS e WMTS 200, tile WMTS `MISS` e depois `HIT` no cache do nginx.
- UID arbitrária (`--user 123456:0`) com rootfs gravável: nss_wrapper ativo, config com grupo 0 gravável.
- Sem `tini` na nova base, o uWSGI é o PID 1; `podman stop` termina em ~1 s (`die-on-term`).

## Ordem sugerida

1. Corrigir o `HOME` com rootfs somente leitura.
2. Enviar a branch (inclui o `concurrency`).
3. Decidir o caso do healthcheck no Podman.
4. Dependabot.
5. O restante conforme houver tempo.
