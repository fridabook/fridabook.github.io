# 第5章：Gum：插桩引擎的心脏

> 如果 Frida 是一辆赛车，那 Gum 就是它的发动机。你可以换轮胎（换前端工具），可以改车身（换通信协议），但发动机不能换——因为真正让代码在目标进程里"跑起来"、让函数调用被拦截、让执行流被追踪的，全靠 Gum。今天我们打开引擎盖，看看里面到底有什么。

## 5.1 Gum 是什么？

Gum 是 Frida 的底层插桩引擎，项目名称叫 `frida-gum`。它是一个纯 C 语言库，提供了在运行时修改、监控、追踪程序执行的所有基础能力。

打个比方：如果你想在一条高速公路上设置检查站（拦截函数调用）、安装摄像头（追踪代码执行路径）、或者修改路标（替换函数实现），Gum 就是那个负责施工的工程队。它知道每种路面（CPU 架构）该怎么施工，知道每种交通规则（操作系统）该怎么遵守。

从 `gum.h` 头文件可以清楚地看到 Gum 的全貌：

```c
// gum.h - Gum 的公开头文件，包含了所有子系统
#include <gum/guminterceptor.h>    // 函数拦截
#include <gum/gumstalker.h>        // 代码追踪
#include <gum/gummemory.h>         // 内存操作
#include <gum/gummodule.h>         // 模块管理
#include <gum/gumprocess.h>        // 进程信息
#include <gum/gumbacktracer.h>     // 调用栈回溯
#include <gum/gumexceptor.h>       // 异常处理
#include <gum/gumcloak.h>          // 隐藏自身
// ... 还有更多
```

## 5.2 Gum 的架构全景

Gum 的架构可以分为四个层次：

```
┌─────────────────────────────────────────────────────────┐
│                    GumJS (JavaScript 绑定)                │
│              将 C API 暴露为 JS 可调用的接口               │
├─────────────────────────────────────────────────────────┤
│                    Gum 核心子系统                          │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐            │
│  │ Interceptor│ │  Stalker   │ │  Memory    │            │
│  │  函数拦截  │ │  代码追踪  │ │  内存操作  │            │
│  └────────────┘ └────────────┘ └────────────┘            │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐            │
│  │  Module    │ │  Process   │ │ ApiResolver│            │
│  │  模块管理  │ │  进程信息  │ │  符号查找  │            │
│  └────────────┘ └────────────┘ └────────────┘            │
├─────────────────────────────────────────────────────────┤
│                    平台抽象层                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐    │
│  │ Windows  │ │  Darwin  │ │  Linux   │ │  QNX     │    │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘    │
├─────────────────────────────────────────────────────────┤
│                  架构特定代码生成                          │
│  ┌──────┐  ┌──────┐  ┌────────┐  ┌──────┐  ┌──────┐    │
│  │ x86  │  │ x64  │  │ ARM32  │  │ARM64 │  │ MIPS │    │
│  └──────┘  └──────┘  └────────┘  └──────┘  └──────┘    │
└─────────────────────────────────────────────────────────┘
```

最底层是架构特定的代码生成器，每种 CPU 架构都有自己的 Writer（代码写入器），比如 `GumX86Writer`、`GumArm64Writer`。往上是平台抽象层，处理不同操作系统的内存管理、进程管理差异。再往上是核心子系统，提供高层的插桩能力。最顶层是 GumJS，把这些 C API 包装成 JavaScript 接口。

## 5.3 Interceptor：函数拦截器

Interceptor 是 Gum 中使用频率最高的组件。当你在 Frida 脚本里写 `Interceptor.attach(addr, {...})` 时，底层就是它在工作。

### 核心 API

从 `guminterceptor.h` 可以看到三组核心操作：

```c
// 1. 附加监听器——在函数入口/出口插入回调
GumAttachReturn gum_interceptor_attach (
    GumInterceptor * self,
    gpointer function_address,       // 目标函数地址
    GumInvocationListener * listener, // 监听器
    gpointer listener_function_data,  // 用户数据
    GumAttachFlags flags
);

// 2. 替换函数——用你的实现替换原函数
GumReplaceReturn gum_interceptor_replace (
    GumInterceptor * self,
    gpointer function_address,       // 原函数地址
    gpointer replacement_function,   // 替换函数
    gpointer replacement_data,
    gpointer * original_function     // 返回原函数指针
);

// 3. 事务机制——批量修改，减少性能开销
void gum_interceptor_begin_transaction (GumInterceptor * self);
void gum_interceptor_end_transaction (GumInterceptor * self);
```

### 工作原理（简化版）

Interceptor 的原理就像在书页上贴便签纸：

