import AVFoundation
import CoreMedia
import CoreVideo

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.gazectl.camera", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer) -> Void)?

    func start(cameraIndex: Int) throws {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discoverySession.devices
        guard cameraIndex < devices.count else {
            throw CameraCaptureError.cameraNotFound(index: cameraIndex, available: devices.count)
        }
        let device = devices[cameraIndex]

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        session.sessionPreset = .medium
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}

enum CameraCaptureError: Error, CustomStringConvertible {
    case cameraNotFound(index: Int, available: Int)
    case cannotAddInput
    case cannotAddOutput

    var description: String {
        switch self {
        case .cameraNotFound(let index, let available):
            return "Camera \(index) not found (available: \(available))"
        case .cannotAddInput:
            return "Cannot add camera input to capture session"
        case .cannotAddOutput:
            return "Cannot add video output to capture session"
        }
    }
}
