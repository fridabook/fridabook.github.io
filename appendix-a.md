# 附录 A：术语表

> 本术语表按英文字母顺序排列，收录了本书中出现的核心技术术语。每个术语提供中文解释和英文原名，方便读者在阅读英文资料时对照使用。

---

**ABI（Application Binary Interface，应用二进制接口）**
定义了函数调用时参数如何传递、返回值如何返回、寄存器如何分配等底层约定。不同平台（如 ARM64 的 AAPCS、x86-64 的 System V ABI）有不同的 ABI 规范。Frida 的 Interceptor 在 hook 函数时必须严格遵守目标平台的 ABI。

**Agent（代理）**
在 Frida 中，Agent 是被注入到目标进程中的动态链接库（.so / .dylib / .dll）。它包含了 JavaScript 运行时和 Gum 引擎，是用户脚本实际执行的载体。对应源码中 `frida-core/src/agent-container.vala`。

**ARM / ARM64（ARM 架构）**
移动设备主流的 CPU 架构。ARM 指 32 位版本（ARMv7），ARM64 指 64 位版本（AArch64/ARMv8）。Frida 的 Gum 引擎对两种架构都有完整支持。

**Backpatching（回补丁）**
Stalker 引擎中的一种优化技术。当代码块第一次被翻译时，某些跳转目标可能尚未确定。Backpatching 是在目标确定后回过头来修补之前的跳转指令，避免重复查找。

**Binary（二进制文件）**
编译后的可执行程序或库文件。不同平台有不同的二进制格式：Linux 用 ELF，macOS/iOS 用 Mach-O，Windows 用 PE。

**Bootstrapper（引导器）**
注入过程中用于初始化 Agent 的一小段代码。它负责加载动态库、解析符号、调用入口函数等基本引导工作。

**Code Signing（代码签名）**
iOS 和 macOS 上的安全机制，要求所有执行的代码都必须经过数字签名验证。Frida 需要处理代码签名问题才能在这些平台上注入代码和修改内存中的指令。

**CModule**
Frida 提供的一种机制，允许用户直接在脚本中编写 C 代码，由 TinyCC 编译后在目标进程中执行。适合性能敏感的场景。

**D-Bus（Desktop Bus）**
一种进程间通信协议。Frida 内部使用了基于 D-Bus 协议的通信机制来实现 frida-server 与客户端之间的消息传递。

**DBI（Dynamic Binary Instrumentation，动态二进制插桩）**
在程序运行时修改其二进制代码以插入分析逻辑的技术。Frida 是 DBI 工具的代表之一。

**Detour / Trampoline（跳板）**
Hook 技术的核心。在目标函数开头写入一条跳转指令（detour），跳转到一块预先分配的代码区域（trampoline），在那里执行用户的回调逻辑，然后再跳回原函数。

**DWARF**
一种调试信息格式，存储在可执行文件中，包含变量名、类型、行号等信息。Frida 的 Gum 引擎可以利用 DWARF 信息进行符号解析。

**ELF（Executable and Linkable Format）**
Linux 和 Android 上的标准可执行文件格式。Frida 的 `backend-elf` 目录包含了解析 ELF 文件的代码。

**Entrypoint（入口点）**
程序或动态库开始执行的地址。Frida 在注入 Agent 时需要找到并调用其入口点。

**ExecMemory（可执行内存）**
具有执行权限的内存区域。Frida 动态生成的代码（如 trampoline、Stalker 翻译后的代码块）都需要写入可执行内存。

**Frida**
本书的主角。一个跨平台的动态插桩框架，支持 Windows、macOS、Linux、iOS、Android 等。项目主页：frida.re。

**Gadget**
Frida 提供的一个特殊的共享库，可以嵌入到目标应用中（而不是远程注入）。适用于无法使用 frida-server 的场景，例如未越狱的 iOS 设备上的重打包应用。

**GLib / GObject**
GNOME 项目的基础库。GLib 提供了数据结构、事件循环、线程等基础设施。GObject 提供了 C 语言的面向对象系统（类、继承、接口、信号）。Frida 的 C 代码大量使用了 GLib/GObject。

**Gum**
Frida 的核心引擎库（`frida-gum`）。提供了 Interceptor、Stalker、Memory、Module 等底层能力。名字没有特殊含义，就是一个简短的项目名。

**GumJS**
Gum 的 JavaScript 绑定层（`frida-gum/bindings/gumjs/`）。负责将 Gum 的 C API 暴露给 JavaScript 世界，支持 V8 和 QuickJS 两种引擎。

**Hook（钩子）**
拦截函数调用的技术。通过修改目标函数的代码，在函数执行前后插入自定义逻辑。Frida 的 `Interceptor.attach()` 就是 hook 操作。

