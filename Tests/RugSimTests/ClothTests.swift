import XCTest
import simd
@testable import RugSim

final class ClothTests: XCTestCase {
    let place = RugPlacement(center: SIMD2(800, 500), angle: 0, size: SIMD2(600, 400))

    func run(_ c: Cloth, seconds: Float) {
        for _ in 0..<Int(seconds * 60) where !c.isSettled { c.step(dt: 1 / 60) }
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
        for _ in 0..<240 where !c.isSettled { c.step(dt: 1 / 60) }
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

    /// 抓中間拖＝只是要移動：遠離手的地方不該拱起皺褶，整張要跟著走
    func testDragFromMiddleMovesWithoutWrinkles() {
        let c = Cloth(placement: place)
        var target = place.center
        c.grab(near: target)
        var worst: Float = 0
        for _ in 0..<40 {
            target += SIMD2(15, 6)          // 約 970 pt/s
            c.moveGrab(to: target)
            c.step(dt: 1 / 60)
            let g = c.pos[c.grabbed!]
            for p in c.pos where simd_length(SIMD2(p.x - g.x, p.y - g.y)) > 150 { worst = max(worst, p.z) }
        }
        print("MIDDLE-DRAG worst far z", worst, "moved", simd_length(c.fittedPlacement().center - place.center))
        XCTAssertLessThan(worst, 12, "離手 150pt 以外不該拱起")
        XCTAssertGreaterThan(simd_length(c.fittedPlacement().center - place.center), 500, "整張要跟著走")
    }

    /// 掀角放下後再抓那個翻上來的角拉回去：只能抓到上層，拉回去要能攤平，不能上下黏住
    func testRegrabFoldedCornerUnfolds() {
        let c = Cloth(placement: place)
        let corner = place.point(u: 1, v: 1), to = place.point(u: 0.55, v: 0.55)
        c.grab(near: corner)
        for f in 0..<60 { c.moveGrab(to: corner + (to - corner) * Float(f) / 59); c.step(dt: 1 / 60) }
        c.release()
        for _ in 0..<240 where !c.isSettled { c.step(dt: 1 / 60) }
        let tipIndex = c.index(c.nx - 1, c.ny - 1)
        let tip = c.pos[tipIndex]
        XCTAssertGreaterThan(tip.z, 3, "前提：角要先躺在上層")
        // 從畫面上點那個角（點在它上面一點點的位置）
        c.grab(near: SIMD2(tip.x, tip.y) + SIMD2(-4, -4))
        XCTAssertEqual(c.grabbed, tipIndex, "要抓到上層翻過來的角，不是底下那層")
        let start = SIMD2(tip.x, tip.y)
        for f in 0..<60 { c.moveGrab(to: start + (corner - start) * Float(f) / 59); c.step(dt: 1 / 60) }
        c.release()
        for _ in 0..<300 where !c.isSettled { c.step(dt: 1 / 60) }
        let maxZ = c.pos.map(\.z).max()!
        print("REGRAB maxZ after unfold", maxZ, "tip", c.pos[tipIndex])
        XCTAssertLessThan(maxZ, 15, "拉回去要攤平")
        XCTAssertLessThan(simd_length(SIMD2(c.pos[tipIndex].x, c.pos[tipIndex].y) - corner), 60)
    }

    /// 點在翻上來那片布的折痕附近：抓起的那一小塊只能有上層的點
    func testGrabNearCreaseTakesOnlyTopLayer() {
        let view = SIMD2<Float>(1920, 1080), w = view.x * 0.42
        let p = RugPlacement(center: view * 0.5, angle: 0, size: SIMD2(w, w / 1.5))
        let c = Cloth(placement: p)
        let corner = p.point(u: 1, v: 1), to = p.point(u: 0.55, v: 0.55)
        c.grab(near: corner)
        for f in 0..<60 { c.moveGrab(to: corner + (to - corner) * Float(f) / 59); c.step(dt: 1 / 60) }
        c.release()
        for _ in 0..<240 where !c.isSettled { c.step(dt: 1 / 60) }
        for (u, v) in [(0.8, 0.95), (0.85, 0.75), (0.75, 0.85)] as [(Float, Float)] {
            let q = c.pos[c.index(Int(u * Float(c.nx - 1)), Int(v * Float(c.ny - 1)))]
            c.grab(near: SIMD2(q.x, q.y))
            let zs = c.grabPatch.map { c.pos[$0.k].z }
            XCTAssertLessThan(zs.max()! - zs.min()!, c.collisionRadius * 2, "抓到下層會兩層黏在一起")
            c.release()
        }
    }

    /// 被翻過來的角蓋住的地方要認得出來
    func testCovered() {
        let c = Cloth(placement: place)
        XCTAssertFalse(c.isCovered(uv: SIMD2(0.5, 0.5)))
        let corner = place.point(u: 1, v: 1), to = place.point(u: 0.55, v: 0.55)
        c.grab(near: corner)
        for f in 0..<60 { c.moveGrab(to: corner + (to - corner) * Float(f) / 59); c.step(dt: 1 / 60) }
        c.release()
        for _ in 0..<240 where !c.isSettled { c.step(dt: 1 / 60) }
        XCTAssertTrue(c.isCovered(uv: SIMD2(0.6, 0.6)), "被翻過來的角蓋住")
        XCTAssertFalse(c.isCovered(uv: SIMD2(0.15, 0.15)), "遠處沒事")
    }

    func testStepPerformance() {
        let c = Cloth(placement: place)
        c.grab(near: place.point(u: 1, v: 1))
        measure { for _ in 0..<60 { c.moveGrab(to: SIMD2(700, 400)); c.step(dt: 1 / 60) } }
    }
}
