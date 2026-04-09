# 第12章：进程注入——打入目标的第一步

> 你有没有想过，当你在终端敲下 `frida -p 1234` 的时候，Frida 是怎么把自己的代码"塞"进一个正在运行的进程里的？这就像一个特工要潜入一栋戒备森严的大楼——他不能从正门走，他需要找到一条隐秘的通道，悄悄进入，然后在里面建立自己的据点。

## 12.1 什么是进程注入？

在操作系统的世界里，每个进程都有自己独立的地址空间，就好比每户人家都有自己的房间，门是锁着的。进程注入，简单来说，就是把一段代码（通常是一个动态库）加载到目标进程的地址空间里，让它在那里执行。

用一个生活中的比喻来理解：

```
你的进程（Frida 客户端）       目标进程（被分析的程序）
┌─────────────────────┐       ┌─────────────────────┐
│                     │       │                     │
│  "我要派特工进去"    │ ───── │  "正常运行中..."     │
│                     │  注入  │                     │
│                     │       │  ┌───────────────┐  │
│                     │       │  │ Frida Agent    │  │
│                     │       │  │ (特工已就位)    │  │
│                     │       │  └───────────────┘  │
└─────────────────────┘       └─────────────────────┘
```

特工要进入大楼，需要几个关键步骤：

1. **找到入口** -- 利用操作系统提供的调试机制（比如 ptrace）
2. **打开门锁** -- 暂停目标进程，获取控制权
3. **携带装备** -- 把 Agent 动态库放到目标能访问的地方
4. **激活特工** -- 让目标进程加载并执行这个动态库

## 12.2 平台差异：每个系统有不同的"入口"

不同操作系统提供了不同的注入手段，就像不同大楼有不同的安保系统：

```
┌──────────────────────────────────────────────────────────┐
│                   Frida 注入机制总览                       │
├────────────┬─────────────────────────────────────────────┤
│  平台       │  核心机制                                   │
├────────────┼─────────────────────────────────────────────┤
│  Linux     │  ptrace + dlopen                            │
│  macOS     │  task_for_pid + mach_vm_* + thread_create   │
│  Windows   │  CreateRemoteThread + LoadLibrary           │
│  Android   │  ptrace + dlopen (与 Linux 类似)             │
│  iOS       │  通常用 Gadget 模式（越狱环境用 substrate）   │
├────────────┼─────────────────────────────────────────────┤
│  通用方案   │  Gadget 模式（不需要注入，第15章详述）        │
└────────────┴─────────────────────────────────────────────┘
```

虽然每个平台细节不同，但核心思路是一致的：利用操作系统的调试接口，在目标进程中执行一个"加载动态库"的操作。今天我们重点分析 Linux 平台的实现。

## 12.3 Linux 注入：Linjector 的故事

在 Frida 的源码中，Linux 注入的核心类是 `Linjector`，位于 `frida-core/src/linux/linjector.vala`。我们来看它的结构：

```vala
// 简化后的 Linjector 结构
public sealed class Linjector : Object, Injector {
    public LinuxHelper helper;      // 实际干活的助手进程
    public TemporaryDirectory tempdir;  // 临时文件目录

    private HashMap<uint, uint> pid_by_id;     // 注入 ID -> 目标 PID
    private HashMap<uint, TemporaryFile> blob_file_by_id;  // blob 临时文件

    // 核心注入方法
    public async uint inject_library_file (uint pid, string path,
        string entrypoint, string data);
    public async uint inject_library_blob (uint pid, Bytes blob,
        string entrypoint, string data);
    public async uint inject_library_fd (uint pid, UnixInputStream library_so,
        string entrypoint, string data);
}
```

注意到了吗？Linjector 本身并不直接操作 ptrace，它把脏活累活都委托给了一个叫 `LinuxHelper` 的对象。这是一个非常聪明的设计。

## 12.4 Helper 进程模式：为什么需要"中间人"？