**Inject / Injection（注入）**
将代码加载到另一个进程的地址空间中的操作。Frida 在不同平台使用不同的注入方式：Linux 用 ptrace，macOS 用 mach_vm + task_for_pid，Android 可能用 /proc/pid/mem 等。

**Interceptor（拦截器）**
Frida 最常用的功能组件。通过 inline hook 技术拦截函数调用，允许用户在函数执行前（onEnter）和执行后（onLeave）运行自定义代码。源码在 `guminterceptor.c`。

**JIT（Just-In-Time Compilation，即时编译）**
在程序运行时将代码编译为机器码的技术。V8 引擎使用 JIT 编译 JavaScript。Stalker 也使用类似 JIT 的技术动态翻译和插桩代码块。

**Mach-O（Mach Object）**
macOS 和 iOS 上的可执行文件格式。Frida 需要解析 Mach-O 格式来查找函数、段、符号等信息。

**Meson**
Frida 使用的构建系统。比 CMake 更现代、更简洁，配置文件使用声明式语法。对应每个子项目中的 `meson.build` 文件。

**Module（模块）**
一个已加载的可执行文件或动态链接库。在 Frida 中，`Module.findExportByName()` 用于在已加载的模块中查找导出符号。

**N-API（Node-API）**
Node.js 的稳定 C/C++ 插件接口。`frida-node` 使用 N-API 将 Frida 的 C 核心包装为 Node.js 模块。

**NativePointer（原生指针）**
Frida JavaScript API 中表示内存地址的对象。支持算术运算、读写操作等。底层对应 C 中的 `gpointer`。

**PE（Portable Executable）**
Windows 上的可执行文件格式（.exe / .dll）。

**Process（进程）**
操作系统中程序运行的实例。Frida 的 `Process` API 提供了查询进程信息（模块列表、线程列表、内存范围等）的能力。

**ptrace**
Linux 上的进程追踪系统调用。Frida 在 Linux/Android 上使用 ptrace 来附加到目标进程并注入代码。

**QuickJS**
Fabrice Bellard 开发的轻量级 JavaScript 引擎。Frida 将其作为 V8 的替代选项，适合资源受限的环境。

**Relocator（重定位器）**
Frida 中负责"搬迁"指令的组件。当 Interceptor hook 一个函数时，被覆盖的原始指令需要被复制到 trampoline 中。但某些指令（如 PC 相对跳转）不能简单复制，需要 Relocator 进行调整。

**RPC（Remote Procedure Call，远程过程调用）**
Frida 提供的机制，允许 Python/Node.js 端直接调用目标进程中 JavaScript 脚本暴露的函数。通过 `script.exports` 和 `rpc.exports` 实现。

**Script（脚本）**
在 Frida 中，Script 是用户编写的 JavaScript 代码的运行时容器。一个 Script 对应一个 JS 引擎实例和一组绑定。

**Session（会话）**
Frida 客户端与目标进程之间的连接。通过 `device.attach(pid)` 创建。一个 Session 可以创建多个 Script。

**Slab（内存块）**
Stalker 引擎中用于分配翻译后代码的内存区域。预先分配大块内存，然后从中按需划分小块，避免频繁的系统调用。

**Stalker（追踪器）**
Frida 的动态代码追踪引擎。能够追踪目标线程执行的每一条指令、每一次函数调用和每一次跳转。通过动态代码翻译（类似 JIT）实现。源码在 `gumstalker.c` 和 `backend-*/gumstalker-*.c`。

**Symbol（符号）**
函数名或变量名在二进制文件中的表示。调试信息、导出表、符号表中都包含符号。Frida 的 `DebugSymbol` API 用于解析地址到符号名。

**Task Port（任务端口）**
macOS/iOS 上的 Mach IPC 概念。`task_for_pid()` 获取目标进程的任务端口后，就可以读写其内存、创建线程等。Frida 在 Darwin 平台的注入依赖此机制。

**Thumb（Thumb 指令集）**
ARM 架构的一种压缩指令编码模式。Thumb 指令为 16 位宽（而标准 ARM 指令为 32 位），Thumb-2 混合了 16 位和 32 位指令。Frida 的 ARM 后端需要正确处理 ARM/Thumb 模式切换。

**Trampoline（跳板）**
见 "Detour" 条目。Trampoline 是 hook 过程中创建的代码片段，用于跳转到用户回调，然后跳回原始函数继续执行。

**V8**
Google 开发的高性能 JavaScript 引擎（Chrome 中使用的引擎）。Frida 默认使用 V8 作为 GumJS 的脚本后端。

**Vala**
一种编译为 C 代码的编程语言，语法类似 C#。Frida-core 大量使用 Vala 编写，它提供了 GObject 之上的现代语法糖，包括异步编程、类型推断等。

**Writer（代码写入器）**
Frida 中用于动态生成机器码的组件。例如 `GumArm64Writer` 提供了一组 API 来生成 ARM64 指令，而不需要手动编码二进制。

