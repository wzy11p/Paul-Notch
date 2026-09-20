import Foundation
import CoreGraphics

/// Resolves a home-card drop target with a small magnetic capture area.
///
/// The visible Bento grid keeps a 12-point gutter between cards. Requiring the
/// pointer to enter the literal card bounds makes that gutter a dead zone, so
/// acquisition expands each frame while retention uses a slightly larger area
/// to prevent the highlight from flickering near an edge.
enum HomeInteractionGeometry {
    static func dropTarget<ID: Hashable>(
        for source: ID,
        at location: CGPoint,
        frames: [ID: CGRect],
        currentTarget: ID?,
        acquisitionPadding: CGFloat = 10,
        retentionPadding: CGFloat = 16
    ) -> ID? {
        if let currentTarget,
           currentTarget != source,
           let currentFrame = frames[currentTarget],
           currentFrame.insetBy(dx: -retentionPadding, dy: -retentionPadding).contains(location) {
            return currentTarget
        }

        return frames
            .compactMap { id, frame -> (id: ID, frame: CGRect, distance: CGFloat)? in
                guard id != source,
                      frame.insetBy(dx: -acquisitionPadding, dy: -acquisitionPadding).contains(location) else {
                    return nil
                }
                return (id, frame, squaredDistance(from: location, to: frame))
            }
            .min { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                return lhs.frame.minX < rhs.frame.minX
            }?
            .id
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
