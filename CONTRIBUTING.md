# 参与开发

本项目的测试纪律比一般项目硬一些。这些规则不是形式主义，
每一条背后都有一次「改一个 bug 又冒出十个」的教训。请先读完再动手。

---

## 一、分层的硬约束

| 层 | 能不能写单元测试 |
|---|---|
| `FlashFindCore` | ✅ 正常写 |
| `FlashFind2App` | ❌ **不能** —— `AppModel` 无法实例化 |

**推论**：任何想被测试覆盖的逻辑，必须下沉到 Core。App 层只保留装配与界面。

App 层怎么保证质量？三种手段叠加：
1. `swift build` 必须过；
2. 扫源码的**结构测试**（见下）；
3. 实机人工点验。

---

## 二、结构测试的写法（很容易写错）

扫源码断言"某行在不在某个分支里"，**不能用 `contains` 扫整个函数** ——
同名分支会让断言假绿。必须用括号配平切出目标分支的花括号块：

```swift
let block = AppLayerStructureTests.braceBlock(after: "HStack(spacing: 14)", in: source)
XCTAssertTrue(block.contains("Button(action: research)"))
```

**断言必须落进目标分支的块里。** 踩过两次：整函数 `contains` 被另一个分支满足，
变异测试直接逃过红证。

---

## 三、单一出处

同一份字面量/名单如果在两处各写一遍，变异测试只改其中一处时，
另一处残留照样满足断言 → **假绿**。

做法：收成一个常量，并额外断言「这个常量被引用了 N 处」。

`braceBlock` 管的是「在不在正确分支」，单一出处管的是「漏没漏环节」，两者都要。

---

## 四、新增测试必须先在未修源码上跑红

写一条新断言，先把它放到**还没修的源码**上跑，确认它真的会失败。
没这一步，你不知道自己锁住的是什么。

---

## 五、跑红证（变异测试）

```bash
python3 tools/red_proof.py
```

它会往源码里注入一批变异，检查每条断言是否真的会变红。
**所有变异是一起注入的**，所以：

- 断言不要读会被别的变异改掉的常量（两个变异的语义可能正好抵消 → 假绿）；
- 预算类的断言按最坏值写死。

目标是**全红**。出现 MISS 说明断言没锁住东西，要补。

---

## 六、改了源码必须重编

- 改了 `.swift` / `.dart` → 必须重新构建，不能沿用旧包。
- **只改包装**（图标、DMG 布局、说明文本）→ 用 `--app-from-zip <已发布 zip>`，绝不重编。

原因：Swift 产物不字节可复现（同源码连编两次主二进制都能差 1914 字节）。
同一个版本号下出现两个不同的二进制，比不升级更糟。

---

## 七、错误 kind 的契约

错误类型**只有一个出处**：`MyNASCore/lib/error_kinds.dart`。
改它要同步：

1. export 出去；
2. 重新生成 `error_kinds.json`；
3. Swift 侧与 Dart 侧各补一条测试。

同一个 kind 不允许出现两种文案。三条失败文案住在 Core：
`NASSearchFailureText` / `OpenFailureText` / `ConnectionFailureText`。

---

## 八、提交前自查

```bash
swift test                        # 必须 0 失败
cd MyNASCore && dart test_*.dart  # 必须全通过
python3 tools/red_proof.py        # 必须全红
```

另外：

- 不要在代码或注释里写真实设备地址、序列号、MAC、用户名、单位名。
  测试 fixture 一律用文档段或 `10.x` 私有示例地址。
- 不要引入密钥链访问（见 `SECURITY.md`）。
- 界面文案避免实现术语（mdfind / DSM / SMB / WebDAV / Adapter / API / Port）。