**XPC（XPC Services）**
macOS/iOS 上的进程间通信机制。Frida 在 Darwin 平台使用 XPC 与系统服务交互，也通过 XPC 与 helper 进程通信。对应 `frida-core/src/darwin/` 中的相关代码。

---

## 补充术语

以下术语在阅读源码时也会经常遇到：

**Allocation（内存分配）**
在 Frida 中，内存分配不仅指普通的堆内存分配，还包括可执行内存的分配。`gumcodeallocator.c` 专门处理可执行代码内存的分配和管理。

**Attach（附加）**
将 Frida 连接到目标进程的操作。附加后才能注入 Agent 和运行脚本。在 `frida-core` 层对应 `HostSession.attach_to()` 方法。

**Capstone**
一个开源的反汇编引擎，支持多种 CPU 架构。Frida 在某些场景下使用 Capstone 来反汇编目标代码，辅助分析指令结构。

**Context（上下文）**
在 Frida 中，Context 通常指 CPU 上下文（`GumCpuContext`），包含了所有寄存器的值。在 `onEnter` 回调中可以通过 `this.context` 访问和修改寄存器。

**DeviceManager（设备管理器）**
Frida 客户端的入口类，负责发现和管理可用的设备（本地设备、USB 设备、远程设备）。

**Dispose / Finalize（销毁/终结）**
GObject 对象的两个析构阶段。Dispose 释放对其他对象的引用（可被多次调用），Finalize 释放自身资源（只调用一次）。理解这两个阶段对于阅读 Frida 的 GObject 代码很重要。

**Enumerate（枚举）**
遍历某类资源的操作。如 `Process.enumerateModules()` 枚举已加载模块，`Module.enumerateExports()` 枚举导出符号。Frida 中大量使用回调式枚举模式。

**FFI（Foreign Function Interface，外部函数接口）**
一种允许某种语言调用另一种语言编写的函数的机制。Frida 的 `NativeFunction` 和 `NativeCallback` 底层使用 libffi 来实现跨语言函数调用。

**Fruitjector**
Frida 在 macOS/iOS 平台上的代码注入器。名字来源于 Darwin（达尔文）-> Fruit（水果）的联想。对应 `frida-core/src/darwin/fruitjector.vala`。

**GMainLoop / GMainContext（GLib 主循环）**
GLib 提供的事件循环机制。Frida 的异步操作（如等待消息、处理信号）都基于 GMainLoop。理解 GLib 事件循环对于理解 Frida 的异步架构至关重要。

**GumInvocationContext（调用上下文）**
Interceptor hook 函数时，传递给回调的上下文对象。包含了函数参数、CPU 上下文、线程 ID 等信息。

**GumInvocationListener（调用监听器）**
Interceptor 的回调接口。实现 `on_enter` 和 `on_leave` 方法来处理函数调用事件。

**Helper（辅助进程）**
Frida 在某些平台上使用特权辅助进程来执行需要高权限的操作（如在 macOS 上使用 task_for_pid）。对应 `frida-core/src/darwin/frida-helper-*.vala` 等文件。

**Inline Hook（内联钩子）**
直接修改目标函数开头的指令来实现 hook 的技术。与 GOT/PLT hook 不同，inline hook 可以 hook 任意地址的函数，不限于导入函数。Frida 的 Interceptor 使用的就是 inline hook。

**Keystone**
一个开源的汇编引擎（Capstone 的姊妹项目），可以将汇编代码转换为机器码。Frida 的 Writer 组件承担了类似 Keystone 的功能。

**Linjector**
Frida 在 Linux/Android 平台上的代码注入器。Lin 来自 Linux。对应 `frida-core/src/linux/linjector.vala`。

**NativeFunction / NativeCallback**
JavaScript 端用于调用原生函数和创建原生回调的 API。`NativeFunction` 将一个地址包装为可调用的 JS 函数，`NativeCallback` 将一个 JS 函数包装为可被原生代码调用的函数指针。

**Ninja**
一个小型高速构建系统，由 Meson 生成构建文件后由 Ninja 执行实际编译。在 Frida 开发中，增量编译时直接运行 `ninja` 比运行完整的 `make` 更快。

**Spawn（启动）**
由 Frida 启动目标进程的操作（与 attach 附加已有进程相对）。spawn 模式下，Frida 可以在程序 main 函数执行之前就完成 hook 设置。

**Transformer（变换器）**
Stalker 的代码变换接口。用户可以通过 Transformer 自定义代码翻译逻辑，例如在特定指令前后插入回调。

**TypeScript**
JavaScript 的超集语言，添加了静态类型。Frida 支持直接运行 TypeScript 脚本（通过内置的编译器），并提供了完整的类型定义文件 `@types/frida-gum`。

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
