//
//  OCRService.swift
//  PastScreen
//
//  Local OCR powered by Vision.
//

import AppKit
import Foundation
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
    static func recognizeText(in image: NSImage, region: CGRect? = nil, preferredLanguages: [String]? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try recognizeTextSync(in: image, region: region, preferredLanguages: preferredLanguages)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func recognizeTextSync(in image: NSImage, region: CGRect?, preferredLanguages: [String]?) throws -> String {
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

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.02
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let requestedLanguages = normalizeRecognitionLanguages(preferredLanguages)
        if !requestedLanguages.isEmpty {
            request.recognitionLanguages = requestedLanguages
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // If the user configured invalid/unsupported language tags, retry with Vision defaults.
            if !requestedLanguages.isEmpty {
                request.recognitionLanguages = []
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
