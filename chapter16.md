# 第16章：Linux 后端——ptrace 与 ELF 的世界

> 你有没有想过，当你在 Linux 上运行 `frida -p 1234` 的时候，Frida 到底是怎么把代码"塞"进另一个进程的？在 Linux 这个开放的世界里，内核给了我们一把万能钥匙——ptrace。让我们打开这扇门，看看 Frida 在 Linux 上的全部秘密。

## 16.1 Linux 后端的整体架构

```
┌─────────────────────────────────────────────┐
│           LinuxHostSession                   │
│  (管理本地 Linux 主机上的所有调试会话)         │
├──────────┬──────────────┬───────────────────┤
│ Linjector│ SpawnGater   │ ProcessEnumerator  │
│ (注入器) │ (eBPF拦截)   │ (进程枚举)          │
├──────────┴──────────────┴───────────────────┤
│         LinuxHelperBackend                   │
│  (fork/ptrace/注入的核心实现)                 │
├─────────────────────────────────────────────┤
│   Linux Kernel: ptrace, /proc, eBPF         │
└─────────────────────────────────────────────┘
```

打个比方，`LinuxHostSession` 就像一个指挥中心，`Linjector` 是执行注入任务的特种兵，而 `LinuxHelperBackend` 是特种兵手里的装备库——里面有 ptrace、fork 这些底层武器。

## 16.2 ptrace——Linux 上的万能调试接口

### 16.2.1 spawn 的实现：fork + ptrace + execve

当你调用 `frida.spawn("/path/to/app")` 时，Frida 内部发生了这些事情：

```c
// 简化自 frida-helper-backend.vala 中的 spawn 实现
pid = fork();
if (pid == 0) {
    setsid();                    // 创建新会话
    ptrace(PTRACE_TRACEME);      // 告诉内核："我愿意被父进程跟踪"
    raise(SIGSTOP);              // 停下来等待父进程
    execve(path, argv, envp);    // 替换为目标程序
}
// 父进程
wait_for_signal(pid, SIGSTOP);   // 等待子进程停在 SIGSTOP
ptrace(PTRACE_CONT, pid);       // 让子进程继续执行
wait_for_signal(pid, SIGTRAP);   // 等待 execve 触发的 SIGTRAP
// 现在目标程序已加载但还没开始运行，可以注入了！
```

这个流程就像导演喊"预备——开始——暂停！"：子进程 fork 出来后先用 PTRACE_TRACEME 声明自己愿意被跟踪，然后 raise(SIGSTOP) 停下来。父进程收到信号后让子进程继续，子进程执行 execve 时会自动触发 SIGTRAP，此时目标程序已加载到内存但还没开始运行——正好是注入的最佳时机。

### 16.2.2 syscall 拦截：等待安全状态

注入代码不能在任意时刻进行。Frida 的做法是等待目标进入"安全"的系统调用：

```c
// 简化自 frida-helper-backend-glue.c
gboolean _frida_syscall_satisfies(gint syscall_id, FridaSyscallMask mask) {
    switch (syscall_id) {
        case __NR_read: case __NR_readv:
            return (mask & SYSCALL_MASK_READ) != 0;
        case __NR_poll: case __NR_epoll_wait:
            return (mask & SYSCALL_MASK_POLL_LIKE) != 0;
        case __NR_futex:
            return (mask & SYSCALL_MASK_FUTEX) != 0;
        case __NR_accept:
            return (mask & SYSCALL_MASK_ACCEPT) != 0;
    }
    return FALSE;
}
```

read、poll、accept 这类调用意味着进程正在"等待"——就像一个人在咖啡厅里发呆，这时候你去找他搭话，远比他在高速公路上飙车时安全得多。

### 16.2.3 exec transition——跟踪程序替换

Frida 还能处理 exec 转换。当进程调用 execve 替换自身时，Frida 需要检测并重新建立控制：

```vala
// 简化自 frida-helper-backend.vala
public async void prepare_exec_transition(uint pid) {
    var session = yield ExecTransitionSession.open(pid);
    exec_transitions[pid] = session;
    update_process_status(pid, EXEC_PENDING);
}

public async void await_exec_transition(uint pid) {
    yield exec_transitions[pid].wait_for_exec(cancellable);
    // exec 完成后重新建立监控
}
```

这在监控通过 shell 脚本启动的程序时特别有用——shell 先 fork，子进程再 exec 成目标程序。

## 16.3 Linjector——Linux 注入器

`Linjector`（"L"代表 Linux）的注入分五步：

```
┌─────────────────────────────────────────────────┐
│              Linjector 注入五步法                 │
├─────────────────────────────────────────────────┤
│  1. ptrace(ATTACH) 附加到目标进程                │
│  2. 在目标地址空间分配内存                        │
│  3. 将 agent .so 内容写入目标进程                │
│  4. 修改寄存器，让目标执行 dlopen 加载 agent      │
│  5. agent 加载后调用指定的入口函数                │
└─────────────────────────────────────────────────┘
```

Frida 支持使用 memfd_create 来避免文件系统操作：

