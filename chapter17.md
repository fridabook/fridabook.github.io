# 第17章：Darwin 后端——Mach 端口与 XPC

> 如果说 Linux 是一间门窗大开的房子，那 Apple 的平台就是一座层层设防的堡垒。在 macOS 和 iOS 上，Frida 不能像 Linux 那样直接用 ptrace 为所欲为——它必须学会使用 Mach 端口、理解代码签名、应对策略限制。让我们来看看 Frida 是如何在 Apple 的地盘上施展身手的。

## 17.1 Darwin 后端的整体架构

Darwin 后端的核心文件结构如下：

```
frida-core/src/darwin/
├── darwin-host-session.vala        # 主会话管理
├── fruitjector.vala                # Darwin 注入器
├── frida-helper-backend.vala       # Helper 后端（Vala层）
├── frida-helper-backend-glue.m     # Helper 后端（ObjC/C层）
├── policy-softener.vala            # 策略软化器（绕过iOS限制）
├── frida-helper-service-glue.m     # Helper 服务胶水代码
└── system-darwin.m                 # 系统信息获取
```

整体架构：

```
┌───────────────────────────────────────────────────┐
│              DarwinHostSession                     │
│  (macOS/iOS 主会话，管理设备上的调试会话)            │
├───────────┬──────────────┬────────────────────────┤
│Fruitjector│ FruitController│ PolicySoftener         │
│(注入器)   │ (iOS应用管理)  │ (策略软化)              │
├───────────┴──────────────┴────────────────────────┤
│           DarwinHelperBackend                      │
│  (Mach端口操作、进程spawn、代码注入)                │
├───────────────────────────────────────────────────┤
│  Mach Kernel: task_port, thread, exception_port   │
└───────────────────────────────────────────────────┘
```

## 17.2 Mach 端口——Darwin 的进程控制基石

在 Darwin 系统上，进程间通信的核心机制不是信号或 ptrace，而是 **Mach 端口**（Mach Port）。每个进程都有一个 task port，拿到这个端口就相当于拿到了进程的"遥控器"。

### 17.2.1 task port 的威力

通过 task port，你可以：

```
┌─────────────────────────────────────────────┐
│            task_port 能做的事情               │
├─────────────────────────────────────────────┤
│  mach_vm_allocate()    - 在目标进程分配内存   │
│  mach_vm_write()       - 向目标进程写入数据   │
│  mach_vm_read()        - 读取目标进程内存     │
│  mach_vm_protect()     - 修改内存保护属性     │
│  thread_create()       - 在目标进程创建线程   │
│  thread_set_state()    - 修改线程寄存器       │
│  task_threads()        - 枚举目标进程的线程   │
└─────────────────────────────────────────────┘
```

这就像拿到了一个人的银行账号加密码——你可以存钱、取钱、转账、查余额，几乎什么都能做。

### 17.2.2 注入过程中的 Mach 端口使用

Frida 在 Darwin 上的注入流程大量使用 Mach 端口操作：

```c
// 简化自 frida-helper-backend-glue.m 中的注入实例结构
struct FridaInjectInstance {
    guint id;
    guint pid;
    mach_port_t task;                    // 目标进程的 task port

    mach_vm_address_t payload_address;   // 注入代码的地址
    mach_vm_size_t payload_size;         // 注入代码的大小
    FridaAgentContext *agent_context;    // Agent 上下文
    mach_vm_address_t remote_agent_context;

    mach_port_t thread;                  // 注入线程
    dispatch_source_t thread_monitor_source;

    // 线程状态（不同架构不同）
    arm_unified_thread_state_t thread_state64;  // ARM64
    // 或 x86_thread_state_t thread_state;      // x86
};
```

注入的关键步骤：

