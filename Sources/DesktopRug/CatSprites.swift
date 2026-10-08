import Foundation
import MetalKit
import RugSim

/// 小貓的貼圖：app bundle 的 Resources/cats/<cat>-<anim>.png（4×4 格），身長比例在 meta.json。
final class CatSprites {
    struct Kind { let name: String; var textures: [Cat.Anim: MTLTexture]; let bodyLength: Float }
    private(set) var kinds: [Kind] = []

    init(device: MTLDevice) {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("cats") else { return }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json"))))
            as? [String: [String: Double]] ?? [:]
        let loader = MTKTextureLoader(device: device)
        for name in ["orange", "black", "calico", "british"] {
            var tex: [Cat.Anim: MTLTexture] = [:]
            for anim in Cat.Anim.allCases {
                let url = dir.appendingPathComponent("\(name)-\(anim.rawValue).png")
                if let t = try? loader.newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true]) { tex[anim] = t }
            }
            // 走路、翻肚、抓癢齊了就放出來；抬頭看還沒生的話畫面會先用站姿代替
            if [Cat.Anim.walk, .belly, .scratch].allSatisfy({ tex[$0] != nil }) {
                kinds.append(Kind(name: name, textures: tex, bodyLength: Float(meta[name]?["bodyLength"] ?? 0.7)))
            }
        }
    }
}
