import Foundation

// MARK: - DSP Interface

protocol DSPInterface: AnyObject {
    func read(register: UInt8) -> UInt8
    func write(register: UInt8, value: UInt8)
}

// MARK: - S-DSP (Digital Signal Processor)

/// S-DSP emulation for the SNES APU.
/// 128 registers, 8 voices, BRR sample decoding, ADSR/GAIN envelopes.
/// Generates 32 kHz stereo audio.
/// Replicate bsnes CLAMP16 macro: clamp Int to [-32768, 32767].
@inline(__always)
private func CLAMP16(_ v: inout Int) {
    if Int16(truncatingIfNeeded: v) != v {
        v = (v >> 63) ^ 0x7FFF  // negative → -32768 (via ^0x7FFF on all-ones), positive → 32767
    }
}

final class DSP: DSPInterface {
    // MARK: Registers

    /// All 128 DSP registers (address space $00-$7F).
    var regs = [UInt8](repeating: 0, count: 128)

    // MARK: RAM access

    /// Closure provided by the APU to read SPC700 RAM (64 KB address space).
    var readRAM: ((UInt16) -> UInt8)?

    // MARK: Per-voice state

    enum EnvMode { case attack, decay, sustain, release }

    struct Voice {
        var brrAddr: UInt16 = 0          // Current BRR block address in SPC RAM
        var brrOffset: Int = 0           // Sample index within decoded block (0-15)
        var brrBuffer = [Int16](repeating: 0, count: 16)  // 16 decoded samples
        var brrHeader: UInt8 = 0         // Header of current BRR block
        var pitchCounter: UInt16 = 0     // 16-bit fractional pitch position
        var envLevel: Int = 0            // Envelope level 0-2047 (11-bit)
        var hiddenEnv: Int = 0           // Hidden envelope (tracks env before counter gate)
        var envMode: EnvMode = .release
        var keyedOn: Bool = false
        var ended: Bool = false
        var konDelay: Int = 0            // Hardware key-on startup delay (~5 samples)
        // Ring of four previous output samples for interpolation
        var prev: [Int16] = [0, 0, 0, 0]
        var output: Int = 0   // Last interpolated sample (for pitch modulation)
    }

    var voices: [Voice] = (0..<8).map { _ in Voice() }

    /// Global sample counter (incremented each generateSample call)
    var sampleCounter: UInt32 = 0

    // MARK: Global counter system (matches bsnes)

    /// Global counter cycles 0..30719 (simple_counter_range = 2048 * 5 * 3 = 30720)
    private static let simpleCounterRange = 30720

    /// Period for each rate 0-31. Rate 0 never fires (period > range).
    private static let counterRates: [Int] = [
        simpleCounterRange + 1, // rate 0: never fires
              2048, 1536,
        1280, 1024,  768,
         640,  512,  384,
         320,  256,  192,
         160,  128,   96,
          80,   64,   48,
          40,   32,   24,
          20,   16,   12,
          10,    8,    6,
           5,    4,    3,
                 2,
                 1
    ]

    /// Offset for each rate 0-31 (bsnes counter_offsets).
    private static let counterOffsets: [Int] = [
          1, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
        536, 0, 1040,
             0,
             0
    ]

    /// Global counter value (decrements each sample, wraps from 0 to 30719).
    var globalCounter: Int = 0

    /// Decrement the global counter, wrapping at 0 back to 30719.
    private func runCounters() {
        globalCounter -= 1
        if globalCounter < 0 {
            globalCounter = DSP.simpleCounterRange - 1
        }
    }

    /// Returns true when the counter fires for the given rate (0-31).
    private func readCounter(rate: Int) -> Bool {
        return ((globalCounter + DSP.counterOffsets[rate]) % DSP.counterRates[rate]) == 0
    }

