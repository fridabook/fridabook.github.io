# 第15章：Gadget 模式——无需注入的插桩

> 前面几章我们看到了 Frida 通过 ptrace 注入 Agent 的精妙设计。但如果目标环境根本不允许 ptrace 呢？比如 iOS 上未越狱的设备，或者一个嵌入式系统里没有调试器支持。这时候该怎么办？Frida 说：注入不了？那我就直接住进去。

## 15.1 什么是 Gadget？

如果说传统注入是"派特工潜入大楼"，那 Gadget 模式就是"装修的时候就把窃听器砌进墙里了"。Gadget 是一个特殊的 Frida 动态库，你在打包应用或编译程序时直接把它链接进去。当程序启动时，Gadget 会自动初始化，完全不需要运行时注入。

```
┌────────────────────────────────────────────────────┐
│         传统注入 vs Gadget 模式                      │
│                                                    │
│  传统注入:                                          │
│  ┌──────────┐  ptrace  ┌──────────┐               │
│  │  Frida   │ ──────>  │ 目标进程  │               │
│  │  Client  │  运行时   │          │               │
│  └──────────┘  注入     │ +Agent   │               │
│                        └──────────┘               │
│                                                    │
│  Gadget 模式:                                      │
│  ┌──────────────────────────────┐                  │
│  │  目标程序 (编译/打包时)        │                  │
│  │  ┌────────────────────────┐  │                  │
│  │  │  frida-gadget.so/dylib │  │                  │
│  │  │  (已经在里面了)         │  │                  │
│  │  └────────────────────────┘  │                  │
│  └──────────────────────────────┘                  │
│         │                                          │
│         v  程序启动时自动初始化                       │
│  ┌──────────┐                                      │
│  │  Frida   │  连接到 Gadget 监听的端口              │
│  │  Client  │                                      │
│  └──────────┘                                      │
└────────────────────────────────────────────────────┘
```

## 15.2 自动初始化：constructor 的魔法

Gadget 最巧妙的地方在于它的初始化完全是自动的。当动态库被加载时，操作系统的动态链接器会自动调用标记了 `constructor` 属性的函数。Frida 在 `gadget-glue.c` 中利用了这一机制：

```c
// gadget-glue.c（简化）

#if defined (HAVE_WINDOWS)
// Windows: DLL 入口点
BOOL WINAPI DllMain (HINSTANCE instance, DWORD reason, LPVOID reserved) {
    switch (reason) {
        case DLL_PROCESS_ATTACH:
            frida_gadget_load (NULL, NULL, NULL);
            break;
        case DLL_PROCESS_DETACH:
            if (reserved == NULL)  // 动态卸载时才清理
                frida_gadget_unload ();
            break;
    }
    return TRUE;
}

#elif defined (HAVE_DARWIN)
// macOS/iOS: constructor 属性
__attribute__ ((constructor)) static void
frida_on_load (int argc, const char * argv[],
               const char * envp[], const char * apple[],
               int * result)
{
    // Darwin 平台可以从 apple[] 参数获取额外配置
    frida_parse_apple_parameters (apple, &found_range, &range, &config_data);
    frida_gadget_load (found_range ? &range : NULL, config_data, result);
}

#else
// Linux/其他: constructor 属性
__attribute__ ((constructor)) static void frida_on_load (void) {
    frida_gadget_load (NULL, NULL, NULL);
}

__attribute__ ((destructor)) static void frida_on_unload (void) {
    frida_gadget_unload ();
}
#endif
```

看到了吗？每个平台都有自己的"自动初始化"机制，但核心都是调用 `frida_gadget_load()`。这就像不同品牌的汽车有不同的启动方式，但最终都是点燃发动机。

## 15.3 Gadget 的加载流程

`frida_gadget_load()` 最终会调用 Vala 层的 `Frida.Gadget.load()` 函数。让我们跟着源码走一遍：

```
┌─────────────────────────────────────────────────────┐
│             Gadget 加载流程                           │
│                                                     │
│  [1] frida_gadget_load()                            │
│       │                                             │
│       v                                             │
│  [2] Gadget.load()                                  │
│       ├── 检查是否已加载 (防重入)                     │
│       ├── Environment.init()                        │
│       ├── detect_location()  // 检测自身位置          │
│       │                                             │
│       v                                             │
│  [3] 加载配置文件                                    │
│       ├── 尝试读取 frida-gadget.config.json          │
│       └── 没有配置文件则使用默认值                     │
│       │                                             │
│       v                                             │
│  [4] 根据配置创建 Controller                         │
│       ├── ScriptInteraction    -> ScriptRunner       │
│       ├── ScriptDirectory      -> ScriptDirRunner    │
│       ├── ListenInteraction    -> ControlServer      │
│       └── ConnectInteraction   -> ClusterClient      │
│       │                                             │
│       v                                             │
│  [5] 决定是否阻塞等待                                │
│       ├── listen + on_load:wait  -> 阻塞直到连接      │
│       └── listen + on_load:resume -> 不阻塞          │
│       │                                             │
│       v                                             │
│  [6] 启动 Controller，进入工作状态                    │
└─────────────────────────────────────────────────────┘
```

