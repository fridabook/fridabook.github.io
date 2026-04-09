# 第9章：Stalker -- 代码追踪引擎

> 如果 Interceptor 是在路口设了一个检查站，那 Stalker 就是给目标车辆装了一个 GPS 追踪器。它不只是在某几个点拦截你，而是追踪你走过的每一条路、每一个转弯。这到底是怎么做到的？

## 9.1 什么是动态二进制插桩？

我们先区分两个概念：

- **静态二进制插桩**：在程序运行之前，修改它的可执行文件，插入额外的代码。好比你在印刷之前修改了一本书的内容。
- **动态二进制插桩**（DBI）：在程序运行时，实时地转换它即将执行的代码。好比你在别人读书的时候，在他翻到下一页之前，偷偷把那一页换成了你修改过的版本。

Stalker 就是 Frida 的 DBI 引擎。它能做到：

- 追踪目标线程执行的每一条指令
- 记录所有函数调用和返回
- 在任意指令处插入自定义代码
- 实时转换正在执行的机器码

## 9.2 Stalker vs Interceptor：什么时候用哪个？

```
┌──────────────────┬────────────────────────┬─────────────────────────┐
│                  │     Interceptor        │       Stalker           │
├──────────────────┼────────────────────────┼─────────────────────────┤
│ 工作方式         │ 修改函数入口           │ 实时重编译代码          │
│ 粒度             │ 函数级别               │ 指令级别                │
│ 性能开销         │ 极小（只在入口处）     │ 较大（每条指令都处理）  │
│ 适用场景         │ Hook 特定函数          │ 代码覆盖率/调用追踪     │
│ 对原始代码的影响 │ 只修改函数开头几字节   │ 创建代码的完整副本      │
│ 同时追踪的范围   │ 你指定的函数           │ 整个线程的执行流        │
└──────────────────┴────────────────────────┴─────────────────────────┘
```

简单说：如果你只想监控几个函数的参数和返回值，用 Interceptor。如果你想知道一个线程执行了哪些代码路径，用 Stalker。

## 9.3 Stalker 的核心 API

让我们看看 `gumstalker.h` 中的关键接口：

```c
// 创建 Stalker 实例
GumStalker * gum_stalker_new (void);

// 追踪当前线程
void gum_stalker_follow_me (GumStalker * self,
    GumStalkerTransformer * transformer,
    GumEventSink * sink);

// 停止追踪当前线程
void gum_stalker_unfollow_me (GumStalker * self);

// 追踪指定线程
void gum_stalker_follow (GumStalker * self,
    GumThreadId thread_id,
    GumStalkerTransformer * transformer,
    GumEventSink * sink);

// 停止追踪指定线程
void gum_stalker_unfollow (GumStalker * self,
    GumThreadId thread_id);
```

两个关键参数：

- **GumStalkerTransformer**: 代码转换器，决定如何修改每个基本块
- **GumEventSink**: 事件接收器，接收追踪过程中产生的事件

## 9.4 基本块编译模型

Stalker 的核心思想是：不修改原始代码，而是创建代码的转换副本来执行。

什么是基本块（Basic Block）？就是一段没有分支的连续指令，从第一条执行到最后一条，中间不会跳走。比如：

```
基本块 A:               基本块 B:
  mov rax, [rdi]          cmp rax, 0
  add rax, 1              je block_C
  mov [rdi], rax          call some_func
  jmp block_B             jmp block_D
```

Stalker 的工作流程：

```
┌─────────────────────────────────────────────────────────┐
│                    Stalker 执行流程                      │
│                                                         │
│  原始代码                         转换后的代码           │
│  ┌───────────┐                   ┌───────────────────┐  │
│  │ 基本块 A  │ ──编译转换──>     │ 基本块 A' (副本)  │  │
│  │           │                   │ + 插桩代码         │  │
│  └─────┬─────┘                   └─────┬─────────────┘  │
│        │                               │                │
│        v                               v                │
│  ┌───────────┐                   ┌───────────────────┐  │
│  │ 基本块 B  │ ──编译转换──>     │ 基本块 B' (副本)  │  │
│  │           │                   │ + 插桩代码         │  │
│  └───────────┘                   └───────────────────┘  │
│                                                         │
│  注意：线程实际执行的是右边的转换后代码！                │
└─────────────────────────────────────────────────────────┘
```

每当线程准备执行一个新的基本块时，Stalker 会：

1. 检查这个基本块是否已经被编译过
2. 如果没有，用 Transformer 编译它（读取原始指令，生成转换后的版本）
3. 让线程跳转到编译后的代码去执行
4. 当编译后的代码执行完毕（遇到跳转），重复上述过程

这就像一个实时翻译员：你说一句话，他翻译一句话给对方听。对方从来不直接听到你说的原话，只听到翻译后的版本。