这里有一个很多人忽略的细节：Frida 并不是直接从主进程去 ptrace 目标的，而是启动了一个独立的 Helper 进程来完成注入。为什么要多此一举呢？

想象一下这个场景：你是一个快递员（Frida 主进程），要往一个小区（目标进程）里送包裹。但小区保安（操作系统权限检查）只认住户和物业人员。怎么办？你找了一个物业的朋友（Helper 进程）帮你送进去。

```
┌────────────────────────────────────────────────────┐
│                  注入架构图                          │
│                                                    │
│  ┌──────────────┐    ┌──────────────┐              │
│  │ Frida 主进程  │    │ Helper 进程  │              │
│  │              │    │  (特权助手)   │              │
│  │  Linjector   │───>│              │              │
│  │              │    │  ptrace()    │              │
│  └──────────────┘    │  dlopen()    │              │
│                      │              │              │
│                      └──────┬───────┘              │
│                             │                      │
│                             v                      │
│                      ┌──────────────┐              │
│                      │  目标进程     │              │
│                      │              │              │
│                      │ ┌──────────┐ │              │
│                      │ │  Agent   │ │              │
│                      │ │  .so     │ │              │
│                      │ └──────────┘ │              │
│                      └──────────────┘              │
└────────────────────────────────────────────────────┘
```

Helper 进程模式有几个好处：

1. **权限隔离** -- Helper 可以以 root 权限运行，而 Frida 主进程不需要
2. **架构适配** -- 32 位和 64 位目标可以用不同架构的 Helper（factory32/factory64）
3. **稳定性** -- 如果注入过程出了问题，崩溃的是 Helper 而不是 Frida 主进程

从 `LinuxHelperProcess` 的源码可以看到这种双架构设计：

```vala
// 简化示意
public sealed class LinuxHelperProcess : Object, LinuxHelper {
    private HelperFactory? factory32;  // 32位 Helper
    private HelperFactory? factory64;  // 64位 Helper

    // 根据目标进程的架构选择合适的 Helper
    private async LinuxHelper obtain_for_pid (uint pid) {
        var cpu_type = cpu_type_from_pid (pid);
        return yield obtain_for_cpu_type (cpu_type);
    }
}
```

## 12.5 注入流程详解

让我们把整个注入过程串起来。当你调用 `inject_library_file` 时，实际发生了以下步骤：

```
时间线 ──────────────────────────────────────────────>

[1] Linjector.inject_library_file()
    │
    ├── 打开 .so 文件，获取文件描述符
    │
    v
[2] Linjector.inject_library_fd()
    │
    ├── 分配注入 ID
    ├── 记录 pid_by_id 映射
    │
    v
[3] helper.inject_library()    // 委托给 Helper 进程
    │
    ├── [3a] ptrace(ATTACH, pid)        暂停目标进程
    ├── [3b] 在目标进程中分配内存        mmap 远程调用
    ├── [3c] 写入引导代码和参数          写入 .so 路径等
    ├── [3d] 创建远程线程执行 dlopen     加载 Agent
    ├── [3e] dlopen 调用 entrypoint     通常是 frida_agent_main
    ├── [3f] ptrace(DETACH, pid)        恢复目标进程
    │
    v
[4] Agent 开始运行（下一章详述）
```

这里有个有趣的细节：Frida 支持多种传递动态库的方式。我们从源码中可以看到三种：

- **inject_library_file** -- 传文件路径，目标进程通过路径加载
- **inject_library_blob** -- 传二进制数据，先写到临时文件或 memfd 再加载
- **inject_library_fd** -- 直接传文件描述符，最灵活的方式

特别值得注意的是 `MemoryFileDescriptor`（memfd）的使用：