    // Gaussian interpolation lookup table (512 entries, from SNES hardware)
    static let gaussTable: [Int16] = [
        0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,0x000,
        0x001,0x001,0x001,0x001,0x001,0x001,0x001,0x001,0x001,0x001,0x001,0x002,0x002,0x002,0x002,0x002,
        0x002,0x002,0x003,0x003,0x003,0x003,0x003,0x004,0x004,0x004,0x004,0x004,0x005,0x005,0x005,0x005,
        0x006,0x006,0x006,0x006,0x007,0x007,0x007,0x008,0x008,0x008,0x009,0x009,0x009,0x00A,0x00A,0x00A,
        0x00B,0x00B,0x00B,0x00C,0x00C,0x00D,0x00D,0x00E,0x00E,0x00F,0x00F,0x00F,0x010,0x010,0x011,0x011,
        0x012,0x013,0x013,0x014,0x014,0x015,0x015,0x016,0x017,0x017,0x018,0x018,0x019,0x01A,0x01B,0x01B,
        0x01C,0x01D,0x01D,0x01E,0x01F,0x020,0x020,0x021,0x022,0x023,0x024,0x024,0x025,0x026,0x027,0x028,
        0x029,0x02A,0x02B,0x02C,0x02D,0x02E,0x02F,0x030,0x031,0x032,0x033,0x034,0x035,0x036,0x037,0x038,
        0x03A,0x03B,0x03C,0x03D,0x03E,0x040,0x041,0x042,0x043,0x045,0x046,0x047,0x049,0x04A,0x04C,0x04D,
        0x04E,0x050,0x051,0x053,0x054,0x056,0x057,0x059,0x05B,0x05C,0x05E,0x060,0x061,0x063,0x065,0x067,
        0x068,0x06A,0x06C,0x06E,0x070,0x072,0x074,0x076,0x078,0x07A,0x07C,0x07E,0x080,0x082,0x084,0x086,
        0x089,0x08B,0x08D,0x08F,0x092,0x094,0x096,0x099,0x09B,0x09D,0x0A0,0x0A2,0x0A5,0x0A7,0x0AA,0x0AC,
        0x0AF,0x0B1,0x0B4,0x0B7,0x0B9,0x0BC,0x0BF,0x0C1,0x0C4,0x0C7,0x0CA,0x0CD,0x0CF,0x0D2,0x0D5,0x0D8,
        0x0DB,0x0DE,0x0E1,0x0E4,0x0E7,0x0EA,0x0ED,0x0F0,0x0F3,0x0F6,0x0FA,0x0FD,0x100,0x103,0x106,0x10A,
        0x10D,0x110,0x114,0x117,0x11A,0x11E,0x121,0x125,0x128,0x12C,0x12F,0x133,0x136,0x13A,0x13E,0x141,
        0x145,0x148,0x14C,0x150,0x154,0x157,0x15B,0x15F,0x163,0x166,0x16A,0x16E,0x172,0x176,0x17A,0x17E,
        0x182,0x186,0x18A,0x18E,0x192,0x196,0x19A,0x19E,0x1A2,0x1A6,0x1AB,0x1AF,0x1B3,0x1B7,0x1BB,0x1C0,
        0x1C4,0x1C8,0x1CC,0x1D1,0x1D5,0x1D9,0x1DD,0x1E2,0x1E6,0x1EB,0x1EF,0x1F3,0x1F8,0x1FC,0x201,0x205,
        0x209,0x20E,0x212,0x217,0x21B,0x220,0x224,0x229,0x22D,0x232,0x236,0x23B,0x240,0x244,0x249,0x24D,
        0x252,0x257,0x25B,0x260,0x265,0x269,0x26E,0x273,0x277,0x27C,0x281,0x286,0x28A,0x28F,0x294,0x299,
        0x29E,0x2A2,0x2A7,0x2AC,0x2B1,0x2B6,0x2BB,0x2BF,0x2C4,0x2C9,0x2CE,0x2D3,0x2D8,0x2DC,0x2E1,0x2E6,
        0x2EB,0x2F0,0x2F5,0x2FA,0x2FF,0x304,0x309,0x30E,0x313,0x318,0x31D,0x322,0x326,0x32B,0x330,0x335,
        0x33A,0x33F,0x344,0x349,0x34E,0x353,0x357,0x35C,0x361,0x366,0x36B,0x370,0x374,0x379,0x37E,0x383,
        0x388,0x38C,0x391,0x396,0x39B,0x39F,0x3A4,0x3A9,0x3AD,0x3B2,0x3B7,0x3BB,0x3C0,0x3C5,0x3C9,0x3CE,
        0x3D2,0x3D7,0x3DC,0x3E0,0x3E5,0x3E9,0x3ED,0x3F2,0x3F6,0x3FB,0x3FF,0x403,0x408,0x40C,0x410,0x415,
        0x419,0x41D,0x421,0x425,0x42A,0x42E,0x432,0x436,0x43A,0x43E,0x442,0x446,0x44A,0x44E,0x452,0x455,
        0x459,0x45D,0x461,0x465,0x468,0x46C,0x470,0x473,0x477,0x47A,0x47E,0x481,0x485,0x488,0x48C,0x48F,
        0x492,0x496,0x499,0x49C,0x49F,0x4A2,0x4A6,0x4A9,0x4AC,0x4AF,0x4B2,0x4B5,0x4B7,0x4BA,0x4BD,0x4C0,
        0x4C3,0x4C5,0x4C8,0x4CB,0x4CD,0x4D0,0x4D2,0x4D5,0x4D7,0x4D9,0x4DC,0x4DE,0x4E0,0x4E3,0x4E5,0x4E7,
        0x4E9,0x4EB,0x4ED,0x4EF,0x4F1,0x4F3,0x4F5,0x4F6,0x4F8,0x4FA,0x4FB,0x4FD,0x4FF,0x500,0x502,0x503,
        0x504,0x506,0x507,0x508,0x50A,0x50B,0x50C,0x50D,0x50E,0x50F,0x510,0x511,0x511,0x512,0x513,0x514,
        0x514,0x515,0x516,0x516,0x517,0x517,0x517,0x518,0x518,0x518,0x518,0x518,0x519,0x519,0x519,0x519,
    ]