```
┌─────────────┐
│  1. 获取     │  task_for_pid(pid) -> task_port
│  task port   │
├─────────────┤
│  2. 分配     │  mach_vm_allocate(task, &addr, size, ...)
│  远程内存    │
├─────────────┤
│  3. 写入     │  mach_vm_write(task, addr, payload, size)
│  注入代码    │
├─────────────┤
│  4. 设置     │  mach_vm_protect(task, addr, size, ..., RX)
│  内存权限    │
├─────────────┤
│  5. 创建     │  thread_create_running(task, flavor,
│  远程线程    │      &thread_state, count, &thread)
├─────────────┤
│  6. 监控     │  dispatch_source 监控线程完成
│  线程执行    │
└─────────────┘
```

### 17.2.3 AgentContext——注入代码的上下文

Frida 在目标进程中执行的代码需要知道如何调用系统函数。`AgentContext` 结构体就是这张"地图"：

```c
// 简化自 frida-helper-backend-glue.m
struct FridaAgentContext {
    // 状态
    FridaUnloadPolicy unload_policy;
    mach_port_t task;
    mach_port_t mach_thread;

    // Mach 线程阶段需要的函数
    GumAddress mach_task_self_impl;
    GumAddress mach_thread_self_impl;
    GumAddress mach_port_allocate_impl;
    GumAddress pthread_create_from_mach_thread_impl;

    // POSIX 线程阶段需要的函数
    GumAddress dlopen_impl;        // 用于加载 agent dylib
    GumAddress dlsym_impl;         // 用于查找入口函数
    GumAddress dlclose_impl;       // 用于卸载

    // 数据存储
    gchar dylib_path_storage[256];
    gchar entrypoint_name_storage[256];
    gchar entrypoint_data_storage[4096];
};
```

注入代码分两个阶段执行：先在 Mach 线程中创建一个 POSIX 线程，然后在 POSIX 线程中执行 dlopen 加载 agent。为什么要这么绕？因为 Mach 线程是内核级线程，缺少很多用户态基础设施（比如 TLS），直接在上面跑复杂代码会出问题。

## 17.3 Spawn 控制——断点与 dyld

在 Darwin 上 spawn 一个进程比 Linux 更复杂。Frida 使用 `posix_spawn` 配合异常端口来控制新进程：

```c
// 简化的 spawn 流程
struct FridaSpawnInstance {
    guint pid;
    GumCpuType cpu_type;
    mach_port_t thread;

    mach_port_t server_port;                // 异常处理端口
    FridaExceptionPortSet previous_ports;   // 保存原有异常端口

    GumDarwinModule *dyld;                  // dyld 模块信息
    FridaDyldFlavor dyld_flavor;            // V4+ 还是 V3-

    FridaBreakpoint breakpoints[4];         // 硬件断点
    FridaBreakpointPhase breakpoint_phase;  // 当前断点阶段
};
```

### 17.3.1 dyld 断点追踪

Frida 需要在目标进程的 dyld（动态链接器）执行过程中设置断点，精确控制加载流程：

```
┌─────────────────────────────────────────────┐
│        Spawn 断点阶段（简化版）              │
├─────────────────────────────────────────────┤
│                                             │
│  DETECT_FLAVOR                              │
│  └─> 判断 dyld 版本（V4+ 还是 V3-）         │
│                                             │
│  [V4+ 路径]                                 │
│  SET_LIBDYLD_INITIALIZE_CALLER_BREAKPOINT   │
│  └─> 在 libdyld 初始化调用处设断点           │
│  LIBSYSTEM_INITIALIZED                      │
│  └─> libSystem 已初始化                      │
│                                             │
│  [V3- 路径]                                 │
│  SET_HELPERS                                │
│  └─> 设置 dyld helpers                      │
│  DLOPEN_LIBC                                │
│  └─> 断点在 dlopen libc 处                   │
│  DLOPEN_BOOTSTRAPPER                        │
│  └─> 加载引导程序                            │
│                                             │
│  [共同路径]                                  │
│  CF_INITIALIZE                              │
│  └─> 等待 CoreFoundation 初始化              │
│  CLEANUP                                    │
│  └─> 清理断点                               │
│  DONE                                       │
│  └─> 控制权交给 Frida                        │
│                                             │
└─────────────────────────────────────────────┘
```

