# NotchSnes

Emulador de Super Nintendo escrito em Swift que vive no notch do MacBook.
O painel se funde ao entalhe da tela: passe o cursor para espiar o título e o
FPS, clique para expandir o jogo, fixe com `⌘⇧P` para manter o teclado capturado.

![macOS 15.4+](https://img.shields.io/badge/macOS-15.4%2B-black) ![Swift 5](https://img.shields.io/badge/Swift-5-orange)

## Recursos

- CPU 65C816, PPU (modos 0–7, sprites, HDMA), APU (SPC700 + S-DSP com BRR/ADSR/echo)
- Mappers LoROM, HiROM e ExHiROM com detecção de header por pontuação
- Coprocessador DSP-1/1B/2/3/4 (NEC µPD77C25) emulado — firmware fornecido pelo usuário
- Áudio a 32 kHz via `AVAudioSourceNode` com ring buffer lock-free
- Save de SRAM (`.srm`) automático em `~/Library/Application Support/NotchSnes/saves/`
- ROMs recentes com bookmarks de sandbox, drag-and-drop, teclas configuráveis
- App acessório (sem Dock nem barra de menus), sandbox ligado

## Build

Requer Xcode 26 e macOS 15.4+.

```sh
xcodebuild -project NotchSnes.xcodeproj -scheme NotchSnes -configuration Release build
```

Ou abra `NotchSnes.xcodeproj` e rode o scheme `NotchSnes`.

Para abrir uma ROM direto no launch (útil em desenvolvimento):

```sh
SNES_ROM=/caminho/jogo.sfc ./NotchSnes.app/Contents/MacOS/NotchSnes
```

## Firmware de coprocessador

Jogos com DSP-1..4 (Super Mario Kart, Pilotwings, Dungeon Master…) precisam do
dump do chip. **O firmware não é distribuído com o app.** Coloque os arquivos em:

```
~/Library/Application Support/NotchSnes/bios/
```

Formatos aceitos: `dspN.program.rom` + `dspN.data.rom` (estilo ares/higan) ou o
combinado `SNES_dspN.rom` de 8 KiB (estilo Snes9x/bsnes). Os arquivos são
identificados por SHA-256, então o nome não importa. As pastas de firmware do
ares, bsnes, higan e Snes9x também são consultadas. A variável
`SNES_DSP_FIRMWARE_DIR` (lista separada por `:`) adiciona outros diretórios.

Sem o firmware o jogo carrega, mas o coprocessador responde com valores vazios.

## Controles padrão

| SNES | Tecla |
|---|---|
| Direcional | Setas |
| B / A | Z / X |
| Y / X | A / S |
| L / R | Q / W |
| Start / Select | Return / Espaço |
| Fixar painel | ⌘⇧P (global) |
| Fechar ajustes / soltar | Esc |

Tudo é reconfigurável no painel de ajustes (ícone de engrenagem).

## Organização do código

```
snes/
├── core/            emulação pura, sem AppKit/SwiftUI
│   ├── CPU/         65C816
│   ├── PPU/         vídeo
│   ├── APU/         SPC700, S-DSP, saída de áudio
│   ├── Memory/      barramento, cartucho, DMA/HDMA
│   └── Coprocessor/ µPD77C25 (DSP-1..4)
├── UI/              painel do notch (AppKit + SwiftUI)
│   └── Notch/       seções da view: cabeçalho, jogo, vazio, ajustes
├── EmulatorViewModel.swift   ciclo de vida da ROM e laço de frames
└── SRAMStore.swift           persistência de saves
```

Logs: `log stream --predicate 'subsystem == "com.ari.NotchSnes"'`.

## Licença

A definir.
