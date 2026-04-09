# 第14章：脚本引擎——JavaScript 遇见原生代码

> 思考一个问题：一段 JavaScript 代码，是怎么在一个 C/C++ 编写的原生进程里运行的？更神奇的是，这段 JS 代码还能读写进程内存、拦截函数调用、修改参数和返回值。这背后到底发生了什么？

## 14.1 两个世界的碰撞

我们先来感受一下这种"神奇"。当你写一个 Frida 脚本：

```javascript
Interceptor.attach(Module.findExportByName(null, "open"), {
    onEnter: function(args) {
        console.log("Opening: " + args[0].readUtf8String());
    }
});
```

这段 JavaScript 代码做了以下事情：
1. 在原生进程中找到 `open` 函数的地址
2. 在那个地址上设置了一个钩子
3. 每次 `open` 被调用时，读取第一个参数（一个 C 字符串指针）
4. 把内容发送到控制台

JavaScript 本身没有操作内存指针的能力，C 语言本身也不认识 JavaScript。是谁在中间搭了这座桥？答案就是 **GumJS** -- Frida 的 JavaScript 绑定层。

```
┌───────────────────────────────────────────────────┐
│              Frida 脚本引擎架构                     │
│                                                   │
│  ┌─────────────────────────────────────────────┐  │
│  │           JavaScript 世界                    │  │
│  │                                             │  │
│  │  Interceptor.attach(...)                    │  │
│  │  Memory.readUtf8String(...)                 │  │
│  │  Process.enumerateModules(...)              │  │
│  └──────────────────┬──────────────────────────┘  │
│                     │ GumJS 绑定层                  │
│  ┌──────────────────v──────────────────────────┐  │
│  │           C/C++ 桥接层                       │  │
│  │                                             │  │
│  │  gumquickinterceptor.c / gumv8interceptor.c │  │
│  │  gumquickmemory.c      / gumv8memory.c      │  │
│  │  gumquickprocess.c     / gumv8process.c     │  │
│  └──────────────────┬──────────────────────────┘  │
│                     │                             │
│  ┌──────────────────v──────────────────────────┐  │
│  │           Gum 核心库                         │  │
│  │                                             │  │
│  │  GumInterceptor  (函数拦截)                  │  │
│  │  GumStalker      (代码追踪)                  │  │
│  │  GumMemory        (内存操作)                  │  │
│  └─────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────┘
```

## 14.2 双引擎：QuickJS 与 V8

Frida 支持两个 JavaScript 引擎，就像一辆跑车配了两个发动机，你可以根据需要切换：

```
┌────────────────────────────────────────────────────┐
│          JavaScript 引擎对比                        │
├──────────────┬──────────────────┬──────────────────┤
│              │    QuickJS       │      V8          │
├──────────────┼──────────────────┼──────────────────┤
│  体积        │  很小 (~300KB)    │  较大 (~5MB)     │
│  启动速度    │  极快             │  较慢            │
│  执行性能    │  一般             │  极好 (JIT)      │
│  内存占用    │  低               │  较高            │
│  适用场景    │  嵌入式/资源受限   │  性能敏感场景    │
│  文件前缀    │  gumquick*        │  gumv8*          │
└──────────────┴──────────────────┴──────────────────┘
```

从 GumJS 的源码目录结构就能清楚看到这种双引擎设计：

```
gumjs/
├── gumquickinterceptor.c    <-- QuickJS 版本
├── gumv8interceptor.cpp     <-- V8 版本
├── gumquickmemory.c
├── gumv8memory.cpp
├── gumquickprocess.c
├── gumv8process.cpp
├── gumquickcore.c
├── gumv8core.cpp
├── gumquickstalker.c
├── gumv8stalker.cpp
└── ... (每个 API 模块都有两个版本)
```

每个 JS API（Interceptor、Memory、Process 等）都有两套实现：一套用 QuickJS 的 C API，一套用 V8 的 C++ API。虽然两套代码在 JS 引擎接口调用上不同，但底层最终都调用同样的 Gum 核心库。

在 ScriptEngine 中，引擎的选择是这样的：

```vala
// 简化示意
private Gum.ScriptBackend pick_backend (ScriptRuntime runtime) {
    if (runtime == DEFAULT)
        runtime = preferred_runtime;  // 默认选择
    return invader.get_script_backend (runtime);
}
```

用户可以在创建脚本时指定引擎，也可以使用默认值。在 Agent 的 Runner 中，两个后端按需初始化：

```vala
// Runner 中的后端管理
private Gum.ScriptBackend? qjs_backend;  // QuickJS，按需创建
private Gum.ScriptBackend? v8_backend;   // V8，按需创建
```

## 14.3 ScriptEngine：脚本的管家

