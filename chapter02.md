# 第2章：源码全景地图

> 当你第一次走进一座大型图书馆时，你会先做什么？是随手抓一本书就开始读，还是先看看楼层指引图？

阅读大型开源项目的源码也是一样。在深入任何一个具体模块之前，我们需要先画出一张"全景地图"。这张地图不需要精确到每一条街道，但它应该能告诉你：哪些是主干道，哪些是小巷，以及它们之间是怎么连接的。

## 2.1 仓库顶层结构

让我们先看看 Frida 仓库的顶层目录：

```
frida/
├── meson.build          # 顶层构建文件，整个项目的"总指挥"
├── meson.options        # 构建选项定义
├── Makefile             # Make 入口，实际会调用 Meson
├── configure            # 配置脚本
├── releng/              # 发布工程相关脚本和工具
│   ├── frida_version.py # 版本号管理
│   ├── deps.toml        # 依赖声明
│   ├── meson/           # Meson 构建系统辅助模块
│   └── ...
├── subprojects/         # 核心子项目，这是重点
│   ├── frida-gum/       # 底层插桩引擎
│   ├── frida-core/      # 框架核心层
│   ├── frida-python/    # Python 绑定
│   ├── frida-node/      # Node.js 绑定
│   ├── frida-tools/     # CLI 命令行工具
│   ├── frida-swift/     # Swift 绑定
│   ├── frida-go/        # Go 绑定
│   ├── frida-clr/       # .NET/CLR 绑定
│   └── frida-qml/       # Qt/QML 绑定
└── tools/               # 辅助脚本
```

顶层仓库本身并不包含太多代码逻辑，它更像是一个"指挥中心"，负责把各个子项目组织在一起。真正的代码都在 `subprojects/` 目录下。

## 2.2 子项目架构：分层设计

Frida 采用了清晰的分层架构。如果把它比作一栋大楼，那从地基到屋顶是这样的：

```
┌─────────────────────────────────────────────────────┐
│                    用户脚本层                         │
│              (你写的 JavaScript 脚本)                 │
├─────────────────────────────────────────────────────┤
│                    绑定层 (Bindings)                  │
│    frida-python | frida-node | frida-swift | ...     │
├─────────────────────────────────────────────────────┤
│                    工具层 (Tools)                     │
│        frida-tools (frida, frida-trace, ...)         │
├─────────────────────────────────────────────────────┤
│                    核心层 (Core)                      │
│                    frida-core                        │
│         进程注入 | 会话管理 | 设备通信 | Agent        │
├─────────────────────────────────────────────────────┤
│                   引擎层 (Engine)                     │
│                    frida-gum                         │
│     Interceptor | Stalker | Memory | CodeWriter      │
├─────────────────────────────────────────────────────┤
│                  JS 运行时 (GumJS)                    │
│              V8 引擎  |  QuickJS 引擎                 │
├─────────────────────────────────────────────────────┤
│                  操作系统 / 硬件                       │
│         Windows | macOS | Linux | iOS | Android      │
└─────────────────────────────────────────────────────┘
```

我来逐层解释这个架构。

## 2.3 frida-gum：地基中的地基

frida-gum 是整个 Frida 的最底层引擎，用纯 C 语言编写。如果 Frida 是一辆汽车，那 frida-gum 就是发动机。

```
frida-gum/
├── gum/                    # 核心 C 代码
│   ├── gum.c/gum.h        # 初始化入口
│   ├── guminterceptor.c   # 函数拦截器 (Interceptor)
│   ├── gumstalker.c       # 代码追踪器 (Stalker)
│   ├── gummemory.c        # 内存操作
│   ├── gumprocess.c       # 进程操作
│   ├── gummodule.c        # 模块（动态库）操作
│   ├── gumcodeallocator.c # 代码内存分配
│   ├── arch-arm/          # ARM 架构特定代码
│   ├── arch-arm64/        # ARM64 架构特定代码
│   ├── arch-x86/          # x86 架构特定代码
│   ├── arch-mips/         # MIPS 架构特定代码
│   ├── backend-darwin/    # macOS/iOS 平台后端
│   ├── backend-linux/     # Linux 平台后端
│   ├── backend-windows/   # Windows 平台后端
│   └── ...
├── bindings/
│   └── gumjs/             # JavaScript 绑定层
│       ├── gumv8*.cpp     # V8 引擎绑定
│       ├── gumquick*.c    # QuickJS 引擎绑定
│       └── runtime/       # JS 运行时脚本
├── libs/                  # 内部依赖库
├── tests/                 # 测试代码
└── vapi/                  # Vala API 描述文件
```

frida-gum 中最重要的三个组件是：

**Interceptor（拦截器）**：能够拦截任意函数的调用。当目标函数被调用时，Frida 可以在函数入口和出口处执行你的回调代码。它的实现原理是修改函数入口处的机器指令，跳转到 Frida 准备好的一段"蹦床代码"（trampoline）。

