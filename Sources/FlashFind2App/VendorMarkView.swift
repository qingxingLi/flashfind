import SwiftUI
import FlashFindCore

/// 品牌标记的绘制。
///
/// ★ 形态取自三家**自己的**标志（2026-10-29 用户提供截图指定）：
///   · 群晖 = DSM 的圆角方块 + 「DSM」三个字母（字母是**镂空**的）
///   · 飞牛 = 牛头：F 形主体 + 左右两只分离的角
///   · OpenList = 按参考图原轮廓描摹的双笔旋涡标记
///
/// 统一成**单色剪影**（fill）：浅色模式黑图形、深色模式白图形，**不铺底色** ——
/// 白底贴片在深色界面上像一张贴纸，而切到白图形就跟其他 SF Symbol 一个观感。
/// 字母、环内空白等「负形」继续用 even-odd 挖空，透出的是窗口背景而不是一块白。
///
/// 坐标写在 24×24 网格（`VendorMark.designSize`），按目标边长等比缩放。
/// 三个标记均由用户提供原图直接提取轮廓后归一化，仅改成单色，不重新设计形状。
struct VendorMarkView: View {
    let mark: VendorMark

    @Environment(\.colorScheme) private var colorScheme

    /// 深色界面画白、浅色界面画黑。只这两个值，不参与 `foregroundStyle`，
    /// 否则被外层染成强调色时三家又变回同一套图标。
    private var ink: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }

            let scale = side / VendorMark.designSize
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let geometry = VendorMarkShapes.geometry(for: mark)
            let filled = geometry.filled.applying(transform)
            if geometry.knockedOut.isEmpty {
                context.fill(filled, with: .color(ink))
            } else {
                var combined = filled
                combined.addPath(geometry.knockedOut.applying(transform))
                context.fill(combined, with: .color(ink),
                             style: FillStyle(eoFill: true, antialiased: true))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 三家标记的几何（24×24 网格）。
enum VendorMarkShapes {
    struct Geometry {
        let filled: Path
        let knockedOut: Path
    }

    static func geometry(for mark: VendorMark) -> Geometry {
        switch mark {
        case .synology: return synology
        case .fnos: return fnos
        case .openlist: return openlist
        }
    }

    /// 轮廓来自用户提供的原始图标截图：先提取原标记，再做亚像素平滑描摹，
    /// 最后按比例归一化到 24×24。这里只改变颜色，不重新设计形状。
    private static func tracedPath(_ contours: [[CGPoint]]) -> Path {
        var path = Path()
        for contour in contours {
            guard let first = contour.first else { continue }
            path.move(to: first)
            for point in contour.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        return path
    }

    /// 群晖 DSM：保留参考图圆角方块及 DSM 原字形比例，仅改为单色。
    private static var synology: Geometry {
        let outer = tracedPath(
[
                [
                    CGPoint(x: 18.779, y: 20.783),
                    CGPoint(x: 18.587, y: 20.927),
                    CGPoint(x: 18.148, y: 21.000),
                    CGPoint(x: 5.852, y: 21.000),
                    CGPoint(x: 5.413, y: 20.927),
                    CGPoint(x: 3.656, y: 19.220),
                    CGPoint(x: 3.509, y: 19.027),
                    CGPoint(x: 3.365, y: 18.587),
                    CGPoint(x: 3.072, y: 18.148),
                    CGPoint(x: 3.000, y: 17.709),
                    CGPoint(x: 3.000, y: 6.730),
                    CGPoint(x: 3.072, y: 6.291),
                    CGPoint(x: 3.362, y: 5.852),
                    CGPoint(x: 3.512, y: 4.973),
                    CGPoint(x: 4.781, y: 3.656),
                    CGPoint(x: 4.973, y: 3.512),
                    CGPoint(x: 5.852, y: 3.362),
                    CGPoint(x: 6.291, y: 3.072),
                    CGPoint(x: 6.730, y: 3.000),
                    CGPoint(x: 17.270, y: 3.000),
                    CGPoint(x: 17.709, y: 3.072),
                    CGPoint(x: 18.148, y: 3.362),
                    CGPoint(x: 19.027, y: 3.512),
                    CGPoint(x: 20.344, y: 4.781),
                    CGPoint(x: 20.488, y: 4.973),
                    CGPoint(x: 20.638, y: 5.852),
                    CGPoint(x: 20.928, y: 6.291),
                    CGPoint(x: 21.000, y: 6.730),
                    CGPoint(x: 21.000, y: 17.709),
                    CGPoint(x: 20.928, y: 18.148),
                    CGPoint(x: 20.635, y: 18.587),
                    CGPoint(x: 20.491, y: 19.027)
                ]
            ]
        )
        let letters = tracedPath(
[
                [
                    CGPoint(x: 7.608, y: 14.778),
                    CGPoint(x: 8.048, y: 14.412),
                    CGPoint(x: 8.629, y: 13.757),
                    CGPoint(x: 8.700, y: 13.318),
                    CGPoint(x: 8.700, y: 11.122),
                    CGPoint(x: 8.627, y: 10.683),
                    CGPoint(x: 8.321, y: 10.243),
                    CGPoint(x: 8.163, y: 9.804),
                    CGPoint(x: 8.048, y: 9.690),
                    CGPoint(x: 7.608, y: 9.591),
                    CGPoint(x: 4.973, y: 9.612),
                    CGPoint(x: 4.550, y: 9.804),
                    CGPoint(x: 4.793, y: 10.243),
                    CGPoint(x: 4.973, y: 10.381),
                    CGPoint(x: 5.413, y: 10.456),
                    CGPoint(x: 7.169, y: 10.463),
                    CGPoint(x: 7.608, y: 10.562),
                    CGPoint(x: 7.740, y: 10.683),
                    CGPoint(x: 7.829, y: 11.122),
                    CGPoint(x: 7.829, y: 12.878),
                    CGPoint(x: 7.756, y: 13.318),
                    CGPoint(x: 7.169, y: 13.904),
                    CGPoint(x: 6.730, y: 13.977),
                    CGPoint(x: 5.852, y: 13.976),
                    CGPoint(x: 5.413, y: 13.874),
                    CGPoint(x: 5.295, y: 13.757),
                    CGPoint(x: 5.193, y: 13.318),
                    CGPoint(x: 5.185, y: 12.439),
                    CGPoint(x: 5.082, y: 12.000),
                    CGPoint(x: 4.973, y: 11.892),
                    CGPoint(x: 4.534, y: 11.892),
                    CGPoint(x: 4.426, y: 12.000),
                    CGPoint(x: 4.322, y: 12.439),
                    CGPoint(x: 4.321, y: 13.757),
                    CGPoint(x: 4.392, y: 14.196),
                    CGPoint(x: 4.973, y: 14.778),
                    CGPoint(x: 5.852, y: 14.851),
                    CGPoint(x: 7.169, y: 14.849)
                ],
                [
                    CGPoint(x: 12.878, y: 14.774),
                    CGPoint(x: 13.896, y: 13.757),
                    CGPoint(x: 13.970, y: 13.318),
                    CGPoint(x: 13.899, y: 12.439),
                    CGPoint(x: 13.317, y: 11.857),
                    CGPoint(x: 12.878, y: 11.786),
                    CGPoint(x: 11.561, y: 11.781),
                    CGPoint(x: 11.122, y: 11.696),
                    CGPoint(x: 10.987, y: 11.561),
                    CGPoint(x: 10.905, y: 11.122),
                    CGPoint(x: 11.004, y: 10.683),
                    CGPoint(x: 11.122, y: 10.565),
                    CGPoint(x: 11.561, y: 10.463),
                    CGPoint(x: 13.317, y: 10.455),
                    CGPoint(x: 13.757, y: 10.352),
                    CGPoint(x: 13.865, y: 10.243),
                    CGPoint(x: 13.865, y: 9.804),
                    CGPoint(x: 13.757, y: 9.696),
                    CGPoint(x: 13.317, y: 9.592),
                    CGPoint(x: 11.122, y: 9.591),
                    CGPoint(x: 10.683, y: 9.662),
                    CGPoint(x: 10.101, y: 10.243),
                    CGPoint(x: 10.030, y: 11.122),
                    CGPoint(x: 10.104, y: 11.561),
                    CGPoint(x: 11.122, y: 12.578),
                    CGPoint(x: 11.561, y: 12.652),
                    CGPoint(x: 12.439, y: 12.659),
                    CGPoint(x: 12.878, y: 12.761),
                    CGPoint(x: 12.996, y: 12.878),
                    CGPoint(x: 13.095, y: 13.318),
                    CGPoint(x: 13.013, y: 13.757),
                    CGPoint(x: 12.878, y: 13.891),
                    CGPoint(x: 12.439, y: 13.977),
                    CGPoint(x: 10.683, y: 13.984),
                    CGPoint(x: 10.243, y: 14.087),
                    CGPoint(x: 10.135, y: 14.196),
                    CGPoint(x: 10.135, y: 14.635),
                    CGPoint(x: 10.243, y: 14.743),
                    CGPoint(x: 10.683, y: 14.847),
                    CGPoint(x: 12.439, y: 14.848)
                ],
                [
                    CGPoint(x: 15.513, y: 14.743),
                    CGPoint(x: 15.952, y: 14.743),
                    CGPoint(x: 16.061, y: 14.635),
                    CGPoint(x: 16.164, y: 14.196),
                    CGPoint(x: 16.195, y: 12.000),
                    CGPoint(x: 16.392, y: 11.573),
                    CGPoint(x: 16.831, y: 11.789),
                    CGPoint(x: 17.270, y: 12.429),
                    CGPoint(x: 17.709, y: 12.206),
                    CGPoint(x: 18.148, y: 11.763),
                    CGPoint(x: 18.587, y: 11.573),
                    CGPoint(x: 18.785, y: 12.000),
                    CGPoint(x: 18.834, y: 14.196),
                    CGPoint(x: 19.027, y: 14.619),
                    CGPoint(x: 19.466, y: 14.376),
                    CGPoint(x: 19.604, y: 14.196),
                    CGPoint(x: 19.679, y: 13.757),
                    CGPoint(x: 19.682, y: 10.243),
                    CGPoint(x: 19.580, y: 9.804),
                    CGPoint(x: 19.466, y: 9.690),
                    CGPoint(x: 19.027, y: 9.592),
                    CGPoint(x: 18.587, y: 9.689),
                    CGPoint(x: 17.999, y: 10.683),
                    CGPoint(x: 17.838, y: 11.122),
                    CGPoint(x: 17.709, y: 11.251),
                    CGPoint(x: 17.270, y: 11.250),
                    CGPoint(x: 17.141, y: 11.122),
                    CGPoint(x: 16.981, y: 10.683),
                    CGPoint(x: 16.392, y: 9.689),
                    CGPoint(x: 15.952, y: 9.592),
                    CGPoint(x: 15.513, y: 9.690),
                    CGPoint(x: 15.399, y: 9.804),
                    CGPoint(x: 15.298, y: 10.243),
                    CGPoint(x: 15.301, y: 14.196),
                    CGPoint(x: 15.405, y: 14.635)
                ]
            ]
        )
        return Geometry(filled: outer, knockedOut: letters)
    }

    /// 飞牛 fnOS：保留参考图两只牛角、顶部弧线和 F 主体的原始轮廓关系。
    private static var fnos: Geometry {
        let mark = tracedPath(
[
                [
                    CGPoint(x: 4.624, y: 10.152),
                    CGPoint(x: 4.124, y: 10.153),
                    CGPoint(x: 3.874, y: 10.112),
                    CGPoint(x: 3.624, y: 9.943),
                    CGPoint(x: 3.374, y: 9.861),
                    CGPoint(x: 3.124, y: 9.690),
                    CGPoint(x: 2.873, y: 9.591),
                    CGPoint(x: 2.806, y: 9.523),
                    CGPoint(x: 2.707, y: 9.270),
                    CGPoint(x: 2.291, y: 8.765),
                    CGPoint(x: 2.206, y: 8.260),
                    CGPoint(x: 2.041, y: 8.007),
                    CGPoint(x: 2.000, y: 7.502),
                    CGPoint(x: 2.041, y: 7.249),
                    CGPoint(x: 2.206, y: 6.997),
                    CGPoint(x: 2.291, y: 6.239),
                    CGPoint(x: 2.458, y: 5.986),
                    CGPoint(x: 2.539, y: 5.734),
                    CGPoint(x: 2.708, y: 5.481),
                    CGPoint(x: 2.790, y: 5.228),
                    CGPoint(x: 3.374, y: 4.619),
                    CGPoint(x: 3.624, y: 4.500),
                    CGPoint(x: 3.684, y: 4.723),
                    CGPoint(x: 3.529, y: 4.976),
                    CGPoint(x: 3.456, y: 5.734),
                    CGPoint(x: 3.291, y: 5.986),
                    CGPoint(x: 3.252, y: 6.239),
                    CGPoint(x: 3.291, y: 6.491),
                    CGPoint(x: 3.458, y: 6.744),
                    CGPoint(x: 3.539, y: 6.997),
                    CGPoint(x: 3.708, y: 7.249),
                    CGPoint(x: 3.806, y: 7.502),
                    CGPoint(x: 3.874, y: 7.570),
                    CGPoint(x: 4.124, y: 7.669),
                    CGPoint(x: 4.374, y: 7.840),
                    CGPoint(x: 4.624, y: 7.922),
                    CGPoint(x: 4.874, y: 8.091),
                    CGPoint(x: 5.374, y: 8.147),
                    CGPoint(x: 5.617, y: 8.260),
                    CGPoint(x: 5.458, y: 8.765),
                    CGPoint(x: 5.290, y: 9.018),
                    CGPoint(x: 5.208, y: 9.270),
                    CGPoint(x: 5.041, y: 9.523),
                    CGPoint(x: 4.939, y: 10.028),
                    CGPoint(x: 4.874, y: 10.094)
                ],
                [
                    CGPoint(x: 7.624, y: 18.996),
                    CGPoint(x: 7.291, y: 18.617),
                    CGPoint(x: 7.208, y: 18.365),
                    CGPoint(x: 7.042, y: 18.112),
                    CGPoint(x: 7.001, y: 17.860),
                    CGPoint(x: 7.001, y: 10.028),
                    CGPoint(x: 7.042, y: 9.776),
                    CGPoint(x: 7.208, y: 9.523),
                    CGPoint(x: 7.291, y: 9.270),
                    CGPoint(x: 7.500, y: 9.018),
                    CGPoint(x: 7.874, y: 8.681),
                    CGPoint(x: 8.124, y: 8.597),
                    CGPoint(x: 8.374, y: 8.429),
                    CGPoint(x: 8.874, y: 8.343),
                    CGPoint(x: 9.125, y: 8.176),
                    CGPoint(x: 9.375, y: 8.135),
                    CGPoint(x: 18.876, y: 8.133),
                    CGPoint(x: 19.376, y: 8.091),
                    CGPoint(x: 19.626, y: 7.922),
                    CGPoint(x: 19.876, y: 7.839),
                    CGPoint(x: 19.986, y: 7.755),
                    CGPoint(x: 20.210, y: 7.502),
                    CGPoint(x: 20.292, y: 7.249),
                    CGPoint(x: 20.459, y: 6.997),
                    CGPoint(x: 20.542, y: 6.491),
                    CGPoint(x: 20.651, y: 6.239),
                    CGPoint(x: 20.542, y: 5.986),
                    CGPoint(x: 20.503, y: 5.734),
                    CGPoint(x: 20.471, y: 4.976),
                    CGPoint(x: 20.316, y: 4.723),
                    CGPoint(x: 20.376, y: 4.500),
                    CGPoint(x: 20.626, y: 4.619),
                    CGPoint(x: 20.876, y: 4.852),
                    CGPoint(x: 21.210, y: 5.228),
                    CGPoint(x: 21.292, y: 5.481),
                    CGPoint(x: 21.461, y: 5.734),
                    CGPoint(x: 21.542, y: 5.986),
                    CGPoint(x: 21.709, y: 6.239),
                    CGPoint(x: 21.794, y: 6.997),
                    CGPoint(x: 21.959, y: 7.249),
                    CGPoint(x: 22.000, y: 7.755),
                    CGPoint(x: 21.959, y: 8.007),
                    CGPoint(x: 21.794, y: 8.260),
                    CGPoint(x: 21.709, y: 8.765),
                    CGPoint(x: 20.736, y: 9.776),
                    CGPoint(x: 20.626, y: 9.860),
                    CGPoint(x: 20.376, y: 9.943),
                    CGPoint(x: 20.126, y: 10.112),
                    CGPoint(x: 19.626, y: 10.154),
                    CGPoint(x: 9.375, y: 10.156),
                    CGPoint(x: 9.125, y: 10.198),
                    CGPoint(x: 8.874, y: 10.424),
                    CGPoint(x: 8.793, y: 10.533),
                    CGPoint(x: 8.751, y: 10.786),
                    CGPoint(x: 8.751, y: 16.849),
                    CGPoint(x: 8.793, y: 17.102),
                    CGPoint(x: 9.125, y: 17.437),
                    CGPoint(x: 9.625, y: 17.481),
                    CGPoint(x: 10.125, y: 17.437),
                    CGPoint(x: 10.457, y: 17.102),
                    CGPoint(x: 10.498, y: 16.849),
                    CGPoint(x: 10.501, y: 15.839),
                    CGPoint(x: 10.542, y: 15.586),
                    CGPoint(x: 10.875, y: 15.013),
                    CGPoint(x: 11.125, y: 14.914),
                    CGPoint(x: 11.375, y: 14.745),
                    CGPoint(x: 11.625, y: 14.703),
                    CGPoint(x: 13.125, y: 14.700),
                    CGPoint(x: 13.375, y: 14.641),
                    CGPoint(x: 13.440, y: 14.575),
                    CGPoint(x: 13.498, y: 14.323),
                    CGPoint(x: 13.502, y: 13.312),
                    CGPoint(x: 13.543, y: 13.060),
                    CGPoint(x: 13.709, y: 12.807),
                    CGPoint(x: 13.792, y: 12.554),
                    CGPoint(x: 14.125, y: 12.219),
                    CGPoint(x: 14.375, y: 12.177),
                    CGPoint(x: 18.876, y: 12.191),
                    CGPoint(x: 19.117, y: 12.302),
                    CGPoint(x: 18.995, y: 12.554),
                    CGPoint(x: 18.626, y: 12.891),
                    CGPoint(x: 18.376, y: 12.975),
                    CGPoint(x: 17.876, y: 13.397),
                    CGPoint(x: 17.626, y: 13.480),
                    CGPoint(x: 17.376, y: 13.648),
                    CGPoint(x: 16.626, y: 13.734),
                    CGPoint(x: 16.376, y: 13.901),
                    CGPoint(x: 15.626, y: 14.005),
                    CGPoint(x: 15.561, y: 14.070),
                    CGPoint(x: 15.503, y: 14.323),
                    CGPoint(x: 15.499, y: 15.586),
                    CGPoint(x: 15.457, y: 15.839),
                    CGPoint(x: 15.250, y: 16.091),
                    CGPoint(x: 14.875, y: 16.427),
                    CGPoint(x: 14.625, y: 16.468),
                    CGPoint(x: 12.875, y: 16.472),
                    CGPoint(x: 12.625, y: 16.531),
                    CGPoint(x: 12.560, y: 16.596),
                    CGPoint(x: 12.502, y: 16.849),
                    CGPoint(x: 12.498, y: 18.365),
                    CGPoint(x: 12.457, y: 18.617),
                    CGPoint(x: 12.249, y: 18.870),
                    CGPoint(x: 11.875, y: 19.207),
                    CGPoint(x: 11.625, y: 19.290),
                    CGPoint(x: 11.375, y: 19.459),
                    CGPoint(x: 11.125, y: 19.500),
                    CGPoint(x: 9.125, y: 19.500),
                    CGPoint(x: 8.874, y: 19.459),
                    CGPoint(x: 8.624, y: 19.292),
                    CGPoint(x: 7.874, y: 19.205)
                ]
            ]
        )
        return Geometry(filled: mark, knockedOut: Path())
    }

    /// OpenList：保留参考图外弧、内斜笔、缺口及末端圆弧的原始轮廓。
    /// 原图的青/蓝双色统一为同一前景色。
    private static var openlist: Geometry {
        let mark = tracedPath(
[
                [
                    CGPoint(x: 14.721, y: 20.917),
                    CGPoint(x: 14.218, y: 20.997),
                    CGPoint(x: 10.700, y: 21.000),
                    CGPoint(x: 9.695, y: 20.916),
                    CGPoint(x: 9.028, y: 20.270),
                    CGPoint(x: 8.945, y: 19.784),
                    CGPoint(x: 9.027, y: 18.811),
                    CGPoint(x: 9.362, y: 18.324),
                    CGPoint(x: 9.527, y: 17.838),
                    CGPoint(x: 10.366, y: 16.865),
                    CGPoint(x: 10.532, y: 16.378),
                    CGPoint(x: 11.371, y: 15.405),
                    CGPoint(x: 11.536, y: 14.919),
                    CGPoint(x: 11.875, y: 14.432),
                    CGPoint(x: 12.040, y: 13.946),
                    CGPoint(x: 12.879, y: 12.973),
                    CGPoint(x: 13.080, y: 12.486),
                    CGPoint(x: 13.213, y: 12.359),
                    CGPoint(x: 13.716, y: 12.247),
                    CGPoint(x: 14.721, y: 12.327),
                    CGPoint(x: 15.388, y: 12.973),
                    CGPoint(x: 15.468, y: 13.459),
                    CGPoint(x: 15.390, y: 13.946),
                    CGPoint(x: 15.054, y: 14.432),
                    CGPoint(x: 14.889, y: 14.919),
                    CGPoint(x: 14.051, y: 15.892),
                    CGPoint(x: 13.885, y: 16.378),
                    CGPoint(x: 13.547, y: 16.865),
                    CGPoint(x: 13.385, y: 17.351),
                    CGPoint(x: 13.005, y: 17.838),
                    CGPoint(x: 12.770, y: 18.324),
                    CGPoint(x: 13.213, y: 18.441),
                    CGPoint(x: 13.716, y: 18.142),
                    CGPoint(x: 14.721, y: 17.997),
                    CGPoint(x: 15.726, y: 17.189),
                    CGPoint(x: 16.229, y: 17.027),
                    CGPoint(x: 16.449, y: 16.865),
                    CGPoint(x: 16.899, y: 16.378),
                    CGPoint(x: 17.066, y: 15.892),
                    CGPoint(x: 17.901, y: 14.919),
                    CGPoint(x: 18.073, y: 13.946),
                    CGPoint(x: 18.405, y: 13.459),
                    CGPoint(x: 18.487, y: 12.973),
                    CGPoint(x: 18.490, y: 12.000),
                    CGPoint(x: 18.487, y: 11.027),
                    CGPoint(x: 18.405, y: 10.541),
                    CGPoint(x: 18.070, y: 10.054),
                    CGPoint(x: 17.906, y: 9.568),
                    CGPoint(x: 17.567, y: 9.081),
                    CGPoint(x: 17.402, y: 8.595),
                    CGPoint(x: 16.981, y: 8.108),
                    CGPoint(x: 15.224, y: 6.486),
                    CGPoint(x: 14.721, y: 6.326),
                    CGPoint(x: 14.218, y: 6.001),
                    CGPoint(x: 13.716, y: 5.922),
                    CGPoint(x: 10.198, y: 5.922),
                    CGPoint(x: 9.695, y: 6.001),
                    CGPoint(x: 9.193, y: 6.326),
                    CGPoint(x: 8.690, y: 6.485),
                    CGPoint(x: 8.187, y: 6.813),
                    CGPoint(x: 7.685, y: 6.973),
                    CGPoint(x: 7.182, y: 7.380),
                    CGPoint(x: 6.512, y: 8.108),
                    CGPoint(x: 6.346, y: 8.595),
                    CGPoint(x: 6.008, y: 9.081),
                    CGPoint(x: 5.842, y: 9.568),
                    CGPoint(x: 5.172, y: 10.213),
                    CGPoint(x: 4.167, y: 10.294),
                    CGPoint(x: 3.664, y: 10.213),
                    CGPoint(x: 3.001, y: 9.568),
                    CGPoint(x: 3.000, y: 9.081),
                    CGPoint(x: 3.328, y: 8.595),
                    CGPoint(x: 3.499, y: 7.622),
                    CGPoint(x: 3.917, y: 7.135),
                    CGPoint(x: 7.182, y: 4.054),
                    CGPoint(x: 7.685, y: 3.894),
                    CGPoint(x: 8.187, y: 3.569),
                    CGPoint(x: 9.695, y: 3.404),
                    CGPoint(x: 10.198, y: 3.083),
                    CGPoint(x: 10.700, y: 3.003),
                    CGPoint(x: 11.705, y: 3.000),
                    CGPoint(x: 13.213, y: 3.003),
                    CGPoint(x: 13.716, y: 3.083),
                    CGPoint(x: 14.218, y: 3.404),
                    CGPoint(x: 15.224, y: 3.569),
                    CGPoint(x: 15.726, y: 3.894),
                    CGPoint(x: 16.229, y: 4.052),
                    CGPoint(x: 16.731, y: 4.380),
                    CGPoint(x: 17.234, y: 4.540),
                    CGPoint(x: 17.737, y: 4.947),
                    CGPoint(x: 19.412, y: 6.649),
                    CGPoint(x: 19.579, y: 7.135),
                    CGPoint(x: 20.414, y: 8.108),
                    CGPoint(x: 20.586, y: 9.081),
                    CGPoint(x: 20.918, y: 9.568),
                    CGPoint(x: 21.000, y: 10.054),
                    CGPoint(x: 21.000, y: 14.432),
                    CGPoint(x: 20.918, y: 14.919),
                    CGPoint(x: 20.583, y: 15.405),
                    CGPoint(x: 20.419, y: 15.892),
                    CGPoint(x: 20.080, y: 16.378),
                    CGPoint(x: 19.915, y: 16.865),
                    CGPoint(x: 18.993, y: 17.838),
                    CGPoint(x: 16.731, y: 19.946),
                    CGPoint(x: 16.229, y: 20.106),
                    CGPoint(x: 15.726, y: 20.434),
                    CGPoint(x: 15.224, y: 20.593)
                ],
                [
                    CGPoint(x: 4.669, y: 18.000),
                    CGPoint(x: 4.002, y: 17.351),
                    CGPoint(x: 3.922, y: 16.865),
                    CGPoint(x: 4.002, y: 16.378),
                    CGPoint(x: 4.837, y: 15.405),
                    CGPoint(x: 5.004, y: 14.919),
                    CGPoint(x: 5.842, y: 13.946),
                    CGPoint(x: 6.008, y: 13.459),
                    CGPoint(x: 6.346, y: 12.973),
                    CGPoint(x: 6.512, y: 12.486),
                    CGPoint(x: 7.350, y: 11.514),
                    CGPoint(x: 7.517, y: 11.027),
                    CGPoint(x: 8.355, y: 10.054),
                    CGPoint(x: 8.522, y: 9.568),
                    CGPoint(x: 9.476, y: 8.595),
                    CGPoint(x: 9.695, y: 8.435),
                    CGPoint(x: 10.198, y: 8.355),
                    CGPoint(x: 10.700, y: 8.356),
                    CGPoint(x: 11.203, y: 8.467),
                    CGPoint(x: 11.867, y: 9.568),
                    CGPoint(x: 11.866, y: 10.054),
                    CGPoint(x: 11.035, y: 11.027),
                    CGPoint(x: 10.870, y: 11.514),
                    CGPoint(x: 10.531, y: 12.000),
                    CGPoint(x: 10.366, y: 12.486),
                    CGPoint(x: 9.527, y: 13.459),
                    CGPoint(x: 9.360, y: 13.946),
                    CGPoint(x: 8.522, y: 14.919),
                    CGPoint(x: 8.355, y: 15.405),
                    CGPoint(x: 7.517, y: 16.378),
                    CGPoint(x: 7.350, y: 16.865),
                    CGPoint(x: 6.177, y: 18.075),
                    CGPoint(x: 5.674, y: 18.369)
                ]
            ]
        )
        return Geometry(filled: mark, knockedOut: Path())
    }
}

/// 来源图标：有品牌标记就画标记，没有就退回 SF Symbol。
///
/// 调用点只认这一个入口 —— 谁都不该再自己写 `Image(systemName: vendor.symbol)`，
/// 否则新加的标记在某处界面漏掉，那处就继续显示通用硬盘图标。
struct VendorIcon: View {
    let vendor: NASSourceConfig.Vendor
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let mark = vendor.mark {
                VendorMarkView(mark: mark)
                    .frame(width: size, height: size)
            } else {
                // 回落符号跟随 `.primary`（浅色近黑、深色近白），与标记同一套明暗。
                Image(systemName: vendor.symbol)
                    .font(.system(size: size * 0.92))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
