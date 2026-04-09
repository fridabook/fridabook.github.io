# 附录 B：源码关键文件索引

> 本附录列出了 Frida 源码中最重要的文件，按子项目和功能模块分类。路径相对于 Frida 主仓库根目录。"相关章节"列指出了本书中详细分析该文件的章节。

---

## frida-gum：核心引擎

| 文件路径 | 功能描述 | 相关章节 |
|---------|---------|---------|
| `frida-gum/gum/gum.c` | Gum 引擎初始化与全局状态管理 | 第3章 |
| `frida-gum/gum/gum.h` | Gum 公共头文件，定义核心类型 | 第3章 |
| `frida-gum/gum/guminterceptor.c` | Interceptor 核心实现——函数 hook 引擎 | 第7-8章 |
| `frida-gum/gum/guminterceptor.h` | Interceptor 公共 API 定义 | 第7章 |
| `frida-gum/gum/guminterceptor-priv.h` | Interceptor 内部数据结构 | 第8章 |
| `frida-gum/gum/gumstalker.c` | Stalker 公共接口与调度逻辑 | 第11章 |
| `frida-gum/gum/gumstalker.h` | Stalker 公共 API 定义 | 第11章 |
| `frida-gum/gum/gumstalker-priv.h` | Stalker 内部数据结构定义 | 第12章 |
| `frida-gum/gum/gummemory.c` | 内存操作：分配、读写、搜索、保护属性修改 | 第15章 |
| `frida-gum/gum/gumprocess.c` | 进程信息查询：模块列表、线程列表、内存范围 | 第16章 |
| `frida-gum/gum/gummodule.c` | 模块（已加载的动态库）信息查询 | 第16章 |
| `frida-gum/gum/gumapiresolver.c` | API 符号解析器 | 第16章 |
| `frida-gum/gum/gumbacktracer.c` | 调用栈回溯接口 | 第17章 |
| `frida-gum/gum/gumcloak.c` | Cloak 机制——隐藏 Frida 自身的内存和线程 | 第22章 |
| `frida-gum/gum/guminvocationlistener.c` | 函数调用监听器接口 | 第7章 |
| `frida-gum/gum/gumcodeallocator.c` | 代码内存分配器——管理可执行内存 | 第9章 |
| `frida-gum/gum/gumcodesegment.c` | 代码段管理（与代码签名相关） | 第22章 |

## frida-gum：架构后端

| 文件路径 | 功能描述 | 相关章节 |
|---------|---------|---------|
| `frida-gum/gum/backend-arm64/gumstalker-arm64.c` | Stalker ARM64 实现——代码翻译核心 | 第12-13章 |
| `frida-gum/gum/backend-x86/gumstalker-x86.c` | Stalker x86/x64 实现 | 第12章 |
| `frida-gum/gum/backend-arm64/guminterceptor-arm64.c` | Interceptor ARM64 后端——trampoline 生成 | 第9章 |
| `frida-gum/gum/backend-x86/guminterceptor-x86.c` | Interceptor x86/x64 后端 | 第9章 |
| `frida-gum/gum/arch-arm64/gumarm64writer.c` | ARM64 指令生成器（代码写入器） | 第10章 |
| `frida-gum/gum/arch-arm64/gumarm64relocator.c` | ARM64 指令重定位器 | 第10章 |
| `frida-gum/gum/arch-x86/gumx86writer.c` | x86/x64 指令生成器 | 第10章 |
| `frida-gum/gum/arch-x86/gumx86relocator.c` | x86/x64 指令重定位器 | 第10章 |
| `frida-gum/gum/arch-arm/gumarmwriter.c` | ARM32 指令生成器 | 第10章 |
| `frida-gum/gum/arch-arm/gumarmrelocator.c` | ARM32 指令重定位器 | 第10章 |
| `frida-gum/gum/arch-arm/gumthumbwriter.c` | Thumb 指令生成器 | 第10章 |
| `frida-gum/gum/arch-arm/gumthumbrelocator.c` | Thumb 指令重定位器 | 第10章 |
| `frida-gum/gum/backend-darwin/gumprocess-darwin.c` | Darwin 平台进程操作实现 | 第16章 |
| `frida-gum/gum/backend-linux/gumprocess-linux.c` | Linux 平台进程操作实现 | 第16章 |

## frida-gum：GumJS 绑定层