```vala
// 简化示意
if (MemoryFileDescriptor.is_supported ()) {
    // 现代 Linux 内核支持 memfd_create
    // 不需要在磁盘上创建临时文件，更隐蔽
    FileDescriptor fd = MemoryFileDescriptor.from_bytes (name, blob);
    return yield inject_library_fd (pid, fd, entrypoint, data);
} else {
    // 回退方案：写入临时文件
    var file = new TemporaryFile (name, blob, tempdir);
    return yield inject_library_file (pid, file.path, entrypoint, data);
}
```

memfd 是 Linux 3.17+ 引入的特性，允许创建一个只存在于内存中的匿名文件。使用 memfd 有两个好处：一是更快（不需要磁盘 IO），二是更隐蔽（不会在文件系统留下痕迹）。

## 12.6 安全挑战与对抗

进程注入本质上是一种"越权"操作，操作系统自然会设置各种障碍：

```
┌─────────────────────────────────────────────────┐
│              安全机制与应对策略                    │
├──────────────────┬──────────────────────────────┤
│  安全机制         │  Frida 的应对                 │
├──────────────────┼──────────────────────────────┤
│  ptrace 限制      │  Helper 进程以 root 运行      │
│  (YAMA ptrace     │  或调整 ptrace_scope 设置     │
│   scope)          │                              │
├──────────────────┼──────────────────────────────┤
│  SELinux          │  在某些模式下需要宽松策略      │
│                  │  Gadget 模式可绕过             │
├──────────────────┼──────────────────────────────┤
│  文件系统权限     │  调整临时文件/目录权限         │
│                  │  使用 memfd 避免文件系统       │
├──────────────────┼──────────────────────────────┤
│  代码签名         │  iOS/macOS 上通常用 Gadget    │
│                  │  而非运行时注入               │
├──────────────────┼──────────────────────────────┤
│  seccomp          │  Helper 在 seccomp 之前注入   │
│                  │  或使用允许的系统调用          │
└──────────────────┴──────────────────────────────┘
```

从 Linjector 的源码中我们还能看到一些细节处理：

```vala
// 确保临时目录权限正确
private void ensure_tempdir_prepared () {
    if (did_prep_tempdir) return;
    if (tempdir.is_ours)
        adjust_directory_permissions (tempdir.path);
    did_prep_tempdir = true;
}
```

这些看似简单的权限调整，是实际工程中不可或缺的细节。很多注入失败的原因，往往就是文件权限不对。

## 12.7 注入后的清理

注入不是一锤子买卖。当 Agent 完成任务或者用户断开连接时，需要清理现场：

```vala
// 当注入完成或 Agent 卸载时的回调
private void on_uninjected (uint id) {
    pid_by_id.unset (id);           // 移除 PID 映射
    blob_file_by_id.unset (id);     // 删除临时文件引用
    uninjected (id);                 // 发送信号通知上层
}
```

还有一个 `demonitor` 方法，允许在不卸载 Agent 的情况下停止监控。这在某些场景下很有用——比如你希望 Agent 继续运行，但不再需要 Frida 端保持连接。

## 本章小结

- **进程注入**是 Frida 动态插桩的第一步，核心思路是利用操作系统调试接口在目标进程中加载动态库
- Linux 上的注入通过 **Linjector** 类实现，它委托 **LinuxHelper** 进程完成实际的 ptrace + dlopen 操作
- **Helper 进程模式**提供了权限隔离、架构适配和稳定性保障
- 支持多种库传递方式：文件路径、二进制 blob、文件描述符，其中 **memfd** 是最现代且隐蔽的方式
- 不同平台有不同的安全挑战，Frida 针对每种都有对应策略

## 思考题

1. 为什么 Frida 在 Linux 上选择了 Helper 进程的架构，而不是直接在主进程中调用 ptrace？如果去掉 Helper 层会有什么问题？
2. memfd_create 相比临时文件有哪些优势？在什么场景下可能无法使用 memfd？
3. 如果目标进程开启了 seccomp 限制，禁止了 dlopen 相关的系统调用，Frida 还能注入吗？有什么替代方案？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
