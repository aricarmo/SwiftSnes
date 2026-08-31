# NotchSnes

A Super Nintendo emulator written in Swift that lives in the MacBook notch.
The panel blends into the display cutout: hover to peek at the game title and
FPS, click to expand the game, pin with `⌘⇧P` to keep the keyboard captured.

![macOS 15.4+](https://img.shields.io/badge/macOS-15.4%2B-black) ![Swift 5](https://img.shields.io/badge/Swift-5-orange)

## Features

- 65C816 CPU, PPU (modes 0–7, sprites, HDMA), APU (SPC700 + S-DSP with BRR/ADSR/echo)
- LoROM, HiROM and ExHiROM mappers with score-based header detection
- Emulated DSP-1/1B/2/3/4 coprocessor (NEC µPD77C25) — firmware supplied by the user
- 32 kHz audio through `AVAudioSourceNode` with a lock-free ring buffer
- Automatic SRAM saves (`.srm`) in `~/Library/Application Support/NotchSnes/saves/`
- Recent ROMs with sandbox bookmarks, drag-and-drop, remappable keys
- Accessory app (no Dock or menu bar presence), sandbox enabled

## Build

Requires Xcode 26 and macOS 15.4+.

```sh
xcodebuild -project NotchSnes.xcodeproj -scheme NotchSnes -configuration Release build
```

Or open `NotchSnes.xcodeproj` and run the `NotchSnes` scheme.

To open a ROM straight at launch (handy for development):

```sh
SNES_ROM=/path/to/game.sfc ./NotchSnes.app/Contents/MacOS/NotchSnes
```

## Coprocessor firmware

Games using DSP-1..4 (Super Mario Kart, Pilotwings, Dungeon Master…) need a
dump of the chip. **The firmware is not distributed with the app.** Put the
files in:

```
~/Library/Application Support/NotchSnes/bios/
```

Accepted formats: `dspN.program.rom` + `dspN.data.rom` (ares/higan style) or
the combined 8 KiB `SNES_dspN.rom` (Snes9x/bsnes style). Files are identified
by SHA-256, so the name doesn't matter. The firmware folders of ares, bsnes,
higan and Snes9x are also searched. The `SNES_DSP_FIRMWARE_DIR` variable
(`:`-separated list) adds extra directories.

Without the firmware the game still loads, but the coprocessor answers with
empty values.

## Default controls

| SNES | Key |
|---|---|
| D-pad | Arrow keys |
| B / A | Z / X |
| Y / X | A / S |
| L / R | Q / W |
| Start / Select | Return / Space |
| Pin panel | ⌘⇧P (global) |
| Close settings / release | Esc |

Everything is remappable in the settings panel (gear icon).

## Code layout

```
snes/
├── core/            pure emulation, no AppKit/SwiftUI
│   ├── CPU/         65C816
│   ├── PPU/         video
│   ├── APU/         SPC700, S-DSP, audio output
│   ├── Memory/      bus, cartridge, DMA/HDMA
│   └── Coprocessor/ µPD77C25 (DSP-1..4)
├── UI/              notch panel (AppKit + SwiftUI)
│   └── Notch/       view sections: header, game, empty, settings
├── EmulatorViewModel.swift   ROM lifecycle and frame loop
└── SRAMStore.swift           save persistence
```

Logs: `log stream --predicate 'subsystem == "com.ari.NotchSnes"'`.

## License

To be defined.
