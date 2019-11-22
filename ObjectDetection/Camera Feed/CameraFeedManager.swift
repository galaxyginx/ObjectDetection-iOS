//
//  CameraFeedManager.swift
//  ObjectDetection
//
//  Created by GINGA WATANABE on 2019/11/22.
//  Copyright © 2019 Y Media Labs. All rights reserved.
//

import UIKit
import AVFoundation

// MARK: CameraFeedManagerDelegate Declaration
protocol CameraFeedManagerDelegate: class {
    
    /**
     This method delivers the pixel buffer of the current frame seen by the device's camera.
     */
    func didOutput(pixelBuffer: CVPixelBuffer)
    
    /**
     This method initimates that the camera permissions have been denied.
     */
    func presentCameraPermissionsDeniedAlert()
    
    /**
     This method initimates that there was an error in video configurtion.
     */
    func presentVideoConfigurationErrorAlert()
    
    /**
     This method initimates that a session runtime error occured.
     */
    func sessionRunTimeErrorOccured()
    
    /**
     This method initimates that the session was interrupted.
     */
    func sessionWasInterrupted(canResumeManually resumeManually: Bool)
    
    /**
     This method initimates that the session interruption has ended.
     */
    func sessionInterruptionEnded()
    
}

enum CameraStatus {
    case ready
    case unavailable
    case permissionDenied
}

/**
 This class manages all camera related functionality
 */
class CameraFeedManager: NSObject {
    
    // MARK: Camera Related Instance Variables
    let session: AVCaptureSession = AVCaptureSession()
    let previewView: PreviewView
    let sessionQueue = DispatchQueue(label: "sessionQueue")
    lazy var videoDataOutput = AVCaptureVideoDataOutput()
    var isSessionRunning = false
    
    var cameraStatus: CameraStatus = .unavailable
    
    // MARK: CameraFeedManagerDelegate
    weak var delegate: CameraFeedManagerDelegate?
    
    // MARK: Initializer
    init(previewView: PreviewView) {
        self.previewView = previewView
        super.init()
        
        // Initializes the session
        session.sessionPreset = .high
        self.previewView.session = session
        self.previewView.previewLayer.connection?.videoOrientation = .portrait
        self.previewView.previewLayer.videoGravity = .resizeAspectFill
        self.checkAVAuthorizationStatus()
    }
    
    private func checkAVAuthorizationStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraStatus = .ready
        case .notDetermined:
            self.sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { (granted) in
                if granted {
                    self.cameraStatus = .ready
                } else {
                    self.cameraStatus = .permissionDenied
                }
                self.sessionQueue.resume()
            }
        case .denied:
            self.cameraStatus = .permissionDenied
        default:
            break
        }
        
        sessionQueue.async {
            self.configureSession()
        }
    }
    
    /**
     This method handles all the steps to configure an AVCaptureSession.
     */
    private func configureSession() {
        
        guard cameraStatus == .ready else {
            return
        }
        session.beginConfiguration()
        
        // Tries to add an AVCaptureDeviceInput.
        guard addVideoDeviceInput() == true else {
            self.session.commitConfiguration()
            self.cameraStatus = .unavailable
            return
        }
        
        // Tries to add an AVCaptureVideoDataOutput.
        guard addVideoDataOutput() else {
            self.session.commitConfiguration()
            self.cameraStatus = .unavailable
            return
        }
        
        session.commitConfiguration()
        self.cameraStatus = .ready
    }
    
    // MARK: Session Start and End methods
    
    /**
     This method starts an AVCaptureSession based on whether the camera configuration was successful.
     */
    func checkCameraConfigurationAndStartSession() {
        sessionQueue.async {
            switch self.cameraStatus {
            case .ready:
                self.addObservers()
                self.startSession()
            case .unavailable:
                DispatchQueue.main.async {
                    self.delegate?.presentVideoConfigurationErrorAlert()
                }
            case .permissionDenied:
                self.cameraStatus = .permissionDenied
                DispatchQueue.main.async {
                    self.delegate?.presentCameraPermissionsDeniedAlert()
                }
            }
        }
    }
    
    /**
     This method starts the AVCaptureSession
     **/
    private func startSession() {
        self.session.startRunning()
        self.isSessionRunning = self.session.isRunning
    }
    
    /**
     This method resumes an interrupted AVCaptureSession.
     */
    func resumeInterruptedSession(withCompletion completion: @escaping (Bool) -> ()) {
        sessionQueue.async {
            self.startSession()
            DispatchQueue.main.async {
                completion(self.isSessionRunning)
            }
        }
    }
    
    /**
     This method stops a running an AVCaptureSession.
     */
    func stopSession() {
        self.removeObservers()
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
    }
    
    /**
     This method tries to an AVCaptureDeviceInput to the current AVCaptureSession.
     */
    private func addVideoDeviceInput() -> Bool {
        
        /**Tries to get the default back camera.
         */
        guard let camera  = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            fatalError("Cannot find camera")
        }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                return true
            }
            else {
                return false
            }
        }
        catch {
            fatalError("Cannot create video device input")
        }
    }
    
    /**
     This method tries to an AVCaptureVideoDataOutput to the current AVCaptureSession.
     */
    private func addVideoDataOutput() -> Bool {
        
        let sampleBufferQueue = DispatchQueue(label: "sampleBufferQueue")
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [ String(kCVPixelBufferPixelFormatTypeKey) : kCMPixelFormat_32BGRA]
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.connection(with: .video)?.videoOrientation = .portrait
            return true
        }
        return false
    }
    
    // MARK: Notification Observer Handling
    private func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedManager.sessionRuntimeErrorOccured(notification:)), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedManager.sessionWasInterrupted(notification:)), name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedManager.sessionInterruptionEnded), name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
    }
    
    // MARK: Notification Observers
    @objc func sessionWasInterrupted(notification: Notification) {
        
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
            let reasonIntegerValue = userInfoValue.integerValue,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")
            
            var canResumeManually = false
            if reason == .videoDeviceInUseByAnotherClient {
                canResumeManually = true
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                canResumeManually = false
            }
            
            self.delegate?.sessionWasInterrupted(canResumeManually: canResumeManually)
            
        }
    }
    
    @objc func sessionInterruptionEnded(notification: Notification) {
        
        self.delegate?.sessionInterruptionEnded()
    }
    
    @objc func sessionRuntimeErrorOccured(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            return
        }
        
        print("Capture session runtime error: \(error)")
        
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.startSession()
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.sessionRunTimeErrorOccured()
                    }
                }
            }
        } else {
            self.delegate?.sessionRunTimeErrorOccured()
            
        }
    }
}

/**
 AVCaptureVideoDataOutputSampleBufferDelegate
 */
extension CameraFeedManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    /** This method delegates the CVPixelBuffer of the frame seen by the camera currently.
     */
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // Converts the CMSampleBuffer to a CVPixelBuffer.
        let pixelBuffer: CVPixelBuffer? = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        guard let imagePixelBuffer = pixelBuffer else {
            return
        }
        
        // Delegates the pixel buffer to the ViewController.
        delegate?.didOutput(pixelBuffer: imagePixelBuffer)
    }
}