**Stalker（追踪器）**：能够追踪程序执行的每一条指令。它使用动态二进制翻译技术，在程序执行前重写代码块，插入追踪逻辑。想象你在一本书的每一行旁边都插入一个书签，记录你读过这一行。

**Memory（内存操作）**：提供读写目标进程内存、扫描内存模式等能力。

注意 `bindings/gumjs/` 这个目录，它是连接 C 引擎和 JavaScript 世界的桥梁。这里有两套实现：基于 V8 引擎的（`gumv8*.cpp`）和基于 QuickJS 的（`gumquick*.c`）。V8 就是 Chrome 浏览器和 Node.js 使用的那个 JavaScript 引擎，性能强大但体积较大；QuickJS 是一个轻量级的 JS 引擎，适合资源受限的场景。

## 2.4 frida-core：大脑和神经系统

如果说 frida-gum 是肌肉，那 frida-core 就是大脑和神经系统。它负责进程管理、设备通信、代码注入等高层功能。frida-core 主要用 **Vala** 语言编写。

```
frida-core/
├── src/                        # 核心源码
│   ├── frida.vala              # 顶层 API 定义（DeviceManager 等）
│   ├── host-session-service.vala  # 会话管理服务
│   ├── control-service.vala    # 控制服务
│   ├── portal-service.vala     # Portal 服务
│   ├── agent-container.vala    # Agent 容器
│   ├── frida-glue.c            # C 语言粘合代码
│   ├── api/                    # 对外公开的 API
│   ├── compiler/               # 脚本编译器
│   ├── darwin/                 # macOS/iOS 平台实现
│   │   ├── darwin-host-session.vala
│   │   └── fruitjector.vala    # Darwin 平台注入器
│   ├── linux/                  # Linux 平台实现
│   │   ├── linux-host-session.vala
│   │   └── linjector.vala      # Linux 平台注入器
│   ├── windows/                # Windows 平台实现
│   │   ├── windows-host-session.vala
│   │   └── winjector.vala      # Windows 平台注入器
│   ├── droidy/                 # Android 设备通信（ADB）
│   ├── fruity/                 # iOS 设备通信（USB/网络）
│   └── barebone/               # 裸机调试支持
├── server/                     # frida-server 入口
├── inject/                     # frida-inject 工具
├── portal/                     # frida-portal 服务
├── lib/                        # 库文件
├── tests/                      # 测试
└── vapi/                       # Vala API 描述
```

frida-core 中有几个关键概念需要理解：

**HostSessionService**：这是整个 frida-core 的"总管"。打开 `host-session-service.vala` 你会看到，它根据当前平台加载不同的后端：

```
┌──────────────────────────────────────────────┐
│            HostSessionService                │
│               "总管"                          │
├──────────────────────────────────────────────┤
│                                              │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│  │ Darwin  │ │  Linux  │ │ Windows │  ...    │
│  │ Backend │ │ Backend │ │ Backend │        │
│  └─────────┘ └─────────┘ └─────────┘        │
│                                              │
│  ┌─────────┐ ┌─────────┐                    │
│  │ Fruity  │ │ Droidy  │   远程设备后端      │
│  │ (iOS)   │ │(Android)│                    │
│  └─────────┘ └─────────┘                    │
└──────────────────────────────────────────────┘
```

**Injector（注入器）**：每个平台都有自己的注入器实现。Darwin 平台叫 `fruitjector`（水果注入器，因为苹果嘛），Linux 平台叫 `linjector`，Windows 平台叫 `winjector`。这些注入器负责把 Frida 的 Agent 动态库注入到目标进程中。

**Agent**：被注入到目标进程中的代码。它包含了 frida-gum 引擎和 JavaScript 运行时，是你的 JS 脚本实际运行的地方。

## 2.5 绑定层：语言的桥梁

Frida 提供了多种语言的绑定，让你可以用自己熟悉的语言来控制 Frida：

| 子项目 | 语言 | 用途 |
|--------|------|------|
| frida-python | Python | 最常用的绑定，pip install frida |
| frida-node | Node.js | 适合前端开发者和工具开发 |
| frida-swift | Swift | 适合 Apple 平台开发者 |
| frida-go | Go | 适合 Go 开发者 |
| frida-clr | C#/.NET | 适合 .NET 开发者 |
| frida-qml | Qt/QML | 适合 Qt 桌面应用开发 |

这些绑定本质上都是对 frida-core 提供的 C API 的封装。数据流是这样的：

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ 你的      │     │  语言    │     │  frida   │     │  frida   │
│ Python   │────>│  绑定    │────>│  -core   │────>│  -gum    │
│ 脚本      │     │ (ctypes) │     │  (Vala)  │     │   (C)    │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
                                                        │
                                                        v
                                                  ┌──────────┐
                                                  │ 目标进程  │
                                                  │ 中运行的  │
                                                  │ JS 脚本   │
                                                  └──────────┘
