# 第13章：Agent 生命周期——注入后的世界

> 上一章我们看到了 Frida 如何把 Agent 这个"特工"送入目标进程。但故事才刚刚开始——特工进了大楼之后，他要做什么？怎么和总部联系？任务完成后又怎么安全撤退？这就是 Agent 生命周期的故事。

## 13.1 Agent 的入口：一切从 main 开始

当 Helper 进程通过 dlopen 加载 Agent 动态库后，会调用指定的入口函数。在 Frida 中，这个入口函数就是 `frida_agent_main`。让我们看看它做了什么：

```vala
// frida-core/lib/agent/agent.vala（简化）
namespace Frida.Agent {
    public void main (string agent_parameters,
                      ref UnloadPolicy unload_policy,
                      void * injector_state) {
        if (Runner.shared_instance == null)
            Runner.create_and_run (agent_parameters,
                ref unload_policy, injector_state);
        else
            Runner.resume_after_transition (
                ref unload_policy, injector_state);
    }
}
```

这段代码虽然短，但信息量很大。它做了一个判断：如果是第一次被调用（shared_instance 为 null），就创建一个新的 Runner 并开始运行；如果不是第一次（比如 fork 之后子进程恢复），就执行恢复流程。

你可以把 `Runner` 想象成特工的"行动指挥中心"——它负责协调 Agent 的整个生命周期。

## 13.2 Runner：Agent 的心脏

Runner 是 Agent 中最核心的类，它实现了多个接口，身兼数职：

```
┌──────────────────────────────────────────────────┐
│                   Runner 的角色                   │
├──────────────────────────────────────────────────┤
│                                                  │
│  ProcessInvader        -- 作为入侵者管理自身      │
│  AgentSessionProvider  -- 提供会话管理能力        │
│  ExitHandler           -- 处理进程退出事件        │
│  ForkHandler           -- 处理 fork 事件          │
│  SpawnHandler          -- 处理进程创建事件        │
│                                                  │
└──────────────────────────────────────────────────┘
```

Runner 内部维护了大量状态，我们来看它最重要的几个成员：

```vala
// 简化后的 Runner 关键成员
private sealed class Runner : Object {
    public static Runner shared_instance = null;  // 全局单例

    private MainContext main_context;     // GLib 主事件循环上下文
    private MainLoop main_loop;          // 事件循环
    private DBusConnection connection;   // 与 Host 的通信通道
    private AgentController? controller; // 远端控制器的代理

    // 脚本相关
    private ScriptBackend? qjs_backend;  // QuickJS 后端
    private ScriptBackend? v8_backend;   // V8 后端

    // 安全与监控
    private ExitMonitor? exit_monitor;   // 监控进程退出
    private Interceptor interceptor;     // 函数拦截器
    private Exceptor? exceptor;          // 异常处理器

    // 进程生命周期
    private ForkMonitor? fork_monitor;   // 监控 fork
    private SpawnMonitor? spawn_monitor; // 监控进程创建
}
```

## 13.3 启动流程：从参数解析到事件循环

Agent 的启动是一个精心编排的过程。让我们跟着 `create_and_run` 走一遍：

```
┌─────────────────────────────────────────────────────┐
│              Agent 启动时间线                         │
│                                                     │
│  [1] Environment._init()                            │
│       └── 初始化 GLib、Gum 等基础设施                 │
│                                                     │
│  [2] 检测自身路径和内存范围                            │
│       └── detect_own_range_and_path()               │
│       └── Gum.Cloak.add_range()  // 隐藏自身         │
│                                                     │
│  [3] 创建 Runner 实例                                │
│       └── new Runner(agent_parameters, ...)          │
│                                                     │
│  [4] runner.run()                                   │
│       ├── push_thread_default()  // 设置线程上下文     │
│       ├── start.begin()          // 开始异步启动      │
│       └── main_loop.run()        // 进入事件循环      │
│                                                     │
│  [5] start() 异步流程                                │
│       ├── 解析 agent_parameters                      │
│       ├── 初始化 Interceptor, ExitMonitor 等         │
│       ├── 建立与 Host 的 DBus 连接                    │
│       └── 预热 JS 引擎线程                            │
│                                                     │
│  [6] 事件循环运行中... (等待指令)                      │
└─────────────────────────────────────────────────────┘
```

其中参数解析这一步值得细看。agent_parameters 是一个用竖线分隔的字符串：