    // MARK: Noise generator
    var noiseLevel: Int16 = 0x4000
    // noiseCounter removed — noise now uses global counter system

    // MARK: Echo / FIR filter
    var writeRAM: ((UInt16, UInt8) -> Void)?
    var echoPos: Int = 0
    var echoHistL: [Int16] = [Int16](repeating: 0, count: 8)
    var echoHistR: [Int16] = [Int16](repeating: 0, count: 8)
    var echoHistPos: Int = 0

    // MARK: Output buffers

    var sampleBufferL = [Int16]()
    var sampleBufferR = [Int16]()

    // MARK: Internal latches

    private var konLatch: UInt8 = 0
    private var koffLatch: UInt8 = 0

    // MARK: Save state

    private static let envModes: [EnvMode] = [.attack, .decay, .sustain, .release]

    func serialize(into w: inout StateWriter) {
        w.put(regs)
        for v in voices {
            w.put(v.brrAddr); w.put(v.brrOffset); w.put(v.brrBuffer); w.put(v.brrHeader)
            w.put(v.pitchCounter); w.put(v.envLevel); w.put(v.hiddenEnv)
            w.put(UInt8(Self.envModes.firstIndex(of: v.envMode) ?? 3))
            w.put(v.keyedOn); w.put(v.ended); w.put(v.konDelay); w.put(v.prev); w.put(v.output)
        }
        w.put(sampleCounter); w.put(globalCounter); w.put(noiseLevel)
        w.put(echoPos); w.put(echoHistL); w.put(echoHistR); w.put(echoHistPos)
        w.put(konLatch); w.put(koffLatch)
    }

