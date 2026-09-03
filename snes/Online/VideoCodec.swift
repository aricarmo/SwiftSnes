//  VideoCodec.swift
//  H.264 de baixa latência via VideoToolbox para o frame de 256×224 do PPU.
//  O anfitrião codifica o framebuffer RGBA; o convidado decodifica de volta
//  para um CGImage RGBA igual ao que o PPU entrega, e a `ScreenView` nem nota.

import Accelerate
import CoreGraphics
import Foundation
import VideoToolbox

private let frameWidth = 256
private let frameHeight = 224
/// RGBA ↔ BGRA: o VideoToolbox só aceita BGRA de entrada e só devolve BGRA.
private let swapRB: [UInt8] = [2, 1, 0, 3]

final class VideoEncoder {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var keyframePending = true
    /// Payload pronto para um quadro `.video`. Chamado na thread do encoder.
    var onEncoded: ((Data) -> Void)?

    init?() {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: frameWidth,
            kCVPixelBufferHeightKey: frameHeight,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(frameWidth), height: Int32(frameHeight),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else {
            Log.online.error("VTCompressionSessionCreate falhou: \(status)")
            return nil
        }
        session = created
        // Tempo real, sem reordenação (B-frames custam frames de atraso) e
        // keyframe a cada 2 s para quem entrar no meio. ~2 Mbps é muito para
        // 256×224: pixel art nítida mesmo em cenas cheias.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_000_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    /// O próximo frame sai como keyframe (alguém acabou de entrar).
    func requestKeyframe() {
        lock.lock(); keyframePending = true; lock.unlock()
    }

    /// `rgba` é o framebuffer do PPU (256×224×4). Chamar a cada frame emulado.
    func encode(rgba: UnsafeBufferPointer<UInt8>, frame: UInt32) {
        guard let session, let base = rgba.baseAddress, rgba.count >= frameWidth * frameHeight * 4,
              let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                   height: vImagePixelCount(frameHeight), width: vImagePixelCount(frameWidth),
                                   rowBytes: frameWidth * 4)
        var destination = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                        height: vImagePixelCount(frameHeight), width: vImagePixelCount(frameWidth),
                                        rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        vImagePermuteChannels_ARGB8888(&source, &destination, swapRB, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        lock.lock()
        let forceKey = keyframePending
        keyframePending = false
        lock.unlock()
        let properties: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: Int64(frame), timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample, frame: frame)
        }
    }

    private func emit(_ sample: CMSampleBuffer, frame: UInt32) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var payload = Data()
        payload.appendU32(frame)
        payload.append(isKeyframe ? 1 : 0)
        if isKeyframe {
            // SPS e PPS vão junto com todo keyframe: o convidado pode ter
            // entrado agora e precisa deles para montar o decoder.
            guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard status == noErr, let pointer else { return }
                payload.appendU16(UInt16(size))
                payload.append(pointer, count: size)
            }
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var nal = Data(count: length)
        let copied = nal.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return }
        payload.append(nal)
        onEncoded?(payload)
    }
}

final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private var rgba = [UInt8](repeating: 0, count: frameWidth * frameHeight * 4)
    /// Frame decodificado, RGBA como o do PPU. Chamado na thread do decoder.
    var onFrame: ((CGImage) -> Void)?

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func decode(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let frame = reader.u32(), let flags = reader.u8() else { return }
        if flags & 1 != 0 {
            guard let spsLength = reader.u16(), let newSPS = reader.bytes(Int(spsLength)),
                  let ppsLength = reader.u16(), let newPPS = reader.bytes(Int(ppsLength)) else { return }
            if session == nil || newSPS != sps || newPPS != pps {
                rebuild(sps: newSPS, pps: newPPS)
            }
        }
        // Sem keyframe ainda não há com que decodificar: espera o próximo.
        guard let session, let format else { return }
        let nal = reader.rest()
        guard !nal.isEmpty else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: nal.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: nal.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        let replaced = nal.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: nal.count)
        }
        guard replaced == noErr else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: CMTime(value: Int64(frame), timescale: 60),
                                        decodeTimeStamp: .invalid)
        var size = nal.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }

        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback],
                                          infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image, let self else { return }
            self.deliver(image)
        }
    }

    private func rebuild(sps newSPS: [UInt8], pps newPPS: [UInt8]) {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        sps = newSPS
        pps = newPPS
        var created: CMVideoFormatDescription?
        let status = newSPS.withUnsafeBufferPointer { spsBuffer in
            newPPS.withUnsafeBufferPointer { ppsBuffer -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes = [spsBuffer.count, ppsBuffer.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &created)
            }
        }
        guard status == noErr, let created else {
            Log.online.error("formato H.264 inválido: \(status)")
            return
        }
        format = created
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var decoder: VTDecompressionSession?
        let creation = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: created, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &decoder)
        guard creation == noErr, let decoder else {
            Log.online.error("VTDecompressionSessionCreate falhou: \(creation)")
            return
        }
        VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = decoder
    }

    private func deliver(_ image: CVPixelBuffer) {
        guard CVPixelBufferGetWidth(image) == frameWidth, CVPixelBufferGetHeight(image) == frameHeight else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        var source = vImage_Buffer(data: CVPixelBufferGetBaseAddress(image),
                                   height: vImagePixelCount(frameHeight), width: vImagePixelCount(frameWidth),
                                   rowBytes: CVPixelBufferGetBytesPerRow(image))
        rgba.withUnsafeMutableBufferPointer { buffer in
            var destination = vImage_Buffer(data: buffer.baseAddress,
                                            height: vImagePixelCount(frameHeight), width: vImagePixelCount(frameWidth),
                                            rowBytes: frameWidth * 4)
            vImagePermuteChannels_ARGB8888(&source, &destination, swapRB, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(image, .readOnly)

        // Mesmo layout do `PPU.getFrameImage`: a ScreenView lê os bytes direto.
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(width: frameWidth, height: frameHeight,
                                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frameWidth * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent) else { return }
        onFrame?(cgImage)
    }
}