```

## 2.6 frida-tools：开箱即用的工具

frida-tools 是一组用 Python 编写的命令行工具，是大多数人接触 Frida 的第一个入口：

- **frida**：交互式 REPL 环境，可以直接输入 JS 代码
- **frida-ps**：列出设备上的进程
- **frida-ls-devices**：列出可用的设备
- **frida-trace**：函数追踪工具，自动生成拦截脚本
- **frida-discover**：发现程序中有趣的函数
- **frida-kill**：终止进程

## 2.7 构建系统

Frida 使用 **Meson** 作为构建系统。Meson 是一个现代化的构建系统，以速度快和易用性著称。

顶层 `meson.build` 文件扮演着"总调度"的角色。打开这个文件，你会发现它的结构非常清晰：

```python
# 项目定义，版本号从 releng/frida_version.py 动态获取
project('frida', 'c',
  version: run_command('releng' / 'frida_version.py').stdout().strip(),
)

# 第一步：构建 frida-gum（底层引擎）
subproject('frida-gum', default_options: gum_options)

# 第二步：构建 frida-core（核心框架）
subproject('frida-core', default_options: core_options)

# 第三步：按需构建各语言绑定
subproject('frida-python')   # 如果条件满足
subproject('frida-node')     # 如果条件满足
subproject('frida-tools')    # 如果条件满足
# ...
```

构建的顺序体现了依赖关系：先构建最底层的 gum，再构建依赖 gum 的 core，最后构建依赖 core 的各种绑定和工具。

`releng/` 目录包含了构建和发布相关的工具脚本，比如：
- `frida_version.py`：管理版本号
- `deps.toml`：声明第三方依赖
- `meson/`：Meson 构建的辅助模块
- `mkdevkit.py`：生成 devkit（开发包）

## 2.8 数据流全景图

当你运行一条简单的 Frida 命令时，数据在各个组件之间是这样流动的：

```
┌──────────────────────────────────────────────────────┐
│                     你的电脑                          │
│                                                      │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────┐ │
│  │ frida    │   │ frida-python │   │ frida-core   │ │
│  │ CLI 工具  │──>│ Python 绑定  │──>│ (本地或远程  │ │
│  │          │   │              │   │  连接管理)   │ │
│  └──────────┘   └──────────────┘   └──────┬───────┘ │
│                                           │ USB/TCP  │
└───────────────────────────────────────────┼──────────┘
                                            │
┌───────────────────────────────────────────┼──────────┐
│                   目标设备                  │          │
│                                           v          │
│  ┌──────────────┐   ┌─────────────────────────────┐ │
│  │ frida-server │   │       目标进程               │ │
│  │ (设备上的    │──>│  ┌──────────────────────┐   │ │
│  │  守护进程)   │   │  │ Agent (frida-agent)  │   │ │
│  └──────────────┘   │  │  ┌──────────┐       │   │ │
│                     │  │  │ frida-gum│       │   │ │
│                     │  │  │ +GumJS   │       │   │ │
│                     │  │  │ +你的 JS │       │   │ │
│                     │  │  └──────────┘       │   │ │
│                     │  └──────────────────────┘   │ │
│                     └─────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

这张图展示了从你输入命令到代码在目标进程中执行的完整路径。理解这个数据流，你就对 Frida 的整体架构有了七八成的把握。

## 2.9 该从哪里开始读

面对这么多代码，我的建议是遵循"自顶向下"和"自底向上"相结合的策略：

1. **先读 frida-gum 的头文件**（`.h` 文件），理解底层引擎提供了哪些能力
2. **再读 frida-core 的 Vala 文件**，理解框架层如何组织和调度
3. **然后读 gumjs 绑定**，理解 C 引擎是怎么暴露给 JavaScript 的
4. **最后读绑定层**，理解用户 API 是怎么映射到内部实现的

不要试图一次读完所有代码。每次带着一个具体问题去读，比如"Interceptor.attach 到底是怎么实现的？"，然后沿着调用链追踪下去，效果远比漫无目的地浏览好得多。

## 本章小结

- Frida 仓库采用 **子项目架构**，核心代码分布在 `subprojects/` 下的各个子项目中
- **frida-gum**（C 语言）是最底层的插桩引擎，提供 Interceptor、Stalker、Memory 等核心能力
- **frida-core**（Vala 语言）是框架层，负责进程注入、会话管理、设备通信
- **绑定层**（Python/Node.js/Swift 等）将 frida-core 的 C API 封装为各语言的友好接口
- **GumJS** 是连接 C 引擎和 JavaScript 脚本世界的桥梁，支持 V8 和 QuickJS 两种引擎
- 构建系统使用 **Meson**，构建顺序遵循依赖关系：gum -> core -> bindings/tools
- 阅读源码建议带着具体问题，沿着调用链追踪

## 思考与讨论

1. Frida 为什么要把 gum 和 core 分成两个独立的子项目，而不是合并成一个？这种分层设计有什么好处？
2. 为什么 frida-core 选择用 Vala 而不是纯 C 来编写？你觉得这个选择有什么利弊？
3. 看看 `host-session-service.vala` 中的平台后端注册逻辑，想想如果要添加一个新平台的支持，需要改动哪些地方？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
