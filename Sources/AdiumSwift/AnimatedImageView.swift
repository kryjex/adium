import SwiftUI
import ImageIO

/// This renders inline message images. It plays multi-frame formats (animated WebP
/// stickers, GIF, APNG). A normal `NSImage` shows these as a static first frame.
struct AnimatedImageView: View {
    let data: Data

    @State private var currentImage: NSImage?
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let image = currentImage ?? NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            }
        }
        .onAppear { startAnimating() }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func startAnimating() {
        guard animationTask == nil else { return }
        let frames = Self.decodeFrames(data)
        guard frames.count > 1 else { return }
        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                for frame in frames {
                    currentImage = frame.image
                    try? await Task.sleep(nanoseconds: UInt64(frame.delay * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private struct Frame {
        let image: NSImage
        let delay: TimeInterval
    }

    private static func decodeFrames(_ data: Data) -> [Frame] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return [] }
        var frames: [Frame] = []
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            frames.append(Frame(image: nsImage, delay: frameDelay(source, index)))
        }
        return frames
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in containers {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let delay = (dictionary[unclampedKey] as? TimeInterval) ?? (dictionary[clampedKey] as? TimeInterval) ?? 0.1
            // Browsers clamp very small delays. A delay of 0 spins the animation loop.
            return max(delay, 0.02)
        }
        return 0.1
    }
}
