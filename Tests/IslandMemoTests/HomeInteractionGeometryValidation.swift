import Foundation
import CoreGraphics

@main
struct HomeInteractionGeometryValidation {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("验证失败：\(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func main() {
        let frames = [
            "source": CGRect(x: 0, y: 0, width: 100, height: 80),
            "right": CGRect(x: 112, y: 0, width: 100, height: 80),
            "lower": CGRect(x: 0, y: 92, width: 100, height: 80),
        ]

        require(
            HomeInteractionGeometry.dropTarget(
                for: "source", at: CGPoint(x: 106, y: 40), frames: frames, currentTarget: nil
            ) == "right",
            "12pt 横向卡片间隙应吸附到相邻目标"
        )
        require(
            HomeInteractionGeometry.dropTarget(
                for: "source", at: CGPoint(x: 50, y: 86), frames: frames, currentTarget: nil
            ) == "lower",
            "12pt 纵向卡片间隙应吸附到相邻目标"
        )
        require(
            HomeInteractionGeometry.dropTarget(
                for: "source", at: CGPoint(x: 227, y: 40), frames: frames, currentTarget: "right"
            ) == "right",
            "现有目标边缘应使用更宽的保留范围，避免闪烁"
        )
        require(
            HomeInteractionGeometry.dropTarget(
                for: "source", at: CGPoint(x: 300, y: 300), frames: frames, currentTarget: nil
            ) == nil,
            "远离卡片时不应误选目标"
        )
        print("首页拖放判定验证通过")
    }
}
