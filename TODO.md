# TODO

Pendências do projeto, levantadas em 20/10/2026 e revisadas em 27/10/2026 (imagem base `ndscprm/gdal:3.12.4-py3.12`). Os itens concluídos são removidos; o histórico fica no git.

Legenda: 🔴 alta · 🟠 média · ⚪ baixa

## CI

- [ ] ⚪ **Dependabot e workflow reutilizável por `@main`.** As actions agora ficam no workflow reutilizável do gdal-oci, fixadas por SHA e atualizadas pelo Dependabot de lá, mas o `uses:` aponta para `@main`: um commit no gdal-oci muda o CI daqui sem revisão. Quando houver uma tag do workflow, fixar o `uses:` nela (ou no SHA) e criar um `.github/dependabot.yml` com os ecossistemas `github-actions`, `docker` e `pip`.

## Build

- [ ] ⚪ **Reprodutibilidade.** Dependências transitivas sem pin (certifi, Werkzeug e outras), e as dependências de build dos pacotes do `NO_BINARY` (pyproj e shapely: Cython, setuptools...) sem versão fixa nem hash; o numpy e os outros pacotes da base já entram como restrição. O pygeoapi-oci resolve isso com locks com hashes por versão, inclusive um lock das dependências de build passado como `--build-constraint`. As imagens base são passadas pelo nome completo: o padrão do Dockerfile são as tags móveis, republicadas toda semana; no CI, o gdal-oci passa as tags datadas com o digest.
- [ ] ⚪ **Compilar o Pillow e o lxml contra as bibliotecas do sistema.** Hoje só o pyproj e o shapely estão no `NO_BINARY`. O Pillow e o lxml usam as wheels do PyPI, que embutem cópias próprias: o Pillow traz cerca de 20 bibliotecas em `pillow.libs` (freetype, libjpeg, libtiff, libwebp, lcms2, openjpeg, harfbuzz, libavif...), e o lxml traz a libxml2 e a libxslt linkadas estáticas. Essas cópias só são atualizadas quando o pacote muda de versão, e não recebem as correções do Debian no rebuild semanal da base. Em 28/10/2026, compilar os dois (`NO_BINARY=pyproj,shapely,Pillow,lxml`) foi testado e funcionou:
  - a `-devel` tem os headers de todas as bibliotecas, mas o `release` precisa instalar com `apt-get` as de runtime que a base não tem (confirmado com `ldd`): `libfreetype6`, `liblcms2-2`, `libopenjp2-7`, `libwebpdemux2`, `libwebpmux3` e `libxcb1` (Pillow) e `libxslt1.1` (lxml, inclui a libexslt; puxa `libgcrypt20` e `libgpg-error0`);
  - o Pillow compilado fica sem AVIF, raqm e libimagequant, que a base não oferece; o lxml passa a usar a libxml2 2.9.14 do Debian, bem mais antiga que a embutida na wheel, mas com as correções de segurança do Debian;
  - o teste de fumaça precisaria voltar a importar as extensões do Pillow (`ImageFont`, `ImageCms`) e o `lxml.etree`, e a falhar com qualquer `<pacote>.libs` carregado, exceto o `numpy.libs` da base;
  - imagem de 709 MB, contra 728 MB só com o pyproj e o shapely; a compilação dos quatro leva cerca de 6,5 minutos em amd64.
- [ ] ⚪ **Atualizações disponíveis** (sem CVEs nas versões atuais): pyproj 3.8.0, shapely 2.2.0, redis 8.1.0 (major). O Dependabot automatizaria o aviso.

## Ordem sugerida

1. Dependabot.
2. O restante conforme houver tempo.
