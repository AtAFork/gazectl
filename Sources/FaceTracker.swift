import CoreVideo
import Vision

final class FaceTracker {
    private let camera = CameraCapture()
    private let lock = NSLock()
    private var _latestYaw: Double?
    private var _frameCount: Int = 0

    var latestYaw: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _latestYaw
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frameCount
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
        let request = VNDetectFaceLandmarksRequest()

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let face = request.results?.first,
              let yawNumber = face.yaw else {
            lock.lock()
            _latestYaw = nil
            _frameCount += 1
            lock.unlock()
            return
        }

        let yawDegrees = yawNumber.doubleValue * 180.0 / .pi

        lock.lock()
        _latestYaw = yawDegrees
        _frameCount += 1
        lock.unlock()
    }
}