    func deserialize(from r: inout StateReader) throws {
        regs = try r.bytes8(count: 128)
        for i in 0..<8 {
            var v = Voice()
            v.brrAddr = try r.u16(); v.brrOffset = try r.int(); v.brrBuffer = try r.i16s(); v.brrHeader = try r.u8()
            v.pitchCounter = try r.u16(); v.envLevel = try r.int(); v.hiddenEnv = try r.int()
            v.envMode = Self.envModes[Int(try r.u8()) & 3]
            v.keyedOn = try r.bool(); v.ended = try r.bool(); v.konDelay = try r.int(); v.prev = try r.i16s(); v.output = try r.int()
            guard v.brrBuffer.count == 16, v.prev.count == 4 else { throw StateReader.Error.sizeMismatch }
            voices[i] = v
        }
        sampleCounter = try r.u32(); globalCounter = try r.int(); noiseLevel = try r.i16()
        echoPos = try r.int(); echoHistL = try r.i16s(); echoHistR = try r.i16s(); echoHistPos = try r.int()
        konLatch = try r.u8(); koffLatch = try r.u8()
        guard echoHistL.count == 8, echoHistR.count == 8 else { throw StateReader.Error.sizeMismatch }
        sampleBufferL.removeAll(keepingCapacity: true)
        sampleBufferR.removeAll(keepingCapacity: true)
    }

    func reset() {
        regs = [UInt8](repeating: 0, count: 128)
        voices = (0..<8).map { _ in Voice() }
        sampleCounter = 0
        globalCounter = 0
        noiseLevel = 0x4000
        echoPos = 0
        echoHistL = [Int16](repeating: 0, count: 8)
        echoHistR = [Int16](repeating: 0, count: 8)
        echoHistPos = 0
        konLatch = 0
        koffLatch = 0
        sampleBufferL.removeAll(keepingCapacity: true)
        sampleBufferR.removeAll(keepingCapacity: true)
    }

    // MARK: - Register I/O

    func read(register: UInt8) -> UInt8 {
        let r = Int(register & 0x7F)
        return regs[r]
    }

    func write(register: UInt8, value: UInt8) {
        let r = Int(register & 0x7F)
        regs[r] = value


        switch r {
        case 0x4C: // KON — key on
            konLatch = value
        case 0x5C: // KOFF — key off
            koffLatch = value
        case 0x6C: // FLG
            break
        case 0x7C: // ENDX — any write clears all flags
            regs[r] = 0
        default:
            break
        }
    }

    // MARK: - Sample generation

