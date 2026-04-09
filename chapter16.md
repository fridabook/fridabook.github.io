# 第16章：Linux 后端——ptrace 与 ELF 的世界

> 你有没有想过，当你在 Linux 上运行 `frida -p 1234` 的时候，Frida 到底是怎么把代码"塞"进另一个进程的？在 Linux 这个开放的世界里，内核给了我们一把万能钥匙——ptrace。让我们打开这扇门，看看 Frida 在 Linux 上的全部秘密。

## 16.1 Linux 后端的整体架构

在 Frida 的源码中，Linux 后端主要由以下几个核心文件构成：

```
frida-core/src/linux/
├── linux-host-session.vala    # 主会话管理
├── linjector.vala             # Linux 注入器（Linjector）
├── frida-helper-backend.vala  # Helper 后端逻辑
├── frida-helper-backend-glue.c # C 语言底层胶水代码
├── spawn-gater.vala           # eBPF 进程拦截
├── activity-sampler.vala      # eBPF 活动采样
├── proc-maps.vala             # /proc 内存映射解析
└── symbol-resolver.vala       # 符号解析
```

这些文件的关系可以用一张图来理解：

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

ptrace 是 Linux 内核提供的进程跟踪系统调用。Frida 的 Linux 后端几乎所有关键操作都建立在它之上。

### 16.2.1 spawn 的实现：fork + ptrace + execve

当你调用 `frida.spawn("/path/to/app")` 时，Frida 内部发生了这些事情：

```c
// 简化自 frida-helper-backend.vala 中的 spawn 实现
pid = fork();

if (pid == 0) {
    // 子进程
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

这个流程就像导演喊"预备——开始——暂停！"：

```
┌──────────┐    fork()     ┌──────────┐
│  Frida   │──────────────>│  子进程   │
│  (父进程) │               │          │
└────┬─────┘               └────┬─────┘
     │                          │
     │                     PTRACE_TRACEME
     │                          │
     │                     raise(SIGSTOP)
     │                          │ (暂停)
     │  wait(SIGSTOP)           │
     │<─────────────────────────│
     │                          │
     │  PTRACE_CONT             │
     │─────────────────────────>│
     │                          │
     │                     execve(目标程序)
     │                          │
     │  wait(SIGTRAP)           │ (execve后的陷阱)
     │<─────────────────────────│
     │                          │
     │  此时可以安全注入！        │
```

### 16.2.2 syscall 拦截：等待目标进程进入安全状态

注入代码不能在任意时刻进行。如果目标进程正在执行关键操作，强行注入可能导致崩溃。Frida 的做法是等待目标进入"安全"的系统调用：

```c
// 简化自 frida-helper-backend-glue.c
gboolean _frida_syscall_satisfies(gint syscall_id, FridaSyscallMask mask) {
    switch (syscall_id) {
        case __NR_read:
        case __NR_readv:
            return (mask & SYSCALL_MASK_READ) != 0;
        case __NR_poll:
        case __NR_epoll_wait:
            return (mask & SYSCALL_MASK_POLL_LIKE) != 0;
        case __NR_futex:
            return (mask & SYSCALL_MASK_FUTEX) != 0;
        case __NR_accept:
            return (mask & SYSCALL_MASK_ACCEPT) != 0;
        // ... 更多系统调用
    }
    return FALSE;
}
```

为什么选择这些系统调用？因为 read、poll、accept 这类调用意味着进程正在"等待"——就像一个人在咖啡厅里发呆，这时候你去找他搭话，远比他在高速公路上飙车时安全得多。

### 16.2.3 exec transition：跟踪程序替换

Frida 还能处理 exec 转换——当一个进程调用 execve 替换自身时，Frida 需要检测这个事件并重新建立控制：

```vala
// 简化自 frida-helper-backend.vala
public async void prepare_exec_transition(uint pid) {
    var session = yield ExecTransitionSession.open(pid);
    exec_transitions[pid] = session;
    update_process_status(pid, EXEC_PENDING);
}

public async void await_exec_transition(uint pid) {
    var session = exec_transitions[pid];
    yield session.wait_for_exec(cancellable);
    // exec 完成后重新建立监控
}
```

## 16.3 Linjector——Linux 注入器

`Linjector` 是 Frida 在 Linux 上的注入器实现。它的名字很有趣——"L"代表 Linux，"injector"代表注入器。

### 16.3.1 注入流程

```vala
// 简化自 linjector.vala
public async uint inject_library_fd(uint pid, UnixInputStream library_so,
        string entrypoint, string data) {
    uint id = next_injectee_id++;
    // 委托给 helper 执行底层注入
    yield helper.inject_library(pid, library_so, entrypoint, data, id);
    pid_by_id[id] = pid;
    return id;
}
```

注入的核心思路是：

1. 通过 ptrace 附加到目标进程
2. 在目标进程的地址空间中分配内存
3. 将 agent .so 文件的内容写入目标进程
4. 修改目标进程的寄存器，让它执行 dlopen 加载 agent
5. agent 加载后调用指定的入口函数

### 16.3.2 memfd 优化

Frida 支持使用 Linux 的 memfd_create 来避免文件系统操作：

```vala
// 简化自 linjector.vala
if (MemoryFileDescriptor.is_supported()) {
    // 使用内存文件描述符，不需要写入磁盘
    FileDescriptor fd = MemoryFileDescriptor.from_bytes(name, blob);
    adjust_fd_permissions(fd);
    return yield inject_library_fd(pid, fd_stream, ...);
}

