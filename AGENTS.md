# Diretrizes do Repositório Muesli

## Lançamento de Nova Versão e Instalação Local
Sempre que uma nova versão do Muesli for publicada/enviada ao GitHub (commit de versão + tag `v*` + `git push`):

1. Atualize a versão de forma consistente em `Sources/Muesli/Support/AppVersion.swift` (`AppVersion.current`) e `Support/Info.plist` (`CFBundleShortVersionString` e `CFBundleVersion`).
2. Registre o que mudou, foi adicionado ou foi corrigido em `CHANGELOG.md` na seção `## vX.Y.Z`, com os blocos `### Português` primeiro e `### English` logo em seguida (em bullets claros para usuários); o workflow do GitHub publica automaticamente essa seção como descrição da release.
3. Execute `swift test` e garanta que todos os testes passem antes do commit/tag.
4. Após enviar o commit e a tag para o GitHub, execute `make install` no diretório do projeto para compilar o `.app` de release e instalá-lo localmente em `~/Applications/Muesli.app`.
   - Caso o processo `Muesli` já esteja em execução, avise o usuário ou feche-o antes de substituir o bundle em `build/Muesli.app` / `~/Applications/Muesli.app`.
