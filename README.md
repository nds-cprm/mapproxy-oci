# mapproxy-oci

Imagem de container OCI para o [MapProxy](https://mapproxy.org), servido pelo uWSGI.

- MapProxy 7 sobre Python 3.14 e Debian trixie (`python:3.14-slim-trixie`)
- Roda como usuário não-root (`55000:0`) e aceita UID arbitrário (OpenShift)
- Funciona com sistema de arquivos raiz somente leitura
- Configuração por `mapproxy.yaml`, variáveis de ambiente e volumes
- Healthcheck que detecta workers travados
- Imagens `linux/amd64` e `linux/arm64`

Imagem publicada: [`ndscprm/mapproxy`](https://hub.docker.com/r/ndscprm/mapproxy), com a tag igual à versão do MapProxy.

## Início rápido

```sh
docker run -d --name mapproxy -p 8000:8000 ndscprm/mapproxy:7.0.0
```

Sem configuração própria, o container gera uma configuração de exemplo em `/var/lib/mapproxy/config`. **Ela serve só para testes**: tem a página `demo` habilitada e placeholders (`${server}`, `$layer`) que geram avisos no log.

A porta 8000 fala o **protocolo uwsgi**, não HTTP. Para acessar pelo navegador, use um proxy reverso (ver [Rede](#rede)) ou o exemplo de produção abaixo.

## Produção com Docker Compose

O repositório traz um exemplo completo:

| Arquivo | Conteúdo |
|---|---|
| [`docker-compose.yaml`](docker-compose.yaml) | MapProxy + nginx, com volume de cache, rootfs somente leitura e limites de recursos |
| [`docker/mapproxy.yaml`](docker/mapproxy.yaml) | Configuração do MapProxy, com o cache e a origem definidos por variáveis de ambiente |
| [`docker/seed.yaml`](docker/seed.yaml) | Tarefas de seed e cleanup do cache (ver [Seed do cache](#seed-do-cache)) |
| [`docker/nginx.conf`](docker/nginx.conf) | Proxy reverso HTTP → uwsgi |

Os arquivos em `docker/` são montados nos containers.

```yaml
name: mapproxy

services:
  # Prepares the cache volume for the image user (UID 55000, GID 0).
  # Runs once and exits; mapproxy only starts after it succeeds.
  cache-init:
    image: ${MAPPROXY_IMAGE:-docker.io/ndscprm/mapproxy:7.0.0}
    user: "0:0"
    entrypoint: ["sh", "-c", "chown 55000:0 /cache && chmod 2775 /cache"]
    volumes:
      - cache:/cache
    restart: "no"

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
      UPSTREAM_WMS_URL: https://ows.terrestris.de/osm/service?
    volumes:
      - ./docker/mapproxy.yaml:/var/lib/mapproxy/config/mapproxy.yaml:ro
      - ./docker/seed.yaml:/var/lib/mapproxy/config/seed.yaml:ro
      - cache:/var/lib/mapproxy/cache
    healthcheck:
      test: ["CMD", "uwsgi", "--socket", "127.0.0.1:8000", "--nagios"]
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
      - ./docker/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    restart: unless-stopped

volumes:
  cache:
```

Para subir, na raiz do repositório:

```sh
docker compose up -d
```

O serviço fica disponível em `http://localhost:8080`:

- WMS: `http://localhost:8080/service?SERVICE=WMS&REQUEST=GetCapabilities`
- WMTS: `http://localhost:8080/wmts/1.0.0/WMTSCapabilities.xml`
- TMS: `http://localhost:8080/tms/1.0.0/`

O que cada parte faz:

- **`cache-init`** ajusta o dono do volume de cache para o usuário da imagem. Volumes nomeados do Docker são criados como `root`, e o Compose não tem equivalente ao `fsGroup` do Kubernetes.
- **`read_only: true` + `tmpfs: /tmp`**: a raiz do container fica somente leitura; só o cache e o `/tmp` são graváveis.
- **`docker/mapproxy.yaml` montado somente leitura** substitui a configuração de exemplo. Como ele existe, o entrypoint não gera nada.
- **Variáveis de ambiente** definem o diretório do cache e a URL da origem, sem editar o YAML (ver [Variáveis no `mapproxy.yaml`](#variáveis-no-mapproxyyaml)).
- **Limites de recursos** batem com os padrões do uWSGI da imagem (2 CPUs, 4 GB; ver [Recursos](#recursos-e-uwsgi)).
- **nginx** usa a imagem `nginx-unprivileged` (UID 101, porta 8080), também com rootfs somente leitura, e só recebe tráfego depois que o MapProxy fica saudável.

O [`docker/nginx.conf`](docker/nginx.conf) também traz ajustes de desempenho:

| Ajuste | Efeito medido no exemplo |
|---|---|
| Cache do nginx (`uwsgi_cache`) para `/wmts/` e `/tms/` | Tiles repetidos são servidos sem passar pelo uWSGI: de ~6.500 para ~18.700 req/s (16 conexões), latência p99 de 5 para 1 ms. O cabeçalho `X-Cache-Status` indica `HIT`/`MISS` |
| `expires_hours: 24` no `docker/mapproxy.yaml` | Tiles saem com `Cache-Control: public, max-age=86400`, então navegadores e CDNs também fazem cache |
| `gzip` para XML | `GetCapabilities` WMS de 2,5 KB para 0,8 KB; `WMTSCapabilities` de 10,6 KB para 1,6 KB |
| Buffers maiores (`uwsgi_buffers 16 64k`) | Respostas de até ~1 MB ficam em memória, e o worker do uWSGI é liberado logo |
| `limit_conn` (20 conexões simultâneas por IP, rejeição com 429) | Um único cliente não consegue ocupar todos os 16 workers |

O cache do nginx fica no `/tmp` (tmpfs) do container, com no máximo 512 MB, e se perde ao recriar o container. O WMS (`/service`) não é cacheado no nginx, porque cada combinação de bbox e tamanho gera uma URL diferente.

> **Atenção ao `limit_conn`:** o limite é por endereço IP. Usuários atrás de um mesmo NAT, ou um balanceador ou terminador TLS na frente do nginx, aparecem como um único IP e seriam bloqueados juntos. Nesses casos, aumente o limite ou configure o IP real do cliente (módulo `realip` do nginx).

> A origem do exemplo (o WMS OpenStreetMap da [terrestris](https://ows.terrestris.de)) é só ilustrativa. Respeite os termos de uso dela, ou troque `UPSTREAM_WMS_URL` e a camada pela sua própria fonte de dados.

Para testar o exemplo com uma imagem construída localmente: `MAPPROXY_IMAGE=mapproxy:local docker compose up -d`.

### Seed do cache

O [`docker/seed.yaml`](docker/seed.yaml), baseado no exemplo gerado pelo `mapproxy-util`, define duas tarefas:

| Tarefa | O que faz |
|---|---|
| `osm_brasil` (seed) | Gera os níveis 0 a 8 sobre o Brasil (coverage em EPSG:4674) e recria tiles com mais de 30 dias. São ~1.800 tiles (~20 MB) |
| `osm_old_tiles` (cleanup) | Remove tiles com mais de 14 dias dos níveis 9 em diante, que são gerados sob demanda |

Para rodar, com o Compose no ar:

```sh
# ver o que seria feito, sem baixar nada
docker compose exec mapproxy mapproxy-seed \
  -f /var/lib/mapproxy/config/mapproxy.yaml \
  -s /var/lib/mapproxy/config/seed.yaml --summary

# seed (2 processos simultâneos)
docker compose exec mapproxy mapproxy-seed \
  -f /var/lib/mapproxy/config/mapproxy.yaml \
  -s /var/lib/mapproxy/config/seed.yaml -c 2 --seed osm_brasil

# cleanup
docker compose exec mapproxy mapproxy-seed \
  -f /var/lib/mapproxy/config/mapproxy.yaml \
  -s /var/lib/mapproxy/config/seed.yaml --cleanup osm_old_tiles
```

O `mapproxy-seed` roda dentro do container `mapproxy`, com as mesmas variáveis de ambiente (`MAPPROXY_CACHE_DIR`, `UPSTREAM_WMS_URL`) e o mesmo volume de cache. Use `--dry-run` para contar os tiles antes de rodar. Mantenha a concorrência (`-c`) baixa ao semear a partir de servidores de terceiros. Para rodar periodicamente, agende esses comandos no host (cron, timer do systemd) ou, no Kubernetes, num `CronJob` que monte o mesmo volume.

## Configuração

### Diretório de configuração

O MapProxy lê `$HOME/mapproxy.yaml`. Na imagem, `HOME=/var/lib/mapproxy/config`. Se você mudar `HOME`, muda também o lugar onde a configuração é lida e gerada.

Na inicialização, o entrypoint:
- usa `$HOME/mapproxy.yaml`, se existir;
- se não existir, gera a configuração de exemplo em `$HOME` e imprime um aviso de que ela é só para testes;
- se não existir e `$HOME` não for gravável, encerra com uma mensagem de erro explicando o problema.

Em produção, forneça seu próprio `mapproxy.yaml`, montando o arquivo ou o diretório por volume, bind mount ou ConfigMap.

### Variáveis no `mapproxy.yaml`

O MapProxy 7 substitui `$VAR` e `${VAR}` por variáveis de ambiente em qualquer valor de texto do YAML:

```yaml
globals:
  cache:
    base_dir: ${MAPPROXY_CACHE_DIR}
```

Cuidados:
- **Não existe valor padrão** (`${VAR:-padrão}` não funciona). Se a variável não estiver definida, o texto `${VAR}` fica literal e aparece um `UserWarning` no log. Defina todas as variáveis usadas.
- A substituição vale só para **valores**, não para chaves. Por exemplo, não dá para ligar ou desligar o serviço `demo` por variável.

### Cache de tiles

Por padrão, o MapProxy grava o cache em `cache_data/`, ao lado do `mapproxy.yaml`. Em produção, prefira um volume próprio para o cache, apontado por `globals.cache.base_dir`, como no exemplo do Compose. Assim a configuração, pequena e versionável, fica separada do cache, grande e descartável.

### Página demo

A página `/demo/` existe só se o `mapproxy.yaml` tiver `demo:` em `services`. A configuração de exemplo tem; o próprio MapProxy recomenda desligá-la em produção.

## Usuário e permissões

- A imagem roda como `55000:0`.
- **UID arbitrário** (OpenShift, `--user`) é suportado: o entrypoint registra o usuário via nss_wrapper, então `whoami` e as consultas de nome funcionam. O GID deve ser `0`.
- **Volumes graváveis** (configuração, cache) precisam permitir escrita ao UID do container ou ao grupo `0`:
  - Kubernetes: `securityContext.fsGroup`;
  - Docker/Podman: prepare o volume, como faz o serviço `cache-init` do exemplo.
- Arquivos criados pelo container ficam graváveis pelo grupo (`umask 002`).

### Sistema de arquivos raiz somente leitura

Suportado (`read_only: true`, `--read-only`, `readOnlyRootFilesystem: true`). Recomenda-se montar `/tmp` como gravável (`tmpfs` ou `emptyDir`):
- sem ele, o servidor funciona, mas o processo fica sem nome de usuário (há um aviso no log);
- requisições POST com corpo acima de 64 KB também precisam do `/tmp`.

## Rede

O uWSGI escuta em `0.0.0.0:8000` com o **protocolo uwsgi**. Use um proxy reverso; no nginx:

```nginx
location / {
    include uwsgi_params;
    uwsgi_pass mapproxy:8000;
}
```

Para servir **HTTP direto**, sobrescreva `/var/lib/uwsgi/uwsgi.conf` com uma cópia que use `http-socket = :8000` no lugar de `socket`. O healthcheck padrão fala o protocolo uwsgi, então ajuste-o também. Outra opção é manter o `socket` e acrescentar um `http-socket` em outra porta.

## Recursos e uWSGI

Os padrões do [`uwsgi.conf`](src/uwsgi.conf.envsubst) são dimensionados para **2 CPUs e 4 GB de memória**:

| Opção | Valor |
|---|---|
| `processes` (máximo de workers) | 16 |
| `cheaper` / `cheaper-initial` / `cheaper-step` | 2 / 4 / 2 |
| `reload-on-rss` | 256 MB |
| `cheaper-rss-limit-soft` | 2,5 GB |
| `max-requests` | 5000 |
| `harakiri` | 60 s |

Para outro tamanho de container, monte seu próprio `uwsgi.conf` em `/var/lib/uwsgi/uwsgi.conf`. Variáveis como `UWSGI_PROCESSES` **não** sobrescrevem os valores do arquivo.

## Healthcheck

A imagem define `HEALTHCHECK` com `uwsgi --socket 127.0.0.1:8000 --nagios`, um ping no protocolo uwsgi respondido por um worker. Ele falha se nenhum worker estiver atendendo.

- **Podman/Buildah:** o `HEALTHCHECK` só é mantido em imagens construídas com `--format docker`. Os exemplos acima definem o healthcheck no próprio Compose para não depender disso.
- **Kubernetes:** use uma probe `exec` com o mesmo comando:
  ```yaml
  livenessProbe:
    exec:
      command: ["uwsgi", "--socket", "127.0.0.1:8000", "--nagios"]
  ```

## Construindo a imagem

```sh
docker build -t mapproxy:local .
# outra versão do MapProxy:
docker build --build-arg MAPPROXY_VERSION=7.0.0 -t mapproxy:local .
```

| Build arg | Padrão |
|---|---|
| `MAPPROXY_VERSION` | `7.0.0` |
| `PYTHON_VERSION` | `3.14` |
| `DEBIAN_VERSION` | `trixie` |
| `MAPPROXY_BASE_DIR` | `/var/lib/mapproxy` |

As dependências Python ficam fixadas em [`requirements.txt`](requirements.txt). O workflow [`docker-image.yml`](.github/workflows/docker-image.yml) constrói e publica as imagens `amd64` e `arm64` e analisa CVEs com o Docker Scout.

## Segurança e atualizações

- **Rebuild mensal:** o workflow reconstrói a imagem no dia 1 de cada mês, sem cache de camadas, e republica a mesma tag com as correções de segurança disponíveis nas imagens base e nos pacotes Debian e Python. Para receber as atualizações, rode `docker compose pull && docker compose up -d` (ou o equivalente no seu ambiente).
- **Análise de vulnerabilidades:** cada build é analisado pelo Docker Scout, e o resultado aparece na aba *Security* do repositório.

### Vulnerabilidades conhecidas e aceitas

O `pip` 26.2.1, a versão mais recente, traz cópias embutidas (*vendored*) de algumas bibliotecas em versões com CVEs conhecidas. Ele está presente no venv e no Python do sistema:

| Biblioteca embutida | Versão | CVEs altas |
|---|---|---|
| `urllib3` | 2.7.0 | 2 |
| `msgpack` | 1.1.2 | 1 |
| `setuptools` (`pkg_resources`) | 70.3.0 | 1 |

**O risco foi aceito**, porque esse código só é executado quando alguém roda o `pip`. O MapProxy e o uWSGI não o usam: o `urllib3` usado pelo MapProxy é outra instalação, já na versão corrigida (2.8.0). Na prática, o risco se limita a quem executar `pip install` dentro do container, o que não faz parte do uso normal da imagem.

Essa decisão será revista quando sair um `pip` com as dependências embutidas atualizadas. O `pip` vem da imagem base do Python, então ele é atualizado quando uma nova imagem `python:3.14` trouxer uma versão nova, o que o rebuild mensal incorpora. Se a sua política de segurança não aceitar esses achados, uma imagem derivada pode remover o `pip`:

```dockerfile
FROM ndscprm/mapproxy:7.0.0
USER 0
RUN /var/lib/mapproxy/venv/bin/python -m pip uninstall -y pip && \
    /usr/local/bin/python3 -m pip uninstall -y pip && \
    rm -rf /usr/local/lib/python3*/ensurepip
USER 55000:0
```

## Licença

[Apache License 2.0](LICENSE). Veja [`NOTICE`](NOTICE) para autoria e avisos.

Este software é fornecido "no estado em que se encontra", sem garantia de qualquer tipo e sem compromisso de manutenção, suporte ou atualização.

O MapProxy é © Omniscale e colaboradores, também sob a Apache License 2.0.
