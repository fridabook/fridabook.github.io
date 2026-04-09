# 第8章：Interceptor -- 函数钩子的魔法

> 你有没有想过，当你在 Frida 里写下 `Interceptor.attach(addr, { onEnter, onLeave })` 的时候，底层到底发生了什么？一个正在运行的函数，怎么就突然"被你控制"了？

## 8.1 什么是函数钩子？

让我们用一个生活中的例子来理解。

假设你家的座机号码是 `12345678`。正常情况下，别人拨打这个号码，电话直接到你家。但有一天，你去电信公司设置了一个"呼叫转移"：所有打到 `12345678` 的电话，先转到你的手机 `98765432` 上，你接听后可以选择再转回家里的座机。

函数钩子（Hook）就是这个道理：

```
正常情况：
  调用者 ──────> 目标函数

Hook 之后：
  调用者 ──────> 你的代码（onEnter）──────> 目标函数 ──────> 你的代码（onLeave）──────> 调用者
```

Frida 的 Interceptor 就是那个"电信公司"，它负责帮你设置这个"呼叫转移"。

## 8.2 Interceptor 的核心 API

打开源码文件 `guminterceptor.h`，我们可以看到 Interceptor 对外暴露的几个核心函数：

```c
// 获取全局唯一的 Interceptor 实例（单例模式）
GumInterceptor * gum_interceptor_obtain (void);

// 在目标函数上挂钩，注册 listener
GumAttachReturn gum_interceptor_attach (
    GumInterceptor * self,
    gpointer function_address,
    GumInvocationListener * listener,
    gpointer listener_function_data,
    GumAttachFlags flags);

// 卸载钩子
void gum_interceptor_detach (
    GumInterceptor * self,
    GumInvocationListener * listener);

// 替换整个函数（不是 hook，而是完全替换）
GumReplaceReturn gum_interceptor_replace (
    GumInterceptor * self,
    gpointer function_address,
    gpointer replacement_function,
    gpointer replacement_data,
    gpointer * original_function);

// 取消替换
void gum_interceptor_revert (
    GumInterceptor * self,
    gpointer function_address);
```

注意 `attach` 和 `replace` 是两个不同的操作：

- **attach**: 在原函数执行前后插入你的代码，原函数照常执行
- **replace**: 用你的函数完全取代原函数，但保留一个指向原函数的指针供你可选调用

## 8.3 InvocationListener：你的"监听器"

当你用 `Interceptor.attach()` 挂钩时，你提供的 `onEnter` 和 `onLeave` 回调函数，在 C 层对应的是 `GumInvocationListener` 接口：

```c
struct _GumInvocationListenerInterface
{
  void (* on_enter) (GumInvocationListener * self,
      GumInvocationContext * context);
  void (* on_leave) (GumInvocationListener * self,
      GumInvocationContext * context);
};
```

Frida 提供了两种快捷创建方式：

```c
// 创建一个 Call Listener（同时关注进入和离开）
GumInvocationListener * gum_make_call_listener (
    on_enter_callback, on_leave_callback, data, destroy);

// 创建一个 Probe Listener（只关注进入，不关心返回值）
GumInvocationListener * gum_make_probe_listener (
    on_hit_callback, data, destroy);
```

Call Listener 好比在函数门口装了两个摄像头，一个拍进门的人，一个拍出门的人。Probe Listener 只装了进门那个摄像头，更轻量。

## 8.4 InvocationContext：你能拿到什么？

每次你的回调被触发时，都会收到一个 `GumInvocationContext`，通过它你可以：

- 读取和修改函数参数
- 读取和修改返回值（在 onLeave 中）
- 获取 CPU 寄存器状态
- 在 onEnter 和 onLeave 之间传递自定义数据

这就像你截获了一个快递包裹，你不仅能看到包裹里的东西（参数），还能偷偷换一个（修改参数），甚至把回执单上的内容改了（修改返回值）。

## 8.5 Interceptor 的内部结构

让我们看看 `GumInterceptor` 对象内部长什么样：

```c
struct _GumInterceptor
{
  GObject parent;
  GRecMutex mutex;                      // 递归锁，保证线程安全
  GHashTable * function_by_address;     // 地址 -> FunctionContext 映射表
  GumInterceptorBackend * backend;      // 架构相关的后端
  GumCodeAllocator allocator;           // 代码内存分配器
  volatile guint selected_thread_id;    // 线程过滤
  GumInterceptorTransaction current_transaction; // 当前事务
};
```

用一张图来理解它的结构：

