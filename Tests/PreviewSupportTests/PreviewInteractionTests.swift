import XCTest
import CoreGraphics
@testable import PreviewSupport

final class PreviewInteractionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testMagnifiedIconsRemainHoverableAtEveryDockEdge() {
        let examples: [(DockEdge, CGRect, CGPoint)] = [
            (.left, CGRect(x: 4, y: 300, width: 120, height: 120), CGPoint(x: 116, y: 360)),
            (.right, CGRect(x: 1316, y: 300, width: 120, height: 120), CGPoint(x: 1320, y: 360)),
            (.top, CGRect(x: 600, y: 4, width: 120, height: 120), CGPoint(x: 660, y: 116)),
            (.bottom, CGRect(x: 600, y: 776, width: 120, height: 120), CGPoint(x: 660, y: 780))
        ]
        for (edge, icon, point) in examples {
            XCTAssertTrue(PreviewInteraction.lane(for: icon, neighbors: [icon], screen: screen, edge: edge).contains(point), "\(edge)")
        }
    }

    func testAdjacentIconWinsOverStickyCurrentLane() {
        let frames = [CGRect(x: 4, y: 200, width: 60, height: 60), CGRect(x: 4, y: 262, width: 60, height: 60)]
        let lanes = frames.map { PreviewInteraction.lane(for: $0, neighbors: frames, screen: screen, edge: .left) }
        XCTAssertEqual(PreviewInteraction.target(at: CGPoint(x: 20, y: 263), frames: frames, lanes: lanes, current: 0, edge: .left), 1)
        XCTAssertEqual(PreviewInteraction.target(at: CGPoint(x: 2, y: 262), frames: frames, lanes: lanes, current: 0, edge: .left), 0)
        XCTAssertNil(PreviewInteraction.target(at: CGPoint(x: 400, y: 263), frames: frames, lanes: lanes, current: 0, edge: .left))
    }

    func testLanesUseTheOwningDisplaysCoordinates() {
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let icon = CGRect(x: -1916, y: 100, width: 96, height: 96)
        let unrelated = CGRect(x: 4, y: 110, width: 60, height: 60)
        let lane = PreviewInteraction.lane(for: icon, neighbors: [icon, unrelated], screen: secondary, edge: .left)
        XCTAssertEqual(lane.minX, secondary.minX)
        XCTAssertEqual(lane.minY, 92)
        XCTAssertEqual(lane.maxY, 204)
        XCTAssertTrue(lane.contains(CGPoint(x: -1830, y: 150)))
        XCTAssertFalse(lane.contains(CGPoint(x: 0, y: 150)))
    }

    func testBridgeProtectsDiagonalTravelButNotOtherDockIcons() {
        let icon = CGRect(x: 4, y: 300, width: 60, height: 60)
        let panel = CGRect(x: 100, y: 200, width: 220, height: 260)
        XCTAssertTrue(PreviewInteraction.bridgeContains(CGPoint(x: 82, y: 280), icon: icon, panel: panel, edge: .left))
        XCTAssertFalse(PreviewInteraction.bridgeContains(CGPoint(x: 20, y: 220), icon: icon, panel: panel, edge: .left))
        XCTAssertFalse(PreviewInteraction.bridgeContains(CGPoint(x: 65, y: 220), icon: icon, panel: panel, edge: .left))
        XCTAssertFalse(PreviewInteraction.bridgeContains(CGPoint(x: 400, y: 330), icon: icon, panel: panel, edge: .left))
    }

    func testBridgeWorksForRightTopAndBottomDocks() {
        let examples: [(DockEdge, CGRect, CGRect, CGPoint)] = [
            (.right, CGRect(x: 1300, y: 300, width: 60, height: 60), CGRect(x: 1000, y: 200, width: 264, height: 260), CGPoint(x: 1282, y: 330)),
            (.bottom, CGRect(x: 600, y: 800, width: 60, height: 60), CGRect(x: 500, y: 500, width: 260, height: 264), CGPoint(x: 630, y: 782)),
            (.top, CGRect(x: 600, y: 4, width: 60, height: 60), CGRect(x: 500, y: 100, width: 260, height: 264), CGPoint(x: 630, y: 82))
        ]
        for (edge, icon, panel, point) in examples {
            XCTAssertTrue(PreviewInteraction.bridgeContains(point, icon: icon, panel: panel, edge: edge), "\(edge)")
        }
    }

    func testZOrderChangesDoNotReorderVisibleCards() {
        XCTAssertEqual(PreviewInteraction.stableOrder([3, 1, 2], previous: [1, 2, 3]), [1, 2, 3])
        XCTAssertEqual(PreviewInteraction.stableOrder([4, 3, 1], previous: [1, 2, 3]), [1, 3, 4])
        XCTAssertEqual(PreviewInteraction.stableOrder([Int](), previous: [1, 2]), [])
    }

    func testEmptyDockHasNoHoverTarget() {
        XCTAssertNil(PreviewInteraction.target(at: .zero, frames: [], lanes: [], current: nil, edge: .left))
    }
}
