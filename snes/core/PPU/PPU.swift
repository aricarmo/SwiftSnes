// PPU.swift
import Foundation
import CoreGraphics

final class PPU {
    private var registers: [UInt8] = Array(repeating: 0, count: 0x40)
    
    private var vram: [UInt8] = Array(repeating: 0, count: 0x10000)  // 64KB
    private var cgram: [UInt8] = Array(repeating: 0, count: 0x200)   // 512 bytes (256 colors)
    private var oam: [UInt8] = Array(repeating: 0, count: 0x220)     // 544 bytes
    
    private var frameBuffer: [UInt8] = Array(repeating: 0, count: 256 * 224 * 4)  // RGBA
    
    private var scanline: Int = 0
    private var cycle: Int = 0
    private var frameCount: Int = 0
    
    private weak var memory: MemoryBus?
    private weak var cpu: CPU65816?

    private var screenMode: Int = 0
    private var brightness: UInt8 = 0
    
    private var vramAddress: UInt16 = 0
    private var vramIncrement: UInt16 = 1
    private var vramRemapMode: UInt8 = 0
    private var vramReadBuffer: UInt16 = 0
    
    private var objSize: Int = 0  // Tamanho dos sprites
    private var objNameBase: UInt16 = 0  // Base address para sprite tiles
    private var objNameSelect: UInt16 = 0  // Gap entre tabelas de sprites
    
    private var oamAddress: UInt16 = 0   // endereço em bytes (0..0x21F)
    private var oamAddrLow: UInt8 = 0
    private var oamAddrHigh: UInt8 = 0
    private var oamHighTable: Bool = false
    private var oamFirstWrite: Bool = true
    private var oamWriteBuffer: UInt8 = 0
    private var oamReadBuffer: UInt8 = 0
    
    struct Sprite {
        var x: Int
        var y: Int
        var tile: UInt16
        var attributes: UInt8
        var size: Bool  // false = small, true = large
        
        var priority: Int { Int((attributes >> 4) & 0x03) }
        var paletteNumber: Int { Int((attributes >> 1) & 0x07) }
        var horizontalFlip: Bool { (attributes & 0x40) != 0 }
        var verticalFlip: Bool { (attributes & 0x80) != 0 }
    }
    
    private func getSprite(index: Int) -> Sprite? {
        guard index < 128 else { return nil }
        
        // Low table: 4 bytes por sprite
        let lowTableBase = index * 4
        let x = Int(oam[lowTableBase])
        let y = Int(oam[lowTableBase + 1])
        let tile = UInt16(oam[lowTableBase + 2])
        let attributes = oam[lowTableBase + 3]
        
        // High table: 2 bits por sprite
        let highTableIndex = 0x200 + (index / 4)
        let highTableShift = (index % 4) * 2
        let highBits = (oam[highTableIndex] >> highTableShift) & 0x03
        
        // Bit 0: MSB da posição X
        // Bit 1: Tamanho (0=small, 1=large)
        let xMSB = (highBits & 0x01) != 0
        let size = (highBits & 0x02) != 0
        
        return Sprite(
            x: x | (xMSB ? 0x100 : 0),
            y: y,
            tile: tile,
            attributes: attributes,
            size: size
        )
    }
    
    private func getSpriteDimensions(size: Bool) -> (width: Int, height: Int) {
        let sizes: [[(Int, Int)]] = [
            [(8, 8), (16, 16)],   // Mode 0
            [(8, 8), (32, 32)],   // Mode 1
            [(8, 8), (64, 64)],   // Mode 2
            [(16, 16), (32, 32)], // Mode 3
            [(16, 16), (64, 64)], // Mode 4
            [(32, 32), (64, 64)], // Mode 5
            [(16, 32), (32, 64)], // Mode 6
            [(16, 32), (32, 32)]  // Mode 7
        ]
        
        let sizeIndex = size ? 1 : 0
        return sizes[objSize][sizeIndex]
    }
    
    private struct BGConfig {
        var tilemapBase: UInt16 = 0
        var tilemapSize: Int = 0  // 0=32x32, 1=64x32, 2=32x64, 3=64x64
        var tileDataBase: UInt16 = 0
        var tileSize: Bool = false  // false=8x8, true=16x16
        var hScroll: Int = 0
        var vScroll: Int = 0
    }
    
    private var bgConfig: [BGConfig] = Array(repeating: BGConfig(), count: 4)
    
    private var bgEnabled: [Bool] = [false, false, false, false]
    private var objEnabled: Bool = false
    
    private var mosaicSize: Int = 0
    private var mosaicEnabled: [Bool] = [false, false, false, false, false] // BG1-4 + OBJ
    
    private var window1Left: UInt8 = 0
    private var window1Right: UInt8 = 0
    private var window2Left: UInt8 = 0
    private var window2Right: UInt8 = 0
    private var windowMaskBG: [UInt8] = [0, 0, 0, 0]
    private var windowMaskOBJ: UInt8 = 0
    private var windowMaskMath: UInt8 = 0
    
    private var colorMathEnabled: Bool = false
    private var colorMathMode: UInt8 = 0
    private var fixedColor: UInt16 = 0
    
    private var mainScreenLayers: UInt8 = 0
    private var subScreenLayers: UInt8 = 0
    
    private var mode7Matrix: [Int16] = [0x0100, 0, 0, 0x0100]  // [A, B, C, D]
    private var mode7CenterX: Int16 = 0
    private var mode7CenterY: Int16 = 0
    private var mode7FlipX: Bool = false
    private var mode7FlipY: Bool = false
    private var mode7Repeat: Bool = false
    private var mode7OutsideFill: Bool = false
    
    // BG3 com prioridade máxima no modo 1 (BGMODE bit 3)
    private var bg3Priority: Bool = false

    private var multiplyResult: UInt32 = 0
    
    private var cgramAddress: UInt8 = 0
    private var cgramLatchBit: Bool = false
    private var cgramLatch: UInt8 = 0
    
    private var m7PrevWrite: UInt8 = 0
    private var mode7HOfs: Int = 0   // 13 bits com sinal
    private var mode7VOfs: Int = 0
    private var bgPrevWrite: UInt8 = 0
    private var bgScrollLatch: UInt8 = 0
    private var bgScrollLatchBit: Bool = false
    
    private var hCounter: UInt16 = 0
    private var vCounter: UInt16 = 0
    private var latchedH: Bool = false
    private var latchedV: Bool = false
    private var hCounterLatched: UInt16 = 0
    private var vCounterLatched: UInt16 = 0
    
    private var ppu1OpenBus: UInt8 = 0
    private var ppu2OpenBus: UInt8 = 0
    
    private var inVBlank: Bool = false
    private var inHBlank: Bool = false
    private var nmiFlag: Bool = false
    private var irqFlag: Bool = false
    private var frameOddEven: Bool = false
    
    private var autoJoypadCounter: Int = 0
    
    init(memory: MemoryBus) {
        self.memory = memory
        reset()
    }

    func connectCPU(_ cpu: CPU65816) {
        self.cpu = cpu
    }