这个过程就像在跑步比赛中每隔一段距离设置一个检查站——选手（进程）每到一个检查站就停下来，裁判（Frida）确认没问题后才放行。

## 17.4 Fruitjector——Darwin 注入器

`Fruitjector`（"水果注入器"，因为苹果嘛）是 Darwin 平台的注入器实现：

```vala
// 简化自 fruitjector.vala
public sealed class Fruitjector : Object, Injector {
    public DarwinHelper helper { get; construct; }

    public async uint inject_library_file(uint pid, string path,
            string entrypoint, string data) {
        var id = yield helper.inject_library_file(pid, path,
            entrypoint, data);
        pid_by_id[id] = pid;
        return id;
    }

    public async uint inject_library_resource(uint pid,
            AgentResource resource, ...) {
        // 优先尝试 mmap 方式
        var blob = yield helper.try_mmap(resource.blob);
        if (blob == null)
            return yield inject_library_file(pid,
                resource.get_file().path, ...);

        // mmap 成功，使用内存映射注入
        return yield helper.inject_library_blob(pid,
            resource.name, blob, ...);
    }
}
```

## 17.5 GumDarwinModule——Mach-O 模块解析

Linux 有 ELF，Darwin 有 Mach-O。`GumDarwinModule` 负责解析 Mach-O 文件格式：

```
┌──────────────────────────────────────┐
│          Mach-O 文件结构              │
├──────────────────────────────────────┤
│  Mach-O Header                       │
│  (magic, cputype, filetype)          │
├──────────────────────────────────────┤
│  Load Commands                       │
│  ├── LC_SEGMENT_64 (__TEXT)          │
│  ├── LC_SEGMENT_64 (__DATA)          │
│  ├── LC_DYLD_INFO_ONLY              │
│  ├── LC_SYMTAB                       │
│  ├── LC_DYSYMTAB                     │
│  ├── LC_LOAD_DYLIB (依赖库)          │
│  ├── LC_CODE_SIGNATURE              │
│  └── LC_DYLD_CHAINED_FIXUPS         │
├──────────────────────────────────────┤
│  __TEXT Segment                       │
│  ├── __text (代码)                   │
│  ├── __stubs (PLT桩)                 │
│  └── __stub_helper                   │
├──────────────────────────────────────┤
│  __DATA Segment                      │
│  ├── __la_symbol_ptr (惰性符号)       │
│  ├── __got (全局偏移表)               │
│  └── __objc_* (ObjC 元数据)          │
├──────────────────────────────────────┤
│  Code Signature                      │
└──────────────────────────────────────┘
```

`GumDarwinMapper`（位于 `gum/backend-darwin/gumdarwinmapper.c`）更进一步，它能在内存中重建一个 Mach-O 模块的完整映射：

```c
// 简化自 gumdarwinmapper.c
struct GumDarwinMapper {
    gchar *name;
    GumDarwinModule *module;
    GumDarwinModuleResolver *resolver;

    gsize vm_size;              // 虚拟内存大小
    gpointer runtime;          // 运行时代码
    GumAddress runtime_address;

    // Chained fixups 支持（现代 dyld）
    GumAddress process_chained_fixups;
    GumAddress chained_symbols_vector;

    // TLV (Thread Local Variables) 支持
    GumAddress tlv_get_addr_addr;
    GumAddress tlv_area;
};
```

GumDarwinMapper 就像一个"模块搬运工"，它能把一个 dylib 从磁盘搬到目标进程的内存中，处理好所有的重定位和符号绑定，让它可以直接运行。

## 17.6 代码签名的挑战

