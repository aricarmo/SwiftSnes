// PPU.swift
import Foundation
import CoreGraphics

class PPU {
    // Registradores principais
    private var registers: [UInt8] = Array(repeating: 0, count: 0x40)
    
    // Memória de vídeo
    private var vram: [UInt8] = Array(repeating: 0, count: 0x10000)  // 64KB
    private var cgram: [UInt8] = Array(repeating: 0, count: 0x200)   // 512 bytes (256 colors)
    private var oam: [UInt8] = Array(repeating: 0, count: 0x220)     // 544 bytes
    
    // Frame buffer
    private var frameBuffer: [UInt8] = Array(repeating: 0, count: 256 * 224 * 4)  // RGBA
    
    // Estado interno
    private var scanline: Int = 0
    private var cycle: Int = 0
    private var frameCount: Int = 0
    
    // Referência para memória
    private weak var memory: MemoryBus?
    
    // Modos e configurações
    private var screenMode: Int = 0
    private var brightness: UInt8 = 0
    
    // VRAM address
    private var vramAddress: UInt16 = 0
    private var vramIncrement: UInt16 = 1
    private var vramRemapMode: UInt8 = 0
    private var vramReadBuffer: UInt16 = 0
    
    // Configurações de sprites
    private var objSize: Int = 0  // Tamanho dos sprites
    private var objNameBase: UInt16 = 0  // Base address para sprite tiles
    private var objNameSelect: UInt16 = 0  // Gap entre tabelas de sprites
    
    // OAM (Object Attribute Memory)
    private var oamAddress: UInt16 = 0
    private var oamHighTable: Bool = false
    private var oamFirstWrite: Bool = true
    private var oamWriteBuffer: UInt8 = 0
    private var oamReadBuffer: UInt8 = 0
    
    // Estrutura para representar um sprite
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
    
    // Obtém informações de um sprite da OAM
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
    
