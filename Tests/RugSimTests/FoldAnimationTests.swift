import XCTest
import simd
@testable import RugSim

final class FoldAnimationTests: XCTestCase {
    let place = RugPlacement(center: SIMD2(800, 500), angle: 0, size: SIMD2(600, 400))

    func testStartsFlatAndEndsGone() {
        let f = FoldAnimation(placement: place)
        for uv in [SIMD2<Float>(0, 0), SIMD2(1, 1), SIMD2(0.7, 0.3)] {
            let p0 = f.position(uv: uv, progress: 0)
            XCTAssertLessThan(simd_distance(p0.xy, place.point(u: uv.x, v: uv.y)), 0.01)
            XCTAssertEqual(p0.z, 0, accuracy: 0.01)
        }
        // 收完：全部縮到同一點
        let a = f.position(uv: SIMD2(0, 0), progress: 1), b = f.position(uv: SIMD2(1, 1), progress: 1)
        XCTAssertLessThan(simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)), 0.5)
    }

    /// 兩折都折完：四層都疊到左下那一塊上方，而且高度各不相同（沒有穿過彼此）。
    /// 圓弧折痕會吃掉一段長度，所以各層不會剛好落在鏡像位置。
    func testFoldedLayersStackWithoutIntersecting() {
        let f = FoldAnimation(placement: place)
        let p = FoldAnimation.away.0   // 剛折好、還沒飛走
        let q = SIMD2<Float>(0.15, 0.15)
        let layers = [q, SIMD2(1 - q.x, q.y), SIMD2(q.x, 1 - q.y), SIMD2(1 - q.x, 1 - q.y)].map { f.position(uv: $0, progress: p) }
        // 四點都落在同一個位置上方
        let quarter = place.point(u: 0.25, v: 0.25)
        for l in layers { XCTAssertLessThan(simd_distance(l.xy, quarter), 160, "都在左下那一塊上") }
        let zs = layers.map(\.z).sorted()
        for i in 1..<zs.count { XCTAssertGreaterThan(zs[i] - zs[i - 1], 3, "層與層之間要有厚度：\(zs)") }
    }

    /// 第一折途中：折起來那片是連續的（相鄰點距離不會跳）
    func testFoldIsContinuous() {
        let f = FoldAnimation(placement: place)
        for p: Float in [0.1, 0.2, 0.3] {
            var maxJump: Float = 0
            for i in 0..<100 {
                let a = f.position(uv: SIMD2(Float(i) / 100, 0.8), progress: p)
                let b = f.position(uv: SIMD2(Float(i + 1) / 100, 0.8), progress: p)
                maxJump = max(maxJump, simd_distance(a, b))
            }
            XCTAssertLessThan(maxJump, 6.5, "progress \(p)：沿布面的間距應該接近 6 點")
        }
    }
}

extension SIMD3 where Scalar == Float { var xy: SIMD2<Float> { SIMD2(x, y) } }

/// 有圖示凸起時收起：縮成一點的那幾格不能算出 NaN（以前會讓 app 當掉）
final class FoldOverBumpsTests: XCTestCase {
    func testStowOverBumpsStaysFinite() {
        let place = RugPlacement(center: SIMD2(800, 500), angle: 0, size: SIMD2(600, 400))
        let c = Cloth(placement: place)
        let floor = HeightField.fromIcons([place.point(u: 0.3, v: 0.4), place.point(u: 0.7, v: 0.6)],
                                          iconSize: 64, origin: .zero, size: SIMD2(1600, 1000))
        c.floor = floor
        var anim = FoldAnimation(placement: place)
        anim.floor = { floor.sample($0, $1) }
        var mesh = RenderMesh(cloth: c)
        for p: Float in [0, 0.3, 0.6, 0.9, 0.99, 1] {
            c.pose { anim.position(uv: $0, progress: p) }
            mesh.update(from: c)
            XCTAssertTrue(mesh.pos.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "progress \(p)")
            XCTAssertTrue(mesh.side.allSatisfy { $0.pos.z.isFinite && $0.nrm.z.isFinite }, "progress \(p)")
        }
    }

    /// 凸起上折好時：疊在同一處的層，上下順序跟沒凸起時一樣（底層不會穿到上面）
    func testLayersKeepOrderOverBumps() {
        let place = RugPlacement(center: SIMD2(800, 500), angle: 0, size: SIMD2(600, 400))
        let floor = HeightField.fromIcons([place.point(u: 0.2, v: 0.2)], iconSize: 64, origin: .zero, size: SIMD2(1600, 1000))
        let flat = FoldAnimation(placement: place)
        var bumpy = FoldAnimation(placement: place); bumpy.floor = { floor.sample($0, $1) }
        let p = FoldAnimation.away.0
        let q = SIMD2<Float>(0.15, 0.15)
        let uvs = [q, SIMD2(1 - q.x, q.y), SIMD2(q.x, 1 - q.y), SIMD2(1 - q.x, 1 - q.y)]
        let orderFlat = uvs.indices.sorted { flat.position(uv: uvs[$0], progress: p).z < flat.position(uv: uvs[$1], progress: p).z }
        let orderBumpy = uvs.indices.sorted { bumpy.position(uv: uvs[$0], progress: p).z < bumpy.position(uv: uvs[$1], progress: p).z }
        XCTAssertEqual(orderFlat, orderBumpy)
    }
}
