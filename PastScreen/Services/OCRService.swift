//
//  OCRService.swift
//  PastScreen
//
//  Local OCR powered by Vision.
//

import AppKit
import Foundation
import ImageIO
import Vision

enum OCRServiceError: LocalizedError {
    case invalidImageData
    case failedToCreateCGImage

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return NSLocalizedString("editor.ocr.error.invalid_image", value: "无法读取图片数据", comment: "")
        case .failedToCreateCGImage:
            return NSLocalizedString("editor.ocr.error.cgimage", value: "无法创建图像用于识别", comment: "")
        }
    }
}

struct OCRService {
    static func recognizeText(
        in image: NSImage,
        region: CGRect? = nil,
        preferredLanguages: [String]? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    let text = try recognizeTextSync(in: image, region: region, preferredLanguages: preferredLanguages)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeText(
        in cgImage: CGImage,
        imageSize: CGSize? = nil,
        region: CGRect? = nil,
        preferredLanguages: [String]? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                do {
                    let baseSize = imageSize ?? CGSize(width: cgImage.width, height: cgImage.height)
                    let text = try recognizeTextSync(
                        in: cgImage,
                        imageSize: baseSize,
                        region: region,
                        preferredLanguages: preferredLanguages
                    )
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func loadCGImage(from url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private static func recognizeTextSync(in image: NSImage, region: CGRect?, preferredLanguages: [String]?) throws -> String {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return try recognizeTextSync(in: cgImage, imageSize: image.size, region: region, preferredLanguages: preferredLanguages)
        }

        guard
            let tiffData = image.tiffRepresentation,
            let ciImage = CIImage(data: tiffData)
        else {
            throw OCRServiceError.invalidImageData
        }

        let ciInput: CIImage
        if let region, region.width > 0, region.height > 0 {
            let cropRect = ciRectFromImageRect(region, imageSize: image.size, ciExtent: ciImage.extent)
            ciInput = ciImage.cropped(to: cropRect)
        } else {
            ciInput = ciImage
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ciContext.createCGImage(ciInput, from: ciInput.extent) else {
            throw OCRServiceError.failedToCreateCGImage
        }

        return try recognizeTextSync(
            in: cgImage,
            imageSize: image.size,
            region: nil,
            preferredLanguages: preferredLanguages
        )
    }

    private static func recognizeTextSync(
        in cgImage: CGImage,
        imageSize: CGSize,
        region: CGRect?,
        preferredLanguages: [String]?
    ) throws -> String {

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Screenshots can be very high resolution; keep this low to avoid missing small UI fonts.
        request.minimumTextHeight = 0.004
        if let best = VNRecognizeTextRequest.supportedRevisions.last {
            request.revision = best
        }

        if let region, region.width > 1, region.height > 1, imageSize.width > 0, imageSize.height > 0 {
            let roi = normalizeRegionOfInterest(region, imageSize: imageSize)
            if roi.width > 0, roi.height > 0 {
                request.regionOfInterest = roi
            }
        }
        if #available(macOS 13.0, *) {
            // Honor user-selected OCR languages; fall back to auto-detect when the list is empty.
            let requestedLanguages = normalizeRecognitionLanguages(preferredLanguages)
            request.automaticallyDetectsLanguage = requestedLanguages.isEmpty
            if !requestedLanguages.isEmpty {
                request.recognitionLanguages = requestedLanguages
            }

            return try perform(request: request, cgImage: cgImage, requestedLanguages: requestedLanguages)
        }

        let requestedLanguages = normalizeRecognitionLanguages(preferredLanguages)
        if !requestedLanguages.isEmpty {
            request.recognitionLanguages = requestedLanguages
        }

        return try perform(request: request, cgImage: cgImage, requestedLanguages: requestedLanguages)
    }

    private static func perform(
        request: VNRecognizeTextRequest,
        cgImage: CGImage,
        requestedLanguages: [String]
    ) throws -> String {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // If the user configured invalid/unsupported language tags, retry with Vision defaults.
            if !requestedLanguages.isEmpty {
                request.recognitionLanguages = []
                if #available(macOS 13.0, *) {
                    request.automaticallyDetectsLanguage = true
                }
                try handler.perform([request])
            } else {
                throw error
            }
        }

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeRecognitionLanguages(_ preferredLanguages: [String]?) -> [String] {
        let trimmed = (preferredLanguages ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var unique: [String] = []
        var seen = Set<String>()
        for language in trimmed where seen.insert(language).inserted {
            unique.append(language)
        }
        return unique
    }

    /// Vision's regionOfInterest is normalized and origin is bottom-left.
    private static func normalizeRegionOfInterest(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        let w = max(1, imageSize.width)
        let h = max(1, imageSize.height)

        let normalized = CGRect(
            x: rect.origin.x / w,
            y: (h - rect.origin.y - rect.height) / h,
            width: rect.width / w,
            height: rect.height / h
        ).standardized

        return normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Convert a rect in image-space (origin top-left, y down) into a CIImage rect (origin bottom-left).
    private static func ciRectFromImageRect(_ rect: CGRect, imageSize: CGSize, ciExtent: CGRect) -> CGRect {
        let scaleX = ciExtent.width / max(1, imageSize.width)
        let scaleY = ciExtent.height / max(1, imageSize.height)
        return CGRect(
            x: rect.origin.x * scaleX,
            y: (imageSize.height - rect.origin.y - rect.height) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).intersection(ciExtent)
    }
}