// 回退到临时文件方式
var file = new TemporaryFile.from_stream(name, blob_stream, tempdir);
return yield inject_library_file(pid, file.path, ...);
```

memfd 就像一个"虚拟U盘"——数据只存在于内存中，不会留下文件痕迹。这对于安全敏感的场景特别有用。

## 16.4 /proc 文件系统——Linux 的透明窗口

Linux 的 /proc 文件系统是一个虚拟文件系统，它把内核中的进程信息以文件的形式暴露出来。Frida 大量使用它来获取进程信息。

### 16.4.1 ProcMapsSnapshot——解析内存映射

```vala
// 简化自 proc-maps.vala
public class ProcMapsSnapshot {
    public class Mapping {
        public uint64 start;
        public uint64 end;
        public bool readable;
        public bool writable;
        public bool executable;
        public string path;
    }

    public static ProcMapsSnapshot from_pid(uint32 pid) {
        // 读取 /proc/<pid>/maps 并解析每一行
        // 格式: start-end flags offset dev inode path
        // 例如: 7f1234000-7f1235000 r-xp 00000000 08:01 12345 /lib/libc.so
        var snap = new ProcMapsSnapshot();
        var it = ProcMapsIter.for_pid(pid);
        while (it.next()) {
            var m = new Mapping();
            m.start = it.start_address;
            m.end = it.end_address;
            m.readable = it.flags[0] == 'r';
            m.writable = it.flags[1] == 'w';
            m.executable = it.flags[2] == 'x';
            m.path = it.path;
            maps.add(m);
        }
        return snap;
    }
}
```

/proc/PID/maps 就像一份详细的"地产登记簿"，记录了进程的每一块内存是谁的、能做什么。Frida 靠它来找到目标进程加载的库、可用的地址空间等关键信息。

### 16.4.2 进程枚举

```
/proc/
├── 1/         # PID 1 (init/systemd)
│   ├── maps   # 内存映射
│   ├── stat   # 进程状态
│   ├── exe    # 可执行文件链接
│   └── cmdline # 命令行参数
├── 1234/      # PID 1234
│   ├── maps
│   └── ...
└── ...
```

遍历 /proc 下的数字目录就能枚举所有进程。Frida 在 `gumprocess-linux.c` 中正是这么做的，通过读取每个进程目录下的信息来构建进程列表。

## 16.5 Helper 进程架构

Frida 不会让主进程直接执行 ptrace 操作。它使用一个独立的 Helper 进程来完成这些敏感操作：

```
┌──────────────────┐     D-Bus IPC      ┌──────────────────────┐
│   Frida Client   │<──────────────────>│   frida-helper       │
│  (你的脚本进程)   │                    │  (特权辅助进程)        │
└──────────────────┘                    ├──────────────────────┤
                                        │ - ptrace 操作         │
                                        │ - 内存读写            │
                                        │ - 代码注入            │
                                        │ - 进程 spawn/resume   │
                                        └──────────┬───────────┘
                                                   │ ptrace
                                                   v
                                        ┌──────────────────────┐
                                        │    Target Process     │
                                        │    (目标进程)          │
                                        └──────────────────────┘
```

为什么要这样设计？两个核心原因：

1. **权限隔离**：ptrace 操作可能需要 root 权限，Helper 可以以提升的权限运行
2. **稳定性**：即使 Helper 崩溃，Frida 客户端也不会受影响

源码中 `LinuxHelperProcess` 负责启动和管理 Helper 进程，`LinuxHelperBackend` 是 Helper 内部的实际实现。

## 16.6 eBPF 集成——现代化的进程监控

Frida 在 Linux 上还集成了 eBPF（Extended Berkeley Packet Filter），用于高效的系统级监控。

### 16.6.1 SpawnGater——进程创建拦截

SpawnGater 使用 eBPF 程序来拦截新进程的创建：

```vala
// 简化自 spawn-gater.vala
public sealed class SpawnGater : Object {
    private BpfRingbufReader? events_reader;
    private Gee.Collection<BpfLink> links;