    /// Generate one stereo sample pair (called at 32 kHz).
    func generateSample() -> (left: Int16, right: Int16) {
        processKeyOnOff()
        runCounters()

        // --- Noise LFSR update (uses global counter, matching bsnes) ---
        let noiseRate = Int(regs[0x6C] & 0x1F)
        if readCounter(rate: noiseRate) {
            let feedback = (Int(noiseLevel) << 13) ^ (Int(noiseLevel) << 14)
            noiseLevel = Int16(truncatingIfNeeded: (feedback & 0x4000) ^ (Int(noiseLevel) >> 1))
        }

        var outL: Int32 = 0
        var outR: Int32 = 0
        var echoInL: Int32 = 0
        var echoInR: Int32 = 0

        let noiseMask = regs[0x3D]  // NON — noise enable
        let pmodMask = regs[0x2D]   // PMON — pitch modulation
        let echoMask = regs[0x4D]   // EON — echo enable

        for v in 0..<8 {
            let voff = v * 0x10

            guard voices[v].keyedOn else { continue }

            // Hardware delays voice startup for 5 samples after KON.
            if voices[v].konDelay > 0 {
                if voices[v].konDelay == 5 {
                    decodeBRR(voice: v)
                }
                voices[v].envLevel = 0
                voices[v].hiddenEnv = 0
                voices[v].output = 0
                regs[voff + 8] = 0
                regs[voff + 9] = 0
                voices[v].konDelay -= 1
                continue
            }

            // 14-bit pitch value
            let pitchLo = UInt16(regs[voff + 2])
            let pitchHi = UInt16(regs[voff + 3] & 0x3F)
            var pitch = Int((pitchHi << 8) | pitchLo)

            // Pitch modulation (voice 0 cannot be modulated)
            if v > 0 && (pmodMask & UInt8(1 << v)) != 0 {
                pitch = pitch + ((pitch * voices[v - 1].output) >> 15)
                pitch = max(0, min(0x3FFF, pitch))
            }

            // Advance pitch counter
            voices[v].pitchCounter &+= UInt16(pitch & 0x3FFF)

            // Consume whole samples
            while voices[v].pitchCounter >= 0x1000 {
                voices[v].pitchCounter -= 0x1000
                advanceBRR(voice: v)
            }

            // Gaussian interpolation using 4-point filter.
            // Hardware BRR buffer stores doubled samples; multiply prev by 2
            // to match the scale. Each product is truncated independently.
            let idx = Int((voices[v].pitchCounter >> 4) & 0xFF)
            let s0 = Int(voices[v].prev[0]) * 2
            let s1 = Int(voices[v].prev[1]) * 2
            let s2 = Int(voices[v].prev[2]) * 2
            let s3 = Int(voices[v].prev[3]) * 2
            var sample = (Int(DSP.gaussTable[255 - idx]) * s0) >> 11
            sample    += (Int(DSP.gaussTable[511 - idx]) * s1) >> 11
            sample    += (Int(DSP.gaussTable[256 + idx]) * s2) >> 11
            sample     = Int(Int16(truncatingIfNeeded: sample))  // hardware truncates to int16 after 3 terms
            sample    += (Int(DSP.gaussTable[idx])       * s3) >> 11
            CLAMP16(&sample)
            sample &= ~1  // hardware clears LSB of interpolated output

            // Noise: replace interpolated sample with noise LFSR output
            if (noiseMask & UInt8(1 << v)) != 0 {
                sample = Int(Int16(truncatingIfNeeded: Int(noiseLevel) &* 2))
            }

            // Apply envelope
            updateEnvelope(voice: v)
            sample = (sample * voices[v].envLevel) >> 11 & ~1

            // Pitch modulation uses the post-envelope voice output.
            voices[v].output = sample

            // Write OUTX (high 8 bits of 15-bit output)
            regs[voff + 9] = UInt8(bitPattern: Int8(clamping: sample >> 7))

            // Per-voice signed volume
            let volL = Int(Int8(bitPattern: regs[voff + 0]))
            let volR = Int(Int8(bitPattern: regs[voff + 1]))
            let voiceL = Int32((sample * volL) >> 7)
            let voiceR = Int32((sample * volR) >> 7)
            outL += voiceL
            outR += voiceR

            // Accumulate echo input for enabled voices
            if (echoMask & UInt8(1 << v)) != 0 {
                echoInL += voiceL
                echoInR += voiceR
            }
        }

        // --- Echo / FIR filter ---
        let echoBase = Int(regs[0x6D]) << 8
        let echoDelayRaw = Int(regs[0x7D] & 0x0F)
        let echoLength = echoDelayRaw == 0 ? 4 : echoDelayRaw * 2048  // EDL=0 → 4 bytes (one stereo sample, hardware pass-through)

        // Read current echo samples from SPC RAM
        let echoAddrL = UInt16((echoBase + echoPos) & 0xFFFF)
        let echoAddrR = UInt16((echoBase + echoPos + 2) & 0xFFFF)
        let echoSampleL = Int16(bitPattern: UInt16(readRAM?(echoAddrL) ?? 0) | (UInt16(readRAM?(echoAddrL &+ 1) ?? 0) << 8))
        let echoSampleR = Int16(bitPattern: UInt16(readRAM?(echoAddrR) ?? 0) | (UInt16(readRAM?(echoAddrR &+ 1) ?? 0) << 8))

        // Push into FIR history ring buffer
        echoHistL[echoHistPos] = echoSampleL
        echoHistR[echoHistPos] = echoSampleR

        // Apply 8-tap FIR filter
        var firL: Int32 = 0
        var firR: Int32 = 0
        for i in 0..<8 {
            let coeff = Int32(Int8(bitPattern: regs[i * 0x10 + 0x0F]))
            let hPos = (echoHistPos + i + 1) & 7
            firL += Int32(echoHistL[hPos]) * coeff
            firR += Int32(echoHistR[hPos]) * coeff
        }
        firL >>= 7
        firR >>= 7
        firL = max(-32768, min(32767, firL))
        firR = max(-32768, min(32767, firR))

        echoHistPos = (echoHistPos + 1) & 7

        // Write back echo buffer if echo write is enabled (FLG bit 5 clear)
        if (regs[0x6C] & 0x20) == 0 {
            let feedback = Int32(Int8(bitPattern: regs[0x0D]))  // EFB
            var writeL = Int32(((firL * feedback) >> 7) + Int32(max(-32768, min(32767, echoInL))))
            var writeR = Int32(((firR * feedback) >> 7) + Int32(max(-32768, min(32767, echoInR))))
            writeL = max(-32768, min(32767, writeL))
            writeR = max(-32768, min(32767, writeR))
            let wL = UInt16(bitPattern: Int16(writeL))
            let wR = UInt16(bitPattern: Int16(writeR))
            writeRAM?(echoAddrL, UInt8(wL & 0xFF))
            writeRAM?(echoAddrL &+ 1, UInt8(wL >> 8))
            writeRAM?(echoAddrR, UInt8(wR & 0xFF))
            writeRAM?(echoAddrR &+ 1, UInt8(wR >> 8))
        }

        // Advance echo position
        echoPos += 4  // 4 bytes per stereo sample (L16 + R16)
        if echoPos >= echoLength {
            echoPos = 0
        }

        // Add echo output to main mix
        let evolL = Int32(Int8(bitPattern: regs[0x2C]))  // EVOL L
        let evolR = Int32(Int8(bitPattern: regs[0x3C]))  // EVOL R
        outL += Int32((firL * evolL) >> 7)
        outR += Int32((firR * evolR) >> 7)

        // Main volume
        let mvolL = Int32(Int8(bitPattern: regs[0x0C]))
        let mvolR = Int32(Int8(bitPattern: regs[0x1C]))
        outL = (outL * mvolL) >> 7
        outR = (outR * mvolR) >> 7

        // FLG mute bit (bit 6)
        if (regs[0x6C] & 0x40) != 0 {
            outL = 0
            outR = 0
        }

        // Clamp to signed 16-bit
        outL = max(-32768, min(32767, outL))
        outR = max(-32768, min(32767, outR))

        return (Int16(outL), Int16(outR))
    }

