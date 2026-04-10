# 第17章：Darwin 后端——Mach 端口与 XPC

> 如果说 Linux 是一间门窗大开的房子，那 Apple 的平台就是一座层层设防的堡垒。在 macOS 和 iOS 上，Frida 不能像 Linux 那样直接用 ptrace 为所欲为——它必须学会使用 Mach 端口、理解代码签名、应对策略限制。让我们来看看 Frida 是如何在 Apple 的地盘上施展身手的。

## 17.1 Darwin 后端的整体架构

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

每个 Darwin 进程都有一个 task port，拿到这个端口就相当于拿到了进程的"遥控器"。通过它你可以：

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
│  task_threads()        - 枚举所有线程         │
└─────────────────────────────────────────────┘
```

这就像拿到了一个人的银行账号加密码——存钱、取钱、转账、查余额，几乎什么都能做。

### 17.2.1 注入的 Mach 端口操作

```c
// 简化自 frida-helper-backend-glue.m
struct FridaInjectInstance {
    guint pid;
    mach_port_t task;                    // 目标进程的 task port
    mach_vm_address_t payload_address;   // 注入代码地址
    mach_vm_size_t payload_size;
    FridaAgentContext *agent_context;    // Agent 上下文
    mach_port_t thread;                  // 注入线程
};
```

注入的关键步骤如下：

```
┌─────────────┐
│  1. 获取     │  task_for_pid(pid) -> task_port
│  task port   │
├─────────────┤
│  2. 分配     │  mach_vm_allocate(task, &addr, size)
│  远程内存    │
├─────────────┤
│  3. 写入     │  mach_vm_write(task, addr, payload, size)
│  注入代码    │
├─────────────┤
│  4. 设置     │  mach_vm_protect(task, addr, size, RX)
│  内存权限    │
├─────────────┤
│  5. 创建     │  thread_create_running(task, ...)
│  远程线程    │
├─────────────┤
│  6. 监控     │  dispatch_source 监控线程完成
│  线程执行    │
└─────────────┘
```

### 17.2.2 AgentContext——两阶段执行

注入代码分两个阶段：先在 Mach 线程中创建 POSIX 线程，再由 POSIX 线程执行 dlopen。为什么这么绕？因为 Mach 线程是内核级线程，缺少 TLS 等用户态基础设施：

```c
// 简化自 frida-helper-backend-glue.m
struct FridaAgentContext {
    // Mach 线程阶段
    GumAddress mach_task_self_impl;
    GumAddress pthread_create_from_mach_thread_impl;
    // POSIX 线程阶段
    GumAddress dlopen_impl;        // 加载 agent dylib
    GumAddress dlsym_impl;         // 查找入口函数
    GumAddress dlclose_impl;
    // 数据存储
    gchar dylib_path_storage[256];
    gchar entrypoint_name_storage[256];
    gchar entrypoint_data_storage[4096];
};
```

## 17.3 Spawn 控制——断点与 dyld

在 Darwin 上 spawn 使用 `posix_spawn` 配合异常端口。Frida 需要在 dyld（动态链接器）的执行过程中设置硬件断点，精确控制加载流程：

```
┌─────────────────────────────────────────────┐
│        Spawn 断点阶段（简化版）              │
├─────────────────────────────────────────────┤
│  DETECT_FLAVOR  -> 判断 dyld 版本            │
│  [V4+] LIBSYSTEM_INITIALIZED               │
│  [V3-] SET_HELPERS -> DLOPEN_LIBC           │
│  [共同] CF_INITIALIZE -> CLEANUP -> DONE    │
└─────────────────────────────────────────────┘
```

源码中 `FridaSpawnInstance` 维护了最多 4 个硬件断点，每到一个检查站（断点阶段）就暂停进程，Frida 确认没问题后才放行——就像跑步比赛中每隔一段距离设置检查站。

Frida 必须区分 dyld V4+（现代 macOS/iOS）和 V3-（旧版），因为两者的初始化路径完全不同。

## 17.4 Fruitjector——Darwin 注入器

`Fruitjector`（"水果注入器"）是 Darwin 平台的注入器，它优先尝试 mmap 方式，回退到文件方式：

```vala
// 简化自 fruitjector.vala
public async uint inject_library_resource(uint pid, AgentResource resource, ...) {
    var blob = yield helper.try_mmap(resource.blob);
    if (blob == null)
        return yield inject_library_file(pid, resource.get_file().path, ...);
    return yield helper.inject_library_blob(pid, resource.name, blob, ...);
}
```

## 17.5 GumDarwinModule 与 GumDarwinMapper

`GumDarwinModule` 解析 Mach-O 格式（Darwin 的可执行文件格式），`GumDarwinMapper` 更进一步，能在目标进程中完整重建 Mach-O 模块：

```c
// 简化自 gumdarwinmapper.c
struct GumDarwinMapper {
    GumDarwinModule *module;
    GumDarwinModuleResolver *resolver;
    gsize vm_size;
    GumAddress process_chained_fixups;  // 现代 dyld 的链式修复
    GumAddress tlv_get_addr_addr;       // TLV 支持
};
```

它就像一个"模块搬运工"，把 dylib 从磁盘搬到目标进程内存中，处理好所有重定位和符号绑定。

Mach-O 与 ELF 的一个重要区别是 **Chained Fixups**（链式修复）。现代 macOS/iOS 的 dyld 使用这种紧凑格式来描述需要修复的指针。GumDarwinMapper 必须正确处理这些修复，否则加载的模块无法正常运行。

另一个关键点是 **Objective-C 元数据**。Darwin 上大量使用 ObjC，Mach-O 文件中包含 `__objc_classlist`、`__objc_methnames` 等 section。Frida 的 `GumObjcApiResolver`（位于 `gum/backend-darwin/gumobjcapiresolver.c`）专门用于解析和搜索 ObjC 的类和方法。

## 17.6 代码签名与 PolicySoftener

Apple 平台最大的障碍之一是**代码签名**。在 iOS 上，所有可执行代码必须经过签名验证。Frida 通过 `PolicySoftener` 接口应对不同越狱环境：

```vala
// 简化自 policy-softener.vala
// 自动选择合适的实现
if (InternalIOSTVOSPolicySoftener.is_available())
    softener = new InternalIOSTVOSPolicySoftener();
