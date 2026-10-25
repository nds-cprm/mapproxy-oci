# TODO

Pendências do projeto, levantadas em 20/10/2026 e revisadas em 23/10/2026 (commit `36f1936`, branch `change-base-image`, imagem base `ndscprm/gdal:3.12.4-py3.12`).

Legenda: 🔴 alta · 🟠 média · ⚪ baixa

## Imagem

- [x] 🔴 **Config montada é ignorada com rootfs somente leitura (Docker/Kubernetes).** O `10-enable-nss-wrapper.sh` da imagem base trocava o `HOME` para `/tmp` quando ele não era gravável, e o `20-mapproxy.sh` gerava a configuração de teste em `/tmp` no lugar do `mapproxy.yaml` montado. Corrigido na imagem base, que agora só troca o `HOME` quando ele está vazio ou é `/` (tags `3.12.4-py3.12` e `-devel` republicadas em 25/10/2026). Verificado em 25/10/2026 (Docker, `--user 123456:0 --read-only --tmpfs /tmp` com o `mapproxy.yaml` montado `:ro`): o arquivo montado é servido.
- [ ] ⚪ **Configuração de exemplo gerada no build.** O `mapproxy-util create` do Dockerfile já deixa um `mapproxy.yaml` na imagem, então num `docker run` sem config o entrypoint não gera nada e não imprime as notas `NOTE:` de "só para testes". O README diz que o container gera a configuração na inicialização. Ou remover a geração do build, ou ajustar o texto.
- [x] ⚪ **`USER 1000` sem grupo.** Trocado por `USER 1000:0` no Dockerfile (e no Dockerfile derivado do README): o GID 0 fica explícito e não depende de a imagem base não ter a UID 1000 no passwd.

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

- [ ] 🟠 **Venv copiado por cima do venv da base.** O `COPY --from=build /opt/geosgb/venv` mescla os arquivos com o venv da `release`. Se as imagens `-devel` e `release` tiverem versões diferentes de um pacote (ex.: uma das duas desatualizada no cache local), as duas versões se misturam no mesmo diretório e a imagem quebra sem erro no build. Aconteceu em 25/10/2026 com uma `-devel` local antiga (numpy 1.26.4 contra 2.5.4): `ImportError: numpy._core.multiarray failed to import` e o uWSGI encerrando. Mitigar com `docker build --pull` ou copiando só os pacotes instalados no estágio de build.
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

1. ~~Corrigir o `HOME` com rootfs somente leitura.~~
2. Enviar a branch (inclui o `concurrency`).
3. Decidir o caso do healthcheck no Podman.
4. Dependabot.
5. O restante conforme houver tempo.