```vala
// 简化自 linjector.vala
if (MemoryFileDescriptor.is_supported()) {
    FileDescriptor fd = MemoryFileDescriptor.from_bytes(name, blob);
    return yield inject_library_fd(pid, fd_stream, ...);
}
// 回退到临时文件方式
var file = new TemporaryFile.from_stream(name, blob_stream, tempdir);
return yield inject_library_file(pid, file.path, ...);
```

memfd 就像一个"虚拟U盘"——数据只存在于内存中，不会留下文件痕迹。

## 16.4 /proc 文件系统——Linux 的透明窗口

Frida 大量使用 /proc 文件系统来获取进程信息。`ProcMapsSnapshot` 解析 `/proc/<pid>/maps` 获取内存映射：

```vala
// 简化自 proc-maps.vala
public static ProcMapsSnapshot from_pid(uint32 pid) {
    var snap = new ProcMapsSnapshot();
    var it = ProcMapsIter.for_pid(pid);  // 读取 /proc/<pid>/maps
    while (it.next()) {
        var m = new Mapping();
        m.start = it.start_address;
        m.end = it.end_address;
        m.readable = it.flags[0] == 'r';
        m.executable = it.flags[2] == 'x';
        m.path = it.path;
        maps.add(m);
    }
    return snap;
}
```

/proc/PID/maps 就像一份详细的"地产登记簿"，记录了进程的每一块内存是谁的、能做什么。遍历 /proc 下的数字目录就能枚举所有进程。

## 16.5 Helper 进程架构

Frida 使用独立的 Helper 进程来完成 ptrace 等敏感操作：

```
┌──────────────────┐     D-Bus IPC      ┌──────────────────────┐
│   Frida Client   │<──────────────────>│   frida-helper       │
│  (你的脚本进程)   │                    │  (特权辅助进程)        │
└──────────────────┘                    └──────────┬───────────┘
                                                   │ ptrace
                                                   v
                                        ┌──────────────────────┐
                                        │    Target Process     │
                                        └──────────────────────┘
```

两个核心原因：**权限隔离**（Helper 可以以 root 权限运行）和**稳定性**（Helper 崩溃不影响客户端）。

## 16.6 eBPF 集成——现代化的进程监控

### 16.6.1 SpawnGater——进程创建拦截

SpawnGater 使用 eBPF 程序拦截新进程创建，通过 Ringbuf 将事件从内核传递到用户空间：

```vala
// 简化自 spawn-gater.vala
public void start() throws Error {
    var obj = BpfObject.open("spawn-gater.elf",
        Data.HelperBackend.get_spawn_gater_elf_blob().data);
    events_reader = new BpfRingbufReader(obj.maps.get_by_name("events"));
    obj.load();
    foreach (var program in obj.programs)
        links.add(program.attach());  // 附加到内核钩子
}
```

### 16.6.2 ActivitySampler——性能采样

ActivitySampler 为每个 CPU 核心创建 perf event，通过 eBPF 采样目标进程的调用栈，就像"交通摄像头"定时拍快照。

## 16.7 ELF 模块处理

在 Linux 上，可执行文件和共享库使用 ELF（Executable and Linkable Format）格式。Frida 的 `GumElfModule`（位于 `gum/backend-linux/gummodule-linux.c`）负责解析 ELF 文件：

```
┌──────────────────────────────────────┐
│            ELF 文件结构               │
├──────────────────────────────────────┤
│  ELF Header (魔数、架构、入口点)      │
├──────────────────────────────────────┤
│  Program Headers (LOAD/DYNAMIC等)    │
├──────────────────────────────────────┤
│  .text     (代码段)                  │
│  .dynsym   (动态符号表)              │
│  .dynstr   (动态字符串表)             │
│  .plt/.got (链接/偏移表)             │
├──────────────────────────────────────┤
│  Section Headers                     │
└──────────────────────────────────────┘
```

Frida 需要解析 ELF 来完成三件事：找到 dlopen/dlsym 等函数的地址、枚举模块中的导出符号、确定模块的加载基址和内存布局。这些信息对于注入和 hook 都至关重要。

## 16.8 本章小结

- Linux 后端的核心武器是 **ptrace** 系统调用，提供进程跟踪、内存读写、寄存器操作
- **spawn** 通过 fork + ptrace(TRACEME) + execve 实现，在 SIGTRAP 处暂停目标
- **注入** 通过 Linjector 完成，本质是在目标进程中执行 dlopen 加载 agent .so
- **/proc** 文件系统用于枚举进程和解析内存映射
- **Helper 进程** 提供权限隔离和稳定性保障
- **eBPF** 带来现代化的内核级监控，SpawnGater 拦截进程创建，ActivitySampler 采样活动
- **memfd** 优化让注入完全在内存中完成，不留磁盘痕迹

## 讨论问题

1. ptrace 的 PTRACE_TRACEME 和 PTRACE_ATTACH 有什么区别？在什么场景下 Frida 会使用 PTRACE_ATTACH？

2. eBPF 相比传统的 ptrace 监控有什么优势和局限？为什么 Frida 同时使用两种技术？

3. memfd_create 在较老的 Linux 内核上不可用，Frida 的回退方案（临时文件）有什么潜在的安全风险？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
