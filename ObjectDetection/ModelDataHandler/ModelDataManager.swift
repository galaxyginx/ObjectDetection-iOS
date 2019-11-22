//
//  ModelDataManager.swift
//  ObjectDetection
//
//  Created by GINGA WATANABE on 2019/11/22.
//  Copyright © 2019 Y Media Labs. All rights reserved.
//

import UIKit
import TensorFlowLite
import CoreImage

struct Result {
  let inferenceTime: Double
  let inferences: [Inference]
}

struct Inference {
  let confidence: Float
  let className: String
  let rect: CGRect
  let displayColor: UIColor
}

typealias ModelInfo = (name: String, labels: String)

enum MobileNetSSD {
    static let detect: ModelInfo = (name: "detect", labels: "labelmap")
}

class ModelDataManager: NSObject {
    
    let threshold: Float = 0.5
    
    // MARK: Model parameters
    let batchSize = 1
    let inputChannels = 3
    let inputWidth = 300
    let inputHeight = 300

    // MARK: Private properties
    private var labels: [String] = []

    /// TensorFlow Lite `Interpreter` object for performing inference on a given model.
    private var interpreter: Interpreter

    private let bgraPixel = (channels: 4, alphaComponent: 3, lastBgrComponent: 2)
    private let rgbPixelChannels = 3
    private let colorStrideValue = 10
    private let colors = [
      UIColor.red,
      UIColor(displayP3Red: 90.0/255.0, green: 200.0/255.0, blue: 250.0/255.0, alpha: 1.0),
      UIColor.green,
      UIColor.orange,
      UIColor.blue,
      UIColor.purple,
      UIColor.magenta,
      UIColor.yellow,
      UIColor.cyan,
      UIColor.brown
    ]
    
    init?(model: String, labels: String) {
        guard let path = Bundle.main.path(forResource: model, ofType: "tflite") else { return nil }
        do {
            interpreter = try Interpreter(modelPath: path)
            try interpreter.allocateTensors()
        } catch let error {
            print(error.localizedDescription)
            return nil
        }
        super.init()
        guard let labelURL = Bundle.main.url(forResource: labels, withExtension: "txt") else { fatalError("Can't find the label file") }
        do {
            self.labels = try String(contentsOf: labelURL, encoding: .utf8).components(separatedBy: .newlines)
        } catch {
            fatalError("Unable to load labels")
        }
    }
    
    func runModel(onFrame pixelBuffer: CVPixelBuffer) -> Result? {
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourcePixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        assert(sourcePixelFormat == kCVPixelFormatType_32ARGB ||
                 sourcePixelFormat == kCVPixelFormatType_32BGRA ||
                   sourcePixelFormat == kCVPixelFormatType_32RGBA)


        let imageChannels = 4
        assert(imageChannels >= inputChannels)

        // Crops the image to the biggest square in the center and scales it down to model dimensions.
        let scaledSize = CGSize(width: inputWidth, height: inputHeight)
        guard let scaledPixelBuffer = pixelBuffer.resized(to: scaledSize) else {
          return nil
        }

        let interval: TimeInterval
        let outputBoundingBox: Tensor
        let outputClasses: Tensor
        let outputScores: Tensor
        let outputCount: Tensor
        do {
          let inputTensor = try interpreter.input(at: 0)

          // Remove the alpha component from the image buffer to get the RGB data.
          guard let rgbData = rgbDataFromBuffer(
            scaledPixelBuffer,
            byteCount: batchSize * inputWidth * inputHeight * inputChannels,
            isModelQuantized: inputTensor.dataType == .uInt8
          ) else {
            print("Failed to convert the image buffer to RGB data.")
            return nil
          }

          // Copy the RGB data to the input `Tensor`.
          try interpreter.copy(rgbData, toInputAt: 0)

          // Run inference by invoking the `Interpreter`.
          let startDate = Date()
          try interpreter.invoke()
          interval = Date().timeIntervalSince(startDate) * 1000

          outputBoundingBox = try interpreter.output(at: 0)
          outputClasses = try interpreter.output(at: 1)
          outputScores = try interpreter.output(at: 2)
          outputCount = try interpreter.output(at: 3)
        } catch let error {
          print("Failed to invoke the interpreter with error: \(error.localizedDescription)")
          return nil
        }

        // Formats the results
        let resultArray = formatResults(
          boundingBox: [Float](unsafeData: outputBoundingBox.data) ?? [],
          outputClasses: [Float](unsafeData: outputClasses.data) ?? [],
          outputScores: [Float](unsafeData: outputScores.data) ?? [],
          outputCount: Int(([Float](unsafeData: outputCount.data) ?? [0])[0]),
          width: CGFloat(imageWidth),
          height: CGFloat(imageHeight)
        )

        // Returns the inference time and inferences
        return Result(inferenceTime: interval, inferences: resultArray)
    }
    