`ScriptEngine` 是管理脚本生命周期的核心类。它的设计很清晰：

```vala
// 简化后的 ScriptEngine
public sealed class ScriptEngine : Object {
    // 信号：脚本发出的消息和调试信息
    public signal void message_from_script (AgentScriptId id, string json, Bytes? data);
    public signal void message_from_debugger (AgentScriptId id, string message);

    // 脚本实例映射表
    private HashMap<AgentScriptId?, ScriptInstance> instances;
    private uint next_script_id = 1;

    // 核心操作
    public async ScriptInstance create_script (string? source, Bytes? bytes, ScriptOptions options);
    public async void load_script (AgentScriptId script_id);
    public async void destroy_script (AgentScriptId script_id);
    public void post_to_script (AgentScriptId script_id, string json, Bytes? data);
}
```

每个脚本的生命都要经历这样的旅程：

```
┌────────────────────────────────────────────────────┐
│              脚本生命周期状态机                       │
│                                                    │
│   create_script()         load_script()            │
│        │                      │                    │
│        v                      v                    │
│   ┌─────────┐           ┌──────────┐               │
│   │ CREATED │ ────────> │ LOADING  │               │
│   └─────────┘           └────┬─────┘               │
│                              │                     │
│                              v                     │
│                         ┌──────────┐               │
│                         │ LOADED   │ <── 正常运行   │
│                         └────┬─────┘               │
│                              │                     │
│              ┌───────────────┼──────────────┐      │
│              v               v              v      │
│       ┌────────────┐  ┌───────────┐  ┌──────────┐ │
│       │ ETERNALIZED│  │ DISPOSED  │  │ (close)  │ │
│       │ (永驻)     │  └─────┬─────┘  └──────────┘ │
│       └────────────┘        │                      │
│                             v                      │
│                       ┌──────────┐                 │
│                       │ UNLOADED │                 │
│                       └─────┬────┘                 │
│                             v                      │
│                       ┌───────────┐                │
│                       │ DESTROYED │                │
│                       └───────────┘                │
└────────────────────────────────────────────────────┘
```

## 14.4 脚本创建：从源码到可执行

当你发送一段 JavaScript 源码给 Frida，`create_script` 方法会这样处理：

```vala
// 简化示意
public async ScriptInstance create_script (string? source, Bytes? bytes,
    ScriptOptions options) throws Error {

    // 1. 分配唯一 ID
    var script_id = AgentScriptId (next_script_id++);

    // 2. 选择 JS 引擎后端
    Gum.ScriptBackend backend = pick_backend (options.runtime);

    // 3. 创建脚本（编译）
    Gum.Script script;
    if (source != null)
        script = yield backend.create (name, source, options.snapshot);
    else
        script = yield backend.create_from_bytes (bytes, options.snapshot);

    // 4. 排除自身范围（避免 Stalker 追踪 Agent 自己）
    script.get_stalker ().exclude (invader.get_memory_range ());

    // 5. 包装成 ScriptInstance
    var instance = new ScriptInstance (script_id, script);
    instances[script_id] = instance;

    return instance;
}
```

这里有一个关键概念：**snapshot**（快照）。Frida 支持预编译脚本并保存快照，下次加载时可以跳过编译步骤，大幅提升启动速度。这就像把一本书翻译好放在书架上，下次要用时直接取，不用再翻译。

## 14.5 GumJS 绑定：桥梁的秘密

GumJS 绑定层是整个系统中最精妙的部分。让我们以 `Interceptor.attach` 为例，看看一次 JS 调用如何穿越到原生世界。

以 QuickJS 版本为例，`gumquickinterceptor.c` 中大致是这样的结构：

```c
// 伪代码，展示绑定层的工作原理
static JSValue gumjs_interceptor_attach (JSContext * ctx,
    JSValue this_val, int argc, JSValue * argv)
{
    // 1. 从 JS 参数中提取目标地址
    gpointer target;
    _gum_quick_native_pointer_get (ctx, argv[0], &target);

    // 2. 从 JS 参数中提取回调对象
    JSValue on_enter = JS_GetPropertyStr (ctx, argv[1], "onEnter");
    JSValue on_leave = JS_GetPropertyStr (ctx, argv[1], "onLeave");

    // 3. 调用 Gum 核心的 C API
    GumAttachReturn result = gum_interceptor_attach (
        self->interceptor,
        target,
        GUM_INVOCATION_LISTENER (listener),
        NULL
    );

    // 4. 返回 JS 对象
    return wrap_as_js_listener (listener);
}
```

这就是桥梁的工作方式：

