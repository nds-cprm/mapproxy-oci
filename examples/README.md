# Exemplos com Docker Compose

Exemplos de produção para a imagem [`ndscprm/mapproxy`](../README.md), cada um num diretório com o seu `docker-compose.yaml` e os arquivos montados nos containers em `conf/`. Os dois servem a mesma camada atrás de um nginx e diferem no cache de tiles:

| Exemplo | Cache de tiles |
|---|---|
| [`cache-file/`](cache-file) | Arquivos num volume; o nginx serve os tiles direto do disco (ver [cache-file](#cache-file)) |
| [`cache-couchdb/`](cache-couchdb) | Banco CouchDB; o nginx mantém um cache próprio (ver [cache-couchdb](#cache-couchdb)) |

> A origem dos exemplos (a camada de litoestratigrafia 1:1.000.000 do [GeoServer do SGB](https://geoservicos.sgb.gov.br/geoserver/ows)) é só ilustrativa. Respeite os termos de uso dela, ou troque `UPSTREAM_WMS_URL` e a camada pela sua própria fonte de dados.

Para testar um exemplo com uma imagem construída localmente: `MAPPROXY_IMAGE=mapproxy:local docker compose up -d`, no diretório dele.

## cache-file

Arquivos do exemplo:

| Arquivo | Conteúdo |
|---|---|
| [`docker-compose.yaml`](cache-file/docker-compose.yaml) | MapProxy + nginx, com volume de cache, rootfs somente leitura e limites de recursos |
| [`conf/mapproxy/mapproxy.yaml`](cache-file/conf/mapproxy/mapproxy.yaml) | Configuração do MapProxy, com o cache e a origem definidos por variáveis de ambiente |
| [`conf/mapproxy/seed.yaml`](cache-file/conf/mapproxy/seed.yaml) | Tarefas de seed e cleanup do cache (ver [Seed do cache](#seed-do-cache)) |
| [`conf/nginx/nginx.conf`](cache-file/conf/nginx/nginx.conf) | Proxy reverso HTTP → uwsgi |

```yaml
name: mapproxy-cache-file

# Logs go to stdout/stderr and are stored by the container runtime; without
# limits the json-file driver grows forever. With Docker, a host-wide default in
# /etc/docker/daemon.json (e.g. "log-driver": "local") is an alternative.
x-logging: &logging
  driver: json-file
  options:
    max-size: 10m
    max-file: "3"

services:
  # Prepares the cache volume for the image user (UID 1000, GID 0).
  # Runs once and exits; mapproxy only starts after it succeeds.
  cache-init:
    image: ${MAPPROXY_IMAGE:-docker.io/ndscprm/mapproxy:7.0.0}
    user: "0:0"
    entrypoint: ["sh", "-c", "chown 1000:0 /cache && chmod 2775 /cache"]
    volumes:
      - cache:/cache
    restart: "no"
    logging: *logging

  mapproxy:
    image: ${MAPPROXY_IMAGE:-docker.io/ndscprm/mapproxy:7.0.0}
    depends_on:
      cache-init:
        condition: service_completed_successfully
    read_only: true
    tmpfs:
      - /tmp
    environment:
      # read by mapproxy.yaml (${MAPPROXY_CACHE_DIR}, ${UPSTREAM_WMS_URL})
      MAPPROXY_CACHE_DIR: /var/lib/mapproxy/cache
      UPSTREAM_WMS_URL: https://geoservicos.sgb.gov.br/geoserver/ows?
    volumes:
      - ./conf/mapproxy/mapproxy.yaml:/var/lib/mapproxy/config/mapproxy.yaml:ro
      - ./conf/mapproxy/seed.yaml:/var/lib/mapproxy/config/seed.yaml:ro
      - cache:/var/lib/mapproxy/cache
    healthcheck:
      test: ["CMD", "healthcheck"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4g
    restart: unless-stopped
    logging: *logging

  # The image speaks the uwsgi protocol on port 8000; nginx exposes it as HTTP.
  # Unprivileged image: runs as UID 101 and listens on 8080.
  nginx:
    image: docker.io/nginxinc/nginx-unprivileged:1.30-alpine
    depends_on:
      mapproxy:
        condition: service_healthy
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "8080:8080"
    volumes:
      - ./conf/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      # MapProxy tile cache, served directly (see conf/nginx/nginx.conf)
      - cache:/var/lib/mapproxy/cache:ro
    restart: unless-stopped
    logging: *logging

volumes:
  cache:
```

Para subir, no diretório do exemplo:

```sh
cd cache-file
docker compose up -d
```

O serviço fica disponível em `http://localhost:8080`:

- WMS: `http://localhost:8080/service?SERVICE=WMS&REQUEST=GetCapabilities`
- WMTS: `http://localhost:8080/wmts/1.0.0/WMTSCapabilities.xml`
- TMS: `http://localhost:8080/tms/1.0.0/`

O que cada parte faz:

- **`cache-init`** ajusta o dono do volume de cache para o usuário da imagem. Volumes nomeados do Docker são criados como `root`, e o Compose não tem equivalente ao `fsGroup` do Kubernetes.
- **`read_only: true` + `tmpfs: /tmp`**: a raiz do container fica somente leitura; só o cache e o `/tmp` são graváveis.
- **`conf/mapproxy/mapproxy.yaml` montado somente leitura** substitui a configuração de exemplo. Como ele existe, o entrypoint não gera nada.
- **Variáveis de ambiente** definem o diretório do cache e a URL da origem, sem editar o YAML (ver [Variáveis no `mapproxy.yaml`](../README.md#variáveis-no-mapproxyyaml)).
- **Limites de recursos** batem com os padrões do uWSGI da imagem (2 CPUs, 4 GB; ver [Recursos e uWSGI](../README.md#recursos-e-uwsgi)).
- **Logs**: todos os serviços escrevem em stdout/stderr, e o runtime guarda essa saída. O bloco `x-logging` limita cada serviço a 3 arquivos de 10 MB (`json-file`, aceito pelo Docker e pelo Podman). No Docker, também dá para definir isso para o host inteiro em `/etc/docker/daemon.json`, por exemplo com `"log-driver": "local"`, que já faz rotação e compressão (o Podman não aceita esse driver). No Kubernetes, o kubelet já faz a rotação.
- **nginx** usa a imagem `nginx-unprivileged` (UID 101, porta 8080), também com rootfs somente leitura, e só recebe tráfego depois que o MapProxy fica saudável.

O [`conf/nginx/nginx.conf`](cache-file/conf/nginx/nginx.conf) também traz ajustes de desempenho:

| Ajuste | Efeito medido no exemplo |
|---|---|
| Tiles WMTS servidos pelo nginx direto do cache do MapProxy (`try_files`) | Tiles já gerados não passam pelo uWSGI: de ~2.200 para ~11.500 req/s (16 conexões), latência p99 de 66 para 2 ms. O cabeçalho `X-Tile-Source` indica `disk` ou `mapproxy` |
| `expires_hours: 24` no `conf/mapproxy/mapproxy.yaml` | Tiles saem com `Cache-Control: public, max-age=86400`, então navegadores e CDNs também fazem cache |
| `gzip` para XML | `GetCapabilities` WMS de 2,5 KB para 0,8 KB; `WMTSCapabilities` de 10,6 KB para 1,6 KB |
| Buffers maiores (`uwsgi_buffers 16 64k`) | Respostas de até ~1 MB ficam em memória, e o worker do uWSGI é liberado logo |
| `limit_conn` (20 conexões simultâneas por IP, rejeição com 429) | Um único cliente não consegue ocupar todos os 16 workers |

O nginx não tem cache próprio: ele monta o volume de cache do MapProxy como somente leitura e, para uma URL WMTS RESTful (`/wmts/<camada>/<grade>/<z>/<x>/<y>.png`), entrega o arquivo do disco se ele existir; senão, repassa o pedido ao MapProxy, que gera o tile e o grava no volume. Assim há um único cache, persistente, que o seed aquece e o cleanup limpa para todos os caminhos de acesso, e os tiles vizinhos que o MapProxy grava junto (metatiles) já ficam disponíveis. O WMTS por KVP, o TMS e o WMS passam pelo MapProxy, que também usa esse cache. O MapProxy grava cada tile de forma atômica, então o nginx nunca lê um arquivo pela metade.

Para uma camada ser servida do disco, o cache dela segue uma convenção no `mapproxy.yaml`: uma grade por cache, `directory_layout: tms` (`<z>/<x>/<y>`, igual à URL do WMTS) e `directory: ${MAPPROXY_CACHE_DIR}/<camada>/<grade>`, com nomes de camada e de grade só com letras, dígitos, `_` e `-`. O `location` do nginx captura a camada e a grade da URL, então novas camadas que seguem a convenção não exigem mudar o `nginx.conf`. Uma camada fora da convenção continua funcionando, só que sempre pelo MapProxy.

```yaml
caches:
  minha_camada_cache:
    grids: [webmercator]
    sources: [minha_fonte]
    cache:
      type: file
      directory_layout: tms
      directory: ${MAPPROXY_CACHE_DIR}/minha_camada/webmercator
```

> **Nota sobre a origem da grade:** o cache em arquivos grava as linhas de tiles na origem da grade, e o WMTS sempre as numera a partir do canto superior esquerdo (`nw`). A convenção acima só vale para grades com origem `nw`, como a `GLOBAL_WEBMERCATOR` do exemplo. Com uma grade de origem `sw`, como a `GLOBAL_GEODETIC`, a `GLOBAL_MERCATOR` ou uma grade própria sem `origin` (o padrão é `sw`), o nginx encontra o arquivo da linha espelhada e entrega o tile errado, sem erro. Para essas grades, defina `origin: nw` na grade ou deixe a camada fora da convenção, para que ela seja servida pelo MapProxy.

Mudar o layout de um cache existente não migra os tiles: o diretório antigo (no layout padrão, `<cache>_<grade>/`) fica órfão no volume e pode ser apagado; rode o seed de novo.

No Kubernetes, o nginx só consegue ler o volume de cache se estiver no mesmo pod que o MapProxy (sidecar) ou se o volume for `ReadWriteMany`.

> **Atenção ao `limit_conn`:** o limite é por endereço IP. Usuários atrás de um mesmo NAT, ou um balanceador ou terminador TLS na frente do nginx, aparecem como um único IP e seriam bloqueados juntos. Nesses casos, aumente o limite ou configure o IP real do cliente (módulo `realip` do nginx).

> **Atenção ao tempo de resposta da origem:** um pedido que leva mais de 60 s é interrompido pelo `harakiri` do uWSGI, e o nginx responde **502** (`upstream prematurely closed connection` no log). Com a origem do exemplo, um GetMap sem cache levou de 30 a 40 s em 25/10/2026, então pedidos maiores ou uma origem mais lenta chegam perto desse limite. O WMS (`/service`) também usa o cache de tiles do MapProxy, então o seed dos níveis baixos (`litoestratigrafia_brasil`, ver [Seed do cache](#seed-do-cache)) reduz bastante esse tempo. Para aumentar o limite, mude juntos o `harakiri` de um `uwsgi.conf` próprio (ver [Recursos e uWSGI](../README.md#recursos-e-uwsgi)) e o `uwsgi_read_timeout` do `conf/nginx/nginx.conf`, que fica alguns segundos acima. O timeout do cliente HTTP do MapProxy (`globals.http.client_timeout`, 60 s por padrão) também precisa acompanhar: senão, o pedido à origem falha antes do novo limite.

### Seed do cache

O [`conf/mapproxy/seed.yaml`](cache-file/conf/mapproxy/seed.yaml), baseado no exemplo gerado pelo `mapproxy-util`, define duas tarefas:

| Tarefa | O que faz |
|---|---|
| `litoestratigrafia_brasil` (seed) | Gera os níveis 0 a 8 sobre o Brasil (coverage em EPSG:4674) e recria tiles com mais de 30 dias. São ~1.800 tiles |
| `litoestratigrafia_old_tiles` (cleanup) | Remove tiles com mais de 14 dias dos níveis 9 em diante, que são gerados sob demanda |

Para rodar, com o Compose no ar:

```sh
# ver o que seria feito, sem baixar nada
docker compose exec mapproxy mapproxy-seed \
  -f /var/lib/mapproxy/config/mapproxy.yaml \
  -s /var/lib/mapproxy/config/seed.yaml --summary

# seed (2 processos simultâneos)
docker compose exec mapproxy mapproxy-seed \
  -f /var/lib/mapproxy/config/mapproxy.yaml \
  -s /var/lib/mapproxy/config/seed.yaml -c 2 --seed litoestratigrafia_brasil

# cleanup
docker compose exec mapproxy mapproxy-seed \
  -f /var/lib/mapproxy/config/mapproxy.yaml \
  -s /var/lib/mapproxy/config/seed.yaml --cleanup litoestratigrafia_old_tiles
```

O `mapproxy-seed` roda dentro do container `mapproxy`, com as mesmas variáveis de ambiente (`MAPPROXY_CACHE_DIR`, `UPSTREAM_WMS_URL`) e o mesmo volume de cache. Use `--dry-run` para contar os tiles antes de rodar. Mantenha a concorrência (`-c`) baixa ao semear a partir de servidores de terceiros. Para rodar periodicamente, agende esses comandos no host (cron, timer do systemd) ou, no Kubernetes, num `CronJob` que monte o mesmo volume.

## cache-couchdb

O [`cache-couchdb/`](cache-couchdb) é uma cópia do [cache-file](#cache-file) com os tiles gravados num [CouchDB](https://couchdb.apache.org) no lugar do volume. Cada tile vira um documento (`<grade>-<z>-<x>-<y>`) com a imagem como anexo e o horário de criação, e o MapProxy cria o banco (`litoestratigrafia_webmercator`) no primeiro uso. As diferenças:

- **Serviço `couchdb`** (`couchdb:3.5`), sem porta publicada no host, com os dados no volume `couchdb-data` e healthcheck em `/_up`. O MapProxy só sobe depois que ele fica saudável.
- **Senha obrigatória:** o Compose não sobe sem `COUCHDB_PASSWORD`. Defina-a num arquivo `.env` ao lado do `docker-compose.yaml`, que o `.gitignore` do repositório já ignora; `COUCHDB_USER` é `mapproxy` por padrão. O MapProxy recebe as duas variáveis e monta a URL `http://<usuário>:<senha>@couchdb:5984`, então uma senha com caracteres especiais precisa estar codificada para URL.
- **[`conf/couchdb/local.ini`](cache-couchdb/conf/couchdb/local.ini)** configura um nó só (`single_node = true`, que cria `_users` e `_replicator`, e `[cluster] n = 1`). No primeiro boot, o CouchDB registra um erro `database_does_not_exist` para `_users`, antes de criá-lo; ele não se repete.
- **O CouchDB roda como o usuário dele (`5984:5984`)** desde o início. Iniciado como root, o entrypoint da imagem tenta ajustar o dono de tudo em `/opt/couchdb`, falha no `local.ini` montado somente leitura e encerra o container sem mensagem nenhuma.
- **Sem `cache-init` nem volume no MapProxy:** o `MAPPROXY_CACHE_DIR` aponta para o `/tmp` (tmpfs), que só guarda os locks de tiles.
- **O nginx usa o próprio cache de tiles** (`uwsgi_cache`, no `/tmp`, até 512 MB, perdido ao recriar o container) para `/wmts/` e `/tms/`, porque aqui não há arquivos para servir direto do disco. O cabeçalho `X-Cache-Status` indica `HIT`/`MISS`, e `docker compose restart nginx` esvazia esse cache.

```sh
cd cache-couchdb
echo "COUCHDB_PASSWORD=$(openssl rand -hex 16)" > .env
docker compose up -d
```

**Cleanup:** num cache em arquivos, o `mapproxy-seed --cleanup` percorre os diretórios. No CouchDB ele não tem como listar o que está gravado e consulta tile por tile da cobertura. Por isso a tarefa `litoestratigrafia_old_tiles` desse exemplo fica limitada ao Brasil e aos níveis 9 a 12, e levou ~6 min em 25/10/2026; cada nível a mais leva 4 vezes mais. Para descartar o cache inteiro, apague o banco e **reinicie o MapProxy**, que só cria o banco uma vez por processo (até lá, os pedidos de tiles respondem 500):

```sh
docker compose exec couchdb sh -c \
  'curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" -X DELETE http://127.0.0.1:5984/litoestratigrafia_webmercator'
docker compose restart mapproxy
```

## Subcaminho

Para publicar um exemplo num subcaminho (`/mapproxy/`), acrescente ao `conf/nginx/nginx.conf` o `location /mapproxy/` de [HTTPS, proxies e subcaminho](../README.md#https-proxies-e-subcaminho). Os `location` de tiles dos exemplos não cobrem `/mapproxy/wmts/`; sem mais nada, esses tiles vão sempre ao MapProxy:
- `cache-file` (tiles do disco): repita o `location` com o prefixo (`^/mapproxy/wmts/...`) e aponte o `try_files` para um `location` nomeado com o mesmo `include uwsgi_params` e `uwsgi_param HTTP_X_SCRIPT_NAME`.
- `cache-couchdb` (`uwsgi_cache`): ajuste a expressão para `^/mapproxy/(wmts|tms)/`, com o mesmo `include uwsgi_params` e `uwsgi_param`.

Verificado em 25/10/2026 no `cache-file`, com TLS autoassinado no nginx e `/mapproxy/` como subcaminho, combinados entre si.