## 9.5 StalkerTransformer：你的代码转换器

Transformer 是你控制 Stalker 行为的主要接口：

```c
// 创建默认的 Transformer（原样复制所有指令）
GumStalkerTransformer * gum_stalker_transformer_make_default (void);

// 创建自定义 Transformer
GumStalkerTransformer * gum_stalker_transformer_make_from_callback (
    GumStalkerTransformerCallback callback,
    gpointer data,
    GDestroyNotify data_destroy);
```

在回调中，你通过 `GumStalkerIterator` 遍历基本块中的每条指令：

```c
void my_transformer (GumStalkerIterator * iterator,
                     GumStalkerOutput * output,
                     gpointer user_data)
{
  const cs_insn * insn;

  // 遍历原始基本块中的每条指令
  while (gum_stalker_iterator_next (iterator, &insn))
  {
    // 你可以检查指令，决定怎么处理

    if (insn->id == X86_INS_CALL)
    {
      // 在 call 指令前插入一个回调
      gum_stalker_iterator_put_callout (iterator,
          my_callout, NULL, NULL);
    }

    // 保留原始指令（复制到输出）
    gum_stalker_iterator_keep (iterator);
  }
}
```

`keep` 是关键操作：它把当前指令复制到转换后的代码中。如果你不调用 `keep`，这条指令就会被"吃掉"。你也可以用 `put_callout` 在任意位置插入 C 函数回调。

## 9.6 EventSink：事件收集器

EventSink 负责接收 Stalker 产生的各种事件。先看事件类型：

```c
enum _GumEventType
{
  GUM_NOTHING  = 0,
  GUM_CALL     = 1 << 0,   // 函数调用
  GUM_RET      = 1 << 1,   // 函数返回
  GUM_EXEC     = 1 << 2,   // 每条指令执行
  GUM_BLOCK    = 1 << 3,   // 基本块执行
  GUM_COMPILE  = 1 << 4,   // 基本块编译
};
```

不同事件携带不同信息：

```c
struct _GumCallEvent {
  GumEventType type;
  gpointer location;    // call 指令的地址
  gpointer target;      // 被调用函数的地址
  gint depth;           // 调用深度
};

struct _GumExecEvent {
  GumEventType type;
  gpointer location;    // 当前执行的指令地址
};

struct _GumBlockEvent {
  GumEventType type;
  gpointer start;       // 基本块起始地址
  gpointer end;         // 基本块结束地址
};
```

EventSink 接口的设计很优雅：

```c
struct _GumEventSinkInterface
{
  GumEventType (* query_mask) (GumEventSink * self);  // 你关心哪些事件？
  void (* start) (GumEventSink * self);               // 追踪开始
  void (* process) (GumEventSink * self,               // 处理每个事件
      const GumEvent * event, GumCpuContext * cpu_context);
  void (* flush) (GumEventSink * self);               // 刷新缓冲区
  void (* stop) (GumEventSink * self);                // 追踪结束
};
```

`query_mask` 非常重要：如果你只关心 `GUM_CALL`，Stalker 就不会为每条指令都生成事件上报代码，大幅减少性能开销。

## 9.7 StalkerWriter：跨架构的代码输出

Stalker 需要在不同架构上生成代码，因此使用了一个联合体来统一接口：

```c
union _GumStalkerWriter
{
  gpointer instance;
  GumX86Writer * x86;
  GumArmWriter * arm;
  GumThumbWriter * thumb;
  GumArm64Writer * arm64;
  GumMipsWriter * mips;
};

struct _GumStalkerOutput
{
  GumStalkerWriter writer;
  GumInstructionEncoding encoding;
};
```

这意味着 Stalker 在 x86 平台上用 `GumX86Writer` 生成代码，在 ARM64 平台上用 `GumArm64Writer`，但对上层提供统一的抽象。

## 9.8 信任阈值与代码缓存

Stalker 编译过的基本块会被缓存起来复用，但问题是：怎么知道缓存的代码还是有效的？

```c
// 获取/设置信任阈值
gint gum_stalker_get_trust_threshold (GumStalker * self);
void gum_stalker_set_trust_threshold (GumStalker * self,
    gint trust_threshold);
```

信任阈值（trust threshold）控制缓存策略：

- **-1**: 永远不信任缓存，每次都重新编译（最安全但最慢）
- **0**: 信任缓存，但不计数（默认值，适合大多数场景）
- **N > 0**: 基本块被执行 N 次后，才完全信任它（折中方案）

为什么需要这个？因为有些程序会动态修改自己的代码（自修改代码）。如果 Stalker 总是用缓存的旧版本，就会执行错误的代码。

## 9.9 Backpatching 优化

Stalker 的一个重要优化是 backpatching（回填修补）。