```
┌─────────────────────────────────────────┐
│            GumInterceptor               │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │   function_by_address (HashMap)   │  │
│  │                                   │  │
│  │  0x7fff1234 -> FunctionContext A  │  │
│  │  0x7fff5678 -> FunctionContext B  │  │
│  │  0x7fff9abc -> FunctionContext C  │  │
│  └───────────────────────────────────┘  │
│                                         │
│  ┌──────────────┐  ┌────────────────┐   │
│  │   Backend    │  │  CodeAllocator │   │
│  │  (架构相关)  │  │  (内存分配)    │   │
│  └──────────────┘  └────────────────┘   │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │     current_transaction           │  │
│  │  (批量操作的事务管理)             │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## 8.6 FunctionContext：每个被 Hook 函数的"档案"

每一个被 Hook 的函数，都有一个 `GumFunctionContext` 来记录它的全部信息：

```c
struct _GumFunctionContext
{
  gpointer function_address;         // 原函数地址

  GumCodeSlice * trampoline_slice;   // 跳板代码的内存
  gpointer on_enter_trampoline;      // 进入跳板
  gpointer on_invoke_trampoline;     // 调用原函数的跳板
  gpointer on_leave_trampoline;      // 离开跳板

  guint8 overwritten_prologue[32];   // 被覆盖的原始字节（用于恢复）
  guint overwritten_prologue_len;    // 被覆盖了多少字节

  volatile GPtrArray * listener_entries; // 监听器列表
  gpointer replacement_function;      // 替换函数（replace 模式）
};
```

注意看 `overwritten_prologue` 这个字段，它最大 32 字节。这是因为 Interceptor 需要把目标函数的开头几条指令替换成一条跳转指令。被替换掉的原始指令需要保存起来，将来恢复时用。

## 8.7 Hook 的工作原理：跳板（Trampoline）

Interceptor 的核心技术就是跳板（Trampoline）。来看这张图：

```
    原函数（Hook 前）：              原函数（Hook 后）：
    ┌──────────────────┐           ┌──────────────────┐
    │ push rbp         │           │ jmp on_enter_     │  <-- 被改写的开头
    │ mov rbp, rsp     │           │    trampoline     │
    │ sub rsp, 0x20    │           │ ...（后续不变）   │
    │ ...              │           │                   │
    │ ret              │           │ ret               │
    └──────────────────┘           └──────────────────┘
                                          │
                                          v
                                   ┌──────────────────┐
                                   │  on_enter_        │
                                   │  trampoline:      │
                                   │                   │
                                   │  保存 CPU 上下文  │
                                   │  调用 onEnter     │
                                   │  恢复 CPU 上下文  │
                                   │  jmp on_invoke_   │
                                   │     trampoline    │
                                   └──────────────────┘
                                          │
                                          v
                                   ┌──────────────────┐
                                   │  on_invoke_       │
                                   │  trampoline:      │
                                   │                   │
                                   │  push rbp         │  <-- 被搬走的原始指令
                                   │  mov rbp, rsp     │
                                   │  sub rsp, 0x20    │
                                   │  jmp 原函数+偏移  │  <-- 跳回原函数继续执行
                                   └──────────────────┘
```

关键点在于：

1. **改写入口**：把原函数开头的几条指令替换为一条跳转指令
2. **保存原始指令**：被替换的指令搬到 `on_invoke_trampoline` 里
3. **构建跳板链**：enter trampoline -> 你的回调 -> invoke trampoline -> 原函数后半段

这就像修路：你把路口改造了一下，让所有车先经过你设的检查站，检查完了再回到原来的路上继续开。

## 8.8 事务机制（Transaction）

如果你要同时 Hook 很多函数，一个一个改写内存既慢又危险（在多线程环境下，你改了一半另一个线程执行到这里就崩了）。Frida 提供了事务机制：

```c
gum_interceptor_begin_transaction (interceptor);

// 批量 attach 多个函数
gum_interceptor_attach (interceptor, func_a, listener_a, NULL, 0);
gum_interceptor_attach (interceptor, func_b, listener_b, NULL, 0);
gum_interceptor_attach (interceptor, func_c, listener_c, NULL, 0);