    func reset() {
        registers.fill(0)
        vram.fill(0)
        cgram.fill(0)
        oam.fill(0)
        frameBuffer.fill(0)

        scanline = 0
        cycle = 0
        frameCount = 0

        registers[0x00] = 0x8F  // Display off (force blank ativo)
        brightness = 15  // Brightness máximo para quando o force blank for desativado
        ppu1OpenBus = 0xFF
        ppu2OpenBus = 0xFF

    }
    
    func readRegister(_ address: UInt16) -> UInt8 {
        let reg = address & 0x3F
        
        switch reg {
        case 0x34:  // MPYL - Math multiply result (low)
            return UInt8(multiplyResult & 0xFF)
            
        case 0x35:  // MPYM - Math multiply result (middle)
            return UInt8((multiplyResult >> 8) & 0xFF)
            
        case 0x36:  // MPYH - Math multiply result (high)
            return UInt8((multiplyResult >> 16) & 0xFF)
            
        case 0x37:  // SLHV - Software latch H/V counter
            if !latchedH {
                hCounterLatched = hCounter
                latchedH = true
            }
            if !latchedV {
                vCounterLatched = vCounter
                latchedV = true
            }
            return ppu1OpenBus
            
        case 0x38:  // OAMDATAREAD - OAM data read
            let value = oamAddress < 0x200 ? oam[Int(oamAddress)] : oam[0x200 + Int(oamAddress & 0x1F)]
            oamAddress = (oamAddress + 1) % 0x220
            if oamAddress == 0 {
                oamHighTable = false
            }
            return value
            
        case 0x39:  // VMDATALREAD - VRAM data read (low)
            let value = UInt8(vramReadBuffer & 0xFF)
            if (registers[0x15] & 0x80) == 0 {
                incrementVRAMAddress()
                vramReadBuffer = readVRAMWord(vramAddress)
            }
            return value

        case 0x3A:  // VMDATAHREAD - VRAM data read (high)
            let value = UInt8((vramReadBuffer >> 8) & 0xFF)
            if (registers[0x15] & 0x80) != 0 {
                incrementVRAMAddress()
                vramReadBuffer = readVRAMWord(vramAddress)
            }
            return value
            
        case 0x3B:  // CGDATAREAD - CGRAM data read
            if !cgramLatchBit {
                cgramLatchBit = true
                cgramLatch = cgram[Int(cgramAddress) << 1]
                ppu2OpenBus = cgramLatch
            } else {
                cgramLatchBit = false
                ppu2OpenBus = cgram[(Int(cgramAddress) << 1) | 1] & 0x7F
                cgramAddress = cgramAddress &+ 1
            }
            return ppu2OpenBus
            
        case 0x3C:  // OPHCT - Horizontal counter (low)
            if !latchedH {
                hCounterLatched = hCounter
            }
            ppu2OpenBus = UInt8(hCounterLatched & 0xFF)
            return ppu2OpenBus
            
        case 0x3D:  // OPVCT - Vertical counter (low)
            if !latchedV {
                vCounterLatched = vCounter
            }
            ppu2OpenBus = UInt8(vCounterLatched & 0xFF)
            return ppu2OpenBus
            
        case 0x3E:  // STAT77 - PPU status
            var value: UInt8 = 0x00
            
            // Bit 4: Frame interlace (0=even, 1=odd)
            if frameOddEven { value |= 0x10 }
            
            // Bit 5: External latch (sempre 0 no emulador)
            
            // Bit 6: PPU1 open bus
            if ppu1OpenBus != 0 { value |= 0x40 }
            
            // Bit 7: Time over (range over) - sempre 0 no emulador
            
            latchedH = false
            latchedV = false
            ppu1OpenBus = value | (ppu1OpenBus & 0x10)
            return ppu1OpenBus
            
        case 0x3F:  // STAT78 - PPU status 2
            var value: UInt8 = 0x03  // PPU1 version (sempre 1)
            
            // Bit 5: Modo de entrelaçamento
            if (registers[0x33] & 0x01) != 0 { value |= 0x20 }
            
            // Bit 6: H counter MSB
            if hCounterLatched > 0xFF { value |= 0x40 }
            
            // Bit 7: V counter MSB
            if vCounterLatched > 0xFF { value |= 0x80 }
            
            latchedH = false
            latchedV = false
            ppu2OpenBus = value
            return ppu2OpenBus
            
        default:
            return ppu2OpenBus  // Open bus
        }
    }
    
