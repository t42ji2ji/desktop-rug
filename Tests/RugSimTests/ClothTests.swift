import XCTest
import simd
@testable import RugSim

final class ClothTests: XCTestCase {
    let place = RugPlacement(center: SIMD2(800, 500), angle: 0, size: SIMD2(600, 400))

    func run(_ c: Cloth, seconds: Float) {
        for _ in 0..<Int(seconds * 60) { c.step(dt: 1 / 60) }
    }

    func testFlatRugStaysPut() {
        let c = Cloth(placement: place)
        run(c, seconds: 1)
        XCTAssertTrue(c.isSettled)
        let fit = c.fittedPlacement()
        XCTAssertLessThan(simd_length(fit.center - place.center), 1)
        XCTAssertLessThan(c.pos.map { abs($0.z) }.max()!, 0.5)
    }

    func testIconStackMakesBump() {
        let c = Cloth(placement: place)
        let icons = [SIMD2<Float>(800, 520)] + Array(repeating: SIMD2<Float>(650, 520), count: 4)
        c.floor = HeightField.fromIcons(icons, iconSize: 64, origin: .zero, size: SIMD2(1600, 1000))
        run(c, seconds: 3)
        func zNear(_ q: SIMD2<Float>) -> Float {
            c.pos.min { simd_length(SIMD2($0.x, $0.y) - q) < simd_length(SIMD2($1.x, $1.y) - q) }!.z
        }
        let single = zNear(SIMD2(800, 500)), stack = zNear(SIMD2(650, 500))
        XCTAssertGreaterThan(single, 3)
        XCTAssertGreaterThan(stack, single * 2, "疊越多凸越高")
        XCTAssertLessThan(c.lastMotion, 0.05)
    }

    func testCornerLiftThenReleaseSettlesFlat() {
        let c = Cloth(placement: place)
        let corner = place.point(u: 1, v: 1)
        c.grab(near: corner)
        run(c, seconds: 0.5)
        XCTAssertGreaterThan(c.pos[c.index(c.nx - 1, c.ny - 1)].z, 40, "抓起來的角要離地")
        c.release()
        run(c, seconds: 3)
        XCTAssertLessThan(c.pos.map(\.z).max()!, 0.5)
        XCTAssertTrue(c.isSettled)
    }

    func testFoldedCornerLiesOnTop() {
        let c = Cloth(placement: place)
        // 把右上角拖到中間偏左，蓋在自己身上
        c.grab(near: place.point(u: 1, v: 1))
        let from = place.point(u: 1, v: 1), to = place.point(u: 0.45, v: 0.45)
        for f in 0..<60 {
            let t = Float(f) / 59
            c.moveGrab(to: from + (to - from) * t)
            c.step(dt: 1 / 60)
        }
        c.release()
        run(c, seconds: 2)
        let tip = c.pos[c.index(c.nx - 1, c.ny - 1)]
        XCTAssertGreaterThan(tip.z, c.params.thickness * 0.8, "折過來的角要躺在下層上面")
        XCTAssertLessThan(tip.z, 20)
        XCTAssertLessThan(simd_length(SIMD2(tip.x, tip.y) - to), 120)
        XCTAssertTrue(c.isSettled, "折好放開後要能休眠，不然會一直吃 CPU")
        XCTAssertLessThan(c.pos.map(\.z).max()!, 60, "折痕不能往上堆成塔")
    }

    func testFastDragDoesNotFlyAway() {
        let c = Cloth(placement: place)
        var target = place.center
        c.grab(near: target)
        for _ in 0..<18 { target.x += 50; c.moveGrab(to: target); c.step(dt: 1 / 60) }
        let atRelease = c.fittedPlacement().center
        c.release()
        var maxZ: Float = 0
        for _ in 0..<420 where !c.isSettled { c.step(dt: 1 / 60); maxZ = max(maxZ, c.pos.map(\.z).max()!) }
        XCTAssertLessThan(maxZ, 250, "兩層互推會往鏡頭爆")
        XCTAssertLessThan(simd_length(c.fittedPlacement().center - atRelease), 200, "放手後不能被甩出去")
        XCTAssertTrue(c.isSettled)
    }

    func testStepPerformance() {
        let c = Cloth(placement: place)
        c.grab(near: place.point(u: 1, v: 1))
        measure { for _ in 0..<60 { c.moveGrab(to: SIMD2(700, 400)); c.step(dt: 1 / 60) } }
    }
}
