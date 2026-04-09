# 第29章：架构之美——设计模式总结

> 当你读完一整本关于 Frida 源码的书，回过头来看，你会发现一个有趣的现象：那些让你觉得"设计得真巧妙"的地方，其实都遵循着一些经典的设计模式。这些模式并非刻意为之，而是工程师在解决真实问题时，自然而然地收敛到了最优解。

Frida 的代码库跨越了 C、Vala、JavaScript、Python 多种语言，支持 Windows、macOS、Linux、iOS、Android 等多个平台。要管理如此庞大的复杂度，仅靠个人英雄主义是不够的——你需要好的架构和设计模式。

## 29.1 分层架构模式

如果让我用一句话概括 Frida 的整体架构，那就是：**严格分层，逐层抽象**。

想象一栋大楼。地基是不可见的，但它承载着整栋建筑。每一层楼都只需要知道自己下面那层提供了什么，而不需要关心地基是怎么打的。Frida 的架构也是如此：

```
┌─────────────────────────────────────────────┐
│          用户脚本层 (JavaScript)              │
│   Interceptor.attach / Stalker.follow / ...  │
├─────────────────────────────────────────────┤
│          绑定层 (GumJS Bindings)             │
│   gumquickinterceptor.c / gumv8stalker.c    │
├─────────────────────────────────────────────┤
│          核心引擎层 (Gum)                     │
│   guminterceptor.c / gumstalker.c / ...     │
├─────────────────────────────────────────────┤
│          平台抽象层 (Backend)                 │
│   backend-arm64/ backend-x86/ backend-darwin/│
├─────────────────────────────────────────────┤
│          操作系统 / 硬件                      │
│   ptrace / mach_vm / /proc/maps / ...       │
└─────────────────────────────────────────────┘
```

这种分层的好处是什么？

- **关注点分离**：写 JavaScript 绑定的人不需要懂 ARM64 指令编码
- **可替换性**：V8 引擎可以替换为 QuickJS，只需改绑定层
- **可测试性**：每一层都可以独立测试

在 Frida 的源码中，你能清晰地看到这些层次对应的目录结构：

- `frida-gum/gum/` —— 核心引擎层
- `frida-gum/gum/backend-*` —— 平台抽象层
- `frida-gum/bindings/gumjs/` —— 绑定层
- `frida-core/src/` —— 服务与会话管理
- `frida-python/` / `frida-node/` —— 用户 API 层

## 29.2 后端/提供者模式（Backend/Provider）

Frida 需要在多种 CPU 架构和操作系统上运行。它是怎么做到的？答案是**后端模式**。

这就像一个万能充电器。你的手机需要充电，充电器提供一个统一的 USB 接口（抽象接口），但内部根据不同国家的电压标准（不同平台）使用不同的变压模块（不同后端）。

以 `GumStalker` 为例，它的头文件 `gumstalker.h` 定义了统一接口：

```c
// 统一接口——所有平台都用这组 API
GumStalker * gum_stalker_new (void);
void gum_stalker_follow_me (GumStalker * self,
    GumStalkerTransformer * transformer,
    GumEventSink * sink);
void gum_stalker_unfollow_me (GumStalker * self);
```

但具体实现分散在不同的后端目录中：

```
frida-gum/gum/
├── backend-arm64/gumstalker-arm64.c    // ARM64 实现
├── backend-arm/gumstalker-arm.c        // ARM32 实现
├── backend-x86/gumstalker-x86.c        // x86/x64 实现
└── gumstalker.h                        // 统一头文件
```

编译系统（Meson）根据目标平台选择编译哪个后端文件。这种模式在 `GumInterceptor`、`GumRelocator`、`GumWriter` 等组件中都能看到。

同样，`frida-core` 中的 `HostSession` 也采用了提供者模式：

```
frida-core/src/
├── darwin/darwin-host-session.vala     // macOS/iOS
├── linux/linux-host-session.vala       // Linux/Android
├── host-session-service.vala           // 统一接口
```

## 29.3 事务模式（Transaction Pattern）

`GumInterceptor` 的 `begin_transaction` / `end_transaction` 是一个教科书级别的事务模式实现。

想象你在银行转账。你不希望钱从 A 账户扣了，但还没到 B 账户的时候系统崩溃。银行用事务来保证：要么全部完成，要么全部回滚。

Frida 的 Interceptor 面临类似问题：当你同时 hook 多个函数时，你不希望 hook 到一半时目标进程恰好执行到了那段被修改了一半的代码。