    func writeRegister(_ address: UInt16, _ value: UInt8) {
        let reg = address & 0x3F
        let previous = registers[Int(reg)]
        registers[Int(reg)] = value
        
        switch reg {
        case 0x00:  // INIDISP - Display control
            // Sair do forced blank durante o vblank também recarrega a OAM
            if (previous & 0x80) != 0 && (value & 0x80) == 0 && inVBlank {
                reloadOAMAddress()
            }
            brightness = value & 0x0F
            ppu1OpenBus = value

        case 0x01:  // OBSEL - Object size and data
            // Bits 0-2: base da tabela de tiles (em words)
            // Bits 3-4: gap para a segunda tabela
            // Bits 5-7: par de tamanhos de sprite
            objNameBase = UInt16(value & 0x07) << 13
            objNameSelect = (UInt16((value >> 3) & 0x03) &+ 1) << 12
            objSize = Int((value >> 5) & 0x07)
            ppu1OpenBus = value
            
        case 0x02:  // OAMADDL - OAM address low
            // $2102/$2103 recebem um endereço em WORDS; internamente usamos bytes.
            oamAddrLow = value
            oamAddress = ((UInt16(oamAddrHigh & 0x01) << 8) | UInt16(value)) << 1
            oamFirstWrite = true
            ppu1OpenBus = value
            
        case 0x03:  // OAMADDH - OAM address high
            oamAddrHigh = value
            oamAddress = ((UInt16(value & 0x01) << 8) | UInt16(oamAddrLow)) << 1
            oamHighTable = (value & 0x01) != 0
            oamFirstWrite = true
            ppu1OpenBus = value
            
        case 0x04:  // OAMDATA - OAM data write
            if oamAddress < 0x200 {
                if oamFirstWrite {
                    oamWriteBuffer = value
                    oamFirstWrite = false
                } else {
                    let index = Int(oamAddress & 0x1FE)
                    oam[index] = oamWriteBuffer
                    oam[index + 1] = value
                    oamFirstWrite = true
                }
            } else {
                // Tabela alta: 32 bytes espelhados em $200-$21F
                oam[0x200 + Int(oamAddress & 0x1F)] = value
            }
            oamAddress = (oamAddress + 1) % 0x220
            ppu1OpenBus = value
            
        case 0x05:  // BGMODE - BG mode and tile size
            screenMode = Int(value & 0x07)
            bgConfig[0].tileSize = (value & 0x10) != 0
            bgConfig[1].tileSize = (value & 0x20) != 0
            bgConfig[2].tileSize = (value & 0x40) != 0
            bgConfig[3].tileSize = (value & 0x80) != 0
            bg3Priority = (value & 0x08) != 0
            ppu1OpenBus = value
            
        case 0x06:  // MOSAIC - Mosaic size and enable
            mosaicSize = Int((value >> 4) & 0x0F) + 1
            mosaicEnabled[0] = (value & 0x01) != 0
            mosaicEnabled[1] = (value & 0x02) != 0
            mosaicEnabled[2] = (value & 0x04) != 0
            mosaicEnabled[3] = (value & 0x08) != 0
            ppu1OpenBus = value
            
        case 0x07...0x0A:  // BG1SC-BG4SC - BG tilemap address and size
            let bg = Int(reg - 0x07)
            bgConfig[bg].tilemapBase = UInt16((value & 0xFC) >> 2) << 10
            bgConfig[bg].tilemapSize = Int(value & 0x03)
            ppu1OpenBus = value
            
        case 0x0B:  // BG12NBA - BG1/2 tile data address
            bgConfig[0].tileDataBase = UInt16(value & 0x0F) << 12
            bgConfig[1].tileDataBase = UInt16((value >> 4) & 0x0F) << 12
            ppu1OpenBus = value
            
        case 0x0C:  // BG34NBA - BG3/4 tile data address
            bgConfig[2].tileDataBase = UInt16(value & 0x0F) << 12
            bgConfig[3].tileDataBase = UInt16((value >> 4) & 0x0F) << 12
            ppu1OpenBus = value
            
        case 0x0D...0x14:  // BG1HOFS..BG4VOFS
            // Escritas de 16 bits em duas etapas, usando um latch compartilhado
            // entre todos os registradores de scroll.
            let isVertical = (reg & 1) == 0   // $210D=HOFS (ímpar), $210E=VOFS (par)
            let bg = Int((reg - 0x0D) / 2)

            if bg == 0 {
                // Em Mode 7, $210D/$210E usam o latch M7 e 13 bits com sinal
                let raw = (Int(value) << 8) | Int(m7PrevWrite)
                let signed = (raw << 51) >> 51   // sign-extend 13 bits
                if isVertical { mode7VOfs = signed } else { mode7HOfs = signed }
                m7PrevWrite = value
            }
            if bg < 4 {
                if isVertical {
                    bgConfig[bg].vScroll = ((Int(value) << 8) | Int(bgPrevWrite)) & 0x3FF
                } else {
                    bgConfig[bg].hScroll = ((Int(value) << 8)
                                            | (Int(bgPrevWrite) & ~7)
                                            | (Int(bgScrollLatch) & 7)) & 0x3FF
                    bgScrollLatch = value
                }
                bgPrevWrite = value
            }
            ppu1OpenBus = value
            
        case 0x15:  // VMAIN - VRAM address increment
            // Bits 0-1: passo do incremento (1, 32, 128, 128 words)
            switch value & 0x03 {
            case 0: vramIncrement = 1
            case 1: vramIncrement = 32
            default: vramIncrement = 128
            }
            // Bits 2-3: modo de remapeamento de endereço
            vramRemapMode = (value >> 2) & 0x03
            // Bit 7: incrementa em $2118 (0) ou em $2119 (1)
            ppu1OpenBus = value

        case 0x16:  // VMADDL - VRAM address low
            vramAddress = (vramAddress & 0xFF00) | UInt16(value)
            vramReadBuffer = readVRAMWord(vramAddress)
            ppu1OpenBus = value

        case 0x17:  // VMADDH - VRAM address high
            vramAddress = ((vramAddress & 0x00FF) | (UInt16(value) << 8)) & 0x7FFF
            vramReadBuffer = readVRAMWord(vramAddress)
            ppu1OpenBus = value

        case 0x18:  // VMDATAL - VRAM data low
            vram[Int(remappedVRAMAddress()) << 1] = value
            if (registers[0x15] & 0x80) == 0 {
                incrementVRAMAddress()
            }
            ppu1OpenBus = value

        case 0x19:  // VMDATAH - VRAM data high
            vram[(Int(remappedVRAMAddress()) << 1) | 1] = value
            if (registers[0x15] & 0x80) != 0 {
                incrementVRAMAddress()
            }
            ppu1OpenBus = value
            
        case 0x1A:  // M7SEL - Mode 7 settings
            mode7FlipX = (value & 0x01) != 0
            mode7FlipY = (value & 0x02) != 0
            mode7OutsideFill = (value & 0x40) != 0
            mode7Repeat = (value & 0x80) != 0
            ppu1OpenBus = value
            
        case 0x1B:  // M7A - Mode 7 matrix A
            mode7Matrix[0] = (Int16(value) << 8) | Int16(m7PrevWrite)
            let product = Int32(mode7Matrix[0]) * Int32(Int8(bitPattern: registers[0x1C]))
            multiplyResult = UInt32(bitPattern: product)
            m7PrevWrite = value
            ppu1OpenBus = value
            
        case 0x1C:  // M7B - Mode 7 matrix B
            mode7Matrix[1] = (Int16(value) << 8) | Int16(m7PrevWrite)
            let product = Int32(mode7Matrix[0]) * Int32(Int8(bitPattern: value))
            multiplyResult = UInt32(bitPattern: product)
            m7PrevWrite = value
            ppu1OpenBus = value
            
        case 0x1D:  // M7C - Mode 7 matrix C
            mode7Matrix[2] = (Int16(value) << 8) | Int16(m7PrevWrite)
            m7PrevWrite = value
            ppu1OpenBus = value
            
        case 0x1E:  // M7D - Mode 7 matrix D
            mode7Matrix[3] = (Int16(value) << 8) | Int16(m7PrevWrite)
            m7PrevWrite = value
            ppu1OpenBus = value
            
        case 0x1F:  // M7X - Mode 7 center X
            mode7CenterX = (Int16(value) << 8) | Int16(m7PrevWrite)
            m7PrevWrite = value
            ppu1OpenBus = value
            
        case 0x20:  // M7Y - Mode 7 center Y
            mode7CenterY = (Int16(value) << 8) | Int16(m7PrevWrite)
            m7PrevWrite = value
            ppu1OpenBus = value
            
        case 0x21:  // CGADD - CGRAM address
            cgramAddress = value
            cgramLatchBit = false
            ppu2OpenBus = value
            
        case 0x22:  // CGDATA - CGRAM data
            if !cgramLatchBit {
                cgramLatch = value
                cgramLatchBit = true
            } else {
                // cgramAddress é um endereço de word: cada cor ocupa 2 bytes
                let index = Int(cgramAddress) << 1
                cgram[index] = cgramLatch
                cgram[index | 1] = value & 0x7F
                cgramAddress = cgramAddress &+ 1
                cgramLatchBit = false
            }
            ppu2OpenBus = value
            
        case 0x23...0x25:  // Window mask settings
            ppu1OpenBus = value
            
        case 0x26...0x29:  // Window positions
            ppu1OpenBus = value
            
        case 0x2A, 0x2B:  // Window logic
            ppu1OpenBus = value
            
        case 0x2C:  // TM - Main screen designation
            mainScreenLayers = value
            bgEnabled[0] = (value & 0x01) != 0
            bgEnabled[1] = (value & 0x02) != 0
            bgEnabled[2] = (value & 0x04) != 0
            bgEnabled[3] = (value & 0x08) != 0
            objEnabled = (value & 0x10) != 0
            ppu1OpenBus = value
            
        case 0x2D:  // TS - Sub screen designation
            subScreenLayers = value
            ppu1OpenBus = value
            
        case 0x2E, 0x2F:  // TMW, TSW - Window mask
            ppu1OpenBus = value
            
        case 0x30:  // CGWSEL - Color addition select
            colorMathMode = value
            ppu1OpenBus = value
            
        case 0x31:  // CGADSUB - Color math designation
            colorMathEnabled = (value & 0x80) != 0
            ppu1OpenBus = value
            
        case 0x32:  // COLDATA - Fixed color data
            if value & 0x20 != 0 {  // Red
                fixedColor = (fixedColor & 0xFFE0) | UInt16(value & 0x1F)
            }
            if value & 0x40 != 0 {  // Green
                fixedColor = (fixedColor & 0xFC1F) | (UInt16(value & 0x1F) << 5)
            }
            if value & 0x80 != 0 {  // Blue
                fixedColor = (fixedColor & 0x83FF) | (UInt16(value & 0x1F) << 10)
            }
            ppu1OpenBus = value
            
        case 0x33:  // SETINI - Screen mode/video select
            // TODO: Implementar interlace, overscan, etc.
            ppu1OpenBus = value
            
        default:
            break
        }
    }
    