else if (ElectraPolicySoftener.is_available())
    softener = new ElectraPolicySoftener();
else if (Unc0verPolicySoftener.is_available())
    softener = new Unc0verPolicySoftener();
else
    softener = new IOSTVOSPolicySoftener();
```

PolicySoftener 还会临时放宽 iOS 的内存限制，防止注入 agent 后因内存占用过大而被系统杀掉（jetsam）。它保存原始限制，在 20 秒后自动恢复：

```vala
// 简化自 policy-softener.vala
protected virtual ProcessEntry perform_softening(uint pid) {
    MemlimitProperties? saved_limits = null;
    if (!DarwinHelperBackend.is_application_process(pid)) {
        saved_limits = try_commit_memlimit_properties(
            pid, MemlimitProperties.without_limits());
    }
    var entry = new ProcessEntry(pid, saved_limits);
    // 20秒后自动恢复原始限制
    var expiry = new TimeoutSource.seconds(20);
    expiry.set_callback(() => { forget(pid); return false; });
    return entry;
}
```

注意 PolicySoftener 有多个实现——对应不同的越狱方案（Electra、unc0ver 等），因为每种越狱对系统策略的修改方式不同。在非越狱设备上只能使用 NullPolicySoftener（什么都不做）。

## 17.7 DTrace 与 Spawn 监控

在 macOS 上，Frida 使用 DTrace（内置的动态跟踪框架）实现进程 spawn 监控，类似 Linux 上的 eBPF。`DTraceAgent` 在 Helper 后端构造时初始化，当启用 spawn gating 时，它监视系统中新进程的创建。

## 17.8 本章小结

- Darwin 后端的核心是 **Mach 端口**，通过 task port 可以完全控制另一个进程
- **注入** 分两阶段：Mach 线程创建 POSIX 线程，POSIX 线程执行 dlopen
- **Spawn 控制** 通过异常端口和硬件断点实现，需要精确跟踪 dyld 初始化流程
- **GumDarwinMapper** 能在目标进程中完整重建 Mach-O 模块
- **代码签名** 是 Apple 平台特有的挑战，PolicySoftener 适配不同越狱环境
- **DTrace** 在 macOS 上提供进程监控能力

## 讨论问题

1. 为什么注入需要两个阶段（Mach 线程 -> POSIX 线程），而不能直接在 Mach 线程上执行 dlopen？

2. dyld V4+ 和 V3- 的区别对 Frida 意味着什么？为什么需要在运行时检测版本？

3. 在没有越狱的 iOS 设备上，Frida 面临哪些根本性的限制？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
