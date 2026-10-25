# CLAUDE.md

Imagem de container OCI para o [MapProxy](https://mapproxy.org), servido pelo uWSGI e publicada como `ndscprm/mapproxy` (amd64 + arm64). Não há código de aplicação: o projeto é um Dockerfile, seus templates de configuração, um exemplo de produção com Compose e o workflow de CI.

Idioma: o README, o TODO.md e este arquivo estão em português do Brasil; os comentários no Dockerfile, nos scripts e nos arquivos de configuração estão em inglês. Mantenha essa divisão.

## Estrutura

| Caminho | Papel |
|---|---|
| `Dockerfile` | Dois estágios sobre `ndscprm/gdal` (Debian trixie + Python + GDAL, venv em `/opt/geosgb/venv`): `build` (tag `-devel`) instala as dependências e o MapProxy via pip e gera os templates; `release` copia o venv e `/var/lib/mapproxy` |
| `requirements.txt` | Dependências Python fixadas; também usado como **arquivo de constraints** na instalação do MapProxy |
| `docker/healthcheck` | Comando de healthcheck único (copiado para `/usr/local/bin`, modo 755), usado pelo `HEALTHCHECK`, pelo Compose e pelos exemplos de Podman/Kubernetes do README |
| `src/*.envsubst` | `app.py` (entrada WSGI) e `uwsgi.conf`, gerados no build com `envsubst '${MAPPROXY_BASE_DIR}'` apenas |
| `docker-entrypoint.d/20-mapproxy.sh` | Hook de inicialização, **carregado com `source`** pelo `/docker-entrypoint.sh` da imagem base (depois do `10-enable-nss-wrapper.sh` dela) |
| `docker-compose.yaml` + `conf/` | Exemplo de produção: `cache-init` (ajusta o dono do volume), `mapproxy`, `nginx-unprivileged` (HTTP :8080 → uwsgi :8000, cache de tiles). Os arquivos de `conf/` (`mapproxy/` e `nginx/`) são montados por bind mount |
| `.github/workflows/docker-image.yml` | Disparo manual + rebuild mensal (dia 1, 03:00 UTC, `no-cache`); push multi-arch com buildx, análise de CVEs com Docker Scout → SARIF |
| `TODO.md` | Pendências do projeto, por área e prioridade; marque os itens concluídos |

## Modelo de execução

- Roda como `1000:0`; UIDs arbitrárias precisam funcionar (OpenShift), então tudo que é gravável deve ser gravável pelo grupo 0 (`umask 002`, `chmod g=u`). `USER_NAME=mapproxy` dá o nome do registro no passwd criado pelo nss_wrapper.
- `HOME=/var/lib/mapproxy/config` **é** o diretório de configuração: o `app.py` lê `$HOME/mapproxy.yaml`. Se ele não existir, o entrypoint gera a `base-config` do MapProxy (só para testes) ou encerra com `exit 1` se `$HOME` for somente leitura.
- Precisa funcionar com rootfs somente leitura; só o `/tmp` (nss_wrapper, corpos de POST grandes) e os volumes montados são graváveis.
- A porta 8000 fala o **protocolo uwsgi, não HTTP**. Healthcheck: script `docker/healthcheck` (→ `/usr/local/bin/healthcheck`, roda `uwsgi --socket 127.0.0.1:8000 --nagios`), chamado igual em todos os runtimes.
- O ENTRYPOINT é herdado da imagem base; o CMD é `uwsgi --ini /var/lib/uwsgi/uwsgi.conf`.

## Comandos

```sh
docker build -t mapproxy:local .
docker build --build-arg MAPPROXY_VERSION=X.Y.Z -t mapproxy:local .
MAPPROXY_IMAGE=mapproxy:local docker compose up -d   # testa o exemplo do Compose com um build local
# teste rápido: http://localhost:8080/service?SERVICE=WMS&REQUEST=GetCapabilities
```

Não há testes unitários nem linters no repositório; valide as mudanças construindo a imagem e rodando o exemplo do Compose (status de saúde, GetCapabilities/GetMap, WMTS).

## Invariantes e o que manter sincronizado

- **Versão do MapProxy**: `ARG MAPPROXY_VERSION=X.Y.Z` no Dockerfile é o único valor padrão; a CI o extrai com `sed -nE 's/^ARG MAPPROXY_VERSION=(.+)$/\1/p'` e valida com `^[0-9]+\.[0-9]+\.[0-9]+$`, então mantenha exatamente esse formato de linha. Ao mudar a versão, atualize também a tag da imagem no `docker-compose.yaml` e no README (`grep -rn "7\.0\.0" --exclude-dir=.git .`).
- **O README contém uma cópia literal do `docker-compose.yaml`**: qualquer mudança no Compose deve ser replicada no bloco do README. O mesmo vale para os padrões dos build args e a tabela de dimensionamento do uWSGI.
- **Label de título da imagem**: `org.opencontainers.image.title=MapProxy` é definido tanto no Dockerfile quanto no passo de metadata do workflow.
- **Dimensionamento do uWSGI ↔ recursos**: os padrões do `uwsgi.conf` (16 workers × 256 MB de `reload-on-rss`, limite soft de 2,5 GB) supõem 2 CPUs / 4 GB, iguais ao `deploy.resources.limits` do Compose. O `uwsgi_read_timeout 65s` do nginx acompanha o `harakiri = 60` do uWSGI; o `limit_conn 20` se relaciona ao máximo de 16 workers.
- **Healthcheck** declarado também no Compose de propósito (o Podman descarta o `HEALTHCHECK` em imagens no formato OCI, e o Kubernetes nunca o usa); o comando fica só em `docker/healthcheck`, e o Dockerfile, o Compose e os exemplos do README (Podman, Quadlet, probes) chamam `healthcheck`. Os intervalos (30s/5s/15s/3) se repetem nesses lugares.
- **O `.dockerignore` é uma allowlist** (`*` e depois `!…`): um arquivo novo copiado pelo Dockerfile precisa ser liberado ali.
- **`docker-entrypoint.d/*.sh`**: `sh` POSIX, copiado com modo 644 (não executável) para ser carregado com `source` sob `set -e`, de modo que `umask` e `export`s cheguem ao uWSGI; use `exit 1` para abortar a inicialização. Um script executável roda em processo à parte e não tem esse efeito.
- **`conf/mapproxy/mapproxy.yaml`** usa a substituição de variáveis do MapProxy (`${VAR}`), que não tem sintaxe de valor padrão e só funciona em valores, não em chaves; toda variável usada precisa estar definida no `environment` do Compose.
- `src/app.py.envsubst` deriva do template WSGI do MapProxy; mantenha a atribuição nele e no `NOTICE`.
- As CVEs conhecidas e aceitas (bibliotecas embutidas no pip) estão documentadas na seção "Segurança" do README; atualize-a se isso mudar.

## Decisões mantidas

Escolhas feitas de propósito; não "corrija" sem discutir.

| Tema | Decisão |
|---|---|
| Protocolo uwsgi na porta 8000 | O container roda atrás de proxy reverso. Para HTTP, sobrescreva `/var/lib/uwsgi/uwsgi.conf` e o `/usr/local/bin/healthcheck` |
| GDAL | O MapProxy usa a `libgdal` via `ctypes` para coverages OGR; as bindings Python estão em avaliação |
| Cache e `HOME` em `config/` | Provisionamento por `mapproxy.yaml` com `${VAR}` e volumes |
| Página demo | A configuração gerada é para testes; em produção, `mapproxy.yaml` próprio sem `demo:` |
| Avisos `${server}`/`$layer` | Vêm da configuração base; o entrypoint imprime uma nota `NOTE:` |
| Log de saturação do busyness | Mantido (sem `log-drain`) |
| `limit_conn` por IP | 20 conexões simultâneas por IP, com rejeição 429; o README alerta sobre NAT e balanceadores |
| `expires_hours: 24` | Os serviços mudam pouco. Para limpar o cache do nginx: `docker compose restart nginx` |
| CVEs no `pip` vendored | Risco aceito e documentado no README, com um Dockerfile derivado para quem precisar remover o `pip` |
