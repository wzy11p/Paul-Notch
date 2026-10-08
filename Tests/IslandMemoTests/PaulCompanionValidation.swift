import AppKit
import SwiftUI

@main
struct PaulCompanionValidation {
    @MainActor static func main() throws {
        let area = CGSize(width: 275, height: 32)
        precondition(PaulCompanionPointer.normalized(.zero, in: area) == CGPoint(x: -1, y: -1))
        precondition(PaulCompanionPointer.normalized(CGPoint(x: 137.5, y: 16), in: area) == .zero)
        precondition(PaulCompanionPointer.normalized(CGPoint(x: 999, y: 999), in: area) == CGPoint(x: 1, y: 1))
        precondition(PaulCompanionPointer.normalized(.zero, in: .zero) == .zero)
        let poses = [(false, false, false), (true, false, false), (true, true, false), (true, true, true)]
        for size: CGFloat in [10, 13] {
            for pose in poses {
                let mark = PaulCompanionMark(size: size, attentive: pose.0, pressed: pose.1, quiet: pose.2)
                let image = ImageRenderer(content: mark).nsImage!
                precondition(image.size == CGSize(width: size, height: size))
            }
        }
        func rendered(_ quiet: Bool, _ attentive: Bool, _ pressed: Bool) -> Data {
            ImageRenderer(content: PaulCompanionMark(size: 16, attentive: attentive, pressed: pressed,
                                                    quiet: quiet)).nsImage!.tiffRepresentation!
        }
        precondition(rendered(true, false, false) == rendered(true, true, true), "Quiet mode must stay static")
        let sheet = HStack(spacing: 24) {
            ForEach(0..<poses.count, id: \.self) { index in
                VStack(spacing: 12) {
                    Text(["Rest", "Track right", "Press left", "Quiet"][index]).font(.system(size: 11))
                    PaulCompanionMark(size: 13, attentive: poses[index].0, pressed: poses[index].1,
                                      quiet: poses[index].2, pointer: CGPoint(x: index == 2 ? -1 : 1, y: 0.8)).frame(height: 32)
                    PaulCompanionMark(size: 64, attentive: poses[index].0, pressed: poses[index].1,
                                      quiet: poses[index].2, pointer: CGPoint(x: index == 2 ? -1 : 1, y: 0.8)).frame(height: 72)
                }
            }
        }.padding(20).foregroundStyle(.white).background(.black)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: eight fixed-size poses, static reduced-motion/full-screen output")
    }
}