Apple 平台上最大的障碍之一是**代码签名**。在 iOS 上，所有可执行代码必须经过签名验证。这对 Frida 来说是个大问题，因为注入的代码显然不是由 Apple 签名的。

### 17.6.1 PolicySoftener——策略软化

Frida 通过 `PolicySoftener` 接口来应对不同越狱环境下的策略限制：

```vala
// 简化自 policy-softener.vala
public interface PolicySoftener : Object {
    public abstract void soften(uint pid) throws Error;
    public abstract void retain(uint pid) throws Error;
    public abstract void release(uint pid);
    public abstract void forget(uint pid);
}

// 不同越狱方案有不同的实现
// 选择逻辑：
if (InternalIOSTVOSPolicySoftener.is_available())
    softener = new InternalIOSTVOSPolicySoftener();
else if (ElectraPolicySoftener.is_available())
    softener = new ElectraPolicySoftener();
else if (Unc0verPolicySoftener.is_available())
    softener = new Unc0verPolicySoftener();
else
    softener = new IOSTVOSPolicySoftener();
```

### 17.6.2 内存限制软化

在 iOS 上，系统对每个进程的内存使用有严格限制。注入 Frida agent 会增加内存占用，可能触发系统杀掉进程。PolicySoftener 会临时放宽这些限制：

```vala
// 简化自 policy-softener.vala
protected virtual ProcessEntry perform_softening(uint pid) {
    MemlimitProperties? saved_limits = null;

    if (!DarwinHelperBackend.is_application_process(pid)) {
        // 保存当前内存限制，然后设置为无限制
        saved_limits = try_commit_memlimit_properties(
            pid, MemlimitProperties.without_limits());
    }

    var entry = new ProcessEntry(pid, saved_limits);
    process_entries[pid] = entry;
    return entry;
}

// 20秒后自动恢复原始限制
var expiry = new TimeoutSource.seconds(20);
expiry.set_callback(() => {
    forget(pid);
    return false;
});
```

## 17.7 DTrace 与 Spawn 监控

在 macOS 上，Frida 使用 DTrace 来实现进程 spawn 的监控（类似 Linux 上的 eBPF）：

```vala
// 简化自 frida-helper-backend.vala
construct {
    dtrace_agent = DTraceAgent.try_open();
    if (dtrace_agent != null) {
        dtrace_agent.spawn_added.connect(on_dtrace_agent_spawn_added);
        dtrace_agent.spawn_removed.connect(on_dtrace_agent_spawn_removed);
    }
}

public async void enable_spawn_gating() {
    get_dtrace_agent().enable_spawn_gating();
}
```

DTrace 是 macOS 内置的动态跟踪框架，Frida 利用它来监视系统中新进程的创建，实现 spawn gating 功能。

## 17.8 本章小结

- Darwin 后端的核心是 **Mach 端口**，通过 task port 可以完全控制另一个进程
- **注入** 分两阶段：先在 Mach 线程中创建 POSIX 线程，再由 POSIX 线程执行 dlopen
- **Spawn 控制** 通过异常端口和硬件断点实现，需要精确跟踪 dyld 的初始化流程
- **Fruitjector** 是 Darwin 平台的注入器，支持文件注入和内存映射注入
- **GumDarwinMapper** 能在目标进程中完整重建 Mach-O 模块，处理符号绑定和重定位
- **代码签名** 是 Apple 平台特有的挑战，Frida 通过 PolicySoftener 适配不同越狱环境
- **DTrace** 在 macOS 上提供进程监控能力，用于实现 spawn gating

## 讨论问题

1. 为什么 Frida 在 Darwin 上的注入需要两个阶段（Mach 线程 -> POSIX 线程），而不能直接在 Mach 线程上执行 dlopen？

2. dyld V4+ 和 V3- 的区别对 Frida 意味着什么？为什么需要在运行时检测版本？

3. 在没有越狱的 iOS 设备上，Frida 面临哪些根本性的限制？PolicySoftener 能否完全解决代码签名的问题？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