    // Obtém dimensões do sprite baseado no modo e tamanho
    private func getSpriteDimensions(size: Bool) -> (width: Int, height: Int) {
        let sizes: [[(Int, Int)]] = [
            // Small, Large
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
    
    // Configurações de Background
    private struct BGConfig {
        var tilemapBase: UInt16 = 0
        var tilemapSize: Int = 0  // 0=32x32, 1=64x32, 2=32x64, 3=64x64
        var tileDataBase: UInt16 = 0
        var tileSize: Bool = false  // false=8x8, true=16x16
        var hScroll: Int = 0
        var vScroll: Int = 0
    }
    
    private var bgConfig: [BGConfig] = Array(repeating: BGConfig(), count: 4)
    
    // Layers habilitadas
    private var bgEnabled: [Bool] = [false, false, false, false]
    private var objEnabled: Bool = false
    
    // Configurações de Mosaic
    private var mosaicSize: Int = 0
    private var mosaicEnabled: [Bool] = [false, false, false, false, false] // BG1-4 + OBJ
    
    // Window settings
    private var window1Left: UInt8 = 0
    private var window1Right: UInt8 = 0
    private var window2Left: UInt8 = 0
    private var window2Right: UInt8 = 0
    private var windowMaskBG: [UInt8] = [0, 0, 0, 0]
    private var windowMaskOBJ: UInt8 = 0
    private var windowMaskMath: UInt8 = 0
    
    // Color math
    private var colorMathEnabled: Bool = false
    private var colorMathMode: UInt8 = 0
    private var fixedColor: UInt16 = 0
    
    // Screen designation
    private var mainScreenLayers: UInt8 = 0
    private var subScreenLayers: UInt8 = 0
    
    // Mode 7 settings
    private var mode7Matrix: [Int16] = [0x0100, 0, 0, 0x0100]  // [A, B, C, D]
    private var mode7CenterX: Int16 = 0
    private var mode7CenterY: Int16 = 0
    private var mode7FlipX: Bool = false
    private var mode7FlipY: Bool = false
    private var mode7Repeat: Bool = false
    private var mode7OutsideFill: Bool = false
    
    // Multiplication result
    private var multiplyResult: UInt32 = 0
    
    // CGRAM
    private var cgramAddress: UInt8 = 0
    private var cgramLatchBit: Bool = false
    private var cgramLatch: UInt8 = 0
    
    // Latches para registradores de 16-bit
    private var m7PrevWrite: UInt8 = 0
    private var bgPrevWrite: UInt8 = 0
    private var bgScrollLatch: UInt8 = 0
    private var bgScrollLatchBit: Bool = false
    
    // Software latches
    private var hCounter: UInt16 = 0
    private var vCounter: UInt16 = 0
    private var latchedH: Bool = false
    private var latchedV: Bool = false
    private var hCounterLatched: UInt16 = 0
    private var vCounterLatched: UInt16 = 0
    
    // PPU estado
    private var ppu1OpenBus: UInt8 = 0
    private var ppu2OpenBus: UInt8 = 0
    
    // Display/HDMA flags
    private var inVBlank: Bool = false
    private var inHBlank: Bool = false
    private var nmiFlag: Bool = false
    private var irqFlag: Bool = false
    private var frameOddEven: Bool = false
    
    // Auto-joypad
    private var autoJoypadCounter: Int = 0
    
    init(memory: MemoryBus) {
        self.memory = memory
        reset()
    }
    
    func reset() {
        // Limpa todos os arrays
        registers.fill(0)
        vram.fill(0)
        cgram.fill(0)
        oam.fill(0)
        frameBuffer.fill(0)
        
        scanline = 0
        cycle = 0
        frameCount = 0
        
        // Valores iniciais padrão
        registers[0x00] = 0x8F  // Display off
        ppu1OpenBus = 0xFF
        ppu2OpenBus = 0xFF
    }
    
    // Lê registrador
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
            // Latch acontece na leitura
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
            let value = oam[Int(oamAddress)]
            oamAddress = (oamAddress + 1) & 0x21F
            if oamAddress == 0 {
                oamHighTable = false
            }
            return value
            
        case 0x39:  // VMDATALREAD - VRAM data read (low)
            let value = UInt8(vramReadBuffer & 0xFF)
            if (registers[0x15] & 0x80) == 0 {
                vramReadBuffer = UInt16(vram[Int(vramAddress)]) | (UInt16(vram[Int(vramAddress) | 1]) << 8)
                incrementVRAMAddress()
            }
            return value
            
        case 0x3A:  // VMDATAHREAD - VRAM data read (high)
            let value = UInt8((vramReadBuffer >> 8) & 0xFF)
            if (registers[0x15] & 0x80) != 0 {
                vramReadBuffer = UInt16(vram[Int(vramAddress)]) | (UInt16(vram[Int(vramAddress) | 1]) << 8)
                incrementVRAMAddress()
            }
            return value
            
        case 0x3B:  // CGDATAREAD - CGRAM data read
            if !cgramLatchBit {
                cgramLatchBit = true
                cgramLatch = cgram[Int(cgramAddress)]
                ppu2OpenBus = cgramLatch
            } else {
                cgramLatchBit = false
                ppu2OpenBus = cgram[Int(cgramAddress) | 1]
                ppu2OpenBus &= 0x7F  // Bit 7 é sempre 0
                cgramAddress = (cgramAddress + 1) & 0xFF
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
            // value |= 0x20
            
            // Bit 6: PPU1 open bus
            if ppu1OpenBus != 0 { value |= 0x40 }
            
            // Bit 7: Time over (range over) - sempre 0 no emulador
            // value |= 0x80
            
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
    
    // Escreve registrador
    func writeRegister(_ address: UInt16, _ value: UInt8) {
        let reg = address & 0x3F
        registers[Int(reg)] = value
        
        switch reg {
        case 0x00:  // INIDISP - Display control
            brightness = value & 0x0F
            let forceBlank = (value & 0x80) != 0
            print("[PPU] INIDISP escrito: \(String(format: "$%02X", value)) - Brightness: \(brightness), ForceBlank: \(forceBlank)")
            ppu1OpenBus = value
            
        case 0x01:  // OBSEL - Object size and data
            objSize = Int(value & 0x07)
            objNameSelect = UInt16((value >> 3) & 0x03) << 12
            objNameBase = UInt16((value >> 5) & 0x07) << 13
            ppu1OpenBus = value
            
        case 0x02:  // OAMADDL - OAM address low
            oamAddress = (oamAddress & 0xFF00) | UInt16(value)
            oamFirstWrite = true
            ppu1OpenBus = value
            
        case 0x03:  // OAMADDH - OAM address high
            oamAddress = (oamAddress & 0x00FF) | (UInt16(value & 0x01) << 8)
            oamHighTable = (value & 0x01) != 0
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
                oam[Int(oamAddress)] = value
            }
            oamAddress = (oamAddress + 1) & 0x3FF
            ppu1OpenBus = value
            
        case 0x05:  // BGMODE - BG mode and tile size
            screenMode = Int(value & 0x07)
            bgConfig[0].tileSize = (value & 0x10) != 0
            bgConfig[1].tileSize = (value & 0x20) != 0
            bgConfig[2].tileSize = (value & 0x40) != 0
            bgConfig[3].tileSize = (value & 0x80) != 0
            print("[PPU] BGMODE escrito: Modo \(screenMode)")
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
            
        case 0x0D...0x14:  // BG Scroll registers
            let isVertical = (reg & 1) != 0
            let bg = Int((reg - 0x0D) / 2)
            
            if bg < 4 {
                if isVertical {
                    // Vertical scroll
                    bgConfig[bg].vScroll = (bgConfig[bg].vScroll & ~0x3FF) | ((Int(value) << 8) | Int(bgPrevWrite))
                } else {
                    // Horizontal scroll
                    bgConfig[bg].hScroll = (bgConfig[bg].hScroll & ~0x3FF) | ((Int(value) << 8) | Int(bgPrevWrite))
                    bgPrevWrite = value
                }
            }
            ppu1OpenBus = value
            
        case 0x15:  // VMAIN - VRAM address increment
            vramIncrement = (value & 0x80) != 0 ? 0x20 : 0x01
            if (value & 0x0C) != 0 {
                vramRemapMode = (value & 0x0C) >> 2
            }
            ppu1OpenBus = value
            
        case 0x16:  // VMADDL - VRAM address low
            vramAddress = (vramAddress & 0xFF00) | UInt16(value)
            vramReadBuffer = UInt16(vram[Int(vramAddress)]) | (UInt16(vram[Int(vramAddress) | 1]) << 8)
            ppu1OpenBus = value
            
        case 0x17:  // VMADDH - VRAM address high
            vramAddress = (vramAddress & 0x00FF) | (UInt16(value) << 8)
            vramReadBuffer = UInt16(vram[Int(vramAddress)]) | (UInt16(vram[Int(vramAddress) | 1]) << 8)
            ppu1OpenBus = value
            
        case 0x18:  // VMDATAL - VRAM data low
            vram[Int(vramAddress)] = value
            if (registers[0x15] & 0x80) == 0 {
                incrementVRAMAddress()
            }
            ppu1OpenBus = value
            
        case 0x19:  // VMDATAH - VRAM data high
            vram[Int(vramAddress) | 1] = value
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
            mode7Matrix[1] = Int16(Int8(bitPattern: value))
            let product = Int32(mode7Matrix[0]) * Int32(Int8(bitPattern: value))
            multiplyResult = UInt32(bitPattern: product)
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
                cgram[Int(cgramAddress)] = cgramLatch
                cgram[Int(cgramAddress) | 1] = value & 0x7F
                cgramAddress = (cgramAddress + 1) & 0xFF
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
            print("[PPU] TM (Main screen) escrito: \(String(format: "$%02X", value)) - BG1:\(bgEnabled[0]) BG2:\(bgEnabled[1]) BG3:\(bgEnabled[2]) BG4:\(bgEnabled[3]) OBJ:\(objEnabled)")
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
    
    // Incrementa endereço VRAM
    private func incrementVRAMAddress() {
        switch vramRemapMode {
        case 0:  // Normal
            vramAddress = (vramAddress + vramIncrement) & 0x7FFF
            
        case 1:  // Remap 32x32
            var addr = vramAddress
            addr = ((addr & 0x7FE0) + (vramIncrement & 0x7FE0)) |
                   ((addr & 0x001F) + (vramIncrement & 0x001F))
            vramAddress = addr & 0x7FFF
            
        case 2:  // Remap 64x32
            var addr = vramAddress
            addr = ((addr & 0x7FC0) + (vramIncrement & 0x7FC0)) |
                   ((addr & 0x003F) + (vramIncrement & 0x003F))
            vramAddress = addr & 0x7FFF
            
        case 3:  // Remap 128x32
            var addr = vramAddress
            addr = ((addr & 0x7F80) + (vramIncrement & 0x7F80)) |
                   ((addr & 0x007F) + (vramIncrement & 0x007F))
            vramAddress = addr & 0x7FFF
            
        default:
            break
        }
    }
    
    // Executa um passo
    func step() {
        // Atualiza contadores H/V
        hCounter = UInt16(cycle)
        vCounter = UInt16(scanline)
        
        cycle += 1
        
        // NTSC timing: 341 dots per line
        if cycle >= 341 {
            cycle = 0
            scanline += 1
            
            // Frame timing
            if scanline == 225 {  // Início do VBlank
                inVBlank = true
                nmiFlag = true
                // TODO: Trigger NMI if enabled
            }
            
            if scanline >= 262 {  // Fim do frame (NTSC)
                scanline = 0
                inVBlank = false
                frameCount += 1
                frameOddEven = !frameOddEven
            }
        }
        
        // HBlank timing
        inHBlank = cycle >= 274
    }
    
    // Fim da scanline
    func endScanline(_ line: Int) {
        if line < 224 {  // Área visível
            renderScanline(line)
        }
    }
    
    // Fim do frame
    func endFrame() {
        // TODO: Enviar frame completo para UI
    }
    
    // Renderiza uma scanline
    private func renderScanline(_ line: Int) {
        guard line < 224 else { return }

        // Se force blank está ativo, não renderiza nada
        let forceBlank = (registers[0x00] & 0x80) != 0

        // Implementação básica de renderização
        let baseOffset = line * 256 * 4

        for x in 0..<256 {
            let offset = baseOffset + x * 4

            if forceBlank {
                // Tela preta quando force blank está ativo
                frameBuffer[offset] = 0
                frameBuffer[offset + 1] = 0
                frameBuffer[offset + 2] = 0
                frameBuffer[offset + 3] = 255
                continue
            }

            // Cor de backdrop (cor 0 da paleta)
            var (r, g, b) = getColorFromCGRAM(0)

            // Renderiza backgrounds baseado no modo
            switch screenMode {
            case 0:  // Mode 0: 4 BGs de 2bpp
                if bgEnabled[0] { (r, g, b) = renderBGPixel(0, x, line) }
                else if bgEnabled[1] { (r, g, b) = renderBGPixel(1, x, line) }

            case 1:  // Mode 1: 3 BGs (mais comum no Super Mario World)
                // BG3 (mais ao fundo)
                if bgEnabled[2] { (r, g, b) = renderBGPixel(2, x, line) }
                // BG2 (meio)
                if bgEnabled[1] { (r, g, b) = renderBGPixel(1, x, line) }
                // BG1 (frente)
                if bgEnabled[0] { (r, g, b) = renderBGPixel(0, x, line) }

            case 7:  // Mode 7
                if bgEnabled[0] { (r, g, b) = renderMode7Pixel(x, line) }

            default:
                // Para outros modos, tenta renderizar BG1
                if bgEnabled[0] { (r, g, b) = renderBGPixel(0, x, line) }
            }

            // Aplica brilho
            if brightness > 0 {
                r = UInt8(min(255, Int(r) * Int(brightness) / 15))
                g = UInt8(min(255, Int(g) * Int(brightness) / 15))
                b = UInt8(min(255, Int(b) * Int(brightness) / 15))
            } else {
                r = 0
                g = 0
                b = 0
            }

            // Escreve no frame buffer
            frameBuffer[offset] = r
            frameBuffer[offset + 1] = g
            frameBuffer[offset + 2] = b
            frameBuffer[offset + 3] = 255
        }

        // Renderiza sprites
        if objEnabled {
            renderSprites(line)
        }
    }
    
    // Renderiza um pixel de background
    private func renderBGPixel(_ bg: Int, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        // Implementação simplificada
        let config = bgConfig[bg]
        
        // Aplica scroll
        let scrolledX = (x + config.hScroll) & 0x3FF
        let scrolledY = (y + config.vScroll) & 0x3FF
        
        // Calcula tile
        let tileX = scrolledX / 8
        let tileY = scrolledY / 8
        
        // TODO: Implementar busca real de tiles e pixels
        
        // Cor temporária baseada no BG
        switch bg {
        case 0: return (64, 64, 128)
        case 1: return (128, 64, 64)
        case 2: return (64, 128, 64)
        case 3: return (128, 128, 64)
        default: return (0, 0, 0)
        }
    }
    
    // Renderiza um pixel do Mode 7
    private func renderMode7Pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        // Mode 7 transformation
        let cx = x - 128
        let cy = y - 112
        
        var transformedX = (Int(mode7Matrix[0]) * cx + Int(mode7Matrix[1]) * cy) >> 8
        var transformedY = (Int(mode7Matrix[2]) * cx + Int(mode7Matrix[3]) * cy) >> 8
        
        transformedX += Int(mode7CenterX)
        transformedY += Int(mode7CenterY)
        
        // Apply flipping
        if mode7FlipX { transformedX = -transformedX }
        if mode7FlipY { transformedY = -transformedY }
        
        // Check bounds
        if !mode7Repeat {
            if transformedX < 0 || transformedX >= 1024 || transformedY < 0 || transformedY >= 1024 {
                if mode7OutsideFill {
                    // Use fixed color
                    let r = UInt8((fixedColor & 0x1F) << 3)
                    let g = UInt8(((fixedColor >> 5) & 0x1F) << 3)
                    let b = UInt8(((fixedColor >> 10) & 0x1F) << 3)
                    return (r, g, b)
                } else {
                    return (0, 0, 0)
                }
            }
        } else {
            transformedX = transformedX & 0x3FF
            transformedY = transformedY & 0x3FF
        }
        
        // Get tile and pixel
        let tileX = transformedX >> 3
        let tileY = transformedY >> 3
        let pixelX = transformedX & 7
        let pixelY = transformedY & 7
        
        // Read from VRAM
        let tileIndex = (tileY * 128 + tileX) & 0x7FFF
        let tileData = vram[Int(tileIndex)]
        
        // TODO: Proper tile/color lookup
        // For now, return a gradient based on tile data
        let value = tileData
        return (value, value, value)
    }
    
    // Renderiza todos os sprites de uma linha
    private func renderSprites(_ line: Int) {
        var spritesOnLine: [(sprite: Sprite, index: Int)] = []
        
        // Busca sprites visíveis nesta linha
        for i in 0..<128 {
            if let sprite = getSprite(index: i) {
                let (_, height) = getSpriteDimensions(size: sprite.size)
                let spriteY = sprite.y < 240 ? sprite.y : sprite.y - 256
                
                if line >= spriteY && line < spriteY + height {
                    spritesOnLine.append((sprite, i))
                }
            }
        }
        
        // Ordena por prioridade (OAM index para empates)
        spritesOnLine.sort { a, b in
            if a.sprite.priority != b.sprite.priority {
                return a.sprite.priority < b.sprite.priority
            }
            return a.index < b.index
        }
        
        // Renderiza cada sprite
        for (sprite, _) in spritesOnLine.reversed() {
            renderSprite(sprite, scanline: line)
        }
    }
    
    // Renderiza um sprite específico
    private func renderSprite(_ sprite: Sprite, scanline: Int) {
        let (width, height) = getSpriteDimensions(size: sprite.size)
        let spriteY = sprite.y < 240 ? sprite.y : sprite.y - 256
        let lineInSprite = scanline - spriteY
        
        // Aplica flip vertical
        let actualLine = sprite.verticalFlip ? (height - 1 - lineInSprite) : lineInSprite
        
        // Calcula endereço base do tile
        var tileRow = actualLine >> 3
        let pixelRow = actualLine & 7
        
        // Para sprites grandes, ajusta o tile
        if sprite.size {
            tileRow = actualLine >> 4
        }
        
        // Renderiza cada pixel do sprite na linha
        for x in 0..<width {
            let screenX = sprite.x + x
            if screenX >= 256 || screenX < 0 { continue }
            
            // Aplica flip horizontal
            let actualX = sprite.horizontalFlip ? (width - 1 - x) : x
            
            // Calcula tile column
            let tileCol = actualX >> 3
            let pixelCol = actualX & 7
            
            // Calcula endereço do tile
            let tileOffset = tileRow * (width >> 3) + tileCol
            let tileNumber = sprite.tile + UInt16(tileOffset)
            
            // Calcula endereço na VRAM
            let tileAddress = objNameBase + (tileNumber << 5)
            
            // Lê dados do tile (simplificado)
            let pixelData = getPixelFromTile(tileAddress, pixelCol, pixelRow, 4) // 4bpp para sprites
            
            if pixelData != 0 {  // Pixel não transparente
                let colorIndex = (sprite.paletteNumber << 4) + Int(pixelData)
                let color = getColorFromCGRAM(128 + colorIndex)  // Sprites usam paletas 128-255
                
                // Escreve no frame buffer
                let offset = (scanline * 256 + screenX) * 4
                frameBuffer[offset] = color.r
                frameBuffer[offset + 1] = color.g
                frameBuffer[offset + 2] = color.b
                frameBuffer[offset + 3] = 255
            }
        }
    }
    
    // Lê um pixel de um tile
    private func getPixelFromTile(_ address: UInt16, _ x: Int, _ y: Int, _ bpp: Int) -> UInt8 {
        // Implementação simplificada
        switch bpp {
        case 2:  // 2bpp
            let offset = Int(address) + y * 2
            let low = vram[offset]
            let high = vram[offset + 1]
            let shift = 7 - x
            return ((low >> shift) & 1) | (((high >> shift) & 1) << 1)
            
        case 4:  // 4bpp
            let offset = Int(address) + y * 2
            var pixel: UInt8 = 0
            for plane in 0..<4 {
                let planeOffset = offset + plane * 16
                let data = vram[planeOffset + (plane & 1)]
                let shift = 7 - x
                pixel |= ((data >> shift) & 1) << plane
            }
            return pixel
            
        case 8:  // 8bpp
            let offset = Int(address) + y * 2
            var pixel: UInt8 = 0
            for plane in 0..<8 {
                let planeOffset = offset + plane * 16
                let data = vram[planeOffset + (plane & 1)]
                let shift = 7 - x
                pixel |= ((data >> shift) & 1) << plane
            }
            return pixel
            
        default:
            return 0
        }
    }
    
    // Obtém cor da CGRAM
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
    
    // Converte para CGImage para exibição
    func getFrameImage() -> CGImage? {
        let width = 256
        let height = 224
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        let provider = CGDataProvider(data: NSData(bytes: frameBuffer, length: frameBuffer.count))
        
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    
    // Estado para save states
    struct State: Codable {
        let registers: [UInt8]
        let vram: [UInt8]
        let cgram: [UInt8]
        let oam: [UInt8]
        let vramAddress: UInt16
        let oamAddress: UInt16
        let cgramAddress: UInt8
        let screenMode: Int
        let brightness: UInt8
        let scanline: Int
        let cycle: Int
        let frameCount: Int
        let inVBlank: Bool
        let inHBlank: Bool
        let frameOddEven: Bool
        let bgHScroll: [Int]
        let bgVScroll: [Int]
        let bgEnabled: [Bool]
        let objEnabled: Bool
        let mainScreenLayers: UInt8
        let subScreenLayers: UInt8
    }
    
    func getState() -> State {
        return State(
            registers: registers,
            vram: vram,
            cgram: cgram,
            oam: oam,
            vramAddress: vramAddress,
            oamAddress: oamAddress,
            cgramAddress: cgramAddress,
            screenMode: screenMode,
            brightness: brightness,
            scanline: scanline,
            cycle: cycle,
            frameCount: frameCount,
            inVBlank: inVBlank,
            inHBlank: inHBlank,
            frameOddEven: frameOddEven,
            bgHScroll: bgConfig.map { $0.hScroll },
            bgVScroll: bgConfig.map { $0.vScroll },
            bgEnabled: bgEnabled,
            objEnabled: objEnabled,
            mainScreenLayers: mainScreenLayers,
            subScreenLayers: subScreenLayers
        )
    }
    
    func setState(_ state: State) {
        registers = state.registers
        vram = state.vram
        cgram = state.cgram
        oam = state.oam
        vramAddress = state.vramAddress
        oamAddress = state.oamAddress
        cgramAddress = state.cgramAddress
        screenMode = state.screenMode
        brightness = state.brightness
        scanline = state.scanline
        cycle = state.cycle
        frameCount = state.frameCount
        inVBlank = state.inVBlank
        inHBlank = state.inHBlank
        frameOddEven = state.frameOddEven
        
        for i in 0..<4 {
            bgConfig[i].hScroll = state.bgHScroll[i]
            bgConfig[i].vScroll = state.bgVScroll[i]
        }
        
        bgEnabled = state.bgEnabled
        objEnabled = state.objEnabled
        mainScreenLayers = state.mainScreenLayers
        subScreenLayers = state.subScreenLayers
    }
    
    // Getters para estado da PPU
    func isInVBlank() -> Bool { return inVBlank }
    func isInHBlank() -> Bool { return inHBlank }
    func getCurrentScanline() -> Int { return scanline }
    func getCurrentCycle() -> Int { return cycle }
    
    // Helper para extensão de Array
}

extension Array where Element: ExpressibleByIntegerLiteral {
    mutating func fill(_ value: Element) {
        for i in 0..<self.count {
            self[i] = value
        }
    }
}