    // MARK: - Key On / Key Off

    private func processKeyOnOff() {
        for v in 0..<8 {
            let mask = UInt8(1 << v)

            // KOFF processed first (real hardware order)
            if (koffLatch & mask) != 0 {
                voices[v].envMode = .release
            }

            // KON overrides KOFF if both set
            if (konLatch & mask) != 0 {
                let srcn = regs[v * 0x10 + 4]
                let dirBase = UInt16(regs[0x5D]) << 8
                let entryAddr = dirBase &+ UInt16(srcn) &* 4
                let lo = UInt16(readRAM?(entryAddr) ?? 0)
                let hi = UInt16(readRAM?(entryAddr &+ 1) ?? 0)
                let brrStart = (hi << 8) | lo
                voices[v].keyedOn = true
                voices[v].envMode = .attack
                voices[v].envLevel = 0
                voices[v].hiddenEnv = 0
                voices[v].pitchCounter = 0
                voices[v].brrOffset = 0
                voices[v].konDelay = 5
                voices[v].prev = [0, 0, 0, 0]
                voices[v].ended = false
                voices[v].output = 0

                // Load start address from sample directory 
                voices[v].brrAddr = brrStart
                regs[0x7C] &= ~mask
            }
        }
        konLatch = 0
        koffLatch = 0
    }