```
原始函数:                   拦截后:
┌──────────────┐           ┌──────────────┐
│ push rbp     │           │ jmp trampoline│ <-- 开头被改写
│ mov rbp, rsp │           │ ...被覆盖... │
│ sub rsp, 0x20│           │ sub rsp, 0x20│
│ ...          │           │ ...          │
│ ret          │           │ ret          │
└──────────────┘           └──────────────┘
                                  │
                                  v
                           ┌──────────────┐
                           │  trampoline  │
                           │  调用 onEnter │
                           │  执行原始指令 │
                           │  跳回原函数   │
                           │  ...         │
                           │  调用 onLeave │
                           └──────────────┘
```

函数开头的几条指令被替换为一个跳转，跳到 Frida 生成的 trampoline 代码。trampoline 负责调用你的回调函数（onEnter），然后执行被覆盖的原始指令，再跳回原函数继续执行。函数返回时，类似的机制触发 onLeave 回调。

### 事务机制

注意 `begin_transaction` 和 `end_transaction` 这对 API。当你需要同时拦截多个函数时，把它们放在一个事务里可以避免每次修改都刷新 CPU 指令缓存。这就像搬家时，你不会每搬一个箱子就锁一次门，而是等所有箱子都搬完再锁。

## 5.4 Stalker：代码追踪器

如果说 Interceptor 是在路口设检查站，那 Stalker 就是派了一个侦探全程跟踪目标。它能追踪每一条被执行的指令。

### 核心概念

Stalker 使用**动态重编译**技术：它不是直接执行原始代码，而是把原始代码复制一份，在副本中插入追踪逻辑，然后执行副本。

```c
// 跟踪当前线程
void gum_stalker_follow_me (
    GumStalker * self,
    GumStalkerTransformer * transformer,  // 可选的代码变换器
    GumEventSink * sink                   // 事件接收器
);

// 跟踪其他线程
void gum_stalker_follow (
    GumStalker * self,
    GumThreadId thread_id,
    GumStalkerTransformer * transformer,
    GumEventSink * sink
);
```

### 架构适配

从 `gumstalker.h` 中的 `GumStalkerWriter` 联合体可以看出 Stalker 需要为每种架构生成不同的代码：

```c
union _GumStalkerWriter {
    gpointer instance;
    GumX86Writer * x86;
    GumArmWriter * arm;
    GumThumbWriter * thumb;
    GumArm64Writer * arm64;
    GumMipsWriter * mips;
};
```

每种 Writer 都知道如何为对应的 CPU 架构生成机器码。这是 Gum 跨平台能力的根基——同一套抽象接口，底层由架构特定的代码生成器实现。

### Transformer：可编程的代码变换

Stalker 最强大的特性之一是 Transformer——你可以在代码被重编译时修改它：

```c
// Transformer 接口
struct _GumStalkerTransformerInterface {
    void (* transform_block) (
        GumStalkerTransformer * self,
        GumStalkerIterator * iterator,
        GumStalkerOutput * output
    );
};
```

通过 iterator，你可以逐条遍历基本块中的指令，决定保留、修改或插入新的指令。这给了你对代码执行流的完全控制权。

## 5.5 Memory：内存操作

内存操作是插桩的基础。Gum 提供了跨平台的内存读写、扫描、分配、保护属性修改等功能：

```
┌─────────────────────────────────────────┐
│            Memory 子系统                 │
├─────────────────────────────────────────┤
│                                         │
│  gum_memory_read     读取内存           │
│  gum_memory_write    写入内存           │
│  gum_memory_scan     扫描内存模式       │
│  gum_memory_allocate 分配可执行内存     │
│  gum_memory_protect  修改保护属性       │
│                                         │
│  GumMemoryMap        内存映射查询       │
│  GumMemoryAccessMonitor  访问监控       │
│                                         │
└─────────────────────────────────────────┘
```

其中 `gum_memory_allocate` 特别值得关注——它分配的内存通常需要有执行权限，因为 Interceptor 和 Stalker 生成的 trampoline 代码需要放在这里。不同操作系统对可执行内存的管理策略不同（比如 iOS 的 JIT 限制），Gum 在平台抽象层统一处理了这些差异。

## 5.6 Module 和 Process：运行时信息

Module 子系统提供了对加载模块（动态库）的查询能力：

```c
// 枚举所有已加载模块
void gum_module_enumerate (GumFoundModuleFunc func, gpointer user_data);

// 枚举模块导出的符号
void gum_module_enumerate_exports (const gchar * module_name,
    GumFoundExportFunc func, gpointer user_data);
```

Process 子系统提供进程级别的信息：

```c
// 枚举线程
void gum_process_enumerate_threads (GumFoundThreadFunc func,
    gpointer user_data);

// 枚举内存范围
void gum_process_enumerate_ranges (GumPageProtection prot,
    GumFoundRangeFunc func, gpointer user_data);
```