    /// Recarrega o endereço interno da OAM a partir de OAMADDL/OAMADDH.
    private func reloadOAMAddress() {
        oamAddress = ((UInt16(oamAddrHigh & 0x01) << 8) | UInt16(oamAddrLow)) << 1
        oamHighTable = (oamAddrHigh & 0x01) != 0
        oamFirstWrite = true
    }

    /// O remapeamento não altera o endereço armazenado: ele só rotaciona os bits
    /// baixos no momento do acesso (usado para uploads de tiles).
    @inline(__always)
    private func remappedVRAMAddress() -> UInt16 {
        let addr = vramAddress & 0x7FFF
        switch vramRemapMode {
        case 1:  // 8x8 -> rotaciona 5 bits
            return (addr & 0x7F00) | ((addr & 0x00E0) >> 5) | ((addr & 0x001F) << 3)
        case 2:  // 8x8 -> rotaciona 6 bits
            return (addr & 0x7E00) | ((addr & 0x01C0) >> 6) | ((addr & 0x003F) << 3)
        case 3:  // 8x8 -> rotaciona 7 bits
            return (addr & 0x7C00) | ((addr & 0x0380) >> 7) | ((addr & 0x007F) << 3)
        default:
            return addr
        }
    }

    @inline(__always)
    private func readVRAMWord(_ wordAddress: UInt16) -> UInt16 {
        let byteAddress = Int(wordAddress & 0x7FFF) << 1
        return UInt16(vram[byteAddress]) | (UInt16(vram[byteAddress | 1]) << 8)
    }

    private func incrementVRAMAddress() {
        vramAddress = (vramAddress &+ vramIncrement) & 0x7FFF
    }
    
    // MARK: - Buffers de composição
    //
    // A composição segue o modelo do hardware: cada camada escreve pixel a pixel
    // num z-buffer (z maior fica na frente), guardando também qual camada venceu.
    // A tela principal (TM) e a sub-tela (TS) são renderizadas separadamente e
    // depois combinadas pelo color math.

    private var mainColorLine = [UInt32](repeating: 0, count: 256)
    private var mainLayerLine = [UInt8](repeating: 0, count: 256)
    private var subColorLine = [UInt32](repeating: 0, count: 256)
    private var subLayerLine = [UInt8](repeating: 0, count: 256)
    private var zLine = [UInt8](repeating: 0, count: 256)

    /// Buffers auxiliares para o mosaico
    private var mosaicColor = [UInt32](repeating: 0, count: 256)
    private var mosaicZ = [UInt8](repeating: 0, count: 256)
    private var mosaicValid = [Bool](repeating: false, count: 256)

    private var renderingSubScreen = false
    private var currentLayer: UInt8 = 0

    /// Identificadores de camada: 0 = backdrop, 1-4 = BG1-BG4,
    /// 5 = sprite fora do color math, 6 = sprite com paleta 4-7 (entra no math).
    @inline(__always)
    private func writePixel(_ x: Int, color: UInt32, z: UInt8, layer: UInt8) {
        guard z >= zLine[x] else { return }

        // Recorte por janela: TMW/TSW dizem quais camadas são mascaradas
        let windowMask = renderingSubScreen ? registers[0x2F] : registers[0x2E]
        let bit: UInt8 = layer >= 5 ? 0x10 : (layer >= 1 ? UInt8(1 << (layer - 1)) : 0)
        if bit != 0 && (windowMask & bit) != 0 {
            if isWindowMasked(layer: layer >= 5 ? 5 : Int(layer), x: x) { return }
        }

        zLine[x] = z
        if renderingSubScreen {
            subColorLine[x] = color
            subLayerLine[x] = layer
        } else {
            mainColorLine[x] = color
            mainLayerLine[x] = layer
        }
    }

    /// Cor da CGRAM já empacotada em 0x00RRGGBB.
    @inline(__always)
    private func packedColor(_ index: Int) -> UInt32 {
        let addr = (index & 0xFF) << 1
        let word = UInt16(cgram[addr]) | (UInt16(cgram[addr | 1]) << 8)
        let r = UInt32((word & 0x1F) << 3)
        let g = UInt32(((word >> 5) & 0x1F) << 3)
        let b = UInt32(((word >> 10) & 0x1F) << 3)
        return (r << 16) | (g << 8) | b
    }

    @inline(__always)
    private func vramByte(_ address: Int) -> UInt8 {
        return vram[address & 0xFFFF]
    }
    // MARK: - Timing

    /// Avança o PPU em um dot. Retorna true quando o frame termina.
    @discardableResult
    func step() -> Bool {
        return step(dots: 1)
    }

    /// Avança vários dots de uma vez. Resolve a referência ao barramento uma
    /// única vez, o que faz diferença no caminho quente (89.342 dots por frame).
    @discardableResult
    func step(dots: Int) -> Bool {
        guard let bus = memory else { return false }
        var frameFinished = false
        for _ in 0..<dots {
            if stepOneDot(bus) { frameFinished = true }
        }
        return frameFinished
    }

