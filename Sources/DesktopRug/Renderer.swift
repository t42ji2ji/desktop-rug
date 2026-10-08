import Metal
import MetalKit
import MetalPerformanceShaders
import RugSim
import simd

/// 鏡頭在螢幕中央正上方 cameraHeight 點，桌面 z=0 剛好對到螢幕像素；抬起來的部分會被透視放大。
let cameraHeight: Float = 2400

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct V { float3 pos; float3 nrm; float2 uv; };
struct U { float2 view; float cam; float2 rugSize; float2 shadowOffset; float shadowLift; float shadowAlpha; float cornerRadius; float2 origin; };

// 到圓角矩形邊緣的有號距離（點）：裡面為負
static float roundedDist(float2 uv, constant U& u) {
    float2 p = (uv - 0.5) * u.rugSize;
    float r = min(u.cornerRadius, min(u.rugSize.x, u.rugSize.y) * 0.5);
    float2 q = abs(p) - (u.rugSize * 0.5 - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

struct RugOut { float4 position [[position]]; float3 nrm; float2 uv; float h; };

static float4 project(float3 p, constant U& u) {
    // 鏡頭在這個螢幕中央正上方；p 是跨螢幕的統一座標，origin 是這個螢幕的左下角
    float s = u.cam / (u.cam - p.z);
    float2 h = u.view * 0.5;
    float2 q = (p.xy - (u.origin + h)) * s / h;
    return float4(q, 0.5 - p.z / 4000.0, 1.0);
}

vertex RugOut rug_vs(uint vid [[vertex_id]], const device V* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    RugOut o;
    o.position = project(v[vid].pos, u);
    o.nrm = v[vid].nrm;
    o.uv = v[vid].uv;
    o.h = v[vid].pos.z;
    return o;
}

fragment float4 rug_fs(RugOut in [[stage_in]], bool front [[front_facing]],
                       texture2d<float> tex [[texture(0)]], constant U& u [[buffer(1)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
    // 法線傾斜放大，凸起和皺褶在繁複花紋上才看得出來
    float3 n = normalize(in.nrm * float3(1.6, 1.6, 1.0));
    // 地毯 uv 以左下為原點、圖片以左上為原點，v 要翻過來
    float3 c = tex.sample(smp, float2(in.uv.x, 1.0 - in.uv.y)).rgb;
    if (!front) {
        // 翻過來看到的是地毯背面：同一個圖案，比較灰暗
        n = -n;
        float g = dot(c, float3(0.3, 0.59, 0.11));
        c = mix(c, float3(g), 0.35) * 0.72;
    }
    float3 L = normalize(float3(-0.5, 0.6, 0.65));
    float shade = 0.28 + 0.72 * max(dot(n, L), 0.0) / L.z;
    // 邊緣包邊稍暗，看起來有厚度
    float sd = roundedDist(in.uv, u);
    if (sd > 0.02) discard_fragment();
    float edge = smoothstep(0.6, 2.2, -sd);
    c *= mix(0.55, 1.0, edge);
    return float4(c * min(shade, 1.3), 1.0);
}

struct ShOut { float4 position [[position]]; float2 uv; };

vertex ShOut shadow_vs(uint vid [[vertex_id]], const device V* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    float3 p = v[vid].pos;
    // 影子落在地上：離地越高偏移越多
    float2 g = p.xy + u.shadowOffset + float2(0.30, -0.42) * p.z * u.shadowLift;
    float2 h = u.view * 0.5;
    ShOut o; o.position = float4((g - (u.origin + h)) / h, 0, 1); o.uv = v[vid].uv;
    return o;
}

fragment float shadow_fs(ShOut in [[stage_in]], constant U& u [[buffer(1)]]) {
    if (roundedDist(in.uv, u) > 0.02) discard_fragment();
    return 1.0;
}

struct CatV { float3 pos; float2 uv; };
struct CatOut { float4 position [[position]]; float2 uv; };

vertex CatOut cat_vs(uint vid [[vertex_id]], const device CatV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    CatOut o; o.position = project(v[vid].pos, u); o.position.z = 0; o.uv = v[vid].uv;
    return o;
}

// shade < 0 = 影子（黑、半透明）；否則照常畫貓
fragment float4 cat_fs(CatOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float& shade [[buffer(2)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(smp, in.uv);
    if (shade < 0) return float4(0, 0, 0, c.a * -shade);
    return float4(c.rgb * c.a, c.a);   // PNG 是直接 alpha，混合要預乘
}

struct Full { float4 position [[position]]; float2 uv; };

vertex Full full_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    Full o; o.position = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 composite_fs(Full in [[stage_in]], texture2d<float> mask [[texture(0)]], constant U& u [[buffer(1)]]) {
    constexpr sampler smp(filter::linear);
    float a = mask.sample(smp, in.uv).r * u.shadowAlpha;
    return float4(0, 0, 0, a);   // premultiplied
}
"""

struct Vertex { var pos: SIMD3<Float>; var nrm: SIMD3<Float>; var uv: SIMD2<Float> }
struct Uniforms {
    var view: SIMD2<Float>; var cam: Float; var rugSize: SIMD2<Float>
    var shadowOffset: SIMD2<Float>; var shadowLift: Float; var shadowAlpha: Float; var cornerRadius: Float
    var origin: SIMD2<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rugPipe: MTLRenderPipelineState
    private let shadowPipe: MTLRenderPipelineState
    private let compPipe: MTLRenderPipelineState
    private let catPipe: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private var maskA: MTLTexture?
    private var maskB: MTLTexture?
    private var blur: MPSImageGaussianBlur

    var texture: MTLTexture?
    /// 每次畫之前由 controller 給目前的布（nil = 地毯收起來了）
    var cloth: Cloth?
    private var mesh: RenderMesh?
    var sideThickness: Float = 6
    var shadowAlpha: Float = 0.22
    var cornerRadius: Float = 16
    /// 這個螢幕左下角在統一座標裡的位置
    var origin = SIMD2<Float>(0, 0)
    /// 要畫的貓：哪一種、哪個姿勢。座標是地毯局部座標，在這裡貼到毯面上
    var cats: [(kind: Int, pose: Cat.Pose)] = []
    var catSprites: CatSprites?
    var catLength: Float = 85
    private weak var meshSource: Cloth?

    init(view: MTKView) {
        device = view.device!
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: shaderSource, options: nil)

        let r = MTLRenderPipelineDescriptor()
        r.vertexFunction = lib.makeFunction(name: "rug_vs")
        r.fragmentFunction = lib.makeFunction(name: "rug_fs")
        r.colorAttachments[0].pixelFormat = view.colorPixelFormat
        r.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        rugPipe = try! device.makeRenderPipelineState(descriptor: r)

        let s = MTLRenderPipelineDescriptor()
        s.vertexFunction = lib.makeFunction(name: "shadow_vs")
        s.fragmentFunction = lib.makeFunction(name: "shadow_fs")
        s.colorAttachments[0].pixelFormat = .r8Unorm
        shadowPipe = try! device.makeRenderPipelineState(descriptor: s)

        let c = MTLRenderPipelineDescriptor()
        c.vertexFunction = lib.makeFunction(name: "full_vs")
        c.fragmentFunction = lib.makeFunction(name: "composite_fs")
        c.colorAttachments[0].pixelFormat = view.colorPixelFormat
        c.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        c.colorAttachments[0].isBlendingEnabled = true
        c.colorAttachments[0].sourceRGBBlendFactor = .one
        c.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.colorAttachments[0].sourceAlphaBlendFactor = .one
        c.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        compPipe = try! device.makeRenderPipelineState(descriptor: c)

        let k = MTLRenderPipelineDescriptor()
        k.vertexFunction = lib.makeFunction(name: "cat_vs")
        k.fragmentFunction = lib.makeFunction(name: "cat_fs")
        k.colorAttachments[0].pixelFormat = view.colorPixelFormat
        k.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        k.colorAttachments[0].isBlendingEnabled = true
        k.colorAttachments[0].sourceRGBBlendFactor = .one
        k.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        k.colorAttachments[0].sourceAlphaBlendFactor = .one
        k.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        catPipe = try! device.makeRenderPipelineState(descriptor: k)

        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        depth = device.makeDepthStencilState(descriptor: d)!
        blur = MPSImageGaussianBlur(device: device, sigma: 5)
        super.init()
    }

    func loadTexture(url: URL) {
        let loader = MTKTextureLoader(device: device)
        texture = try? loader.newTexture(URL: url, options: [
            .generateMipmaps: true, .SRGB: false, .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { maskA = nil }

    private func ensureMasks(_ size: CGSize) {
        let w = max(1, Int(size.width) / 2), h = max(1, Int(size.height) / 2)
        if let m = maskA, m.width == w, m.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = .private
        maskA = device.makeTexture(descriptor: d)
        maskB = device.makeTexture(descriptor: d)
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].loadAction = .clear

        guard let cloth, let texture else {
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            cmd.present(drawable); cmd.commit(); return
        }

        if mesh == nil || meshSource !== cloth { mesh = RenderMesh(cloth: cloth); meshSource = cloth }
        mesh!.thickness = sideThickness
        mesh!.cornerRadius = cornerRadius
        mesh!.update(from: cloth)
        let m = mesh!
        var verts = [Vertex](); verts.reserveCapacity(m.indices.count + m.side.count)
        for i in m.indices {
            let k = Int(i)
            verts.append(Vertex(pos: m.pos[k], nrm: m.normals[k], uv: m.uv[k]))
        }
        for v in m.side { verts.append(Vertex(pos: v.pos, nrm: v.nrm, uv: v.uv)) }
        let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count)!
        let b = view.bounds.size
        var u = Uniforms(view: SIMD2(Float(b.width), Float(b.height)), cam: cameraHeight,
                         rugSize: cloth.restSize, shadowOffset: SIMD2(1.5, -3), shadowLift: 1, shadowAlpha: shadowAlpha, cornerRadius: cornerRadius,
                         origin: origin)

        // 1. 影子遮罩（半解析度）→ 模糊
        ensureMasks(view.drawableSize)
        let sp = MTLRenderPassDescriptor()
        sp.colorAttachments[0].texture = maskA
        sp.colorAttachments[0].loadAction = .clear
        sp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        sp.colorAttachments[0].storeAction = .store
        if let e = cmd.makeRenderCommandEncoder(descriptor: sp) {
            e.setRenderPipelineState(shadowPipe)
            e.setVertexBuffer(vbuf, offset: 0, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            e.endEncoding()
        }
        blur.encode(commandBuffer: cmd, sourceTexture: maskA!, destinationTexture: maskB!)

        // 2. 影子合成 + 地毯
        guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(compPipe)
        e.setFragmentTexture(maskB, index: 0)
        e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        e.setRenderPipelineState(rugPipe)
        e.setDepthStencilState(depth)
        e.setCullMode(.none)
        e.setFrontFacing(.counterClockwise)
        e.setVertexBuffer(vbuf, offset: 0, index: 0)
        e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        e.setFragmentTexture(texture, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        drawCats(e, mesh: m, cloth: cloth, uniforms: &u)
        e.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct CatVertex { var pos: SIMD3<Float>; var uv: SIMD2<Float> }

extension Renderer {
    /// 貓貼在毯面上：位置取細網格在那個 uv 的表面，方向 = 地毯角度 + 貓自己的朝向。先畫影子再畫貓。
    fileprivate func drawCats(_ e: MTLRenderCommandEncoder, mesh: RenderMesh, cloth: Cloth, uniforms u: inout Uniforms) {
        guard let sprites = catSprites, !cats.isEmpty else { return }
        let rugAngle = cloth.fittedPlacement().angle
        let size = cloth.restSize
        e.setRenderPipelineState(catPipe)
        e.setDepthStencilState(nil)
        e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        for (kind, pose) in cats where kind < sprites.kinds.count {
            let k = sprites.kinds[kind]
            guard let tex = k.textures[pose.anim] else { continue }
            let uv = SIMD2(pose.pos.x / size.x + 0.5, pose.pos.y / size.y + 0.5)
            let (center, _) = mesh.sample(uv)
            let w = catLength / k.bodyLength, h = w * (128.0 / 192.0)
            let a = rugAngle + pose.heading
            let ax = SIMD2(cos(a), sin(a)), ay = SIMD2(-sin(a), cos(a))
            let col = Float(pose.frame % 4), row = Float(pose.frame / 4)
            // 貼圖原點在左上：格子上緣（v 小）是貓的左側（局部 +y）
            func corner(_ sx: Float, _ sy: Float) -> CatVertex {
                let p = SIMD2(center.x, center.y) + ax * (sx * w / 2) + ay * (sy * h / 2)
                return CatVertex(pos: SIMD3(p.x, p.y, center.z + 1),
                                 uv: SIMD2((col + (sx + 1) / 2) / 4, (row + (1 - sy) / 2) / 4))
            }
            var quad = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, -1), corner(1, 1), corner(-1, 1)]
            e.setFragmentTexture(tex, index: 0)
            // 影子：往右下偏一點
            var shadow = quad.map { CatVertex(pos: $0.pos + SIMD3(2, -3, -1), uv: $0.uv) }
            var shade: Float = -0.28
            e.setVertexBytes(&shadow, length: MemoryLayout<CatVertex>.stride * 6, index: 0)
            e.setFragmentBytes(&shade, length: 4, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            shade = 1
            e.setVertexBytes(&quad, length: MemoryLayout<CatVertex>.stride * 6, index: 0)
            e.setFragmentBytes(&shade, length: 4, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }
}

/// 某個螢幕的鏡頭：模擬的統一座標 ↔ 這個螢幕上看到的位置（也是統一座標），跟 shader 的 project 一致
struct ScreenCamera {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var center: SIMD2<Float> { origin + size * 0.5 }

    func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
        center + (SIMD2(p.x, p.y) - center) * (cameraHeight / (cameraHeight - p.z))
    }

    func unproject(_ q: SIMD2<Float>, z: Float) -> SIMD2<Float> {
        center + (q - center) * ((cameraHeight - z) / cameraHeight)
    }

    func contains(_ q: SIMD2<Float>) -> Bool {
        q.x >= origin.x && q.y >= origin.y && q.x < origin.x + size.x && q.y < origin.y + size.y
    }
}
