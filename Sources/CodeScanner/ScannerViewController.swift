//
//  CodeScanner.swift
//  https://github.com/twostraws/CodeScanner
//
//  Created by Paul Hudson on 14/12/2021.
//  Copyright © 2021 Paul Hudson. All rights reserved.
//

import AVFoundation
import UIKit

@available(macCatalyst 14.0, *)
extension CodeScannerView {
    
    public class ScannerViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate, AVCaptureMetadataOutputObjectsDelegate, UIAdaptivePresentationControllerDelegate {
        private let photoOutput = AVCapturePhotoOutput()
        private var isCapturing = false
        private var handler: ((UIImage) -> Void)?
        var parentView: CodeScannerView!
        var codesFound = Set<String>()
        var didFinishScanning = false
        var lastTime = Date(timeIntervalSince1970: 0)
        private let showViewfinder: Bool
        
        private var isGalleryShowing: Bool = false {
            didSet {
                // Update binding
                if parentView.isGalleryPresented.wrappedValue != isGalleryShowing {
                    parentView.isGalleryPresented.wrappedValue = isGalleryShowing
                }
            }
        }

        public init(showViewfinder: Bool = false, parentView: CodeScannerView) {
            self.parentView = parentView
            self.showViewfinder = showViewfinder
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            self.showViewfinder = false
            super.init(coder: coder)
        }
        
        func openGallery() {
            isGalleryShowing = true
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self
            imagePicker.presentationController?.delegate = self
            present(imagePicker, animated: true, completion: nil)
        }
        
        @objc func openGalleryFromButton(_ sender: UIButton) {
            openGallery()
        }

        public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            isGalleryShowing = false
            
            if let qrcodeImg = info[.originalImage] as? UIImage {
                let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
                let ciImage = CIImage(image:qrcodeImg)!
                var qrCodeLink = ""

                let features = detector.features(in: ciImage)

                for feature in features as! [CIQRCodeFeature] {
                    qrCodeLink = feature.messageString!
                    if qrCodeLink == "" {
                        didFail(reason: .badOutput)
                    } else {
                        let corners = [
                            feature.bottomLeft,
                            feature.bottomRight,
                            feature.topRight,
                            feature.topLeft
                        ]
                        let result = ScanResult(string: qrCodeLink, type: .qr, image: qrcodeImg, corners: corners)
                        found(result)
                    }

                }

            } else {
                print("Something went wrong")
            }