从源码中可以看到这个清晰的分支逻辑：

```vala
// 简化示意
public void load (Gum.MemoryRange? mapped_range,
                  string? config_data, int * result) {
    if (loaded) return;
    loaded = true;

    Environment.init ();
    location = detect_location (mapped_range);

    // 加载配置
    config = (config_data != null)
        ? parse_config (config_data)
        : load_config (location);

    // 根据交互模式创建对应的 Controller
    var interaction = config.interaction;
    if (interaction is ScriptInteraction) {
        controller = new ScriptRunner (config, location);
    } else if (interaction is ScriptDirectoryInteraction) {
        controller = new ScriptDirectoryRunner (config, location);
    } else if (interaction is ListenInteraction) {
        controller = new ControlServer (config, location);
    } else if (interaction is ConnectInteraction) {
        controller = new ClusterClient (config, location);
    }
}
```

## 15.4 配置文件：Gadget 的行为说明书

Gadget 的行为由配置文件 `frida-gadget.config.json` 控制。这个文件需要放在与 Gadget 动态库相同的目录下。让我们看看 Frida 支持的配置选项：

```json
{
  "interaction": {
    "type": "listen",
    "address": "0.0.0.0",
    "port": 27042,
    "on_port_conflict": "fail",
    "on_load": "wait"
  },
  "teardown": "minimal",
  "runtime": "default",
  "code_signing": "optional"
}
```

从源码中的 Config 类定义，我们可以看到所有配置项：

```vala
// 简化的 Config 结构
private sealed class Config : Object {
    public Object interaction;    // 交互模式（核心配置）
    public TeardownRequirement teardown;  // 清理策略
    public ScriptRuntime runtime;         // JS 引擎选择
    public CodeSigningPolicy code_signing; // 代码签名策略
}
```

## 15.5 四种交互模式详解

这是 Gadget 最重要的部分。四种交互模式决定了 Gadget 的工作方式：

```
┌──────────────────────────────────────────────────────┐
│             Gadget 交互模式                            │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  1. listen (监听模式) -- 默认                  │    │
│  │     Gadget 启动一个 TCP/Unix 服务器             │    │
│  │     等待 Frida 客户端连接                       │    │
│  │     适合: 开发调试，需要交互式分析               │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  2. connect (连接模式)                         │    │
│  │     Gadget 主动连接到指定的 Frida Portal        │    │
│  │     适合: 设备在 NAT 后面，无法被直连            │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  3. script (脚本模式)                          │    │
│  │     Gadget 直接加载指定的 JS 脚本文件            │    │
│  │     不需要 Frida 客户端连接                      │    │
│  │     适合: 自动化测试，生产环境监控               │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  4. script-directory (脚本目录模式)             │    │
│  │     Gadget 加载指定目录下的所有脚本              │    │
│  │     支持文件变更时自动重扫描                      │    │
│  │     适合: 多脚本管理，热更新场景                  │    │
│  └──────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
```

每种模式对应的配置文件示例：

**Listen 模式**（默认，最常用）：
```json
{
  "interaction": {
    "type": "listen",
    "address": "127.0.0.1",
    "port": 27042,
    "on_load": "wait"
  }
}
```

当 `on_load` 设为 `"wait"` 时，Gadget 会在加载时阻塞应用程序的主线程，直到 Frida 客户端连接上来。这在调试启动阶段的代码时特别有用。设为 `"resume"` 则允许应用正常启动，客户端随时可以连接。

**Script 模式**（独立运行）：
```json
{
  "interaction": {
    "type": "script",
    "path": "/path/to/agent.js",
    "parameters": {
      "target_function": "secret_check"
    },
    "on_change": "reload"
  }
}
```

从源码中的 ScriptInteraction 类可以看到，脚本模式支持传入自定义参数和变更行为：

```vala
private sealed class ScriptInteraction : Object {
    public string path;           // 脚本文件路径
    public Json.Node parameters;  // 传给脚本的参数
    public ChangeBehavior on_change;  // 文件变更时的行为
    // on_change: IGNORE (忽略) 或 RELOAD (重新加载)
}
```

