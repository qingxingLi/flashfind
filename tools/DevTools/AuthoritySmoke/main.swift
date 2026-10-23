import Foundation
import FlashFindCore

// 开发期工具：起一个**真实的**权威端监听，供另一个进程（python / curl 类）冒烟用。
//
// ★ 不进产品，也不进 `products`：与 `FlashFindCLI` / `FlashFindSmoke` 同类。
//   它的存在只为一件事——`swift test` 里的用例和监听在同一个进程里，
//   证明不了「另一个进程能不能连上、文件权限对不对、第二个实例会不会抢」。
//
// ★ 6.2 起挂的是**真实的** `RoutingAuthorityService`（而不是空业务实现），
//   于是跨进程冒烟能看见「App 现读设置 → 判定 → list_sources」的真链路：
//   三个候选来源里只授权两个，第三个的 id 与名字都不该出现在响应里。
//
// 用法：
//     FF_AUTHORITY_SOCKET=/tmp/ff-smoke/mcp.sock swift run AuthoritySmoke
//   然后由另一个进程往那个 socket 发一行 JSON；本进程读到 stdin EOF 就退出。

let path: String = {
    if let override = ProcessInfo.processInfo.environment["FF_AUTHORITY_SOCKET"], !override.isEmpty {
        return override
    }
    return AuthoritySocketPath.standard()
}()


/// 冒烟用的假事实。**没有一个是真实设备名**：这个文件会进公开仓。
///
/// `src_nas_other` 故意存在但**未授权**：它的 id 与名字出现在任何响应里都是泄露
/// （§4.3.1），跨进程冒烟要能把这件事测出来。
let smokeSettings = AIAccessSettings(isEnabled: true,
                                     allowedSources: ["local_mac", "src_nas_work"])

let smokeSources = [AuthoritySource(id: "local_mac", name: "This Mac"),
                    AuthoritySource(id: "src_nas_other", name: "Private Archive"),
                    AuthoritySource(id: "src_nas_work", name: "Work NAS")]

let service = RoutingAuthorityService(settings: { smokeSettings },
                                      sources: { smokeSources })

let listener = AuthorityListener(path: path, service: service)

switch listener.start() {
case .listening(let location):
    // 行缓冲靠 fflush：stdout 接管道时是块缓冲，不刷就等不到这一行。
    print("LISTENING \(location)")
case .ownedByAnotherInstance:
    print("OWNED_BY_ANOTHER_INSTANCE")
    exit(2)
case .failed(let reason):
    print("FAILED \(reason)")
    exit(3)
}
fflush(stdout)

// 读到 stdin EOF 就收工（客户端关管道 / `</dev/null` 都会立即结束）。
while readLine(strippingNewline: true) != nil {}

listener.stop()
print("STOPPED")
fflush(stdout)