这些信息对于插桩至关重要——你需要知道目标函数在哪个模块里、地址是多少、有哪些线程在运行，才能正确地进行拦截和追踪。

## 5.7 Cloak：隐藏自身

一个有趣的子系统是 `GumCloak`。Frida 作为插桩工具注入到目标进程后，它自身的线程、内存映射、文件描述符都会在进程中可见。如果目标程序有反调试检测，就可能发现 Frida 的存在。

Cloak 的作用就是维护一个"隐藏列表"，记录哪些资源属于 Frida 自身。当目标程序枚举线程或内存映射时，Gum 可以过滤掉这些资源。这就像间谍行动中的"清除痕迹"。

## 5.8 Gum 的初始化

Gum 提供了两种初始化方式：

```c
// 方式一：标准初始化（用于独立使用 Gum）
void gum_init (void);
void gum_shutdown (void);
void gum_deinit (void);

// 方式二：嵌入式初始化（用于 Frida Agent 等场景）
void gum_init_embedded (void);
void gum_deinit_embedded (void);
```

嵌入式初始化是为 Frida Agent（注入到目标进程中的那部分代码）设计的。它会做一些额外的工作，比如确保 GLib 的类型系统在目标进程中正确初始化。

还有一组 fork 相关的函数值得注意：

```c
void gum_prepare_to_fork (void);
void gum_recover_from_fork_in_parent (void);
void gum_recover_from_fork_in_child (void);
```

当目标进程调用 `fork()` 时，Gum 需要正确处理子进程中的状态。这些函数确保 Interceptor 和 Stalker 的内部数据结构在 fork 后保持一致。

## 5.9 Gum C API 与 GumJS 的关系

普通用户通过 JavaScript 使用 Frida，而 GumJS 就是连接 JavaScript 世界和 Gum C API 的桥梁：

```
┌───────────────────────────────────────────┐
│        用户 JavaScript 脚本               │
│   Interceptor.attach(addr, {              │
│     onEnter(args) { ... }                 │
│   });                                     │
├───────────────────────────────────────────┤
│              GumJS 绑定层                  │
│   将 JS 对象/回调转换为 C 结构/函数指针   │
│   管理 JS 运行时 (QuickJS 或 V8)         │
├───────────────────────────────────────────┤
│              Gum C API                    │
│   gum_interceptor_attach(...)             │
│   实际执行底层插桩操作                    │
└───────────────────────────────────────────┘
```

GumJS 支持两种 JavaScript 引擎：QuickJS（轻量级，适合嵌入式场景）和 V8（性能更好，功能更全）。用户可以通过 `--runtime qjs` 或 `--runtime v8` 来选择。

GumJS 做了大量的"翻译"工作：把 JavaScript 的回调函数包装成 C 的函数指针，把 C 的结构体转换成 JavaScript 对象，处理两个世界之间的内存管理和生命周期。

## 5.10 Gum 的设计哲学

回顾 Gum 的整体设计，有几个明显的特征：

1. **单例模式**：`gum_interceptor_obtain()` 返回的是进程级别的唯一实例，因为同一个进程里只能有一套拦截管理。

2. **架构与平台分离**：CPU 架构相关的代码（代码生成）和操作系统相关的代码（内存管理）被清晰地分开，使得移植到新平台只需要实现对应的那一层。

3. **最小化侵入**：Gum 尽量减少对目标进程的影响，Cloak 机制就是这一理念的体现。

4. **性能优先**：事务机制、Stalker 的信任阈值（trust threshold，控制代码缓存的复用策略）等设计都是为了在保证正确性的前提下最大化性能。

## 本章小结

- Gum 是 Frida 的核心插桩引擎，用纯 C 编写，提供跨平台的运行时代码修改能力
- Interceptor 通过改写函数开头的指令实现函数拦截，支持 attach（监听）和 replace（替换）两种模式
- Stalker 使用动态重编译技术追踪代码执行，Transformer 允许用户在重编译时修改指令
- Memory、Module、Process 子系统提供了插桩所需的运行时信息查询能力
- Gum 通过架构特定的 Writer（代码生成器）和平台抽象层实现跨平台支持
- GumJS 将 Gum 的 C API 暴露为 JavaScript 接口，支持 QuickJS 和 V8 两种引擎

## 思考题

1. Interceptor 的 attach 和 replace 分别适用于什么场景？如果你想记录一个函数的参数但不改变它的行为，应该用哪个？如果你想完全替换一个函数的返回值呢？

2. Stalker 的动态重编译会产生额外的内存和 CPU 开销。在什么场景下值得使用 Stalker，什么场景下应该优先使用 Interceptor？

3. 为什么 Gum 需要专门处理 fork() 的情况？如果不处理，子进程中可能会出现什么问题？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