Connect 模式和 Script-Directory 模式的配置类似，分别指定远程地址/token 和脚本目录路径。Script-Directory 模式还支持进程过滤（通过 `ProcessFilter` 按可执行文件名、Bundle ID 或 ObjC 类名匹配），每个脚本可以有独立配置，只在符合条件的进程中运行。

## 15.6 等待与恢复机制

Gadget 的一个关键设计是 "wait for resume" 机制。在 listen 模式下，应用可能需要暂停在 constructor 中，等 Frida 客户端连接并完成 Hook 设置后再继续运行：

```vala
// 简化示意
wait_for_resume_needed = true;

var listen_interaction = config.interaction as ListenInteraction;
if (listen_interaction != null
    && listen_interaction.on_load == LoadBehavior.RESUME) {
    wait_for_resume_needed = false;
}

if (wait_for_resume_needed && Environment.can_block_at_load_time ()) {
    // 在当前线程阻塞，直到客户端连接并调用 resume
    var loop = new MainLoop (wait_for_resume_context, true);
    wait_for_resume_loop = loop;
    loop.run ();  // 阻塞在这里
}
```

当 Frida 客户端调用 `device.resume(pid)` 时，Gadget 端的 `resume()` 方法会修改状态为 STARTED，通过条件变量唤醒阻塞的线程，并退出等待循环。这个机制保证了你可以在应用的第一行业务代码执行之前就完成所有 Hook 设置。

## 15.7 Gadget vs 动态注入：如何选择？

```
┌────────────────────────────────────────────────────────┐
│           Gadget vs 动态注入 对比                       │
├──────────────────┬──────────────────┬──────────────────┤
│                  │  动态注入         │  Gadget          │
├──────────────────┼──────────────────┼──────────────────┤
│  需要修改应用？   │  不需要           │  需要            │
│  需要 root/越狱？ │  通常需要         │  不需要          │
│  启动时 Hook？    │  有时间窗口       │  可以完美覆盖    │
│  适用环境        │  开发/测试设备     │  任何环境        │
│  对 App Store    │  无影响           │  不能上架         │
│  调试便利性      │  即连即用         │  需要重新打包     │
│  自动化测试      │  需要额外步骤     │  天然支持         │
│  CI/CD 集成      │  较复杂           │  简单            │
└──────────────────┴──────────────────┴──────────────────┘
```

## 15.8 实际使用场景

**场景一：iOS 应用分析（非越狱）**

在 iOS 上，没有越狱就无法使用 ptrace 注入。常见做法是：
1. 解包 IPA 文件
2. 将 `FridaGadget.dylib` 放入 Frameworks 目录
3. 修改二进制的 Load Commands，添加对 Gadget 的依赖
4. 重签名后安装

应用启动时，iOS 的 dyld 会自动加载 Gadget，触发 constructor。

**场景二：嵌入式设备** -- 编译时链接 `frida-gadget.so`，配置 script 模式指向监控脚本，设备启动后自动插桩。

**场景三：自动化测试** -- CI/CD 中构建内嵌 Gadget 的测试版应用，配合 script 模式自动收集覆盖率、检测内存泄漏，无需额外 Frida 服务端。

## 15.9 Gadget 的卸载

Gadget 的卸载通过 `destructor`（Linux/macOS）或 `DLL_PROCESS_DETACH`（Windows）触发。卸载时，Gadget 会在工作线程中停止 Controller，等待所有异步操作完成。配置中的 `teardown` 项控制清理程度：`"full"` 完全清理所有资源（适合测试），`"minimal"`（默认）只做最少清理以加快退出速度。

## 本章小结

- **Gadget** 是 Frida 的嵌入式插桩方案，通过编译/打包时嵌入，利用 `constructor`/`DllMain` 自动初始化
- 支持四种交互模式：**listen**（等待连接）、**connect**（主动连接）、**script**（独立脚本）、**script-directory**（多脚本目录）
- 通过 `frida-gadget.config.json` 配置文件控制行为，配置文件放在 Gadget 动态库的同级目录
- "wait for resume" 机制可以在应用启动前完成所有 Hook 设置
- Gadget 模式特别适合 **iOS 非越狱分析**、**嵌入式设备**和 **CI/CD 自动化测试**场景

## 思考题

1. 在 iOS 非越狱环境下使用 Gadget，重签名后的应用无法上架 App Store。如果你需要在生产环境中做类似的监控，有什么替代方案？
2. Gadget 的 listen 模式中，`on_load: "wait"` 会阻塞主线程。如果应用有启动超时机制（比如 iOS 的 watchdog），可能会被系统杀掉。你会怎么处理这个问题？
3. 比较 Gadget 的 script 模式和 connect 模式，在一个需要远程管理的物联网设备上，你会选择哪种？为什么？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