    @inline(__always)
    private func stepOneDot(_ bus: MemoryBus) -> Bool {
        cycle += 1
        hCounter = UInt16(cycle)

        var frameFinished = false

        if cycle == 274 {
            inHBlank = true
            bus.setHBlank(true)
        }

        if cycle >= 341 {
            cycle = 0
            inHBlank = false
            bus.setHBlank(false)

            // Renderiza a linha que acabou de terminar, com os registradores
            // no estado em que ficaram durante ela.
            if scanline < 224 {
                renderScanline(scanline)
            }

            scanline += 1
            vCounter = UInt16(scanline)

            if scanline == 225 {
                inVBlank = true
                nmiFlag = true
                // No início do vblank (fora do forced blank) o hardware recarrega
                // o endereço interno da OAM a partir de $2102/$2103. Jogos como
                // DKC fazem DMA para $2104 todo frame sem reescrever OAMADD e
                // dependem disso; sem a recarga a OAM fica deslocada.
                if (registers[0x00] & 0x80) == 0 {
                    reloadOAMAddress()
                }
                // Dispara NMI e auto-joypad read
                bus.setVBlank(true)
            }

            if scanline >= 262 {
                scanline = 0
                vCounter = 0
                inVBlank = false
                nmiFlag = false
                bus.setVBlank(false)
                bus.hdmaInit()
                // A linha 0 também recebe HDMA: sem isso a primeira linha
                // visível fica com os valores do frame anterior.
                bus.hdmaRun()
                frameCount += 1
                frameOddEven = !frameOddEven
                frameFinished = true
            } else if scanline < 225 {
                // HDMA roda uma vez por linha visível
                bus.hdmaRun()
            }
        }

        bus.checkTimerIRQ(scanline: scanline, dot: cycle)

        return frameFinished
    }

    // MARK: - Renderização

    private func renderScanline(_ line: Int) {
        guard line < 224 else { return }

        let baseOffset = line * 256 * 4

        // Force blank: a tela fica preta e nada mais é desenhado
        if (registers[0x00] & 0x80) != 0 {
            for x in 0..<256 {
                let o = baseOffset + x * 4
                frameBuffer[o] = 0; frameBuffer[o + 1] = 0
                frameBuffer[o + 2] = 0; frameBuffer[o + 3] = 255
            }
            return
        }

        let backdrop = packedColor(0)
        let tm = registers[0x2C]
        let ts = registers[0x2D]
        let cgwsel = registers[0x30]
        let cgadsub = registers[0x31]

        // --- tela principal ---
        for x in 0..<256 {
            mainColorLine[x] = backdrop
            mainLayerLine[x] = 0
            zLine[x] = 0
        }
        renderingSubScreen = false
        renderLayers(mask: tm, line: line)

        // --- sub-tela e color math ---
        if cgadsub != 0 {
            let blendWithSub = (cgwsel & 0x02) != 0

            if blendWithSub {
                for x in 0..<256 {
                    subColorLine[x] = backdrop
                    subLayerLine[x] = 0
                    zLine[x] = 0
                }
                if ts != 0 {
                    renderingSubScreen = true
                    renderLayers(mask: ts, line: line)
                    renderingSubScreen = false
                }
            }

            applyColorMath(cgwsel: cgwsel, cgadsub: cgadsub, blendWithSub: blendWithSub)
        }

        // --- saída, aplicando o brilho do INIDISP ---
        let scale = Int(brightness) + 1   // 1..16
        for x in 0..<256 {
            let c = mainColorLine[x]
            var r = Int((c >> 16) & 0xFF)
            var g = Int((c >> 8) & 0xFF)
            var b = Int(c & 0xFF)
            if scale < 16 {
                r = (r * scale) >> 4
                g = (g * scale) >> 4
                b = (b * scale) >> 4
            }
            let o = baseOffset + x * 4
            frameBuffer[o] = UInt8(r)
            frameBuffer[o + 1] = UInt8(g)
            frameBuffer[o + 2] = UInt8(b)
            frameBuffer[o + 3] = 255
        }
    }

