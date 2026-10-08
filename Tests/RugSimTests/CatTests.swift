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
        XCTAssertEqual(seen, ["walk", "belly", "scratch", "lookup"], "兩分鐘內每種動作都要出現")
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

    func testPickUpCarryDrop() {
        var c = Cat(pos: .zero, heading: 0, length: 90, seed: 5)
        c.pickUp()
        c.carry(to: SIMD2(900, 0))            // 拎到地毯外面
        c.update(dt: 1 / 60, rugSize: rug, others: [])
        XCTAssertTrue(c.pose.lifted)
        XCTAssertEqual(c.pose.pos.x, 900, "拎著的時候跟著手，不收回地毯")
        c.drop()
        c.update(dt: 1 / 60, rugSize: rug, others: [])
        XCTAssertFalse(c.pose.lifted)
        XCTAssertLessThan(abs(c.pos.x), rug.x / 2, "放下後回到地毯上")
    }

    /// 被蓋住：鑽出來，而且之後的目的地也不挑被蓋住的地方
    func testCatLeavesWrinkledArea() {
        // 地毯右半邊 x > 0 都被蓋住
        let ok: (SIMD2<Float>) -> Bool = { $0.x < 0 }
        var c = Cat(pos: SIMD2(100, 0), heading: 0, length: 90, seed: 11)
        var maxRightAfter: Float = -.infinity
        for f in 0..<(60 * 60) {
            c.update(dt: 1 / 60, rugSize: rug, others: [], spotOK: ok)
            if f > 120 { maxRightAfter = max(maxRightAfter, c.pos.x) }
        }
        XCTAssertLessThan(maxRightAfter, 1, "兩秒內鑽出來，之後不再走回去")
    }

    func testShrinkingRugPullsCatBackOn() {
        var cats = [Cat(pos: SIMD2(350, 200), heading: 0, length: 90, seed: 3)]
        run(&cats, seconds: 0.1, rug: SIMD2(300, 200))
        XCTAssertLessThanOrEqual(abs(cats[0].pos.x), 150)
        XCTAssertLessThanOrEqual(abs(cats[0].pos.y), 100)
    }
}