考虑这个场景：基本块 A 的末尾跳转到基本块 B。第一次执行时，Stalker 必须从 A' 返回到 Stalker 引擎，查找或编译 B，再跳到 B'。但如果 B 已经编译好了，后续执行时可以直接从 A' 跳到 B'，跳过 Stalker 引擎这个中间环节。

```
首次执行:
  A'末尾 ──> Stalker引擎 ──> 查找/编译B ──> B'

Backpatch 后:
  A'末尾 ──────────────────────────────────> B'
```

这就像你第一次去一个地方需要查地图，但走过一次后就记住路了，下次直接走。

Stalker 通过 Observer 接口通知外部关于 backpatch 的操作：

```c
struct _GumStalkerObserverInterface
{
  GumStalkerNotifyBackpatchFunc notify_backpatch;
  // ... 各种计数器 ...
  GumStalkerIncrementFunc increment_call_imm;
  GumStalkerIncrementFunc increment_call_reg;
  GumStalkerIncrementFunc increment_jmp_imm;
  GumStalkerIncrementFunc increment_ret;
  // ...
};
```

## 9.10 排除区域

有些代码你不希望 Stalker 去转换（比如 Frida 自己的代码），可以用 exclude 排除：

```c
void gum_stalker_exclude (GumStalker * self,
    const GumMemoryRange * range);
```

当执行流进入排除区域时，Stalker 会让它直接原生执行，离开后再恢复追踪。

## 9.11 其他实用功能

```c
// 添加调用探针（当特定地址被 call 时触发）
GumProbeId gum_stalker_add_call_probe (GumStalker * self,
    gpointer target_address, GumCallProbeCallback callback,
    gpointer data, GDestroyNotify notify);

// 在指定线程上执行函数
gboolean gum_stalker_run_on_thread (GumStalker * self,
    GumThreadId thread_id, GumStalkerRunOnThreadFunc func,
    gpointer data, GDestroyNotify data_destroy);

// 使指定地址的缓存失效（代码被修改后需要调用）
void gum_stalker_invalidate (GumStalker * self,
    gconstpointer address);

// 预编译指定地址的代码
void gum_stalker_prefetch (GumStalker * self,
    gconstpointer address, gint recycle_count);
```

`run_on_thread` 特别有趣：它允许你在目标线程的上下文中执行一段代码。这对于需要在特定线程上操作的场景非常有用。

## 9.12 Stalker 的完整工作流程

把所有的概念串起来：

```
┌─────────────────────────────────────────────────────┐
│                Stalker 完整流程                      │
│                                                     │
│  1. follow_me() / follow(thread_id)                 │
│     │                                               │
│  2. 获取目标线程当前的 PC（程序计数器）              │
│     │                                               │
│  3. 查找该 PC 对应的基本块是否已编译                 │
│     │                                               │
│     ├─ 是 ──> 直接执行编译后的代码                   │
│     │                                               │
│     └─ 否 ──> 4. 编译基本块                         │
│                  │                                   │
│                  ├─ 用 Capstone 反汇编原始指令        │
│                  ├─ 调用 Transformer 处理每条指令     │
│                  ├─ 用 Writer 生成转换后的代码        │
│                  ├─ 插入事件上报代码（根据 EventSink │
│                  │  的 query_mask）                   │
│                  └─ 缓存编译结果                     │
│                                                     │
│  5. 执行编译后的代码                                 │
│     │                                               │
│  6. 遇到跳转/调用/返回时                             │
│     │                                               │
│     ├─ 产生对应事件发送给 EventSink                  │
│     └─ 回到第3步处理下一个基本块                     │
│                                                     │
│  7. unfollow_me() / unfollow(thread_id) 停止追踪     │
└─────────────────────────────────────────────────────┘
```

## 9.13 本章小结

- Stalker 是 Frida 的动态二进制插桩引擎，能追踪线程执行的每一条指令
- 核心原理是实时编译：将原始代码的基本块转换成插桩后的副本来执行
- Transformer 让你控制如何转换每条指令，EventSink 让你收集执行事件
- Backpatching 优化减少了反复查找编译代码的开销
- 信任阈值控制代码缓存的策略，平衡安全性和性能
- 与 Interceptor 相比，Stalker 粒度更细但开销更大

## 讨论问题

1. Stalker 为什么选择"复制并转换代码"的方案，而不是像 Interceptor 那样在原地修改代码？

2. 如果目标程序存在自修改代码（比如解密 shellcode 后执行），Stalker 如何处理？trust_threshold 在这种场景下应该怎么设置？

3. 在 JavaScript 层面使用 `Stalker.follow()` 时，开启 `GUM_EXEC` 事件（追踪每条指令）和只开启 `GUM_CALL` 事件，性能差异为什么会很大？从源码层面解释原因。

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