```c
// 事务模式使用方式
gum_interceptor_begin_transaction (interceptor);

// 批量操作——此时修改还没有"生效"
gum_interceptor_attach (interceptor, target_a, listener, NULL);
gum_interceptor_attach (interceptor, target_b, listener, NULL);
gum_interceptor_attach (interceptor, target_c, listener, NULL);

// 提交——所有修改一次性生效
gum_interceptor_end_transaction (interceptor);
```

在 `end_transaction` 内部，Frida 会：
1. 暂停目标进程的所有其他线程
2. 一次性刷新所有待写入的 hook 代码
3. 刷新 CPU 指令缓存
4. 恢复所有线程

这样就保证了原子性——外部观察者要么看到 hook 前的状态，要么看到 hook 后的状态，不会看到中间状态。

## 29.4 观察者模式（Observer Pattern）

观察者模式在 Frida 中无处不在。核心思想是：**当某件事发生时，通知所有关心这件事的人**。

最典型的例子是 `GumEventSink`。当 Stalker 追踪代码执行时，它会产生大量事件（执行了哪条指令、调用了哪个函数、跳转到了哪里）。这些事件通过 `GumEventSink` 接口传递给订阅者：

```c
// GumEventSink 接口定义
struct _GumEventSinkInterface {
  GTypeInterface parent;

  GumEventType (* query_mask) (GumEventSink * self);
  void (* start)   (GumEventSink * self);
  void (* process)  (GumEventSink * self,
                     const GumEvent * event,
                     GumCpuContext * cpu_context);
  void (* flush)   (GumEventSink * self);
  void (* stop)    (GumEventSink * self);
};
```

`query_mask` 方法让观察者声明自己关心哪些类型的事件，这样 Stalker 就不会产生没人需要的事件，避免了性能浪费。

在 `frida-core` 层面，`SessionService` 的信号机制也是观察者模式：

```
┌──────────────┐     信号: "detached"     ┌──────────────┐
│              │ ──────────────────────>  │              │
│   Session    │     信号: "message"      │   Listener   │
│              │ ──────────────────────>  │              │
└──────────────┘                          └──────────────┘
```

GObject 的信号系统天然支持这种模式，Frida 大量使用 `g_signal_connect` 和 `g_signal_emit` 来实现组件间的松耦合通信。

## 29.5 工厂模式（Factory Pattern）

Frida 中的 Session 创建就是工厂模式的典型应用。你不需要自己 `new` 一个 Session 对象，而是通过 Device 来"生产"它：

```python
# Python 端——用户看到的简洁 API
device = frida.get_usb_device()
session = device.attach(pid)       # Device 是 Session 的工厂
script = session.create_script(src) # Session 是 Script 的工厂
```

在内部，`device.attach()` 触发了一连串的创建过程：

```
Device.attach(pid)
  └─> HostSession.attach_to(pid)
        └─> AgentSession 创建
              └─> Agent 注入到目标进程
                    └─> ScriptBackend 初始化
```

每一层都是下一层的工厂。这种设计隐藏了复杂的创建逻辑，用户只需要一行 `device.attach(pid)` 就完成了注入、通信建立、脚本引擎初始化等一系列操作。

`GumScriptBackend` 也是工厂模式的体现——它根据配置创建不同类型的 Script 对象（V8 或 QuickJS）：

```c
// 根据运行时选择创建不同的脚本后端
GumScriptBackend * backend;
backend = gum_script_backend_obtain_qjs ();  // 或 obtain_v8()
```

## 29.6 桥接模式（Bridge Pattern）

GumJS 层是整个 Frida 中最精彩的桥接模式实现。它在 C 语言的高性能世界和 JavaScript 的高表达力世界之间架起了一座桥。

```
┌─────────────────────┐          ┌─────────────────────┐
│   JavaScript 世界    │          │      C 世界          │
│                     │          │                     │
│ Interceptor.attach  │ ──桥──>  │ gum_interceptor_    │
│                     │          │   attach             │
│ ptr("0x1234")       │ ──桥──>  │ GumAddress           │
│                     │          │                     │
│ callback(args)      │ <──桥──  │ GumInvocationContext │
└─────────────────────┘          └─────────────────────┘
```

桥接的核心挑战在于**类型转换**和**生命周期管理**：

- JavaScript 的 `NativePointer` 需要桥接为 C 的 `gpointer`
- C 的回调需要安全地调用 JavaScript 函数
- JavaScript 的垃圾回收器不能回收还在被 C 引用的对象

