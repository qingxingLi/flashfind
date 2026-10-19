// 从 ShanXun.icns 派生 macOS 状态栏模板图标。
//
// 用法：swift tools/make-menubar-icon.swift <ShanXun.icns> <输出目录>
//
// 做法：取 icns 最大位图 → 所有非透明像素改纯黑（保留原始 alpha 抗锯齿）→
// 裁掉透明边 → 按 15/30px 字形高居中贴到 18/36px 画布 → 输出 PNG。
// App 侧给 NSImage 设 isTemplate=true，macOS 按明暗模式自动黑/白着色。
// 重新生成品牌图标后重跑本脚本即可，产物直接进 Resources/Brand/。
import AppKit

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: swift make-menubar-icon.swift <ShanXun.icns> <outDir>")
}
let icnsPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard let img = NSImage(contentsOf: URL(fileURLWithPath: icnsPath)),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read icns")
}

let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let data = ctx.data else { fatalError("no bitmap") }
let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

// 剪影化分两步：
// 1) 亮度掩膜剔底板：品牌图形 = 亮色圆环 + 亮色闪电，底板是深色（亮度 <40）。
//    alpha' = alpha × smooth((lum-50)/50)，底板归零、图形全保留、辉光留半透明过渡。
// 2) 保留像素改纯黑（premultiplied），as Template 由 App 侧 isTemplate=true 接管着色。
for i in 0..<(w * h) {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2]), a = Int(px[i * 4 + 3])
    let lum = (r * 299 + g * 587 + b * 114) / 1000
    var m = (lum - 80) * 255 / 40
    if m < 0 { m = 0 }
    if m > 255 { m = 255 }
    px[i * 4 + 3] = UInt8(a * m / 255)
    px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0
}

// 裁掉透明边（alpha 阈值 8，排除几乎不可见的杂边）。
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("glyph is fully transparent") }
let bw = maxX - minX + 1, bh = maxY - minY + 1
let crop = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
crop.draw(ctx.makeImage()!, in: CGRect(x: CGFloat(-minX), y: CGFloat(-minY),
                                       width: CGFloat(w), height: CGFloat(h)))
guard let glyph = crop.makeImage() else { fatalError("crop failed") }

// 居中贴到标准状态栏画布：1x=18px（字形高 15px），2x=36px（字形高 30px）。
func emit(canvas: Int, glyphHeight: Int, name: String) throws {
    let scale = CGFloat(glyphHeight) / CGFloat(glyph.height)
    let gw = max(1, Int((CGFloat(glyph.width) * scale).rounded()))
    let gh = glyphHeight
    let c = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                      bytesPerRow: canvas * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let gx = (canvas - gw) / 2, gy = (canvas - gh) / 2
    c.draw(glyph, in: CGRect(x: CGFloat(gx), y: CGFloat(gy), width: CGFloat(gw), height: CGFloat(gh)))
    guard let out = c.makeImage() else { fatalError("canvas failed") }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode") }
    try png.write(to: URL(fileURLWithPath: outDir + "/" + name))
    print("\(name): canvas \(canvas)x\(canvas), glyph \(gw)x\(gh)")
}

try emit(canvas: 36, glyphHeight: 30, name: "ShanXunMenuIcon@2x.png")
try emit(canvas: 18, glyphHeight: 15, name: "ShanXunMenuIcon.png")

// 同一枚字形还要当**搜索框前导图标**（22pt）。这里不能复用上面那套：
// 状态栏画布只有 36px，画到 22pt 在 Retina 上需要 44px 像素，等于放大 1.22 倍、
// 边缘发虚。所以另出一组像素对齐的：@1x 画布 24px 正好等于 22pt 取整略冲、
// @2x 画布 48px 覆盖 Retina 的 44px。填充比仍锁 30/36 = 20/24 = 40/48 = 0.8333，
// 与状态栏完全同源，换过去不会「看起来大了一圈」。
try emit(canvas: 48, glyphHeight: 40, name: "ShanXunGlyph@2x.png")
try emit(canvas: 24, glyphHeight: 20, name: "ShanXunGlyph.png")