    public void start() throws Error {
        // 加载预编译的 eBPF 程序
        var obj = BpfObject.open("spawn-gater.elf",
            Data.HelperBackend.get_spawn_gater_elf_blob().data);

        var events = obj.maps.get_by_name("events");
        obj.prepare();

        // 创建 ringbuf 读取器
        events_reader = new BpfRingbufReader(events);
        obj.load();

        // 附加所有 eBPF 程序到内核钩子
        foreach (var program in obj.programs) {
            var link = program.attach();
            links.add(link);
        }

        // 监听事件
        events_channel = new IOChannel.unix_new(events.fd);
        // ... 设置事件回调
    }
}
```

SpawnGater 的工作原理：

```
┌──────────────────┐
│    用户空间       │
│  ┌─────────────┐ │     ┌──────────────────┐
│  │ SpawnGater  │ │     │  目标进程         │
│  │ (Ringbuf    │<──────│  fork()/exec()   │
│  │  Reader)    │ │     └──────────────────┘
│  └─────────────┘ │
├──────────────────┤
│    内核空间       │
│  ┌─────────────┐ │
│  │ eBPF 程序   │ │
│  │ (挂在 exec  │ │
│  │  系统调用上) │ │
│  └──────┬──────┘ │
│         │        │
│  ┌──────v──────┐ │
│  │  Ringbuf    │ │
│  │  (环形缓冲) │ │
│  └─────────────┘ │
└──────────────────┘
```

### 16.6.2 ActivitySampler——性能采样

ActivitySampler 也使用 eBPF，但目的不同——它用于采样目标进程的活动：

```vala
// 简化自 activity-sampler.vala
public sealed class ActivitySampler : Object {
    public void start() throws Error {
        var obj = BpfObject.open("activity-sampler.elf", ...);

        // 设置目标进程ID
        var target_tgid = obj.maps.get_by_name("target_tgid");
        target_tgid.update_u32_u32(0, pid);

        // 为每个CPU核心创建性能事件
        uint ncpus = get_num_processors();
        for (uint cpu = 0; cpu < ncpus; cpu++) {
            var pea = PerfEventAttr();
            pea.event_type = SOFTWARE;
            pea.config = CPU_CLOCK;
            pea.sample_period = 1;

            var pefd = PerfEvent.open(&pea, -1, cpu, -1, 0);
            var link = program.attach_perf_event(pefd);
        }
    }
}
```

ActivitySampler 就像一个"交通摄像头"，每隔一段时间拍一张快照，记录目标进程此刻在执行什么代码、调用栈是什么样的。

## 16.7 ELF 模块处理

在 Linux 上，可执行文件和共享库使用 ELF（Executable and Linkable Format）格式。Frida 的 `GumElfModule`（位于 `gum/backend-linux/`）负责解析 ELF 文件：

```
┌──────────────────────────────────────┐
│            ELF 文件结构               │
├──────────────────────────────────────┤
│  ELF Header                          │
│  (魔数、架构、入口点)                  │
├──────────────────────────────────────┤
│  Program Headers (Segments)          │
│  (LOAD、DYNAMIC、INTERP等)           │
├──────────────────────────────────────┤
│  .text (代码段)                       │
│  .rodata (只读数据)                   │
│  .data (可读写数据)                   │
│  .bss (未初始化数据)                  │
│  .dynsym (动态符号表)                 │
│  .dynstr (动态字符串表)               │
│  .plt / .got (过程链接/全局偏移表)     │
├──────────────────────────────────────┤
│  Section Headers                     │
└──────────────────────────────────────┘
```

Frida 需要解析 ELF 来完成：
- 找到 dlopen、dlsym 等函数的地址
- 枚举模块中的导出符号
- 确定模块的加载基址和内存布局

## 16.8 本章小结

- Linux 后端的核心武器是 **ptrace** 系统调用，它提供了进程跟踪、内存读写、寄存器操作等能力
- **spawn** 通过 fork + ptrace(TRACEME) + execve 实现，在 execve 后的 SIGTRAP 处暂停目标
- **注入** 通过 Linjector 完成，本质是在目标进程中执行 dlopen 加载 agent .so
- **/proc** 文件系统是 Linux 上获取进程信息的主要途径，Frida 用它来枚举进程、解析内存映射
- **Helper 进程** 提供权限隔离和稳定性保障
- **eBPF** 为 Frida 带来了现代化的内核级监控能力，SpawnGater 拦截进程创建，ActivitySampler 采样进程活动
- **memfd** 优化让注入可以完全在内存中完成，不留磁盘痕迹

## 讨论问题

1. ptrace 的 PTRACE_TRACEME 和 PTRACE_ATTACH 有什么区别？在什么场景下 Frida 会使用 PTRACE_ATTACH 而不是 PTRACE_TRACEME？

2. eBPF 相比传统的 ptrace 监控有什么优势和局限？为什么 Frida 同时使用两种技术？

3. memfd_create 在较老的 Linux 内核上不可用，Frida 的回退方案（临时文件）有什么潜在的安全风险？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