            dismiss(animated: true, completion: nil)
        }
        
        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            isGalleryShowing = false
            dismiss(animated: true, completion: nil)
        }

        public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            // Galery is no longer being presented
            isGalleryShowing = false
        }

        #if targetEnvironment(simulator)
        override public func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = true

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.text = "You're running in the simulator, which means the camera isn't available. Tap anywhere to send back some simulated data."
            label.textAlignment = .center

            let button = UIButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle("Select a custom image", for: .normal)
            button.setTitleColor(UIColor.systemBlue, for: .normal)
            button.setTitleColor(UIColor.gray, for: .highlighted)
            button.addTarget(self, action: #selector(openGalleryFromButton), for: .touchUpInside)

            let stackView = UIStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.axis = .vertical
            stackView.spacing = 50
            stackView.addArrangedSubview(label)
            stackView.addArrangedSubview(button)

            view.addSubview(stackView)

            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: 50),
                stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }

        override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Send back their simulated data, as if it was one of the types they were scanning for
            found(ScanResult(
                string: parentView.simulatedData,
                type: parentView.codeTypes.first ?? .qr, image: nil, corners: []
            ))
        }
        
        #else
        
        var captureSession: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer!
        let fallbackVideoCaptureDevice = AVCaptureDevice.default(for: .video)
        private var activeVideoCaptureDevice: AVCaptureDevice?
        private var previewLayerAdded = false

        // Dedicated serial queue for all AVCaptureSession operations (thread safety)
        private let sessionQueue = DispatchQueue(label: "com.codescanner.session")

        private lazy var viewFinder: UIImageView? = {
            guard let image = UIImage(named: "viewfinder", in: .module, with: nil) else {
                return nil
            }

            let imageView = UIImageView(image: image)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            return imageView
        }()
        
        private lazy var manualCaptureButton: UIButton = {
            let button = UIButton(type: .system)
            let image = UIImage(named: "capture", in: .module, with: nil)
            button.setBackgroundImage(image, for: .normal)
            button.addTarget(self, action: #selector(manualCapturePressed), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }()

        private lazy var manualSelectButton: UIButton = {
            let button = UIButton(type: .system)
            let image = UIImage(systemName: "photo.on.rectangle")
            let background = UIImage(systemName: "capsule.fill")?.withTintColor(.systemBackground, renderingMode: .alwaysOriginal)
            button.setImage(image, for: .normal)
            button.setBackgroundImage(background, for: .normal)
            button.addTarget(self, action: #selector(openGalleryFromButton), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }()

        override public func viewDidLoad() {
            super.viewDidLoad()
            codeScannerLogger?.log(level: .info, message: "ScannerViewController viewDidLoad started")
            self.addOrientationDidChangeObserver()
            self.setBackgroundColor()
            self.handleCameraPermission()
        }

        override public func viewWillLayoutSubviews() {
            previewLayer?.frame = view.layer.bounds
        }

        @objc func updateOrientation() {
            guard let orientation = view.window?.windowScene?.interfaceOrientation else { return }
            guard let connection = captureSession?.connections.last, connection.isVideoOrientationSupported else { return }
            switch orientation {
            case .portrait:
                connection.videoOrientation = .portrait
            case .landscapeLeft:
                connection.videoOrientation = .landscapeLeft
            case .landscapeRight:
                connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                connection.videoOrientation = .portraitUpsideDown
            default:
                connection.videoOrientation = .portrait
            }
        }

        override public func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateOrientation()
        }

        override public func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)

            codeScannerLogger?.log(level: .info, message: "viewWillAppear - captureSession exists: \(captureSession != nil)")

            // Only restart session if it was previously configured
            // Initial setup happens in handleCameraPermission
            sessionQueue.async { [weak self] in
                guard let self = self, let session = self.captureSession else {
                    codeScannerLogger?.log(level: .info, message: "viewWillAppear: Skipping - session not configured yet" )
                    return
                }

                if !session.isRunning {
                    codeScannerLogger?.log(level: .info, message: "viewWillAppear: Restarting session" )
                    self.startSession()
                }
            }
        }

        private func handleCameraPermission() {
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            codeScannerLogger?.log(level: .info, message: "Camera permission status: \(authStatus.rawValue)" )

            switch authStatus {
            case .restricted:
                break

            case .denied:
                self.didFail(reason: .permissionDenied)

            case .notDetermined:
                // Suspend session queue to prevent operations until permission resolved
                sessionQueue.suspend()

                codeScannerLogger?.log(level: .info, message: "Suspended session queue until permission resolved" )

                self.requestCameraAccess { [weak self] granted in
                    guard let self else {
                        self?.sessionQueue.resume()
                        return
                    }

                    if granted {
                        self.sessionQueue.async {
                            self.setupCaptureDevice()
                            DispatchQueue.main.async {
                                self.setupPreviewLayer()
                            }
                            self.startSession()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.didFail(reason: .permissionDenied)
                        }
                    }

                    // Resume session queue
                    self.sessionQueue.resume()

                    codeScannerLogger?.log(level: .info, message: "Resumed session queue after permission response")
                }

            case .authorized:
                codeScannerLogger?.log(level: .info, message: "Camera permission authorized, setting up capture device")

                // Setup on session queue
                sessionQueue.async { [weak self] in
                    guard let self = self else { return }

                    self.setupCaptureDevice()

                    // Setup preview layer on main thread
                    DispatchQueue.main.async {
                        self.setupPreviewLayer()
                    }

                    // Start session on session queue
                    self.startSession()
                }

            default:
                codeScannerLogger?.log(level: .error, message: "Unknown camera permission status: \(authStatus.rawValue)")
                break
            }
        }

        private func requestCameraAccess(completion: @escaping (Bool) -> Void) {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                codeScannerLogger?.log(level: granted ? .info : .error, message: "Camera access request result: \(granted)")
                completion(granted)
            }
        }
      
        private func addOrientationDidChangeObserver() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateOrientation),
                name: Notification.Name("UIDeviceOrientationDidChangeNotification"),
                object: nil
            )
        }

        private func addSessionObservers() {
            // Monitor runtime errors
            NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
                    return
                }

                codeScannerLogger?.log(level: .error, message: "AVCaptureSession runtime error: \(error.localizedDescription) (code: \(error.code.rawValue))")

                // Report error to client - let them decide how to handle it
                DispatchQueue.main.async {
                    self?.didFail(reason: .initError(error))
                }
            }

            // Monitor interruptions
            NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: captureSession,
                queue: nil
            ) { notification in
                if let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? AVCaptureSession.InterruptionReason {
                    codeScannerLogger?.log(level: .info, message: "AVCaptureSession was interrupted - reason: \(reason.rawValue)")
                } else {
                    codeScannerLogger?.log(level: .info, message: "AVCaptureSession was interrupted")
                }
            }

            NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: captureSession,
                queue: nil
            ) { notification in
                codeScannerLogger?.log(level: .info, message: "AVCaptureSession interruption ended")
            }
        }

        private func setBackgroundColor(_ color: UIColor = .black) {
            view.backgroundColor = color
        }

        private func setupCaptureDevice() {
            codeScannerLogger?.log(level: .info, message: "Setting up capture device")

            guard let videoCaptureDevice = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice else {
                codeScannerLogger?.log(level: .error, message: "No video capture device available")
                DispatchQueue.main.async {
                    self.didFail(reason: .badInput)
                }
                return
            }

            // Store the active device for torch control
            activeVideoCaptureDevice = videoCaptureDevice

            codeScannerLogger?.log(level: .info, message: "Using video capture device: \(videoCaptureDevice.localizedName)")

            captureSession = AVCaptureSession()

            captureSession?.beginConfiguration()

            codeScannerLogger?.log(level: .info, message: "Beginning capture session configuration")

            // Create video input
            let videoInput: AVCaptureDeviceInput

            do {
                videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
                codeScannerLogger?.log(level: .info, message: "Successfully created video input")
            } catch {
                codeScannerLogger?.log(level: .error, message: "Failed to create video input: \(error.localizedDescription)")
                captureSession?.commitConfiguration()
                DispatchQueue.main.async {
                    self.didFail(reason: .initError(error))
                }
                return
            }

            // Add video input
            if captureSession?.canAddInput(videoInput) == true {
                captureSession?.addInput(videoInput)
                codeScannerLogger?.log(level: .info, message: "Successfully added video input to capture session")
            } else {
                codeScannerLogger?.log(level: .error, message: "Cannot add video input to capture session")
                captureSession?.commitConfiguration()
                DispatchQueue.main.async {
                    self.didFail(reason: .badInput)
                }
                return
            }

            // Add metadata output
            let metadataOutput = AVCaptureMetadataOutput()
            if captureSession?.canAddOutput(metadataOutput) == true {
                captureSession?.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metadataOutput.metadataObjectTypes = parentView.codeTypes
                codeScannerLogger?.log(level: .info, message: "Successfully added metadata output. Code types: \(parentView.codeTypes)")
            } else {
                codeScannerLogger?.log(level: .error, message: "Cannot add metadata output to capture session")
                captureSession?.commitConfiguration()
                DispatchQueue.main.async {
                    self.didFail(reason: .badOutput)
                }
                return
            }

            // Add photo output
            if captureSession?.canAddOutput(photoOutput) == true {
                captureSession?.addOutput(photoOutput)
            }

            // Commit atomic configuration
            captureSession?.commitConfiguration()

            codeScannerLogger?.log(level: .info, message: "Committed capture session configuration")

            // Add observers after session is configured
            DispatchQueue.main.async {
                self.addSessionObservers()
            }
        }

        private func setupPreviewLayer() {
            // MUST be called on main thread (UIKit requirement)
            guard Thread.isMainThread else {
                DispatchQueue.main.async { self.setupPreviewLayer() }
                return
            }

            codeScannerLogger?.log(level: .info, message: "Setting up preview layer on main thread")

            guard let captureSession else {
                codeScannerLogger?.log(level: .error, message: "Cannot setup preview layer: captureSession is nil")
                return
            }

            // Create preview layer if needed
            if previewLayer == nil {
                previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                codeScannerLogger?.log(level: .info, message: "Created preview layer")
            }

            previewLayer.frame = view.layer.bounds
            previewLayer.videoGravity = .resizeAspectFill

            // Add preview layer if not already added
            if !previewLayerAdded {
                view.layer.addSublayer(previewLayer)
                previewLayerAdded = true
                codeScannerLogger?.log(level: .info, message: "Added preview layer to view hierarchy")
            }

            addviewfinder()
            reset()
        }

        private func startSession() {
            codeScannerLogger?.log(level: .info, message: "Starting capture session on session queue")

            guard let session = captureSession else {
                codeScannerLogger?.log(level: .error, message: "Cannot start: session is nil")
                DispatchQueue.main.async {
                    self.didFail(reason: .badInput)
                }
                return
            }

            // Validate configuration
            guard session.inputs.count > 0 else {
                codeScannerLogger?.log(level: .error, message: "Cannot start: no inputs configured (count: 0)")
                DispatchQueue.main.async {
                    self.didFail(reason: .badInput)
                }
                return
            }

            guard session.outputs.count > 0 else {
                codeScannerLogger?.log(level: .error, message: "Cannot start: no outputs configured (count: 0)")
                DispatchQueue.main.async {
                    self.didFail(reason: .badOutput)
                }
                return
            }

            guard !session.isRunning else {
                codeScannerLogger?.log(level: .info, message: "Session already running")
                return
            }

            // Log configuration before starting
            codeScannerLogger?.log(level: .info, message: "Starting session - inputs: \(session.inputs.count), outputs: \(session.outputs.count)")

            // Start on session queue (blocking call)
            session.startRunning()

            // IMPORTANT: Check isRunning on MAIN thread (non-atomic property)
            DispatchQueue.main.async {
                let isRunning = self.captureSession?.isRunning ?? false
                codeScannerLogger?.log(level: isRunning ? .info : .error, message: "Session started, isRunning: \(isRunning)")

                if !isRunning {
                    codeScannerLogger?.log(level: .error, message: "Session failed to start - interrupted: \(session.isInterrupted)")
                    self.didFail(reason: .badInput)
                }
            }
        }

        private func addviewfinder() {
            guard showViewfinder, let imageView = viewFinder else { return }

            view.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 200),
                imageView.heightAnchor.constraint(equalToConstant: 200),
            ])
        }

        override public func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)

            // Stop session on session queue (thread safety)
            sessionQueue.async { [weak self] in
                guard let self, let session = self.captureSession else {
                    return
                }

                if session.isRunning {
                    codeScannerLogger?.log(level: .info, message: "Stopping capture session in viewDidDisappear")
                    session.stopRunning()
                }
            }

            NotificationCenter.default.removeObserver(self)
        }

        override public var prefersStatusBarHidden: Bool {
            true
        }

        override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            .all
        }

        /** Touch the screen for autofocus */
        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.view == view,
                  let touchPoint = touches.first,
                  let device = parentView.videoCaptureDevice ?? fallbackVideoCaptureDevice,
                  device.isFocusPointOfInterestSupported
            else { return }

            let videoView = view
            let screenSize = videoView!.bounds.size
            let xPoint = touchPoint.location(in: videoView).y / screenSize.height
            let yPoint = 1.0 - touchPoint.location(in: videoView).x / screenSize.width
            let focusPoint = CGPoint(x: xPoint, y: yPoint)

            do {
                try device.lockForConfiguration()
            } catch {
                return
            }

            // Focus to the correct point, make continiuous focus and exposure so the point stays sharp when moving the device closer
            device.focusPointOfInterest = focusPoint
            device.focusMode = .continuousAutoFocus
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
            device.unlockForConfiguration()
        }
        
        @objc func manualCapturePressed(_ sender: Any?) {
            self.readyManualCapture()
        }
        
        func showManualCaptureButton(_ isManualCapture: Bool) {
            if manualCaptureButton.superview == nil {
                view.addSubview(manualCaptureButton)
                NSLayoutConstraint.activate([
                    manualCaptureButton.heightAnchor.constraint(equalToConstant: 60),
                    manualCaptureButton.widthAnchor.constraint(equalTo: manualCaptureButton.heightAnchor),
                    view.centerXAnchor.constraint(equalTo: manualCaptureButton.centerXAnchor),
                    view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: manualCaptureButton.bottomAnchor, constant: 32)
                ])
            }
            
            view.bringSubviewToFront(manualCaptureButton)
            manualCaptureButton.isHidden = !isManualCapture
        }
        
        func showManualSelectButton(_ isManualSelect: Bool) {
            if manualSelectButton.superview == nil {
                view.addSubview(manualSelectButton)
                NSLayoutConstraint.activate([
                    manualSelectButton.heightAnchor.constraint(equalToConstant: 50),
                    manualSelectButton.widthAnchor.constraint(equalToConstant: 60),
                    view.centerXAnchor.constraint(equalTo: manualSelectButton.centerXAnchor),
                    view.safeAreaLayoutGuide.bottomAnchor.constraint(equalTo: manualSelectButton.bottomAnchor, constant: 32)
                ])
            }
            
            view.bringSubviewToFront(manualSelectButton)
            manualSelectButton.isHidden = !isManualSelect
        }
        #endif
        
        func updateViewController(isTorchOn: Bool, isGalleryPresented: Bool, isManualCapture: Bool, isManualSelect: Bool) {
            #if !targetEnvironment(simulator)
            // Use the active video capture device from the session instead of creating a new one
            if let device = activeVideoCaptureDevice, device.hasTorch {
                do {
                    try device.lockForConfiguration()
                    device.torchMode = isTorchOn ? .on : .off
                    device.unlockForConfiguration()
                } catch {
                    codeScannerLogger?.log(level: .error, message: "Failed to configure torch: \(error.localizedDescription)")
                }
            }

            showManualCaptureButton(isManualCapture)
            showManualSelectButton(isManualSelect)
            #endif

            if isGalleryPresented && !isGalleryShowing {
                openGallery()
            }
        }
        
        public func reset() {
            codesFound.removeAll()
            didFinishScanning = false
            lastTime = Date(timeIntervalSince1970: 0)
        }
        
        public func readyManualCapture() {
            guard parentView.scanMode == .manual else { return }
            self.reset()
            lastTime = Date()
        }

        public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let metadataObject = metadataObjects.first {
                guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
                guard let stringValue = readableObject.stringValue else { return }
                
                guard didFinishScanning == false else { return }
                
                let photoSettings = AVCapturePhotoSettings()
                guard !isCapturing else { return }
                isCapturing = true
                
                handler = { [weak self] image in
                    guard let self else { return }
                    let result = ScanResult(string: stringValue, type: readableObject.type, image: image, corners: readableObject.corners)
                    
                    switch parentView.scanMode {
                    case .once:
                        found(result)
                        // make sure we only trigger scan once per use
                        didFinishScanning = true
                        
                    case .manual:
                        if !didFinishScanning, isWithinManualCaptureInterval() {
                            found(result)
                            didFinishScanning = true
                        }
                        
                    case .oncePerCode:
                        if !codesFound.contains(stringValue) {
                            codesFound.insert(stringValue)
                            found(result)
                        }
                        
                    case .continuous:
                        if isPastScanInterval() {
                            found(result)
                        }
                    }
                }
                photoOutput.capturePhoto(with: photoSettings, delegate: self)
            }
        }

        func isPastScanInterval() -> Bool {
            Date().timeIntervalSince(lastTime) >= parentView.scanInterval
        }
        
        func isWithinManualCaptureInterval() -> Bool {
            Date().timeIntervalSince(lastTime) <= 0.5
        }

        func found(_ result: ScanResult) {
            lastTime = Date()

            if parentView.shouldVibrateOnSuccess {
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            }

            parentView.completion(.success(result))
        }

        func didFail(reason: ScanError) {
            codeScannerLogger?.log(level: .error, message: "Scanner failed with reason: \(reason)")
            DispatchQueue.main.async {
                self.parentView.completion(.failure(reason))
            }
        }
        
    }
}

@available(macCatalyst 14.0, *)
extension CodeScannerView.ScannerViewController: AVCapturePhotoCaptureDelegate {
    
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        isCapturing = false
        guard let imageData = photo.fileDataRepresentation() else {
            print("Error while generating image from photo capture data.");
            return
        }
        guard let qrImage = UIImage(data: imageData) else {
            print("Unable to generate UIImage from image data.");
            return
        }
        handler?(qrImage)
    }
    
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        AudioServicesDisposeSystemSoundID(1108)
    }
    
    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        AudioServicesDisposeSystemSoundID(1108)
    }
    
}

@available(macCatalyst 14.0, *)
public extension AVCaptureDevice {
    
    /// This returns the Ultra Wide Camera on capable devices and the default Camera for Video otherwise.
    static var bestForVideo: AVCaptureDevice? {
        let deviceHasUltraWideCamera = !AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back).devices.isEmpty
        return deviceHasUltraWideCamera ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : AVCaptureDevice.default(for: .video)
    }
    
}
