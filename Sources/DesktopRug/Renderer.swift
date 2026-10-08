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
struct U { float2 view; float cam; float2 rugSize; float2 shadowOffset; float shadowLift; };

struct RugOut { float4 position [[position]]; float3 nrm; float2 uv; float h; };

static float4 project(float3 p, constant U& u) {
    float s = u.cam / (u.cam - p.z);
    float2 c = u.view * 0.5;
    float2 q = (p.xy - c) * s / c;
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
    float3 c = tex.sample(smp, in.uv).rgb;
    if (!front) {
        // 翻過來看到的是地毯背面：同一個圖案，比較灰暗
        n = -n;
        float g = dot(c, float3(0.3, 0.59, 0.11));
        c = mix(c, float3(g), 0.35) * 0.72;
    }
    float3 L = normalize(float3(-0.5, 0.6, 0.65));
    float shade = 0.28 + 0.72 * max(dot(n, L), 0.0) / L.z;
    // 邊緣包邊稍暗，看起來有厚度
    float2 d = min(in.uv, 1.0 - in.uv) * u.rugSize;
    float edge = smoothstep(0.6, 2.2, min(d.x, d.y));
    c *= mix(0.55, 1.0, edge);
    return float4(c * min(shade, 1.3), 1.0);
}

struct ShOut { float4 position [[position]]; };

vertex ShOut shadow_vs(uint vid [[vertex_id]], const device V* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    float3 p = v[vid].pos;
    // 影子落在地上：離地越高偏移越多
    float2 g = p.xy + u.shadowOffset + float2(0.30, -0.42) * p.z * u.shadowLift;
    float2 c = u.view * 0.5;
    ShOut o; o.position = float4((g - c) / c, 0, 1);
    return o;
}

fragment float shadow_fs(ShOut in [[stage_in]]) { return 1.0; }

struct Full { float4 position [[position]]; float2 uv; };

vertex Full full_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    Full o; o.position = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 composite_fs(Full in [[stage_in]], texture2d<float> mask [[texture(0)]]) {
    constexpr sampler smp(filter::linear);
    float a = mask.sample(smp, in.uv).r * 0.42;
    return float4(0, 0, 0, a);   // premultiplied
}
"""

struct Vertex { var pos: SIMD3<Float>; var nrm: SIMD3<Float>; var uv: SIMD2<Float> }
struct Uniforms {
    var view: SIMD2<Float>; var cam: Float; var rugSize: SIMD2<Float>
    var shadowOffset: SIMD2<Float>; var shadowLift: Float
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rugPipe: MTLRenderPipelineState
    private let shadowPipe: MTLRenderPipelineState
    private let compPipe: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private var maskA: MTLTexture?
    private var maskB: MTLTexture?
    private var blur: MPSImageGaussianBlur

    var texture: MTLTexture?
    /// 每次畫之前由 controller 給目前的布（nil = 地毯收起來了）
    var cloth: Cloth?

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

        let nrm = cloth.normals()
        var verts = [Vertex](); verts.reserveCapacity(cloth.indices.count)
        for i in cloth.indices {
            let k = Int(i)
            verts.append(Vertex(pos: cloth.pos[k], nrm: nrm[k], uv: cloth.uv[k]))
        }
        let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count)!
        let b = view.bounds.size
        var u = Uniforms(view: SIMD2(Float(b.width), Float(b.height)), cam: cameraHeight,
                         rugSize: cloth.restSize, shadowOffset: SIMD2(1.5, -3), shadowLift: 1)

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
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            e.endEncoding()
        }
        blur.encode(commandBuffer: cmd, sourceTexture: maskA!, destinationTexture: maskB!)

        // 2. 影子合成 + 地毯
        guard let e = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(compPipe)
        e.setFragmentTexture(maskB, index: 0)
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
        e.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// 畫面上看到的點 ↔ 模擬座標（跟 shader 的 project 一致）
func projectToScreen(_ p: SIMD3<Float>, view: SIMD2<Float>) -> SIMD2<Float> {
    let c = view * 0.5
    return c + (SIMD2(p.x, p.y) - c) * (cameraHeight / (cameraHeight - p.z))
}

func unprojectFromScreen(_ q: SIMD2<Float>, z: Float, view: SIMD2<Float>) -> SIMD2<Float> {
    let c = view * 0.5
    return c + (q - c) * ((cameraHeight - z) / cameraHeight)
}
