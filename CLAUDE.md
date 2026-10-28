# CLAUDE.md

Imagem de container OCI para o [MapProxy](https://mapproxy.org), servido pelo uWSGI e publicada como `ndscprm/mapproxy` (amd64 + arm64). Não há código de aplicação: o projeto é um Dockerfile, seus templates de configuração, um exemplo de produção com Compose e o workflow de CI.

Idioma: os READMEs (`README.md` e `examples/README.md`), o TODO.md e este arquivo estão em português do Brasil; os comentários no Dockerfile, nos scripts e nos arquivos de configuração estão em inglês. Mantenha essa divisão.

## Estrutura

| Caminho | Papel |
|---|---|
| `Dockerfile` | Dois estágios sobre `ndscprm/gdal` (Debian trixie + Python + GDAL, venv em `/opt/geosgb/venv`), passadas pelo nome completo (`ARG GDAL_IMAGE_DEVEL` e `ARG GDAL_IMAGE_PY`; o padrão são as tags móveis `3.12.4-py3.12-devel` e `3.12.4-py3.12`, reconstruídas no lugar toda semana; no CI, o gdal-oci passa as tags datadas com o digest do build que acabou de publicar, `<tag>-<AAAAMMDD>@sha256:...`, as duas do mesmo build): `build` (tag `-devel`, com compiladores) gera as wheels do MapProxy e das dependências em `/wheels` (os pacotes do `NO_BINARY` compilados a partir do sdist, veja abaixo) e os templates, e deixa o `config/` vazio (a configuração base só é gerada pelo entrypoint); `release` instala as mesmas wheels com o próprio pip (`--no-index`, com os pacotes da base como restrições), roda `pip check` e um teste de fumaça, define `PROJ_DATA=/usr/share/proj` e copia `/var/lib/mapproxy` |
| `requirements.txt` | Dependências Python fixadas; também usado como **arquivo de constraints** na instalação do MapProxy |
| `docker/healthcheck` | Comando de healthcheck único (copiado para `/usr/local/bin`, modo 755), usado pelo `HEALTHCHECK`, pelo Compose e pelos exemplos de Podman/Kubernetes do README |
| `src/*.envsubst` | `app.py` (entrada WSGI) e `uwsgi.conf`, gerados no build com `envsubst '${MAPPROXY_BASE_DIR}'` apenas |
| `docker-entrypoint.d/20-mapproxy.sh` | Hook de inicialização, **carregado com `source`** pelo `/docker-entrypoint.sh` da imagem base (depois do `10-enable-nss-wrapper.sh` dela) |
| `examples/README.md` | Documentação dos exemplos com Compose (em português) |
| `examples/cache-file/` | Exemplo de produção com Compose e cache em arquivos: `cache-init` (ajusta o dono do volume), `mapproxy`, `nginx-unprivileged` (HTTP :8080 → uwsgi :8000; serve os tiles WMTS direto do volume de cache do MapProxy, montado `:ro`). Os arquivos de `conf/` (`mapproxy/` e `nginx/`) são montados por bind mount |
| `examples/cache-couchdb/` | Cópia do `cache-file` com os tiles num CouchDB (serviço `couchdb`, `conf/couchdb/local.ini`, senha em `.env`, ignorado pelo `.gitignore`); sem `cache-init` nem volume no MapProxy; o nginx mantém o `uwsgi_cache` de tiles |
| `.github/workflows/docker-image.yml` | Disparo manual (com as imagens base opcionais `image_devel`/`image_py`/`image_nopy`, nomes completos, repassadas como build args `GDAL_IMAGE_DEVEL`/`GDAL_IMAGE_PY`; o `image_nopy` é aceito e ignorado, porque as três derivadas do gdal-oci declaram as mesmas entradas; vazias = `ARG` do Dockerfile; o job `check` recusa nomes fora de `docker.io/ndscprm/gdal:`); também disparado pelo CI do gdal-oci, job `dispatch`, depois que ele publica tags novas da `ndscprm/gdal`, com os nomes delas (tag datada e digest); sem build agendado (uma base nova invalida todas as camadas); chama o workflow reutilizável `nds-cprm/gdal-oci/.github/workflows/oci-image.yml@main` (runners nativos amd64/arm64, push por digest, teste, Scout + Grype → SARIF, tags `<versão>` e `<versão>-<AAAAMMDD>[.N]` só depois disso). Mudanças no fluxo são feitas no gdal-oci |
| `.github/scripts/smoke-test.sh` | Teste de fumaça rodado pelo CI em cada arquitetura (e localmente, `DOCKER=podman`): sobe o container com `--user 12345:0 --read-only --tmpfs /tmp` e o `HOME` vazio e gravável (`tmpfs`, já que a imagem não traz configuração), espera o `healthcheck`, confere que os scripts de `/docker-entrypoint.d` rodaram (nss_wrapper carregado no uWSGI, umask 002) e pede o GetCapabilities do WMS e do WMTS da configuração base chamando a aplicação WSGI do `app.py` (a porta 8000 fala uwsgi). Depois confere que a configuração base é criada sem nenhuma mensagem do entrypoint no stdout do comando, e que, sem configuração e com o `HOME` somente leitura, o container não inicia. No Podman, usa `--passwd=false` (senão ele acrescenta o UID ao `/etc/passwd` e o nss_wrapper não entra) e `notmpcopyup` (senão o `tmpfs` vem com o conteúdo da imagem) |
| `TODO.md` | Pendências do projeto, por área e prioridade; só os itens em aberto (remova os concluídos, o histórico fica no git) |

## Modelo de execução

- Roda como `1000:0`; UIDs arbitrárias precisam funcionar (OpenShift), então tudo que é gravável deve ser gravável pelo grupo 0 (`umask 002`, `chmod g=u`). O nome do registro no passwd criado pelo nss_wrapper é o padrão da base, `sgb` (`USER_NAME` não é definido na imagem), igual nos projetos irmãos (`mapserver-oci`, `pygeoapi-oci`).
- `HOME=/var/lib/mapproxy/config` **é** o diretório de configuração: o `app.py` lê `$HOME/mapproxy.yaml`. Se ele não existir, o entrypoint gera a `base-config` do MapProxy (só para testes) ou encerra com `exit 1` se `$HOME` for somente leitura.
- Precisa funcionar com rootfs somente leitura; só o `/tmp` (nss_wrapper, corpos de POST grandes) e os volumes montados são graváveis.
- A porta 8000 fala o **protocolo uwsgi, não HTTP**. Healthcheck: script `docker/healthcheck` (→ `/usr/local/bin/healthcheck`, roda `uwsgi --socket 127.0.0.1:8000 --nagios`), chamado igual em todos os runtimes.
- O ENTRYPOINT é herdado da imagem base; o CMD é `uwsgi --ini /var/lib/uwsgi/uwsgi.conf`.

## Comandos

```sh
docker build -t mapproxy:local .
docker build --build-arg MAPPROXY_VERSION=X.Y.Z -t mapproxy:local .
docker build --build-arg GDAL_IMAGE_DEVEL=docker.io/ndscprm/gdal:3.12.4-py3.12-devel-20261026 --build-arg GDAL_IMAGE_PY=docker.io/ndscprm/gdal:3.12.4-py3.12-20261026 -t mapproxy:local .   # base fixa, como no CI
cd examples/cache-file && MAPPROXY_IMAGE=mapproxy:local docker compose up -d   # testa um exemplo com um build local
cd examples/cache-couchdb && echo COUCHDB_PASSWORD=... > .env && MAPPROXY_IMAGE=mapproxy:local docker compose up -d
# teste rápido: http://localhost:8080/service?SERVICE=WMS&REQUEST=GetCapabilities
```

Não há testes unitários nem linters no repositório; valide as mudanças construindo a imagem e rodando o exemplo do Compose (status de saúde, GetCapabilities/GetMap, WMTS).

## Invariantes e o que manter sincronizado

- **Versão do MapProxy**: `ARG MAPPROXY_VERSION=X.Y.Z` no Dockerfile é o único valor padrão; o workflow reutilizável o extrai com `sed -nE 's/^ARG MAPPROXY_VERSION=(.+)$/\1/p'` (entrada `version-arg`) e valida com `^[0-9]+\.[0-9]+\.[0-9]+$`, então mantenha exatamente esse formato de linha. Ao mudar a versão, atualize também a tag da imagem nos `docker-compose.yaml` de `examples/` e no README (`grep -rn "7\.0\.0" --exclude-dir=.git .`).
- **O `examples/README.md` contém uma cópia literal do `examples/cache-file/docker-compose.yaml`**: qualquer mudança nesse Compose deve ser replicada ali. A documentação dos exemplos (Compose, nginx, seed, CouchDB) fica no `examples/README.md`; o `README.md` trata da imagem e só aponta para os exemplos. No `README.md` ficam, e precisam acompanhar o código, os padrões dos build args e a tabela de dimensionamento do uWSGI.
- **Os dois exemplos são cópias**: o que não é específico do cache (origem WMS, seed, healthcheck, limites, logging, o nginx fora dos `location` de tiles) deve mudar igual em `examples/cache-file/` e `examples/cache-couchdb/`. No CouchDB, o cleanup fica limitado ao Brasil e aos níveis 9–12 (ele consulta tile por tile), e o serviço roda como `5984:5984` (como root, o entrypoint da imagem aborta no `local.ini` montado `:ro`).
- **Wheels, não o venv**: o `release` nunca copia o venv do `build`. Um `COPY` do venv mescla os arquivos com o venv da base e, se a `-devel` e a `release` divergirem (tags republicadas em momentos diferentes, cache local antigo), deixa duas versões do mesmo pacote no `site-packages`, sem erro no build (aconteceu com o numpy em 25/10/2026). O teste de fumaça do `release` importa os módulos usados pelo `app.py` e pelas dependências diretas; acrescente ali as dependências novas do `requirements.txt`.
- **Pacotes compilados (`ARG NO_BINARY=pyproj,shapely`)**: no estágio `build`, o `pip wheel` recebe `--no-binary "$NO_BINARY"` e compila esses pacotes a partir do sdist contra o PROJ (9.6.0) e o GEOS (3.13.1) da imagem base, os mesmos da `libgdal`, em vez das wheels do PyPI, que embutem cópias próprias (PROJ 9.5.1 no `pyproj.libs`, GEOS no `shapely.libs`). Só nomes, separados por vírgula; cada um precisa estar fixado no `requirements.txt` (a versão vem dali), senão o build falha antes de compilar (`<nome> (NO_BINARY) is not pinned in requirements.txt`). Detalhes, iguais aos do pygeoapi-oci:
  - o setup do pyproj procura o executável `proj`, que a `-devel` não tem: o `pip wheel` recebe `PROJ_DIR=/usr` e `PROJ_VERSION=$(pkg-config --modversion proj)`;
  - as dependências de build (Cython, setuptools, numpy...) rodam em ambientes isolados, que o `-c` não alcança: o `--build-constraint` com o `pip freeze --all` da base fixa ali os pacotes dela (o numpy). As que não vêm da base ficam sem versão fixa nem hash (este repositório não tem locks);
  - `LDFLAGS=-s` tira os símbolos de depuração do que é compilado, como faz a base (a imagem de runtime não tem `strip`);
  - o `pip wheel` e o `pip install` do `release` recebem o `pip freeze --all` da imagem como restrição (`-c`), para que nenhuma dependência troque um pacote da base;
  - o pyproj compilado não traz os dados do PROJ e, ao contrário da `libproj` usada pelo `osgeo`, não procura em `/usr/share/proj` por padrão: `ENV PROJ_DATA=/usr/share/proj`;
  - o teste de fumaça (`## native libraries`) confere que o PROJ do pyproj e o GEOS do shapely são os do `osgeo` e falha se algum módulo carregar uma biblioteca do `pyproj.libs` ou do `shapely.libs` (lê o `/proc/self/maps` depois dos imports). Um teste com a wheel do PyPI do pyproj instalada por cima falhou pelos dois motivos. Ao acrescentar um pacote ao `NO_BINARY`, acrescente-o também ali;
  - o Pillow e o lxml continuam com as wheels do PyPI (cópias próprias de freetype, libjpeg, libtiff... e libxml2/libxslt estáticas). Por enquanto, a decisão é usar as bibliotecas que vêm nas wheels. Compilá-los contra o sistema foi testado e funciona, mas exige instalar no `release` bibliotecas de runtime que a base não tem; os detalhes estão no `TODO.md`;
  - a imagem ficou com 728 MB (eram 768 MB).
- **Labels da imagem**: `title`, `version`, `source`, `licenses` e `base.name` vêm do Dockerfile; `description` e `url`, da entrada `labels` do workflow; `created` e `revision`, do workflow reutilizável. O `org.opencontainers.image.base.name` é o `GDAL_IMAGE_PY` do build (redeclarado com `ARG` no estágio `release`), porque as tags da imagem não dizem sobre qual base ela foi construída: no CI, a tag datada com o digest, passada pelo gdal-oci; num build local, a tag móvel ou o que for passado.
- **Dimensionamento do uWSGI ↔ recursos**: os padrões do `uwsgi.conf` (16 workers × 256 MB de `reload-on-rss`, limite soft de 2,5 GB) supõem 2 CPUs / 4 GB, iguais ao `deploy.resources.limits` do Compose. O `uwsgi_read_timeout 65s` do nginx acompanha o `harakiri = 60` do uWSGI, que acompanha o `globals.http.client_timeout` do MapProxy (padrão 60 s; nota no README, já que o GetMap na origem do exemplo leva 30–40 s); o `limit_conn 20` se relaciona ao máximo de 16 workers.
- **Tiles do disco**: no `cache-file`, o `location` regex do `conf/nginx/nginx.conf` (`/wmts/<camada>/<grade>/<z>/<x>/<y>.<ext>` → `try_files /<camada>/<grade>/<z>/<x>/<y>.<ext>`) depende da convenção dos caches no `mapproxy.yaml` (`directory_layout: tms`, `directory: ${MAPPROXY_CACHE_DIR}/<camada>/<grade>`, uma grade por cache) e só vale para grades com origem `nw` (o WMTS numera as linhas a partir do topo; com origem `sw` o nginx entregaria o tile espelhado), limitação documentada em nota no `examples/README.md`. O `Cache-Control` que o nginx envia nos acertos repete o do `expires_hours: 24`; o `root` do nginx é o ponto de montagem do volume no Compose.
- **Healthcheck** declarado também no Compose de propósito (o Podman descarta o `HEALTHCHECK` em imagens no formato OCI, e o Kubernetes nunca o usa); o comando fica só em `docker/healthcheck`, e o Dockerfile, o Compose e os exemplos do README (Podman, Quadlet, probes) chamam `healthcheck`. Os intervalos (30s/5s/15s/3) se repetem nesses lugares.
- **O `.dockerignore` é uma allowlist** (`*` e depois `!…`): um arquivo novo copiado pelo Dockerfile precisa ser liberado ali.
- **`docker-entrypoint.d/*.sh`**: `sh` POSIX, copiado com modo 644 (não executável) para ser carregado com `source` sob `set -e`, de modo que `umask` e `export`s cheguem ao uWSGI; use `exit 1` para abortar a inicialização. Um script executável roda em processo à parte e não tem esse efeito.
- **`conf/mapproxy/mapproxy.yaml`** dos exemplos usa a substituição de variáveis do MapProxy (`${VAR}`), que não tem sintaxe de valor padrão e só funciona em valores, não em chaves; toda variável usada precisa estar definida no `environment` do Compose.
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
| `limit_conn` por IP | 20 conexões simultâneas por IP, com rejeição 429; o `examples/README.md` alerta sobre NAT e balanceadores |
| `expires_hours: 24` | Os serviços mudam pouco. No `cache-file`, o nginx não tem cache próprio (lê o do MapProxy): limpe com o cleanup do `mapproxy-seed` ou apagando arquivos do volume. No `cache-couchdb`: `docker compose restart nginx` |
| Tiles servidos do disco pelo nginx (`cache-file`) | Um cache só (o do MapProxy), no lugar do `uwsgi_cache`; desempenho igual ao do `uwsgi_cache` medido em 25/10/2026 |
| CVEs no `pip` vendored | Risco aceito e documentado no README, com um Dockerfile derivado para quem precisar remover o `pip` |
