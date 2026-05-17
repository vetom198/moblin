@preconcurrency import AVFoundation
import VideoToolbox

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoderOutputSampleBuffer(_ codec: VideoDecoder, _ sampleBuffer: CMSampleBuffer)
}

class VideoDecoder: @unchecked Sendable {
    private var isRunning = false
    private let lockQueue: DispatchQueue
    private var formatDescription: CMFormatDescription?
    weak var delegate: (any VideoDecoderDelegate)?
    private var invalidateSession = true
    // Consecutive frames with no successfully-decoded output. A weak DJI
    // RTMP signal can feed the decoder corrupt frames; VTDecompressionSession
    // then returns kVTVideoDecoderMalfunctionErr / kVTVideoDecoderBadDataErr
    // (NOT kVTInvalidSessionErr) and gets stuck producing nothing forever —
    // video freezes until the whole app is restarted. We watch for a run of
    // failures and force a session rebuild to self-heal.
    private var framesSinceOutput = 0
    private let maxFramesSinceOutputBeforeReset = 60
    private var session: VTDecompressionSession? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
            framesSinceOutput = 0
        }
    }

    init(lockQueue: DispatchQueue) {
        self.lockQueue = lockQueue
    }

    func startRunning(formatDescription: CMFormatDescription? = nil) {
        lockQueue.async {
            self.isRunning = true
            self.invalidateSession = true
            self.formatDescription = formatDescription
        }
    }

    func stopRunning() {
        lockQueue.async {
            self.session = nil
            self.invalidateSession = true
            self.formatDescription = nil
            self.isRunning = false
        }
    }

    func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        if invalidateSession {
            session = makeSession()
        }
        framesSinceOutput += 1
        let err = session?
            .decodeFrame(sampleBuffer) { [
                weak self
            ] status, _, imageBuffer, presentationTimeStamp, duration in
                guard let self else {
                    return
                }
                guard let imageBuffer, status == noErr else {
                    logger.info("video-decoder: Failed to decode frame status \(status)")
                    return
                }
                guard let formatDescription = CMVideoFormatDescription.create(imageBuffer: imageBuffer) else {
                    return
                }
                guard let sampleBuffer = CMSampleBuffer.create(imageBuffer,
                                                               formatDescription,
                                                               duration,
                                                               presentationTimeStamp,
                                                               sampleBuffer.decodeTimeStamp)
                else {
                    return
                }
                lockQueue.async {
                    self.framesSinceOutput = 0
                    self.delegate?.videoDecoderOutputSampleBuffer(self, sampleBuffer)
                }
            }
        // Reset on the documented invalid-session error, on the other
        // hard decoder errors a corrupt RTMP bitstream can trigger, and
        // — as a catch-all for "session silently produces nothing" — when
        // we've gone too long without any decoded output.
        if err == kVTInvalidSessionErr
            || err == kVTVideoDecoderMalfunctionErr
            || err == kVTVideoDecoderBadDataErr
        {
            logger.info("video-decoder: Decode failed (\(err)). Resetting session.")
            invalidateSession = true
            framesSinceOutput = 0
        } else if framesSinceOutput > maxFramesSinceOutputBeforeReset {
            logger.info("""
            video-decoder: \(framesSinceOutput) frames with no output — \
            forcing session rebuild to recover from a wedged decoder.
            """)
            invalidateSession = true
            framesSinceOutput = 0
        }
    }

    private func makeSession() -> VTDecompressionSession? {
        guard let formatDescription else {
            logger.info("video-decoder: Format description missing")
            return nil
        }
        let attributes: [NSString: AnyObject] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pixelFormatType),
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary?,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr else {
            logger.info("video-decoder: Failed to create session with status \(status)")
            return nil
        }
        return session
    }
}