    // MARK: - BRR Decoding

    /// Decode one BRR block (9 bytes → 16 samples) for a voice.
    private func decodeBRR(voice v: Int) {
        let addr = voices[v].brrAddr
        let header = readRAM?(addr) ?? 0
        voices[v].brrHeader = header

        let shift = Int((header >> 4) & 0x0F)
        let filter = Int((header >> 2) & 0x03)

        // Carry forward the two most recent samples for prediction filters.
        // After key-on (brrOffset==0, prev all zero), old/older start at 0.
        // After subsequent blocks (brrOffset==16), use last two samples from previous block.
        var old: Int
        var older: Int
        if voices[v].brrOffset >= 2 {
            old  = Int(voices[v].brrBuffer[voices[v].brrOffset - 1])
            older = Int(voices[v].brrBuffer[voices[v].brrOffset - 2])
        } else {
            old  = Int(voices[v].prev[3])
            older = Int(voices[v].prev[2])
        }

        for i in 0..<16 {
            let byteIdx = 1 + i / 2
            let byte = readRAM?(addr &+ UInt16(byteIdx)) ?? 0

            // High nybble first, then low nybble
            var nybble: Int
            if i & 1 == 0 {
                nybble = Int(byte >> 4)
            } else {
                nybble = Int(byte & 0x0F)
            }
            // Sign-extend from 4-bit
            if nybble >= 8 { nybble -= 16 }

            // Shift sample based on header
            var sample: Int = (nybble << shift) >> 1
            if shift >= 0xD {
                // Hardware quirk: result is -0x800 or 0 based on sign
                sample = (sample >> 25) << 11
            }

            // Prediction filter
            switch filter {
            case 1:
                sample += old + ((-old) >> 4)
            case 2:
                sample += (old << 1) + ((-old * 3) >> 5)
                       - older + (older >> 4)
            case 3:
                sample += (old << 1) + ((-old * 13) >> 6)
                       - older + ((older * 3) >> 4)
            default:
                break // filter 0: direct
            }

            // Hardware clip: clamp to 16-bit, then double-and-wrap to int16,
            // then halve back. This replicates the S-DSP's 15-bit overflow
            // wrapping (bsnes: CLAMP16(s); s = (int16_t)(s * 2); stored.)
            // When |sample| > 16383 the ×2 overflows int16, wrapping the
            // value — this IS the hardware behavior and affects filter state.
            sample = max(-32768, min(32767, sample))
            sample = Int(Int16(truncatingIfNeeded: sample &* 2)) >> 1

            voices[v].brrBuffer[i] = Int16(clamping: sample)
            older = old
            old = sample
        }

        voices[v].brrOffset = 0
    }

    /// Advance one sample within (or past) the current BRR block.
    private func advanceBRR(voice v: Int) {
        voices[v].brrOffset += 1

        // Handle block boundary BEFORE updating interpolation ring
        if voices[v].brrOffset >= 16 {
            let header = voices[v].brrHeader
            let isEnd  = (header & 0x01) != 0
            let isLoop = (header & 0x02) != 0

            if isEnd {
                // Set ENDX flag for this voice
                regs[0x7C] |= UInt8(1 << v)

                if isLoop {
                    // Jump to loop address from directory entry (+2 bytes)
                    let srcn = regs[v * 0x10 + 4]
                    let dirBase = UInt16(regs[0x5D]) << 8
                    let entryAddr = dirBase &+ UInt16(srcn) &* 4 &+ 2
                    let lo = UInt16(readRAM?(entryAddr) ?? 0)
                    let hi = UInt16(readRAM?(entryAddr &+ 1) ?? 0)
                    voices[v].brrAddr = (hi << 8) | lo
                } else {
                    // Voice ends — enter silent release
                    voices[v].keyedOn = false
                    voices[v].envLevel = 0
                    voices[v].envMode = .release
                    return
                }
            } else {
                // Advance to next 9-byte BRR block
                voices[v].brrAddr &+= 9
            }

            decodeBRR(voice: v)
            // brrOffset is now 0 after decodeBRR
        }

        // Push current sample into interpolation ring
        voices[v].prev[0] = voices[v].prev[1]
        voices[v].prev[1] = voices[v].prev[2]
        voices[v].prev[2] = voices[v].prev[3]
        voices[v].prev[3] = voices[v].brrBuffer[voices[v].brrOffset]
    }

