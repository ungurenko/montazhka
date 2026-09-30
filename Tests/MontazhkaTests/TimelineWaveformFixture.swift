import CoreGraphics
import SwiftUI

@testable import MontazhkaKit

/// Characterization reference: the complete waveform loop from a4e252e.
enum TimelineWaveformFixture {
    static func original(clip: Clip, peaks: [Float], size: CGSize) -> Path {
        let wps = WaveformStore.windowsPerSecond
        let mid = size.height / 2
        let step: CGFloat = 2
        let secondsPerPixel = clip.duration / Double(size.width)
        var x: CGFloat = 0
        var path = Path()
        while x < size.width {
            let from = clip.start + Double(x) * secondsPerPixel
            let to = from + Double(step) * secondsPerPixel
            let i0 = max(0, min(peaks.count - 1, Int(from * wps)))
            let i1 = max(i0 + 1, min(peaks.count, Int(to * wps)))
            var peak: Float = 0
            for i in i0..<i1 where peaks[i] > peak { peak = peaks[i] }
            let value = min(1.0, pow(Double(peak) * 4.0, 0.8))
            let h = max(1, mid * CGFloat(value))
            path.addRoundedRect(
                in: CGRect(x: x, y: mid - h, width: 1.5, height: h * 2),
                cornerSize: CGSize(width: 0.75, height: 0.75))
            x += step
        }
        return path
    }

    static func pixels(_ path: Path, offset: CGFloat, width: Int = 1200) -> Data {
        let context = CGContext(
            data: nil, width: width, height: 80, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -offset, y: 0)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path.cgPath)
        context.fillPath()
        return Data(bytes: context.data!, count: width * 80 * 4)
    }
}