```vala
// 参数格式: "传输地址|选项1|选项2|..."
string[] tokens = agent_parameters.split ("|");
unowned string transport_uri = tokens[0];  // 第一个是传输地址

foreach (unowned string option in tokens[1:]) {
    if (option == "eternal")
        ensure_eternalized ();         // 永不卸载模式
    else if (option == "sticky")
        stop_thread_on_unload = false; // 卸载时不停线程
    else if (option == "exit-monitor:off")
        enable_exit_monitor = false;   // 关闭退出监控
    // ... 更多选项
}
```

这种简单的文本协议设计得很巧妙——通过字符串传参避免了复杂的结构体跨进程传递问题。

## 13.4 通信通道：DBus 连接

Agent 与 Host（Frida 客户端）之间的通信是通过 DBus 协议建立的。但请注意，这里并不是系统的 DBus 总线，而是一个点对点的 DBus 连接，跑在 Unix socket（Linux）或命名管道（Windows）上。

```
┌──────────────────────────────────────────────────┐
│            Agent <-> Host 通信架构                 │
│                                                  │
│   Host 端                      Agent 端           │
│  ┌────────────┐              ┌────────────┐      │
│  │ Frida      │              │ Runner     │      │
│  │ Client     │              │            │      │
│  │            │   DBus over  │ Agent      │      │
│  │ Agent      │<────────────>│ Session    │      │
│  │ Controller │  Unix Socket │ Provider   │      │
│  │            │              │            │      │
│  └────────────┘              └────────────┘      │
│                                                  │
│  控制命令 ──────────────>  创建脚本/Hook/...       │
│  <──────────────  消息/事件/数据                   │
└──────────────────────────────────────────────────┘
```

在 Linux 上，通信通道的建立有一个特别有趣的细节。从 AgentContainer 的源码我们可以看到：

```vala
// 简化示意
// Linux 使用 socketpair 创建连接
int agent_ctrlfds[2];
Posix.socketpair (AF_UNIX, SOCK_STREAM, 0, agent_ctrlfds);

// fd[0] 给 Host 端
// fd[1] 传给 Agent（通过 injector_state）
```

而在 Agent 端的 `create_and_run` 方法中：

```vala
// Agent 侧接收 socket fd
var linjector_state = (LinuxInjectorState *) opaque_injector_state;
int agent_ctrlfd = linjector_state->agent_ctrlfd;

// 构建传输地址: "socket:FD号"
agent_parameters = "socket:%d%s".printf (agent_ctrlfd, agent_parameters);
```

这样 Agent 就通过继承的文件描述符直接与 Host 通信，无需经过任何文件系统或网络。这个方案既高效又安全。

## 13.5 会话管理

建立连接后，Host 可以通过 AgentSessionProvider 接口创建多个会话（Session）。每个会话可以独立加载脚本、进行 Hook 操作：

```
┌──────────────────────────────────────────────┐
│          Agent 内部会话结构                    │
│                                              │
│  Runner (AgentSessionProvider)               │
│  │                                           │
│  ├── Session A                               │
│  │   ├── ScriptEngine                        │
│  │   │   ├── Script 1 (hook malloc)          │
│  │   │   └── Script 2 (trace calls)          │
│  │   └── DBus 接口注册                        │
│  │                                           │
│  ├── Session B                               │
│  │   ├── ScriptEngine                        │
│  │   │   └── Script 3 (custom logic)         │
│  │   └── DBus 接口注册                        │
│  │                                           │
│  └── Direct Connections (直连)                │
│      └── 不经过主连接的独立通道                 │
└──────────────────────────────────────────────┘
```

## 13.6 隐身术：Cloak 机制

一个优秀的特工，最重要的技能之一就是不被发现。Frida Agent 也是如此。在启动过程中，你会看到这样的代码：

```vala
// 隐藏 Agent 自身的内存范围
cached_agent_range = detect_own_range_and_path (mapped_range, out cached_agent_path);
Gum.Cloak.add_range (cached_agent_range);

// 隐藏文件描述符
Gum.Cloak.add_file_descriptor (injector_state.fifo_fd);
```

`Gum.Cloak` 是 Frida 的隐身系统。当目标进程试图枚举自己的内存映射（比如读 `/proc/self/maps`）或文件描述符时，被 Cloak 标记的范围会被自动隐藏。同时，Agent 的线程也会被隐藏：

```vala
var ignore_scope = new ThreadIgnoreScope (FRIDA_THREAD);
// 在这个 scope 内，Frida 的线程对 Stalker 等机制不可见
```

