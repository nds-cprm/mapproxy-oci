# TODO

Pendências do projeto, levantadas em 20/10/2026 e revisadas em 25/10/2026 (imagem base `ndscprm/gdal:3.12.4-py3.12`). Os itens concluídos são removidos; o histórico fica no git.

Legenda: 🔴 alta · 🟠 média · ⚪ baixa

## Imagem

- [ ] ⚪ **Configuração de exemplo gerada no build.** O `mapproxy-util create` do Dockerfile já deixa um `mapproxy.yaml` na imagem, então num `docker run` sem config o entrypoint não gera nada e não imprime as notas `NOTE:` de "só para testes". O README diz que o container gera a configuração na inicialização. Ou remover a geração do build, ou ajustar o texto.

## CI

- [ ] ⚪ **Dependabot e workflow reutilizável por `@main`.** As actions agora ficam no workflow reutilizável do gdal-oci, fixadas por SHA e atualizadas pelo Dependabot de lá, mas o `uses:` aponta para `@main`: um commit no gdal-oci muda o CI daqui sem revisão. Quando houver uma tag do workflow, fixar o `uses:` nela (ou no SHA) e criar um `.github/dependabot.yml` com os ecossistemas `github-actions`, `docker` e `pip`.

## Build

- [ ] ⚪ **Reprodutibilidade.** Dependências transitivas sem pin (numpy, certifi, Werkzeug e outras) e imagens base fixadas por tag, não por digest. A `ndscprm/gdal` é republicada com a mesma tag.
- [ ] 🟠 **Módulos compilados contra as bibliotecas do sistema (`--no-binary`).** As wheels do PyPI trazem as próprias cópias das bibliotecas nativas (PROJ no pyproj, GEOS no shapely, libjpeg/libpng/libtiff/freetype no Pillow, libxml2/libxslt no lxml), que podem divergir das usadas pela `libgdal` da imagem base (ex.: dois `proj.db`) e não recebem as correções de segurança do rebuild semanal da base. Avaliar `pip wheel --no-binary <pacotes>` no estágio `build`, que já tem os compiladores e os headers, para que os módulos usem as libs da `ndscprm/gdal`. Verificar: quais libs cada pacote embute hoje e quais a base oferece (e em que prefixo, para `PROJ_DIR`/`GEOS_CONFIG`), o tempo de build no arm64, e acrescentar ao teste de fumaça do `release` uma checagem das versões vinculadas (ex.: `pyproj.proj_version_str` igual à PROJ da GDAL).
- [ ] ⚪ **Atualizações disponíveis** (sem CVEs nas versões atuais): pyproj 3.8.0, shapely 2.2.0, redis 8.1.0 (major). O Dependabot automatizaria o aviso.

## Exemplo (Compose / nginx)

- [ ] ⚪ **Nível de log do `limit_conn`.** Cada rejeição gera uma linha `[error]` no log do nginx; acrescentar `limit_conn_log_level warn;` ao `conf/nginx/nginx.conf` dos dois exemplos.

## Ordem sugerida

1. Dependabot.
2. O restante conforme houver tempo.