```
┌────────────────────────────────────────────────────┐
│         一次 Interceptor.attach 的旅程               │
│                                                    │
│  JS 世界:                                          │
│  Interceptor.attach(ptr("0x12345"), {              │
│      onEnter(args) { ... }                         │
│  })                                                │
│       │                                            │
│       v                                            │
│  GumJS 绑定层:                                      │
│  gumjs_interceptor_attach()                        │
│       │  解析 JS 参数                                │
│       │  转换类型 (JSValue -> C pointer)             │
│       │  创建 InvocationListener                    │
│       v                                            │
│  Gum 核心:                                          │
│  gum_interceptor_attach()                          │
│       │  修改目标函数的机器码                         │
│       │  插入跳转指令到 trampoline                   │
│       v                                            │
│  原生世界:                                          │
│  目标函数被调用时 -> trampoline -> 回调 JS 函数       │
└────────────────────────────────────────────────────┘
```

GumJS 目录下的模块覆盖了 Frida JS API 的所有功能：

```
┌──────────────────────────────────────────────────┐
│           GumJS 模块映射                          │
├──────────────────┬───────────────────────────────┤
│  JS API          │  对应 C/C++ 模块               │
├──────────────────┼───────────────────────────────┤
│  Interceptor     │  gumquickinterceptor.c        │
│  Stalker         │  gumquickstalker.c            │
│  Memory          │  gumquickmemory.c             │
│  Process         │  gumquickprocess.c            │
│  Module          │  gumquickmodule.c             │
│  Thread          │  gumquickthread.c             │
│  Socket          │  gumquicksocket.c             │
│  File            │  gumquickfile.c               │
│  Database (SQLite)│  gumquickdatabase.c          │
│  ApiResolver     │  gumquickapiresolver.c        │
│  CModule         │  gumquickcmodule.c            │
│  Symbol          │  gumquicksymbol.c             │
│  Instruction     │  gumquickinstruction.c        │
│  CodeWriter      │  gumquickcodewriter.c         │
│  CodeRelocator   │  gumquickcoderelocator.c      │
└──────────────────┴───────────────────────────────┘
```

## 14.6 消息传递：JS 与 Host 的对话

脚本运行过程中，JS 代码和 Frida 客户端之间需要互相发消息。这个通信管道经历了多层传递：

```
┌──────────────────────────────────────────────────────┐
│           消息传递路径                                 │
│                                                      │
│  JS 脚本端:                                           │
│  send({type: "info", payload: "hello"})              │
│       │                                              │
│       v                                              │
│  Gum.Script 消息处理器                                 │
│  on_message(json, data)                              │
│       │                                              │
│       ├── RPC 消息？ -> rpc_client.try_handle_message │
│       │                                              │
│       └── 普通消息 -> ScriptInstance.message 信号      │
│                │                                     │
│                v                                     │
│           ScriptEngine.message_from_script 信号       │
│                │                                     │
│                v                                     │
│           通过 DBus 连接发送到 Host                    │
│                │                                     │
│                v                                     │
│  Python/Node.js 端:                                   │
│  script.on('message', function(message, data) { })   │
└──────────────────────────────────────────────────────┘
```

消息到达 ScriptInstance 后，会先检查是否为 RPC 响应（Frida 内置了 RPC 机制，支持 Host 调用脚本的 `rpc.exports` 方法），非 RPC 消息则作为普通消息转发。反方向，Host 通过 `post_to_script` 向脚本发消息，但只有处于 LOADING/LOADED/DISPOSED 状态的脚本才能接收。

ScriptEngine 还支持 JavaScript 调试器接口，通过 `enable_debugger` 启用后，调试消息通过 DBus 传回 Host，最终转发给 Chrome DevTools。

## 本章小结

- Frida 的脚本引擎通过 **GumJS 绑定层**把 JavaScript API 映射到 Gum 核心库的 C API
- 支持 **QuickJS**（轻量快速）和 **V8**（高性能 JIT）两个 JS 引擎，每个 API 模块都有两套实现
- **ScriptEngine** 管理脚本的完整生命周期：创建、编译、加载、执行、卸载、销毁
- 消息传递经历多层：JS -> Gum.Script -> ScriptInstance -> ScriptEngine -> DBus -> Host
- 内置 **RPC 机制**支持双向方法调用，**调试器接口**支持 Chrome DevTools 连接

## 思考题

1. 为什么 Frida 要同时支持 QuickJS 和 V8 两个引擎？在实际使用中你会怎么选择？
2. GumJS 的每个模块都有 Quick 和 V8 两个版本，这是否会导致代码维护困难？你能想到什么方法来减少重复代码？
3. 当一个 Interceptor Hook 被触发时，从原生函数调用到 JS onEnter 回调执行，大概会经历哪些步骤？这个过程的性能开销在哪里？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