gum_interceptor_end_transaction (interceptor);
```

事务的内部结构：

```c
struct _GumInterceptorTransaction
{
  gboolean is_dirty;                    // 有没有待提交的修改
  gint level;                           // 事务嵌套层级
  GQueue * pending_destroy_tasks;       // 待销毁的任务
  GHashTable * pending_update_tasks;    // 待更新的任务
  GumInterceptor * interceptor;
};
```

事务机制好比银行转账：你不会一笔一笔地操作，而是把所有转账请求收集好，然后一次性提交。`begin_transaction` 就是"开始收集"，`end_transaction` 就是"一次性提交"。在提交的那一刻，Frida 会暂停所有相关线程，批量修改内存，然后恢复运行。

## 8.9 一步步跟踪：attach 到底做了什么？

让我们从上到下追踪一次 `Interceptor.attach()` 调用的完整流程：

```
第1步：gum_interceptor_attach()
  │
  ├─ 加锁（GRecMutex）
  │
  ├─ 第2步：gum_interceptor_instrument()
  │    │
  │    ├─ 在 function_by_address 中查找是否已有 FunctionContext
  │    │
  │    ├─ 如果没有，创建新的 FunctionContext
  │    │    │
  │    │    └─ _gum_interceptor_backend_create_trampoline()
  │    │         │
  │    │         ├─ 分析目标函数开头的指令
  │    │         ├─ 用 Relocator 搬移原始指令
  │    │         ├─ 用 Writer 生成跳板代码
  │    │         └─ 记录被覆盖的原始字节
  │    │
  │    └─ 返回 FunctionContext
  │
  ├─ 第3步：将 Listener 添加到 FunctionContext
  │
  ├─ 第4步：安排事务更新（schedule_update）
  │    │
  │    └─ 在 end_transaction 时执行：
  │         │
  │         ├─ _gum_interceptor_backend_activate_trampoline()
  │         │    │
  │         │    └─ 把原函数开头改写为跳转指令
  │         │
  │         └─ 刷新 CPU 指令缓存
  │
  └─ 解锁
```

注意看第2步中出现了两个重要的组件：**Relocator** 和 **Writer**。它们分别负责"搬移指令"和"生成指令"，我们将在后面的章节详细介绍。

## 8.10 线程安全与忽略机制

Interceptor 还提供了线程控制能力：

```c
// 忽略当前线程（Interceptor 的回调不会在当前线程触发）
gum_interceptor_ignore_current_thread (interceptor);
gum_interceptor_unignore_current_thread (interceptor);

// 忽略其他所有线程（只有当前线程会触发回调）
gum_interceptor_ignore_other_threads (interceptor);
gum_interceptor_unignore_other_threads (interceptor);
```

这在你的回调函数里调用了被 Hook 的函数时特别有用。如果不忽略，就会无限递归。每个线程有一个 `InterceptorThreadContext`，其中的 `ignore_level` 控制忽略层级：

```c
struct _InterceptorThreadContext
{
  GumInvocationBackend listener_backend;
  GumInvocationBackend replacement_backend;
  gint ignore_level;            // > 0 时忽略这个线程
  GumInvocationStack * stack;   // 调用栈
  GArray * listener_data_slots;
};
```

## 8.11 attach 的返回值

attach 可能失败，返回值告诉你原因：

```c
typedef enum
{
  GUM_ATTACH_OK               =  0,  // 成功
  GUM_ATTACH_WRONG_SIGNATURE  = -1,  // 函数签名不对（无法识别为有效代码）
  GUM_ATTACH_ALREADY_ATTACHED = -2,  // 同一个 listener 已经挂在这个函数上了
  GUM_ATTACH_POLICY_VIOLATION = -3,  // 权限策略不允许
  GUM_ATTACH_WRONG_TYPE       = -4,  // 类型冲突（比如已经 replace 了又要 attach）
} GumAttachReturn;
```

另外还有一个 `GUM_ATTACH_FLAGS_FORCE` 标志，用于强制 Hook，即使 Frida 检测到目标函数可能已经被其他工具修改过。

## 8.12 本章小结

- Interceptor 是 Frida 最核心的 Hook 引擎，通过修改目标函数入口实现钩子
- `attach` 在函数前后插入回调，`replace` 完全替换函数
- 跳板（Trampoline）是 Hook 的核心机制：修改入口跳转 -> 执行你的代码 -> 跳回原函数
- 事务机制保证多个 Hook 操作的原子性
- 每个被 Hook 的函数都有一个 `FunctionContext` 记录其全部状态
- Interceptor 依赖 Writer（生成代码）和 Relocator（搬移代码）两个底层组件

## 讨论问题

1. 为什么 Interceptor 需要保存被覆盖的原始字节？如果不保存会怎样？

2. 在多线程环境下，如果线程 A 正在执行目标函数的开头几条指令，而线程 B 此时正在修改这些指令，会发生什么？Frida 如何避免这个问题？

3. `attach` 和 `replace` 各适用于什么场景？能不能对同一个函数同时使用这两种操作？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