    // MARK: - Envelope (ADSR / GAIN)
    // Matches bsnes run_envelope() — compute-then-gate pattern with global counter.

    private func updateEnvelope(voice v: Int) {
        let voff = v * 0x10
        var env = voices[v].envLevel

        if voices[v].envMode == .release {
            // Release always decrements by 8 every sample (no counter gating)
            env -= 8
            if env < 0 { env = 0 }
            voices[v].envLevel = env
            regs[voff + 8] = UInt8(env >> 4)
            return
        }

        let adsr0 = regs[voff + 5]  // bsnes: adsr0 = register offset 0x05
        let rate: Int
        var envData: Int

        if (adsr0 & 0x80) != 0 {
            // ADSR mode
            envData = Int(regs[voff + 6])  // bsnes: adsr1 = register offset 0x06
            if voices[v].envMode == .decay || voices[v].envMode == .sustain {
                // Exponential decrease: env--; env -= env >> 8;
                env -= 1
                env -= env >> 8
                if voices[v].envMode == .decay {
                    rate = (Int(adsr0) >> 3 & 0x0E) + 0x10
                } else {
                    // Sustain rate from adsr1 bits 0-4
                    rate = envData & 0x1F
                }
            } else {
                // Attack
                let ar = (Int(adsr0) & 0x0F) * 2 + 1
                rate = ar
                env += ar < 31 ? 0x20 : 0x400
            }
        } else {
            // GAIN mode — env_data reassigned to gain register (matches bsnes line 266)
            let gainReg = regs[voff + 7]
            envData = Int(gainReg)
            let mode = envData >> 5
            if mode < 4 {
                // Direct mode: immediate set, rate 31 (fires every sample)
                env = envData * 0x10
                rate = 31
            } else {
                rate = envData & 0x1F
                if mode == 4 {
                    // Linear decrease
                    env -= 0x20
                } else if mode < 6 {
                    // Exponential decrease
                    env -= 1
                    env -= env >> 8
                } else {
                    // Linear increase
                    env += 0x20
                    if mode > 6 && voices[v].hiddenEnv >= 0x600 {
                        // Bent increase: net +8 above 0x600
                        env += 0x8 - 0x20
                    }
                }
            }
        }

        // Sustain level check (only during decay)
        // bsnes: if ((env >> 8) == (env_data >> 5) && v->env_mode == env_decay)
        if (env >> 8) == (envData >> 5) && voices[v].envMode == .decay {
            voices[v].envMode = .sustain
        }

        // Store hidden_env before clamping
        voices[v].hiddenEnv = env

        // Clamp to 0..0x7FF; overflow triggers attack->decay transition
        if env < 0 || env > 0x7FF {
            env = env < 0 ? 0 : 0x7FF
            if voices[v].envMode == .attack {
                voices[v].envMode = .decay
            }
        }

        // Counter gates whether env is actually written
        if readCounter(rate: rate) {
            voices[v].envLevel = env
        }

        // Write ENVX register
        regs[voff + 8] = UInt8(voices[v].envLevel >> 4)
    }
}
