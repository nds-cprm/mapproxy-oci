# TODO

Pendências do projeto, levantadas em 20/10/2026 e revisadas na branch `change-base-image`.

Legenda: 🔴 alta · 🟠 média · ⚪ baixa

## CI

- [ ] 🟠 **Commitar o `concurrency` do workflow.** O bloco (uma execução por vez, sem cancelar a que está rodando) está só na cópia local. Até o push, um disparo manual no dia 1 pode rodar em paralelo com o rebuild agendado.
- [ ] 🟠 **Healthcheck da imagem publicada no Podman.** O buildx publica com media types OCI, e o Podman ignora o `Healthcheck` dessas imagens (`podman healthcheck run` → "has no defined healthcheck"). O Docker o aplica normalmente. Escolher uma opção:
  - documentar no README que, no Podman, é preciso usar `--health-cmd 'uwsgi --socket 127.0.0.1:8000 --nagios'` ou definir o healthcheck no Compose ou no Quadlet; hoje o texto fala só de builds locais com `--format docker`;
  - ou publicar com media types Docker (`outputs: type=image,oci-mediatypes=false` no `build-push-action`). Precisa de teste, porque as attestations de proveniência dependem do índice OCI e podem exigir `provenance: false`.
- [ ] ⚪ **Dependabot e actions por SHA.** As actions usam tags móveis (`@v7`, `@v4`, `@v1`), e não há `.github/dependabot.yml`. Criar um com os ecossistemas `github-actions`, `docker` e `pip`; opcionalmente, fixar as actions por SHA de commit.

## Documentação (README)

- [ ] ⚪ **Docker não reinicia containers `unhealthy`.** No Docker e no Compose o healthcheck só marca o container; o `restart` só age quando o processo termina. Acrescentar uma frase na seção do healthcheck (o uWSGI já se recupera com `harakiri`, e o container termina se o master morrer).
- [ ] ⚪ **HTTPS e proxy na frente do nginx.** Documentar que, com `X-Forwarded-Proto: https` vindo de um terminador TLS externo, o MapProxy gera URLs `https://` sem configuração extra; que, com TLS no próprio nginx, o `uwsgi_params` já envia `HTTPS`; e o uso de `X-Script-Name` para publicar num subcaminho (`/mapproxy/`).
- [x] ⚪ **Texto sobre o `pip` datado.** Trocado "a versão mais recente" pela data da verificação.

## Build e imagem

- [ ] ⚪ **Reprodutibilidade.** Dependências transitivas sem pin (numpy, certifi, Werkzeug e outras) e imagens base fixadas por tag, não por digest.
- [ ] ⚪ **Atualizações disponíveis** (sem CVEs nas versões atuais): Pillow 13.0.0 (major), pyproj 3.8.0, shapely 2.2.0, redis 8.1.0 (major). O Dependabot automatizaria o aviso.
- [x] ⚪ **`requirements.txt` copiado duas vezes no estágio de build.** Removido o `COPY`; o arquivo chega só pelo `--mount=type=bind`.

## Exemplo (Compose / nginx)

- [ ] ⚪ **Nível de log do `limit_conn`.** Cada rejeição gera uma linha `[error]` no log do nginx; acrescentar `limit_conn_log_level warn;` ao `docker/nginx.conf`.

## Ordem sugerida

1. Commitar o `concurrency`.
2. Decidir o caso do healthcheck no Podman.
3. Dependabot.
4. Ajustes do README.
5. O restante conforme houver tempo.
