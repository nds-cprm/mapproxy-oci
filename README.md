# mapproxy-oci

Imagem de container OCI para o [MapProxy](https://mapproxy.org), servido pelo uWSGI.

- MapProxy 7 sobre Python 3.12, GDAL 3.12 e Debian trixie (imagem base [`ndscprm/gdal`](https://hub.docker.com/r/ndscprm/gdal): `3.12.4-py3.12`, e `3.12.4-py3.12-devel` no estágio de build)
- Roda como usuário não-root (`1000:0`) e aceita UID arbitrário (OpenShift)
- Funciona com sistema de arquivos raiz somente leitura
- Configuração por `mapproxy.yaml`, variáveis de ambiente e volumes
- Healthcheck que detecta workers travados
- Imagens `linux/amd64` e `linux/arm64`

Imagem publicada: [`ndscprm/mapproxy`](https://hub.docker.com/r/ndscprm/mapproxy), com duas tags por build:

| Tag | Exemplo | Comportamento |
|---|---|---|
| `<versão do MapProxy>` | `7.0.0` | **Móvel**: republicada todo mês com as correções de segurança. Recomendada para uso geral |
| `<versão>-<AAAAMMDD>` | `7.0.0-20261101` | **Imutável**: cada build mantém a sua. Use para fixar uma imagem exata ou para voltar a uma versão anterior |

A tag com data só muda se o workflow rodar duas vezes no mesmo dia (por exemplo, um disparo manual depois do rebuild agendado). Para garantir uma imagem exata, fixe também o digest (`ndscprm/mapproxy@sha256:…`).

## Início rápido

```sh
docker run -d --name mapproxy -p 8000:8000 ndscprm/mapproxy:7.0.0
```

Sem configuração própria, o container gera uma configuração de exemplo em `/var/lib/mapproxy/config`. **Ela serve só para testes**: tem a página `demo` habilitada e placeholders (`${server}`, `$layer`) que geram avisos no log.

A porta 8000 fala o **protocolo uwsgi**, não HTTP. Para acessar pelo navegador, use um proxy reverso (ver [Rede](#rede)) ou um dos [exemplos com Docker Compose](examples/README.md).

## Exemplos com Docker Compose

O diretório [`examples/`](examples/README.md) traz exemplos de produção prontos: MapProxy atrás de nginx, rootfs somente leitura, limites de recursos, logs com rotação e tarefas de seed. A documentação deles, com o `docker-compose.yaml` comentado, está em [`examples/README.md`](examples/README.md).

| Exemplo | Cache de tiles |
|---|---|
| [`cache-file`](examples/README.md#cache-file) | Arquivos num volume; o nginx serve os tiles direto do disco |
| [`cache-couchdb`](examples/README.md#cache-couchdb) | Banco CouchDB; o nginx mantém um cache próprio |

## Configuração

### Diretório de configuração

O MapProxy lê `$HOME/mapproxy.yaml`. Na imagem, `HOME=/var/lib/mapproxy/config`. Se você mudar `HOME`, muda também o lugar onde a configuração é lida e gerada.

Na inicialização, o entrypoint da imagem base (`/docker-entrypoint.sh`) carrega os scripts de `/docker-entrypoint.d` em ordem e depois executa o uWSGI. O [`20-mapproxy.sh`](docker-entrypoint.d/20-mapproxy.sh), deste projeto:
- usa `$HOME/mapproxy.yaml`, se existir;
- se não existir, gera a configuração de exemplo em `$HOME` e imprime um aviso de que ela é só para testes;
- se não existir e `$HOME` não for gravável, encerra com uma mensagem de erro explicando o problema.

Em produção, forneça seu próprio `mapproxy.yaml`, montando o arquivo ou o diretório por volume, bind mount ou ConfigMap.

Para rodar outras tarefas na inicialização, monte scripts `.sh` adicionais em `/docker-entrypoint.d`. Os executáveis rodam num processo à parte; os não executáveis são carregados com `source` pelo `sh`, e as variáveis que eles exportam chegam ao uWSGI. Um script que falha impede o container de iniciar.

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

Por padrão, o MapProxy grava o cache em `cache_data/`, ao lado do `mapproxy.yaml`. Em produção, prefira um volume próprio para o cache, apontado por `globals.cache.base_dir`, como no exemplo [`cache-file`](examples/README.md#cache-file). Assim a configuração, pequena e versionável, fica separada do cache, grande e descartável.

### Página demo

A página `/demo/` existe só se o `mapproxy.yaml` tiver `demo:` em `services`. A configuração de exemplo tem; o próprio MapProxy recomenda desligá-la em produção.

## Usuário e permissões

- A imagem roda como `1000:0`.
- **UID arbitrário** (OpenShift, `--user`) é suportado. O GID deve ser `0`.
- Quando a UID não existe no `/etc/passwd`, o script `10-enable-nss-wrapper.sh` da imagem base a registra via nss_wrapper com o nome `mapproxy` (variável `USER_NAME`), e `whoami` e as consultas de nome funcionam no uWSGI. O registro vale só para os processos iniciados pelo entrypoint; num `docker exec`, o usuário aparece sem nome. O Podman já acrescenta a UID ao `/etc/passwd` do container, e nesse caso o nss_wrapper não é necessário.
- **Volumes graváveis** (configuração, cache) precisam permitir escrita ao UID do container ou ao grupo `0`:
  - Kubernetes: `securityContext.fsGroup`;
  - Docker/Podman: prepare o volume, como faz o serviço `cache-init` do exemplo [`cache-file`](examples/README.md#cache-file).
- Arquivos criados pelo container ficam graváveis pelo grupo (`umask 002`).

### Sistema de arquivos raiz somente leitura

Suportado (`read_only: true`, `--read-only`, `readOnlyRootFilesystem: true`), desde que `/tmp` seja gravável (`tmpfs` ou `emptyDir`):
- o nss_wrapper grava o registro do usuário no `/tmp`. Sem ele, o container não inicia quando a UID não existe no `/etc/passwd` (Docker, Kubernetes, OpenShift);
- requisições POST com corpo acima de 64 KB também usam o `/tmp`.

## Rede

O uWSGI escuta em `0.0.0.0:8000` com o **protocolo uwsgi**. Use um proxy reverso; no nginx:

```nginx
location / {
    include uwsgi_params;
    uwsgi_pass mapproxy:8000;
}
```

Para servir **HTTP direto**, sobrescreva `/var/lib/uwsgi/uwsgi.conf` com uma cópia que use `http-socket = :8000` no lugar de `socket`. O healthcheck padrão fala o protocolo uwsgi, então substitua também o `/usr/local/bin/healthcheck` (veja [Healthcheck](#healthcheck)). Outra opção é manter o `socket` e acrescentar um `http-socket` em outra porta.

### HTTPS, proxies e subcaminho

O MapProxy monta as URLs absolutas dos documentos de capabilities (WMS, WMTS e TMS) a partir do pedido. Ele não tem uma opção de URL pública fixa: as URLs saem certas quando o pedido chega com as informações certas.

| Cenário | O que fazer | URL gerada |
|---|---|---|
| TLS no próprio nginx (`listen ... ssl`) | Nada: o `uwsgi_params` envia `HTTPS=on`, e o uWSGI passa o esquema `https` ao MapProxy | `https://<host>/service` |
| Terminador TLS ou balanceador na frente do nginx | O proxy externo envia `X-Forwarded-Proto: https` (e, se trocar o `Host`, `X-Forwarded-Host`). O nginx repassa esses cabeçalhos sem configuração extra | `https://<X-Forwarded-Host>/service` |
| Publicação num subcaminho (`/mapproxy/`) | Enviar `X-Script-Name` com o prefixo; o MapProxy o retira do caminho e o acrescenta às URLs | `https://<host>/mapproxy/service` |

O `X-Forwarded-Host` precisa incluir a porta pública, se ela não for a padrão. Sem ele, o MapProxy usa o `Host` recebido, e um proxy externo que reescreve o `Host` para `nginx:8080` gera URLs com esse endereço interno.

Para o subcaminho, no nginx:

```nginx
location /mapproxy/ {
    # uwsgi_param in a location drops the ones inherited from server: include them again
    include uwsgi_params;
    uwsgi_param HTTP_X_SCRIPT_NAME /mapproxy;
    uwsgi_pass mapproxy;
}
```

- O `include uwsgi_params` dentro do `location` é obrigatório. Qualquer `uwsgi_param` num bloco cancela os herdados do nível de cima, e o MapProxy, sem `PATH_INFO` e `QUERY_STRING`, responde a página "Welcome to MapProxy" para qualquer pedido.
- Nos [exemplos](examples/README.md#subcaminho), os `location` de tiles também precisam do prefixo.
- Se o proxy externo já envia `X-Script-Name`, o nginx o repassa e o `location` acima não é necessário.

Como o nginx repassa esses cabeçalhos do cliente, quem acessa o nginx diretamente pode alterar as URLs dos capabilities que *ele mesmo* recebe. Isso não afeta outros usuários: o nginx não guarda os capabilities, e os tiles não contêm URLs. Para fixar os valores mesmo assim, defina-os com `uwsgi_param` (por exemplo, `uwsgi_param HTTP_X_FORWARDED_PROTO https;`), seguindo a mesma regra do `include uwsgi_params`.

Verificado em 25/10/2026, com o exemplo [`cache-file`](examples/README.md#cache-file), TLS autoassinado no nginx e `/mapproxy/` como subcaminho, combinados entre si.

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

A imagem traz o comando [`healthcheck`](docker/healthcheck) (em `/usr/local/bin`), que roda `uwsgi --socket 127.0.0.1:8000 --nagios`: um ping no protocolo uwsgi respondido por um worker. Ele falha se nenhum worker estiver atendendo.

O `HEALTHCHECK` do Dockerfile não é suportado por todos os runtimes: o Podman o ignora em imagens no formato OCI, como as publicadas, e o Kubernetes nunca o usa. Por isso o comando é o mesmo em todos os runtimes, mas cada um precisa declarar o seu healthcheck:

| Runtime | Onde declarar | Quando o check falha |
|---|---|---|
| `docker run` | `HEALTHCHECK` da imagem (automático) | só marca `unhealthy` |
| Docker Compose / `podman compose` | `healthcheck:` no Compose, como nos [exemplos](examples/README.md) | só marca `unhealthy` (Docker) |
| Podman | `--health-cmd` ou Quadlet | pode reiniciar com `--health-on-failure` / `HealthOnFailure=` |
| Kubernetes / OpenShift | probes `exec` | a liveness reinicia o container; a readiness tira o pod do Service |

O Docker e o Compose **não reiniciam** containers `unhealthy`: o healthcheck só marca o estado, e a política de `restart` age só quando o processo termina. Na prática, o uWSGI já mata workers travados (`harakiri`) e o container termina se o processo master morrer.

- **Podman:**
  ```sh
  podman run -d --health-cmd healthcheck --health-interval 30s \
    --health-start-period 15s --health-on-failure restart ndscprm/mapproxy:7.0.0
  ```
  No Quadlet (`.container`):
  ```ini
  [Container]
  HealthCmd=healthcheck
  HealthInterval=30s
  HealthTimeout=5s
  HealthStartPeriod=15s
  HealthRetries=3
  HealthOnFailure=restart
  ```
  O Podman executa os checks por timers do systemd. Sem systemd (como em alguns ambientes de CI), eles não rodam sozinhos; use `podman healthcheck run <container>`.
- **Kubernetes / OpenShift** (o `podman kube play` também aceita):
  ```yaml
  startupProbe:
    exec:
      command: ["healthcheck"]
    periodSeconds: 5
    failureThreshold: 6
  livenessProbe:
    exec:
      command: ["healthcheck"]
    periodSeconds: 30
    timeoutSeconds: 5
  readinessProbe:
    exec:
      command: ["healthcheck"]
    periodSeconds: 10
    timeoutSeconds: 5
  ```

Para mudar a verificação (por exemplo, ao servir HTTP), substitua `/usr/local/bin/healthcheck` por um arquivo montado ou numa imagem derivada; as declarações acima continuam valendo.

## Construindo a imagem

```sh
docker build -t mapproxy:local .
# outra versão do MapProxy:
docker build --build-arg MAPPROXY_VERSION=7.0.0 -t mapproxy:local .
```

| Build arg | Padrão |
|---|---|
| `MAPPROXY_VERSION` | `7.0.0` |
| `GDAL_VERSION` | `3.12.4` |
| `PYTHON_VERSION` | `3.12` |
| `MAPPROXY_BASE_DIR` | `/var/lib/mapproxy` |

### Atualizando a versão do MapProxy

A versão padrão fica no `ARG MAPPROXY_VERSION` do [`Dockerfile`](Dockerfile). O workflow lê esse valor quando nenhuma versão é informada no disparo manual, e também no rebuild mensal. Para mudar de versão:

1. Altere `ARG MAPPROXY_VERSION=` no `Dockerfile`, mantendo o formato `X.Y.Z`.
2. Atualize a tag padrão nos `docker-compose.yaml` de `examples/` e os exemplos deste README e do [`examples/README.md`](examples/README.md). Para achar todas as ocorrências: `grep -rn "7\.0\.0" --exclude-dir=.git .`
3. Rode o build localmente e confira se as dependências do `requirements.txt` continuam compatíveis.
4. Faça o commit e dispare o workflow, ou aguarde o rebuild mensal.

Para publicar outra versão sem mudar o padrão, informe-a no campo `mapproxy_version` ao disparar o workflow manualmente.

As dependências Python ficam fixadas em [`requirements.txt`](requirements.txt). O workflow [`docker-image.yml`](.github/workflows/docker-image.yml) constrói e publica as imagens `amd64` e `arm64` e analisa CVEs com o Docker Scout.

## Segurança e atualizações

- **Rebuild mensal:** o workflow reconstrói a imagem no dia 1 de cada mês, sem cache de camadas, e republica a mesma tag com as correções de segurança disponíveis nas imagens base e nos pacotes Debian e Python. Para receber as atualizações, rode `docker compose pull && docker compose up -d` (ou o equivalente no seu ambiente).
- **Análise de vulnerabilidades:** cada build é analisado pelo Docker Scout, e o resultado aparece na aba *Security* do repositório.

### Vulnerabilidades conhecidas e aceitas

O `pip` 26.2.2 (versão verificada em 20/10/2026) traz cópias embutidas (*vendored*) de algumas bibliotecas em versões com CVEs conhecidas. Ele está no venv onde o MapProxy é instalado (`/opt/geosgb/venv`, da imagem base), e o Python do sistema traz outra cópia no `ensurepip`:

| Biblioteca embutida | Versão | CVEs altas |
|---|---|---|
| `urllib3` | 2.7.0 | 2 |
| `msgpack` | 1.1.2 | 1 |
| `setuptools` (`pkg_resources`) | 70.3.0 | 1 |

**O risco foi aceito**, porque esse código só é executado quando alguém roda o `pip`. O MapProxy e o uWSGI não o usam: o `urllib3` usado pelo MapProxy é outra instalação, já na versão corrigida (2.8.0). Na prática, o risco se limita a quem executar `pip install` dentro do container, o que não faz parte do uso normal da imagem.

Essa decisão será revista quando sair um `pip` com as dependências embutidas atualizadas. O `pip` vem da imagem base `ndscprm/gdal`, então ele é atualizado quando uma nova versão dela trouxer um `pip` novo, o que o rebuild mensal incorpora. Se a sua política de segurança não aceitar esses achados, uma imagem derivada pode remover o `pip`:

```dockerfile
FROM ndscprm/mapproxy:7.0.0
USER 0
RUN /opt/geosgb/venv/bin/python -m pip uninstall -y pip && \
    rm -rf /usr/local/lib/python3*/ensurepip
USER 1000:0
```

## Licença

[Apache License 2.0](LICENSE). Veja [`NOTICE`](NOTICE) para autoria e avisos.

Este software é fornecido "no estado em que se encontra", sem garantia de qualquer tipo e sem compromisso de manutenção, suporte ou atualização.

O MapProxy é © Omniscale e colaboradores, também sob a Apache License 2.0.
