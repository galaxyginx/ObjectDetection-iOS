//
//  CameraView.swift
//  ObjectDetection
//
//  Created by GINGA WATANABE on 2019/11/22.
//  Copyright © 2019 Y Media Labs. All rights reserved.
//

import UIKit

class CameraView: UIViewController {
    
    @IBOutlet weak var previewView: PreviewView!
    @IBOutlet weak var overlayView: OverlayView!
    @IBOutlet weak var resumeButton: UIButton!
    @IBOutlet weak var cameraUnavailableLabel: UILabel!
    
    // MARK: Constants
    private let displayFont = UIFont.systemFont(ofSize: 14.0, weight: .medium)
    private let edgeOffset: CGFloat = 2.0
    private let labelOffset: CGFloat = 10.0
    private let animationDuration = 0.5
    private let collapseTransitionThreshold: CGFloat = -30.0
    private let expandThransitionThreshold: CGFloat = 30.0
    private let delayBetweenInferencesMs: Double = 200
    
    // Holds the results at any time
    private var previousInferenceTimeMs: TimeInterval = Date.distantPast.timeIntervalSince1970 * 1000
    
    // MARK: Controllers that manage functionality
    private lazy var cameraFeedManager = CameraFeedManager(previewView: previewView)
    
    private var modelDataHandler: ModelDataManager? = ModelDataManager(model: MobileNetSSD.detect.name, labels: MobileNetSSD.detect.labels)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard modelDataHandler != nil else {
            fatalError("Failed to load model")
        }
        cameraFeedManager.delegate = self
        overlayView.clearsContextBeforeDrawing = true
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        cameraFeedManager.checkCameraConfigurationAndStartSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        cameraFeedManager.stopSession()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    // MARK: Button Actions
    @IBAction func onClickResumeButton(_ sender: Any) {
        
        cameraFeedManager.resumeInterruptedSession { (complete) in
            
            if complete {
                self.changeCameraVisibility(to: true)
            }
            else {
                self.presentUnableToResumeSessionAlert()
            }
        }
    }
    
    func presentUnableToResumeSessionAlert() {
        let alert = UIAlertController(
            title: "Unable to Resume Session",
            message: "There was an error while attempting to resume session.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        self.present(alert, animated: true)
    }
    
    /** This method runs the live camera pixelBuffer through tensorFlow to get the result.
     */
    func runModel(onPixelBuffer pixelBuffer: CVPixelBuffer) {
        
        // Run the live camera pixelBuffer through tensorFlow to get the result
        
        let currentTimeMs = Date().timeIntervalSince1970 * 1000
        
        guard  (currentTimeMs - previousInferenceTimeMs) >= delayBetweenInferencesMs else {
            return
        }
        
        previousInferenceTimeMs = currentTimeMs
        
        guard let displayResult = self.modelDataHandler?.runModel(onFrame: pixelBuffer) else {
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        DispatchQueue.main.async {
            // Draws the bounding boxes and displays class names and confidence scores.
            self.drawAfterPerformingCalculations(onInferences: displayResult.inferences, withImageSize: CGSize(width: CGFloat(width), height: CGFloat(height)))
        }
    }
    
    func drawAfterPerformingCalculations(onInferences inferences: [Inference], withImageSize imageSize:CGSize) {
        
        self.overlayView.objectOverlays = []
        self.overlayView.setNeedsDisplay()
        
        guard !inferences.isEmpty else {
            return
        }
        
        var objectOverlays: [ObjectOverlay] = []
        
        for inference in inferences {
            
            // Translates bounding box rect to current view.
            var convertedRect = inference.rect.applying(CGAffineTransform(scaleX: self.overlayView.bounds.size.width / imageSize.width, y: self.overlayView.bounds.size.height / imageSize.height))
            
            if convertedRect.origin.x < 0 {
                convertedRect.origin.x = self.edgeOffset
            }
            
            if convertedRect.origin.y < 0 {
                convertedRect.origin.y = self.edgeOffset
            }
            
            if convertedRect.maxY > self.overlayView.bounds.maxY {
                convertedRect.size.height = self.overlayView.bounds.maxY - convertedRect.origin.y - self.edgeOffset
            }
            
            if convertedRect.maxX > self.overlayView.bounds.maxX {
                convertedRect.size.width = self.overlayView.bounds.maxX - convertedRect.origin.x - self.edgeOffset
            }
            
            let confidenceValue = Int(inference.confidence * 100.0)
            let string = "\(inference.className)  (\(confidenceValue)%)"
            
            let size = string.size(usingFont: self.displayFont)
            
            let objectOverlay = ObjectOverlay(name: string, borderRect: convertedRect, nameStringSize: size, color: inference.displayColor, font: self.displayFont)
            
            objectOverlays.append(objectOverlay)
        }
        
        // Hands off drawing to the OverlayView
        self.draw(objectOverlays: objectOverlays)
    }
    
    /** Calls methods to update overlay view with detected bounding boxes and class names.
     */
    func draw(objectOverlays: [ObjectOverlay]) {
        self.overlayView.objectOverlays = objectOverlays
        self.overlayView.setNeedsDisplay()
    }
    
    func changeCameraVisibility(to: Bool) {
        self.resumeButton.isHidden = to
        self.cameraUnavailableLabel.isHidden = to
    }
}

// MARK: CameraFeedManagerDelegate Methods
extension CameraView: CameraFeedManagerDelegate {
    
    func didOutput(pixelBuffer: CVPixelBuffer) {
        runModel(onPixelBuffer: pixelBuffer)
    }
    
    // MARK: Session Handling Alerts
    func sessionRunTimeErrorOccured() {
        changeCameraVisibility(to: false)
    }
    
    func sessionWasInterrupted(canResumeManually resumeManually: Bool) {
        changeCameraVisibility(to: false)
    }
    
    func sessionInterruptionEnded() {
        changeCameraVisibility(to: true)
    }
    
    func presentVideoConfigurationErrorAlert() {
        let alertController = UIAlertController(title: "Confirguration Failed", message: "Configuration of camera has failed.", preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
        present(alertController, animated: true, completion: nil)
        changeCameraVisibility(to: false)
    }
    
    func presentCameraPermissionsDeniedAlert() {
        let alertController = UIAlertController(title: "Camera Permissions Denied", message: "Camera permissions have been denied for this app. You can change this by going to Settings", preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alertController.addAction(UIAlertAction(title: "Settings", style: .default) { (action) in
            
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
        })
        present(alertController, animated: true, completion: nil)
        changeCameraVisibility(to: false)
    }
}