为了支持两个不同的 JS 引擎，Frida 对每个需要暴露给 JS 的模块都实现了两套绑定：

```
bindings/gumjs/
├── gumquickinterceptor.c     // QuickJS 版桥接
├── gumv8interceptor.cpp      // V8 版桥接
├── gumquickstalker.c         // QuickJS 版桥接
├── gumv8stalker.cpp          // V8 版桥接
└── ...
```

这正是桥接模式的精髓：**抽象和实现可以独立变化**。无论底层用 QuickJS 还是 V8，上层的 `Interceptor.attach()` API 都是一样的。

## 29.7 代理模式（Proxy Pattern）

Frida 的 RPC 机制是代理模式的完美体现。当你在 Python 中调用 `script.exports.my_function()` 时，你调用的并不是真正的函数——你调用的是一个代理，它把调用序列化为 JSON 消息，通过管道发送到目标进程，在那里反序列化并执行真正的函数，然后把结果原路返回。

```
┌─────────┐    JSON/RPC    ┌─────────┐    实际调用    ┌─────────┐
│  Python  │ ────────────> │  Frida  │ ────────────> │ 目标进程 │
│  代理    │ <──────────── │  管道   │ <──────────── │ 真实函数 │
└─────────┘    返回结果     └─────────┘    执行结果    └─────────┘
```

对调用者来说，代理对象和本地对象没有区别——这就是代理模式的力量。

## 29.8 模式总结表

```
┌────────────┬─────────────────────┬──────────────────────┐
│  设计模式   │   Frida 中的应用     │     关键文件          │
├────────────┼─────────────────────┼──────────────────────┤
│ 分层架构    │ Gum/GumJS/Core/     │ 整体目录结构          │
│            │ Python 四层          │                      │
├────────────┼─────────────────────┼──────────────────────┤
│ 后端/提供者 │ Stalker/Interceptor │ backend-*/           │
│            │ 多架构支持           │ *-host-session.vala  │
├────────────┼─────────────────────┼──────────────────────┤
│ 事务       │ Interceptor 的      │ guminterceptor.c     │
│            │ begin/end           │                      │
├────────────┼─────────────────────┼──────────────────────┤
│ 观察者     │ EventSink/GObject   │ gumstalker.h         │
│            │ 信号                │ GObject signal       │
├────────────┼─────────────────────┼──────────────────────┤
│ 工厂       │ Device->Session->   │ frida.vala           │
│            │ Script 创建链       │ host-session-*.vala  │
├────────────┼─────────────────────┼──────────────────────┤
│ 桥接       │ GumJS 双引擎绑定    │ gumquick*.c          │
│            │                     │ gumv8*.cpp           │
├────────────┼─────────────────────┼──────────────────────┤
│ 代理       │ RPC exports 机制    │ script.py / rpc.js   │
└────────────┴─────────────────────┴──────────────────────┘
```

## 29.9 为什么这些模式重要

你可能会想："我知道这些模式有什么用？我又不写 Frida。"

但事实是，这些模式解决的是**通用问题**：

- 你的项目需要支持多个平台？学习后端模式
- 你的操作需要原子性？学习事务模式
- 你需要在不同语言间传递数据？学习桥接模式
- 你需要解耦组件之间的通信？学习观察者模式

Frida 源码是一本活生生的设计模式教科书，而且每个模式都经过了真实项目的验证。

## 本章小结

- Frida 采用**严格分层架构**，从硬件到用户脚本共五层
- **后端模式**让 Frida 能用统一接口支持多种 CPU 架构和操作系统
- **事务模式**保证了多个 hook 的原子性提交
- **观察者模式**通过 EventSink 和 GObject 信号实现了松耦合通信
- **工厂模式**隐藏了 Session 和 Script 的复杂创建逻辑
- **桥接模式**让 JavaScript 和 C 两个世界无缝协作
- **代理模式**让跨进程调用像本地调用一样简单
- 这些模式不是学术概念，而是解决真实工程问题的经验结晶

## 讨论问题

1. 如果你要为 Frida 添加一个新的 CPU 架构支持（比如 RISC-V），后端模式需要你修改哪些文件？你能从现有的 ARM64 后端中借鉴什么？

2. 事务模式中"暂停所有线程再刷新代码"的做法有什么潜在问题？在高并发场景下你会如何优化？

3. 假设你要设计一个类似 Frida 的工具，但目标是在浏览器中运行（比如 WebAssembly 插桩）。你会保留哪些设计模式，又会放弃哪些？为什么？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