    func formatResults(boundingBox: [Float], outputClasses: [Float], outputScores: [Float], outputCount: Int, width: CGFloat, height: CGFloat) -> [Inference]{
      var resultsArray: [Inference] = []
      if (outputCount == 0) {
        return resultsArray
      }
      for i in 0...outputCount - 1 {

        let score = outputScores[i]

        // Filters results with confidence < threshold.
        guard score >= threshold else {
          continue
        }

        // Gets the output class names for detected classes from labels list.
        let outputClassIndex = Int(outputClasses[i])
        let outputClass = labels[outputClassIndex + 1]

        var rect: CGRect = CGRect.zero

        // Translates the detected bounding box to CGRect.
        rect.origin.y = CGFloat(boundingBox[4*i])
        rect.origin.x = CGFloat(boundingBox[4*i+1])
        rect.size.height = CGFloat(boundingBox[4*i+2]) - rect.origin.y
        rect.size.width = CGFloat(boundingBox[4*i+3]) - rect.origin.x

        // The detected corners are for model dimensions. So we scale the rect with respect to the
        // actual image dimensions.
        let newRect = rect.applying(CGAffineTransform(scaleX: width, y: height))

        // Gets the color assigned for the class
        let colorToAssign = colorForClass(withIndex: outputClassIndex + 1)
        let inference = Inference(confidence: score,
                                  className: outputClass,
                                  rect: newRect,
                                  displayColor: colorToAssign)
        resultsArray.append(inference)
      }

      // Sort results in descending order of confidence.
      resultsArray.sort { (first, second) -> Bool in
        return first.confidence  > second.confidence
      }

      return resultsArray
    }
    
    private func rgbDataFromBuffer(
      _ buffer: CVPixelBuffer,
      byteCount: Int,
      isModelQuantized: Bool
    ) -> Data? {
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      guard let mutableRawPointer = CVPixelBufferGetBaseAddress(buffer) else {
        return nil
      }
      assert(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
      let count = CVPixelBufferGetDataSize(buffer)
      let bufferData = Data(bytesNoCopy: mutableRawPointer, count: count, deallocator: .none)
      var rgbBytes = [UInt8](repeating: 0, count: byteCount)
      var pixelIndex = 0
      for component in bufferData.enumerated() {
        let bgraComponent = component.offset % bgraPixel.channels;
        let isAlphaComponent = bgraComponent == bgraPixel.alphaComponent;
        guard !isAlphaComponent else {
          pixelIndex += 1
          continue
        }
        // Swizzle BGR -> RGB.
        let rgbIndex = pixelIndex * rgbPixelChannels + (bgraPixel.lastBgrComponent - bgraComponent)
        rgbBytes[rgbIndex] = component.element
      }
      if isModelQuantized { return Data(bytes: rgbBytes) }
      return Data(copyingBufferOf: rgbBytes.map { Float($0) / 255.0 })
    }
    
    private func colorForClass(withIndex index: Int) -> UIColor {

      // We have a set of colors and the depending upon a stride, it assigns variations to of the base
      // colors to each object based on its index.
      let baseColor = colors[index % colors.count]

      var colorToAssign = baseColor

      let percentage = CGFloat((colorStrideValue / 2 - index / colors.count) * colorStrideValue)

      if let modifiedColor = baseColor.getModified(byPercentage: percentage) {
        colorToAssign = modifiedColor
      }

      return colorToAssign
    }
}

// MARK: - Extensions

extension Data {
  /// Creates a new buffer by copying the buffer pointer of the given array.
  ///
  /// - Warning: The given array's element type `T` must be trivial in that it can be copied bit
  ///     for bit with no indirection or reference-counting operations; otherwise, reinterpreting
  ///     data from the resulting buffer has undefined behavior.
  /// - Parameter array: An array with elements of type `T`.
  init<T>(copyingBufferOf array: [T]) {
    self = array.withUnsafeBufferPointer(Data.init)
  }
}

extension Array {
  /// Creates a new array from the bytes of the given unsafe data.
  ///
  /// - Warning: The array's `Element` type must be trivial in that it can be copied bit for bit
  ///     with no indirection or reference-counting operations; otherwise, copying the raw bytes in
  ///     the `unsafeData`'s buffer to a new array returns an unsafe copy.
  /// - Note: Returns `nil` if `unsafeData.count` is not a multiple of
  ///     `MemoryLayout<Element>.stride`.
  /// - Parameter unsafeData: The data containing the bytes to turn into an array.
  init?(unsafeData: Data) {
    guard unsafeData.count % MemoryLayout<Element>.stride == 0 else { return nil }
    #if swift(>=5.0)
    self = unsafeData.withUnsafeBytes { .init($0.bindMemory(to: Element.self)) }
    #else
    self = unsafeData.withUnsafeBytes {
      .init(UnsafeBufferPointer<Element>(
        start: $0,
        count: unsafeData.count / MemoryLayout<Element>.stride
      ))
    }
    #endif  // swift(>=5.0)
  }
}
