# Changelog

Todas as mudanças notáveis de cada versão do Muesli para macOS são documentadas aqui e publicadas automaticamente nas Releases do GitHub.

## v1.4.7

### Português
- **Assinatura de código estável em builds locais:** `Scripts/build-app.sh` detecta automaticamente certificados locais (`Developer ID Application` ou `Apple Development`), preservando permissões (Microfone e Gravação de Áudio do Sistema) e acesso às Chaves entre atualizações locais (com fallback ad-hoc no CI).
- **Chaves de API consolidadas no Keychain:** todas as chaves de IA e STT passam a ser salvas em um único item (`api-keys-v1`), com migração automática dos itens antigos, evitando múltiplos prompts seguidos de senha.
- **Instalação única sem duplicatas:** `make install` move `build/Muesli.app` para `~/Applications/Muesli.app` e atualiza o registro no LaunchServices para evitar conflitos entre cópias antigas no macOS.

### English
- **Stable code signing for local builds:** `Scripts/build-app.sh` automatically detects local signing certificates (`Developer ID Application` or `Apple Development`) to preserve TCC permissions (Microphone and Screen & System Audio Recording) and Keychain ACLs across local updates (with ad-hoc fallback in CI).
- **Consolidated Keychain storage:** all AI and STT API keys are now stored in a single Keychain item (`api-keys-v1`) with automatic migration from legacy per-provider items, avoiding repeated password prompts.
- **Single canonical app installation:** `make install` moves `build/Muesli.app` to `~/Applications/Muesli.app` and refreshes LaunchServices registration to prevent conflicts with duplicate app bundles.

## v1.4.6

### Português
- **Correção no cancelamento de eco (`AUVoiceIO`):** substituído o uso de `mainMixerNode` (que falhava com erro `-10875` no macOS 27) por um `AVAudioPlayerNode` mudo conectado ao `outputNode`.
- **Estabilidade na inicialização do processamento de voz:** `MicRecorder` agora aguarda e trata a troca inicial de configuração (`AVAudioEngineConfigurationChange`) até o primeiro buffer de áudio chegar.
- **Conversão de canais discretos:** `StreamConverter` passa a mapear explicitamente o canal `0` (`channelMap = [0]`) em entradas multicanal discretas do `AUVoiceIO`, evitando áudio silencioso.
- **Reset automático de estado antigo:** migrada a flag `vpKnownBad` para `vpKnownBadV2` e adicionado aviso nas Configurações quando o processamento de voz falhar.

### English
- **Echo cancellation (`AUVoiceIO`) fix:** replaced `mainMixerNode` (which failed with `-10875` on macOS 27) with a muted `AVAudioPlayerNode` connected to `outputNode`.
- **Voice-processing bring-up resilience:** `MicRecorder` now handles the initial `AVAudioEngineConfigurationChange` and waits for the first audio buffer before adopting the engine.
- **Discrete multi-channel audio conversion:** `StreamConverter` explicitly maps channel `0` (`channelMap = [0]`) for discrete multi-channel `AUVoiceIO` inputs instead of producing silence.
- **Clean retry state:** migrated `vpKnownBad` to `vpKnownBadV2` and added a Settings status hint when voice processing fails.

## v1.4.5

### Português
- **Visual:** atualizado o ícone do aplicativo para fundo preto (`AppIcon.icns`) e alinhada a versão `1.4.5`.

### English
- **Visual:** updated the app icon to a black background (`AppIcon.icns`) and bumped the version to `1.4.5`.

## v1.4.4

### Português
- **Documentação e UI:** atualizadas capturas de tela no tema escuro no README, corrigido o fundo do `SetupSheet` e alinhada a versão `1.4.4`.

### English
- **Docs & UI:** updated dark-mode README screenshots, fixed `SetupSheet` background styling, and aligned version `1.4.4`.

## v1.3.0

### Português
- **Categorias e privacidade:** adicionada organização de reuniões por categorias e melhorias nos avisos/controles de privacidade durante gravações.

### English
- **Categories & privacy:** added meeting categories organization and improved recording privacy notices/controls.

## v1.2.2

### Português
- **Correções de janela e gravação:** corrigida a reabertura da janela principal, a abertura de Configurações e o timer de gravação.

### English
- **Window & recording fixes:** fixed reopening the main window, opening Settings, and the recording timer.

## v1.2.1

### Português
- **Compatibilidade com 9router e modelos de raciocínio:** suporte completo a `stream: false`, fallback SSE e `max_tokens`.

### English
- **9router & reasoning model compatibility:** full support for `stream: false`, SSE fallback, and `max_tokens`.

## v1.2.0

### Português
- **Transcrição na nuvem:** adicionada transcrição via API na nuvem (Groq, OpenAI e OpenRouter) com envio em lotes, suporte a múltiplas chaves e fallback automático para Whisper local.

### English
- **Cloud transcription:** added cloud STT support (Groq, OpenAI, and OpenRouter) with batch processing, multi-key rotation, and automatic local Whisper fallback.

## v1.1.0

### Português
- **Paridade visual e provedores de IA:** alinhamento visual/funcional com o Muesli Windows e suporte a Groq, Gemini, OpenAI, Anthropic, Ollama e rotação de múltiplas chaves.

### English
- **Visual parity & AI providers:** visual/functional parity with Muesli Windows plus support for Groq, Gemini, OpenAI, Anthropic, Ollama, and multi-key rotation.

## v1.0.0

### Português
- **Lançamento inicial estruturado:** suporte a PT-BR, exportação SESI/Obsidian, OpenAI/9router e pipeline de release automatizada no GitHub Actions.

### English
- **Initial structured release:** PT-BR localization, SESI/Obsidian export, OpenAI/9router support, and automated GitHub Actions release pipeline.