    /// Ordem de desenho e valores de z por modo de vídeo. Os números seguem a
    /// tabela de prioridades do hardware: z maior fica mais à frente.
    private func renderLayers(mask: UInt8, line: Int) {
        let hasOBJ = (mask & 0x10) != 0

        switch screenMode {
        case 0:
            if mask & 0x08 != 0 { renderBGLine(3, line, bpp: 2, paletteBase: 96, z0: 1, z1: 4) }
            if mask & 0x04 != 0 { renderBGLine(2, line, bpp: 2, paletteBase: 64, z0: 2, z1: 5) }
            if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 2, paletteBase: 32, z0: 7, z1: 10) }
            if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 2, paletteBase: 0, z0: 8, z1: 11) }
            if hasOBJ { renderSpritesLine(line, zOrders: (3, 6, 9, 12)) }

        case 1:
            if bg3Priority {
                if mask & 0x04 != 0 { renderBGLine(2, line, bpp: 2, paletteBase: 0, z0: 1, z1: 10) }
                if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 4, paletteBase: 0, z0: 4, z1: 7) }
                if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 4, paletteBase: 0, z0: 5, z1: 8) }
                if hasOBJ { renderSpritesLine(line, zOrders: (2, 3, 6, 9)) }
            } else {
                if mask & 0x04 != 0 { renderBGLine(2, line, bpp: 2, paletteBase: 0, z0: 1, z1: 3) }
                if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 4, paletteBase: 0, z0: 5, z1: 8) }
                if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 4, paletteBase: 0, z0: 6, z1: 9) }
                if hasOBJ { renderSpritesLine(line, zOrders: (2, 4, 7, 10)) }
            }

        case 2:
            if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 4, paletteBase: 0, z0: 1, z1: 5) }
            if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 4, paletteBase: 0, z0: 3, z1: 7) }
            if hasOBJ { renderSpritesLine(line, zOrders: (2, 4, 6, 8)) }

        case 3:
            if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 4, paletteBase: 0, z0: 1, z1: 5) }
            if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 8, paletteBase: 0, z0: 3, z1: 7) }
            if hasOBJ { renderSpritesLine(line, zOrders: (2, 4, 6, 8)) }

        case 4:
            if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 2, paletteBase: 0, z0: 1, z1: 5) }
            if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 8, paletteBase: 0, z0: 3, z1: 7) }
            if hasOBJ { renderSpritesLine(line, zOrders: (2, 4, 6, 8)) }

        case 5:
            if mask & 0x02 != 0 { renderBGLine(1, line, bpp: 2, paletteBase: 0, z0: 1, z1: 5) }
            if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 4, paletteBase: 0, z0: 3, z1: 7) }
            if hasOBJ { renderSpritesLine(line, zOrders: (2, 4, 6, 8)) }

        case 6:
            if mask & 0x01 != 0 { renderBGLine(0, line, bpp: 4, paletteBase: 0, z0: 2, z1: 5) }
            if hasOBJ { renderSpritesLine(line, zOrders: (1, 3, 4, 6)) }

        case 7:
            if mask & 0x01 != 0 { renderMode7Line(line, z: 1) }
            if hasOBJ { renderSpritesLine(line, zOrders: (1, 2, 3, 4)) }

        default:
            break
        }
    }

    /// Desenha uma linha de um background baseado em tiles.
    private func renderBGLine(_ bg: Int, _ line: Int, bpp: Int, paletteBase: Int, z0: UInt8, z1: UInt8) {
        let cfg = bgConfig[bg]
        let layerID = UInt8(bg + 1)
        currentLayer = layerID

        let tileSizePx = cfg.tileSize ? 16 : 8
        let tileBytes = bpp * 8                    // 2bpp=16, 4bpp=32, 8bpp=64
        let tilemapBase = Int(cfg.tilemapBase) << 1   // words -> bytes
        let chrBase = Int(cfg.tileDataBase) << 1
        let mapSize = cfg.tilemapSize

        // Mosaico: os pixels são amostrados numa grade grossa. Trava a linha na
        // grade e, no fim, replica cada coluna amostrada.
        let mosaic = mosaicEnabled[bg] ? mosaicSize : 1
        let sourceLine = mosaic > 1 ? line - (line % mosaic) : line

        if mosaic > 1 {
            for i in 0..<256 { mosaicValid[i] = false }
        }

        let screenY = sourceLine + cfg.vScroll

        var x = 0
        while x < 256 {
            let px = x + cfg.hScroll

            let tileX = px / tileSizePx
            let tileY = screenY / tileSizePx

            // Cada "tela" do tilemap tem 32x32 tiles = $800 bytes
            var mapAddr = tilemapBase
            if (mapSize & 1) != 0 && (tileX & 0x20) != 0 { mapAddr += 0x800 }
            if (mapSize & 2) != 0 && (tileY & 0x20) != 0 {
                mapAddr += (mapSize & 1) != 0 ? 0x1000 : 0x800
            }
            mapAddr += ((tileY & 0x1F) * 32 + (tileX & 0x1F)) * 2

            let entry = UInt16(vramByte(mapAddr)) | (UInt16(vramByte(mapAddr + 1)) << 8)
            var tileNum = Int(entry & 0x03FF)
            let palette = Int((entry >> 10) & 0x07)
            let z = (entry & 0x2000) != 0 ? z1 : z0
            let hFlip = (entry & 0x4000) != 0
            let vFlip = (entry & 0x8000) != 0

            // Tiles 16x16 são quatro tiles 8x8; o de baixo fica +16
            if tileSizePx == 16 {
                let sx = hFlip ? (1 - ((px / 8) & 1)) : ((px / 8) & 1)
                let sy = vFlip ? (1 - ((screenY / 8) & 1)) : ((screenY / 8) & 1)
                tileNum += sx + sy * 16
            }

            var fineY = screenY & 7
            if vFlip { fineY = 7 - fineY }

            let chrAddr = chrBase + (tileNum & 0x3FF) * tileBytes + fineY * 2
            let paletteOffset = paletteBase + palette * (1 << bpp)

            let firstFine = px & 7
            let count = min(8 - firstFine, 256 - x)

            for i in 0..<count {
                let fineX = hFlip ? (7 - (firstFine + i)) : (firstFine + i)
                let pixel = tilePixelBytes(chrAddr, fineX: fineX, bpp: bpp)
                if pixel != 0 {
                    let index = bpp == 8 ? pixel : (paletteOffset + pixel)
                    let color = packedColor(index)
                    if mosaic > 1 {
                        mosaicColor[x + i] = color
                        mosaicZ[x + i] = z
                        mosaicValid[x + i] = true
                    } else {
                        writePixel(x + i, color: color, z: z, layer: layerID)
                    }
                }
            }

            x += count
        }

        // Replica a amostra do canto de cada bloco do mosaico
        if mosaic > 1 {
            for px in 0..<256 {
                let src = px - (px % mosaic)
                if mosaicValid[src] {
                    writePixel(px, color: mosaicColor[src], z: mosaicZ[src], layer: layerID)
                }
            }
        }
    }

    /// Lê um pixel de uma linha de tile já posicionada (endereço em bytes).
    @inline(__always)
    private func tilePixelBytes(_ rowAddress: Int, fineX: Int, bpp: Int) -> Int {
        let shift = UInt8(7 - fineX)
        var pixel = 0
        var plane = 0
        while plane < bpp {
            // Cada par de bitplanes fica 16 bytes adiante do anterior
            let addr = rowAddress + (plane >> 1) * 16
            let low = vramByte(addr)
            let high = vramByte(addr + 1)
            pixel |= Int((low >> shift) & 1) << plane
            pixel |= Int((high >> shift) & 1) << (plane + 1)
            plane += 2
        }
        return pixel
    }

    /// Mode 7: tilemap nos bytes pares da VRAM, character data nos ímpares.
    private func renderMode7Line(_ line: Int, z: UInt8) {
        currentLayer = 1

        let cx = Int(mode7CenterX)
        let cy = Int(mode7CenterY)
        // Hardware limita (hofs - cx) e (vofs - cy) a 13 bits com sinal
        let hofs = ((mode7HOfs - cx) << 51) >> 51
        let vofs = ((mode7VOfs - cy) << 51) >> 51
        let a = Int(mode7Matrix[0]), b = Int(mode7Matrix[1])
        let c = Int(mode7Matrix[2]), d = Int(mode7Matrix[3])

        let screenY = mode7FlipY ? (255 - line) : line

        for x in 0..<256 {
            let screenX = mode7FlipX ? (255 - x) : x
            let dx = screenX + hofs
            let dy = screenY + vofs

            var vx = ((a * dx + b * dy) >> 8) + cx
            var vy = ((c * dx + d * dy) >> 8) + cy

            if vx < 0 || vx >= 1024 || vy < 0 || vy >= 1024 {
                if mode7Repeat {
                    vx &= 0x3FF; vy &= 0x3FF
                } else if mode7OutsideFill {
                    vx &= 0x07; vy &= 0x07
                } else {
                    continue
                }
            }

            let tileIndex = ((vy >> 3) & 0x7F) * 128 + ((vx >> 3) & 0x7F)
            let tile = Int(vramByte(tileIndex << 1))
            let color = vramByte(((tile * 64 + (vy & 7) * 8 + (vx & 7)) << 1) | 1)
            if color != 0 {
                writePixel(x, color: packedColor(Int(color)), z: z, layer: 1)
            }
        }
    }

    /// Desenha os sprites que cruzam esta scanline.
    private func renderSpritesLine(_ line: Int, zOrders: (UInt8, UInt8, UInt8, UInt8)) {
        let nameBase = Int(objNameBase) << 1     // words -> bytes
        let nameGap = Int(objNameSelect) << 1

        // Do último para o primeiro: sprites de índice menor ficam por cima
        for i in stride(from: 127, through: 0, by: -1) {
            let base = i * 4
            let rawX = Int(oam[base])
            let rawY = Int(oam[base + 1])
            let tile = Int(oam[base + 2])
            let attr = oam[base + 3]

            let highIdx = 0x200 + (i >> 2)
            let highBits = (oam[highIdx] >> ((i & 3) * 2)) & 0x03
            let xBit9 = (highBits & 0x01) != 0
            let isLarge = (highBits & 0x02) != 0

            let (width, height) = getSpriteDimensions(size: isLarge)

            // O Y da OAM é a linha de cima menos 1
            let spriteY = (rawY + 1) & 0xFF
            let relY = (line - spriteY) & 0xFF
            guard relY < height else { continue }

            var spriteX = rawX
            if xBit9 { spriteX -= 256 }

            let palette = Int((attr >> 1) & 0x07)
            let hFlip = (attr & 0x40) != 0
            let vFlip = (attr & 0x80) != 0
            let nameTable = (attr & 0x01) != 0

            let z: UInt8
            switch (attr >> 4) & 0x03 {
            case 0: z = zOrders.0
            case 1: z = zOrders.1
            case 2: z = zOrders.2
            default: z = zOrders.3
            }

            // Só as paletas 4-7 dos sprites participam do color math
            let layerID: UInt8 = palette >= 4 ? 6 : 5

            var fineY = relY
            if vFlip {
                if width == height {
                    fineY = height - 1 - fineY
                } else if fineY < width {
                    fineY = width - 1 - fineY
                } else {
                    fineY = width + (width - 1) - (fineY - width)
                }
            }

            let tilesWide = width / 8
            let tileRow = fineY / 8
            let chrBase = nameTable ? (nameBase + nameGap) : nameBase
            let paletteOffset = 128 + palette * 16

            for tileCol in 0..<tilesWide {
                let drawX = spriteX + tileCol * 8
                if drawX >= 256 || drawX + 8 <= 0 { continue }

                let mirrorCol = hFlip ? (tilesWide - 1 - tileCol) : tileCol
                // O hardware faz wrap separado: a coluna dá a volta dentro da
                // linha de 16 tiles (nibble baixo) e a linha dentro das 16 linhas
                // (nibble alto). Sem isso, sprites cujo tile base fica no fim da
                // linha puxam tiles da linha seguinte e aparecem com lixo.
                let actualTile = ((tile + tileRow * 16) & 0xF0) | ((tile + mirrorCol) & 0x0F)
                let rowAddr = chrBase + actualTile * 32 + (fineY & 7) * 2

                for px in 0..<8 {
                    let screenX = drawX + px
                    guard screenX >= 0 && screenX < 256 else { continue }

                    let fineX = hFlip ? (7 - px) : px
                    let pixel = tilePixelBytes(rowAddr, fineX: fineX, bpp: 4)
                    if pixel != 0 {
                        writePixel(screenX, color: packedColor(paletteOffset + pixel),
                                   z: z, layer: layerID)
                    }
                }
            }
        }
    }

    // MARK: - Janelas

    /// Avalia uma das duas janelas horizontais para um pixel.
    @inline(__always)
    private func windowInside(_ select: UInt8, _ log: UInt8, _ x: Int) -> Bool {
        let wh0 = Int(registers[0x26]), wh1 = Int(registers[0x27])
        let wh2 = Int(registers[0x28]), wh3 = Int(registers[0x29])

        let w1on = (select & 0x02) != 0
        let w1inv = (select & 0x01) != 0
        var w1 = false
        if w1on {
            w1 = x >= wh0 && x <= wh1
            if w1inv { w1 = !w1 }
        }

        let w2on = (select & 0x08) != 0
        let w2inv = (select & 0x04) != 0
        var w2 = false
        if w2on {
            w2 = x >= wh2 && x <= wh3
            if w2inv { w2 = !w2 }
        }

        if w1on && w2on {
            switch log {
            case 0: return w1 || w2      // OR
            case 1: return w1 && w2      // AND
            case 2: return w1 != w2      // XOR
            default: return w1 == w2     // XNOR
            }
        }
        if w1on { return w1 }
        if w2on { return w2 }
        return false
    }

    /// layer: 1-4 = BG1-BG4, 5 = sprites
    private func isWindowMasked(layer: Int, x: Int) -> Bool {
        let w12sel = registers[0x23]
        let w34sel = registers[0x24]
        let wobjsel = registers[0x25]
        let wbglog = registers[0x2A]
        let wobjlog = registers[0x2B]

        let select: UInt8
        let log: UInt8
        switch layer {
        case 1: select = w12sel;       log = wbglog & 0x03
        case 2: select = w12sel >> 4;  log = (wbglog >> 2) & 0x03
        case 3: select = w34sel;       log = (wbglog >> 4) & 0x03
        case 4: select = w34sel >> 4;  log = (wbglog >> 6) & 0x03
        case 5: select = wobjsel;      log = wobjlog & 0x03
        default: return false
        }
        return windowInside(select, log, x)
    }

    /// Janela dedicada do color math (bits altos de WOBJSEL / WOBJLOG).
    @inline(__always)
    private func colorWindowInside(_ x: Int) -> Bool {
        return windowInside(registers[0x25] >> 4, (registers[0x2B] >> 2) & 0x03, x)
    }

    /// mask: 0 = sempre, 1 = só dentro, 2 = só fora, 3 = nunca
    @inline(__always)
    private func colorWindowAllows(_ mask: UInt8, _ x: Int) -> Bool {
        switch mask {
        case 0: return true
        case 1: return colorWindowInside(x)
        case 2: return !colorWindowInside(x)
        default: return false
        }
    }

    /// Combina tela principal e sub-tela conforme CGWSEL/CGADSUB.
    private func applyColorMath(cgwsel: UInt8, cgadsub: UInt8, blendWithSub: Bool) {
        let subtract = (cgadsub & 0x80) != 0
        let half = (cgadsub & 0x40) != 0

        let fixedR = Int(fixedColor & 0x1F) << 3
        let fixedG = Int((fixedColor >> 5) & 0x1F) << 3
        let fixedB = Int((fixedColor >> 10) & 0x1F) << 3

        let aboveMask = (cgwsel >> 6) & 0x03
        let belowMask = (cgwsel >> 4) & 0x03
        let useColorWindow = aboveMask != 0 || belowMask != 0

        for x in 0..<256 {
            if useColorWindow {
                guard colorWindowAllows(aboveMask, x), colorWindowAllows(belowMask, x) else { continue }
            }

            // Bits do CGADSUB: 0=BG1 1=BG2 2=BG3 3=BG4 4=OBJ 5=backdrop
            let layerBit: UInt8
            switch mainLayerLine[x] {
            case 0: layerBit = 0x20
            case 1: layerBit = 0x01
            case 2: layerBit = 0x02
            case 3: layerBit = 0x04
            case 4: layerBit = 0x08
            case 6: layerBit = 0x10
            default: continue          // sprites de paleta 0-3 não entram
            }
            guard (cgadsub & layerBit) != 0 else { continue }

            let main = mainColorLine[x]
            let mainR = Int((main >> 16) & 0xFF)
            let mainG = Int((main >> 8) & 0xFF)
            let mainB = Int(main & 0xFF)

            var subR = fixedR, subG = fixedG, subB = fixedB
            var shouldHalf = half
            if blendWithSub {
                if subLayerLine[x] != 0 {
                    let sub = subColorLine[x]
                    subR = Int((sub >> 16) & 0xFF)
                    subG = Int((sub >> 8) & 0xFF)
                    subB = Int(sub & 0xFF)
                } else {
                    // Sub-tela transparente: o hardware usa a cor fixa (COLDATA)
                    // e não divide por dois.
                    shouldHalf = false
                }
            }

            var r: Int, g: Int, b: Int
            if subtract {
                r = mainR - subR; g = mainG - subG; b = mainB - subB
            } else {
                r = mainR + subR; g = mainG + subG; b = mainB + subB
            }
            if shouldHalf { r >>= 1; g >>= 1; b >>= 1 }

            r = max(0, min(255, r)); g = max(0, min(255, g)); b = max(0, min(255, b))
            mainColorLine[x] = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        }
    }
    private func getColorFromCGRAM(_ index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let colorAddr = index * 2
        let low = cgram[colorAddr]
        let high = cgram[colorAddr + 1]
        let word = UInt16(low) | (UInt16(high) << 8)
        
        let r = UInt8((word & 0x1F) << 3)
        let g = UInt8(((word >> 5) & 0x1F) << 3)
        let b = UInt8(((word >> 10) & 0x1F) << 3)
        
        return (r, g, b)
    }
    
    func getFrameImage() -> CGImage? {
        let width = 256
        let height = 224
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let provider = CGDataProvider(data: Data(frameBuffer) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    
    // MARK: - Save state

    func serialize(into w: inout StateWriter) {
        w.put(registers); w.put(vram); w.put(cgram); w.put(oam); w.put(frameBuffer)
        w.put(scanline); w.put(cycle); w.put(frameCount)
        w.put(screenMode); w.put(brightness)
        w.put(vramAddress); w.put(vramIncrement); w.put(vramRemapMode); w.put(vramReadBuffer)
        w.put(objSize); w.put(objNameBase); w.put(objNameSelect)
        w.put(oamAddress); w.put(oamAddrLow); w.put(oamAddrHigh); w.put(oamHighTable)
        w.put(oamFirstWrite); w.put(oamWriteBuffer); w.put(oamReadBuffer)
        for bg in bgConfig {
            w.put(bg.tilemapBase); w.put(bg.tilemapSize); w.put(bg.tileDataBase)
            w.put(bg.tileSize); w.put(bg.hScroll); w.put(bg.vScroll)
        }
        w.put(bgEnabled); w.put(objEnabled)
        w.put(mosaicSize); w.put(mosaicEnabled)
        w.put(window1Left); w.put(window1Right); w.put(window2Left); w.put(window2Right)
        w.put(windowMaskBG); w.put(windowMaskOBJ); w.put(windowMaskMath)
        w.put(colorMathEnabled); w.put(colorMathMode); w.put(fixedColor)
        w.put(mainScreenLayers); w.put(subScreenLayers)
        w.put(mode7Matrix); w.put(mode7CenterX); w.put(mode7CenterY)
        w.put(mode7FlipX); w.put(mode7FlipY); w.put(mode7Repeat); w.put(mode7OutsideFill)
        w.put(bg3Priority); w.put(multiplyResult)
        w.put(cgramAddress); w.put(cgramLatchBit); w.put(cgramLatch)
        w.put(m7PrevWrite); w.put(mode7HOfs); w.put(mode7VOfs)
        w.put(bgPrevWrite); w.put(bgScrollLatch); w.put(bgScrollLatchBit)
        w.put(hCounter); w.put(vCounter); w.put(latchedH); w.put(latchedV)
        w.put(hCounterLatched); w.put(vCounterLatched)
        w.put(ppu1OpenBus); w.put(ppu2OpenBus)
        w.put(inVBlank); w.put(inHBlank); w.put(nmiFlag); w.put(irqFlag); w.put(frameOddEven)
        w.put(autoJoypadCounter)
    }

    func deserialize(from r: inout StateReader) throws {
        registers = try r.bytes8(count: registers.count)
        vram = try r.bytes8(count: vram.count)
        cgram = try r.bytes8(count: cgram.count)
        oam = try r.bytes8(count: oam.count)
        frameBuffer = try r.bytes8(count: frameBuffer.count)
        scanline = try r.int(); cycle = try r.int(); frameCount = try r.int()
        screenMode = try r.int(); brightness = try r.u8()
        vramAddress = try r.u16(); vramIncrement = try r.u16(); vramRemapMode = try r.u8(); vramReadBuffer = try r.u16()
        objSize = try r.int(); objNameBase = try r.u16(); objNameSelect = try r.u16()
        oamAddress = try r.u16(); oamAddrLow = try r.u8(); oamAddrHigh = try r.u8(); oamHighTable = try r.bool()
        oamFirstWrite = try r.bool(); oamWriteBuffer = try r.u8(); oamReadBuffer = try r.u8()
        for i in 0..<4 {
            bgConfig[i].tilemapBase = try r.u16(); bgConfig[i].tilemapSize = try r.int()
            bgConfig[i].tileDataBase = try r.u16(); bgConfig[i].tileSize = try r.bool()
            bgConfig[i].hScroll = try r.int(); bgConfig[i].vScroll = try r.int()
        }
        bgEnabled = try r.bools(); objEnabled = try r.bool()
        mosaicSize = try r.int(); mosaicEnabled = try r.bools()
        window1Left = try r.u8(); window1Right = try r.u8(); window2Left = try r.u8(); window2Right = try r.u8()
        windowMaskBG = try r.bytes8(count: 4); windowMaskOBJ = try r.u8(); windowMaskMath = try r.u8()
        colorMathEnabled = try r.bool(); colorMathMode = try r.u8(); fixedColor = try r.u16()
        mainScreenLayers = try r.u8(); subScreenLayers = try r.u8()
        mode7Matrix = try r.i16s(); mode7CenterX = try r.i16(); mode7CenterY = try r.i16()
        mode7FlipX = try r.bool(); mode7FlipY = try r.bool(); mode7Repeat = try r.bool(); mode7OutsideFill = try r.bool()
        bg3Priority = try r.bool(); multiplyResult = try r.u32()
        cgramAddress = try r.u8(); cgramLatchBit = try r.bool(); cgramLatch = try r.u8()
        m7PrevWrite = try r.u8(); mode7HOfs = try r.int(); mode7VOfs = try r.int()
        bgPrevWrite = try r.u8(); bgScrollLatch = try r.u8(); bgScrollLatchBit = try r.bool()
        hCounter = try r.u16(); vCounter = try r.u16(); latchedH = try r.bool(); latchedV = try r.bool()
        hCounterLatched = try r.u16(); vCounterLatched = try r.u16()
        ppu1OpenBus = try r.u8(); ppu2OpenBus = try r.u8()
        inVBlank = try r.bool(); inHBlank = try r.bool(); nmiFlag = try r.bool(); irqFlag = try r.bool(); frameOddEven = try r.bool()
        autoJoypadCounter = try r.int()
        guard bgEnabled.count == 4, mosaicEnabled.count == 5, mode7Matrix.count == 4 else {
            throw StateReader.Error.sizeMismatch
        }
    }

    func isInVBlank() -> Bool { return inVBlank }
    func isInHBlank() -> Bool { return inHBlank }
    func getCurrentScanline() -> Int { return scanline }
    func getCurrentCycle() -> Int { return cycle }
    
}

extension Array where Element: ExpressibleByIntegerLiteral {
    mutating func fill(_ value: Element) {
        for i in 0..<self.count {
            self[i] = value
        }
    }
}