## 13.7 卸载与清理

Agent 的退出有几种不同的方式，对应不同的 UnloadPolicy：

```
┌────────────────────────────────────────────────┐
│           卸载策略 (UnloadPolicy)                │
├────────────┬───────────────────────────────────┤
│  IMMEDIATE │ 立即卸载，清理所有资源              │
│            │ 这是默认行为                       │
├────────────┼───────────────────────────────────┤
│  RESIDENT  │ Agent 永驻内存，不卸载              │
│            │ 用于 eternalize 场景               │
├────────────┼───────────────────────────────────┤
│  DEFERRED  │ 延迟卸载                           │
│            │ 用于 fork/exec 等进程转换场景       │
└────────────┴───────────────────────────────────┘
```

正常卸载流程：

```vala
// 简化的关闭流程
// 1. 停止事件循环
main_loop.quit ();

// 2. 根据 stop_reason 决定后续
if (stop_reason == PROCESS_TRANSITION) {
    unload_policy = DEFERRED;    // fork 后保留
} else if (is_eternal) {
    unload_policy = RESIDENT;    // 永驻模式
    keep_running_eternalized (); // 在新线程继续运行
} else {
    release_shared_instance ();  // 释放单例
    Environment._deinit ();      // 清理环境
}
```

"Eternalize" 是一个特别有趣的概念。当脚本调用了某些需要永久存在的 Hook 时，Agent 可以进入永驻模式——即使 Frida 客户端断开连接，Agent 依然在目标进程中运行，Hook 继续生效：

```vala
private void keep_running_eternalized () {
    // 在一个新线程中继续运行事件循环
    agent_gthread = new Thread<bool> ("frida-eternal-agent", () => {
        main_context.push_thread_default ();
        main_loop.run ();  // 永远不会返回
        main_context.pop_thread_default ();
        return true;
    });
}
```

## 13.8 完整生命周期图

把所有阶段串起来：

```
┌─────────────────────────────────────────────────────────┐
│               Agent 完整生命周期                          │
│                                                         │
│  dlopen() ──> frida_agent_main()                        │
│                    │                                    │
│                    v                                    │
│              Runner.create_and_run()                    │
│                    │                                    │
│           ┌────────┴────────┐                           │
│           v                 v                           │
│    Environment._init()   检测自身范围                    │
│           │              并 Cloak 隐藏                   │
│           v                                             │
│    创建 Runner 单例                                      │
│           │                                             │
│           v                                             │
│    runner.run()                                         │
│    ┌──────┴──────┐                                      │
│    v             v                                      │
│  start()    main_loop.run()                             │
│    │             ^                                      │
│    v             │ (事件驱动)                             │
│  解析参数         │                                      │
│  初始化拦截器     │                                      │
│  建立 DBus 连接   │                                      │
│  注册服务 ────────┘                                      │
│                                                         │
│  ═══════ 运行阶段 ═══════                                │
│  接收指令 -> 创建会话 -> 加载脚本 -> 执行 Hook            │
│                                                         │
│  ═══════ 退出阶段 ═══════                                │
│  main_loop.quit()                                       │
│       │                                                 │
│       ├─── IMMEDIATE: 清理并卸载                         │
│       ├─── RESIDENT:  新线程继续运行                      │
│       └─── DEFERRED:  等待进程转换后恢复                  │
└─────────────────────────────────────────────────────────┘
```

## 本章小结

- Agent 的入口是 `frida_agent_main`，通过 **Runner** 单例管理整个生命周期
- 启动过程包括：环境初始化、自身隐藏（Cloak）、参数解析、DBus 连接建立
- Agent 与 Host 通过 **点对点 DBus 协议**通信，Linux 上使用 socketpair 传递文件描述符
- 支持多种卸载策略：**IMMEDIATE**（立即）、**RESIDENT**（永驻）、**DEFERRED**（延迟）
- **Cloak 机制**让 Agent 对目标进程"隐身"，隐藏内存范围、文件描述符和线程

## 思考题

1. Agent 为什么选择 DBus 协议而不是更简单的 JSON-RPC？DBus 在这个场景下有什么优势？
2. "Eternalize" 模式下，如果 Frida 客户端已经断开，Agent 的 Hook 还能继续工作。这是怎么实现的？会不会有内存泄漏的风险？
3. 在 fork 场景下，Agent 需要处理哪些特殊情况？父进程和子进程的 Agent 如何区分和独立运行？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
