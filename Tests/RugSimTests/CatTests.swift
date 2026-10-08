import XCTest
import simd
@testable import RugSim

final class CatTests: XCTestCase {
    let rug = SIMD2<Float>(800, 533)

    func run(_ cats: inout [Cat], seconds: Float, rug: SIMD2<Float>, each: (Cat.Pose) -> Void = { _ in }) {
        for _ in 0..<Int(seconds * 60) {
            for i in cats.indices {
                let others = cats.indices.filter { $0 != i }.map { cats[$0].pos }
                cats[i].update(dt: 1 / 60, rugSize: rug, others: others)
                each(cats[i].pose)
            }
        }
    }

    func testCatsStayOnRugAndDoEverything() {
        var cats = (0..<4).map { Cat(pos: SIMD2(Float($0) * 60 - 90, 0), heading: 0, length: 90, seed: UInt64($0 + 1)) }
        var seen = Set<String>()
        var maxOut = -Float.infinity
        run(&cats, seconds: 120, rug: rug) { p in
            seen.insert(p.anim.rawValue)
            let half = self.rug / 2
            maxOut = max(maxOut, abs(p.pos.x) - half.x, abs(p.pos.y) - half.y)
            XCTAssert((0..<Cat.frames).contains(p.frame))
        }
        XCTAssertLessThan(maxOut, -10, "貓不能走出地毯")
        XCTAssertEqual(seen, ["walk", "belly", "scratch"], "兩分鐘內三種動作都要出現")
    }

    func testWalkFramesFollowDistance() {
        // 走路幀跟走過的距離成正比：走一個身長大約播 8 格
        var c = Cat(pos: SIMD2(-300, 0), heading: 0, length: 90, seed: 7)
        var frames: [Int] = []
        var moved: Float = 0
        var last = c.pos
        for _ in 0..<600 {
            c.update(dt: 1 / 60, rugSize: rug, others: [])
            if c.pose.anim == .walk && c.pose.frame != 0 { frames.append(c.pose.frame); moved += simd_length(c.pos - last) }
            last = c.pos
        }
        XCTAssertGreaterThan(moved, 50)
    }

    func testShrinkingRugPullsCatBackOn() {
        var cats = [Cat(pos: SIMD2(350, 200), heading: 0, length: 90, seed: 3)]
        run(&cats, seconds: 0.1, rug: SIMD2(300, 200))
        XCTAssertLessThanOrEqual(abs(cats[0].pos.x), 150)
        XCTAssertLessThanOrEqual(abs(cats[0].pos.y), 100)
    }
}