| 文件路径 | 功能描述 | 相关章节 |
|---------|---------|---------|
| `frida-gum/bindings/gumjs/gumscript.c` | Script 生命周期管理 | 第18章 |
| `frida-gum/bindings/gumjs/gumscriptbackend.c` | 脚本后端接口（V8 / QuickJS 选择） | 第18章 |
| `frida-gum/bindings/gumjs/gumquickinterceptor.c` | Interceptor 的 QuickJS 绑定 | 第19章 |
| `frida-gum/bindings/gumjs/gumquickstalker.c` | Stalker 的 QuickJS 绑定 | 第19章 |
| `frida-gum/bindings/gumjs/gumquickcore.c` | 核心类型（NativePointer 等）的 QuickJS 绑定 | 第19章 |
| `frida-gum/bindings/gumjs/gumquickmodule.c` | Module API 的 QuickJS 绑定 | 第19章 |
| `frida-gum/bindings/gumjs/gumquickmemory.c` | Memory API 的 QuickJS 绑定 | 第19章 |
| `frida-gum/bindings/gumjs/gumcmodule.c` | CModule——在 JS 中编写并编译 C 代码 | 第20章 |
| `frida-gum/bindings/gumjs/gumffi.c` | FFI（外部函数接口）绑定 | 第19章 |
| `frida-gum/bindings/gumjs/gumscriptscheduler.c` | 脚本线程调度器 | 第18章 |

## frida-core：服务与会话管理

| 文件路径 | 功能描述 | 相关章节 |
|---------|---------|---------|
| `frida-core/src/frida.vala` | Frida 入口——DeviceManager、Device 等核心类 | 第4章 |
| `frida-core/src/host-session-service.vala` | HostSession 服务——管理进程附加与注入 | 第5章 |
| `frida-core/src/control-service.vala` | 控制服务——frida-server 的 D-Bus 服务端 | 第5章 |
| `frida-core/src/portal-service.vala` | Portal 服务——集群模式支持 | 第5章 |
| `frida-core/src/agent-container.vala` | Agent 容器——管理注入到目标进程的 Agent | 第6章 |
| `frida-core/src/darwin/darwin-host-session.vala` | macOS/iOS 平台的 HostSession 实现 | 第21章 |
| `frida-core/src/darwin/fruitjector.vala` | Darwin 平台代码注入器 | 第21章 |
| `frida-core/src/linux/linux-host-session.vala` | Linux/Android 平台的 HostSession 实现 | 第21章 |
| `frida-core/src/linux/linjector.vala` | Linux 平台代码注入器 | 第21章 |
| `frida-core/src/linux/linjector-glue.c` | Linux 注入器的 C 层胶水代码（ptrace 操作） | 第21章 |
| `frida-core/src/system.vala` | 系统信息查询 | 第4章 |
| `frida-core/src/async-task.vala` | 异步任务基础设施 | 第5章 |
| `frida-core/src/file-monitor.vala` | 文件系统监控 | 第16章 |
| `frida-core/src/compiler/compiler.vala` | TypeScript 编译器集成 | 第20章 |

## frida-python 与 frida-tools

| 文件路径 | 功能描述 | 相关章节 |
|---------|---------|---------|
| `frida-python/frida/__init__.py` | Python 绑定入口——定义顶层 API | 第2章 |
| `frida-python/frida/core.py` | Python 端核心类：Device、Session、Script 等 | 第2章 |
| `frida-tools/frida_tools/application.py` | CLI 工具基础框架 | 第2章 |
| `frida-tools/frida_tools/itracer.py` | frida-trace 工具实现 | 第2章 |
| `frida-tools/frida_tools/discoverer.py` | frida-discover 工具实现 | 第2章 |
| `frida-tools/frida_tools/reactor.py` | 事件循环与脚本重载机制 | 第2章 |
| `frida-tools/frida_tools/creator.py` | frida-create 项目模板生成器 | 第2章 |

## 构建系统与配置

| 文件路径 | 功能描述 | 相关章节 |
|---------|---------|---------|
| `meson.build` | 主仓库构建入口 | 第3章 |
| `frida-gum/meson.build` | Gum 构建配置 | 第3章 |
| `frida-core/meson.build` | Core 构建配置 | 第3章 |
| `releng/` | 发布工程脚本——依赖管理、交叉编译配置 | 第3章 |

---

> 提示：以上文件路径基于 Frida 主仓库的 `subprojects/` 目录结构。在实际源码中，完整路径为 `frida/subprojects/frida-gum/gum/...` 等。

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
