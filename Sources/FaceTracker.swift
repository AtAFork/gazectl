import CoreVideo
import Vision

final class FaceTracker {
    private let camera = CameraCapture()
    private let lock = NSLock()
    private var _latestYaw: Double?
    private var _smoothedYaw: Double?
    private var _latestPitch: Double?
    private var _smoothedPitch: Double?
    private var _frameCount: Int = 0

    /// EMA smoothing factor (0–1). Lower = smoother / more lag, higher = more responsive / more noise.
    private let smoothing: Double = 0.3

    // MARK: - Blink detection state

    private var _wasEyesClosed = false
    private var _lastBlinkTime: Date?
    private var _doubleBlinkCooldownUntil = Date.distantPast
    private var _doubleBlinkPending = false
    private var _latestEAR: Double?

    /// Eye Aspect Ratio below this → eyes considered closed.
    private let blinkThreshold: Double = 0.18
    /// Eye Aspect Ratio above this → eyes considered open (hysteresis).
    private let openThreshold: Double = 0.22

    /// Max time between two blinks to count as a double-blink.
    private let doubleBlinkMaxGap: TimeInterval = 0.6
    /// Min time between two blinks (filters noise / flutter).
    private let doubleBlinkMinGap: TimeInterval = 0.1
    /// Cooldown after a double-blink before accepting new blinks.
    private let doubleBlinkCooldown: TimeInterval = 1.5

    // MARK: - Public accessors

    var latestYaw: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _smoothedYaw
    }

    var latestPitch: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _smoothedPitch
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
    }

    var latestEAR: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _latestEAR
    }

    /// Returns true (once) if a double-blink was detected since the last call.
    func consumeDoubleBlink() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _doubleBlinkPending {
            _doubleBlinkPending = false
            return true
        }
        return false
    }

    func start(cameraIndex: Int) throws {
        camera.onFrame = { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
        try camera.start(cameraIndex: cameraIndex)
    }

    func stop() {
        camera.stop()
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let face = request.results?.first,
              let yawNumber = face.yaw else {
            lock.lock()
            _latestYaw = nil
            _latestPitch = nil
            _frameCount += 1
            lock.unlock()
            return
        }

        let yawDegrees = yawNumber.doubleValue * 180.0 / .pi
        let pitchDegrees = face.pitch.map { $0.doubleValue * 180.0 / .pi }

        // Detect eye landmarks for blink detection
        var ear: Double? = nil
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = [face]
        do {
            try handler.perform([landmarksRequest])
            if let landmarks = landmarksRequest.results?.first?.landmarks,
               let leftEye = landmarks.leftEye,
               let rightEye = landmarks.rightEye {
                let leftEAR = eyeAspectRatio(region: leftEye)
                let rightEAR = eyeAspectRatio(region: rightEye)
                ear = (leftEAR + rightEAR) / 2.0
            }
        } catch {
            // Landmark detection failed — skip blink detection this frame
        }

        lock.lock()
        _latestYaw = yawDegrees
        if let prev = _smoothedYaw {
            _smoothedYaw = prev + smoothing * (yawDegrees - prev)
        } else {
            _smoothedYaw = yawDegrees
        }
        if let pitch = pitchDegrees {
            if let prev = _smoothedPitch {
                _smoothedPitch = prev + smoothing * (pitch - prev)
            } else {
                _smoothedPitch = pitch
            }
            _latestPitch = pitch
        }
        _frameCount += 1

        if let earValue = ear {
            _latestEAR = earValue
            detectBlink(ear: earValue)
        }
        lock.unlock()
    }

    // MARK: - Blink detection (called under lock)

    private func detectBlink(ear: Double) {
        let eyesClosed = ear < blinkThreshold
        let eyesOpen = ear >= openThreshold

        if _wasEyesClosed && eyesOpen {
            // Blink completed (eyes reopened after being closed)
            let now = Date()

            if now >= _doubleBlinkCooldownUntil {
                if let lastBlink = _lastBlinkTime {
                    let gap = now.timeIntervalSince(lastBlink)
                    if gap >= doubleBlinkMinGap && gap <= doubleBlinkMaxGap {
                        // Double-blink detected
                        _doubleBlinkPending = true
                        _doubleBlinkCooldownUntil = now.addingTimeInterval(doubleBlinkCooldown)
                        _lastBlinkTime = nil
                        _wasEyesClosed = false
                        return
                    }
                }
                _lastBlinkTime = now
            }
        }

        if eyesClosed {
            _wasEyesClosed = true
        } else if eyesOpen {
            _wasEyesClosed = false
        }
        // In the hysteresis zone (between thresholds), keep previous state
    }

    /// Eye Aspect Ratio: height / width of the eye contour bounding box.
    /// Open eyes ≈ 0.3–0.5, closed ≈ 0.05–0.15.
    private func eyeAspectRatio(region: VNFaceLandmarkRegion2D) -> Double {
        let count = region.pointCount
        guard count >= 4 else { return 1.0 }

        let ptr = region.normalizedPoints
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for i in 0..<count {
            let p = ptr[i]
            let x = Double(p.x)
            let y = Double(p.y)
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }

        let width = maxX - minX
        let height = maxY - minY
        guard width > 0.001 else { return 1.0 }
        return height / width
    }
}
