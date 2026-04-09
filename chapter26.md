# 第26章：内存操作——扫描、监控与读写

> 如果你能随意翻看别人书架上的每一本书，找到某一页的某一句话，甚至在上面涂涂改改，你会做什么？在动态插桩的世界里，内存就是那个书架，而 Frida 给了你一把万能钥匙。

## 26.1 为什么内存操作是核心能力

在逆向工程和安全研究中，几乎所有的工作最终都归结为"读内存"和"写内存"。Hook 函数是在代码段写入跳转指令，读取返回值是在栈上读内存，修改游戏数值是在堆上写内存。可以说，没有内存操作能力的插桩框架就像一把没有刀刃的瑞士军刀——好看但没用。

Frida 的内存操作能力主要集中在 `frida-gum` 的 `gummemory.h` 中，它提供了一套完整的内存读写、扫描、保护、分配的 API。让我们逐一拆解。

## 26.2 内存的基本抽象

在深入具体操作之前，我们先看看 Frida 如何描述内存。这就好比你要去图书馆找书，首先得知道图书馆的编目系统。

### 内存范围（GumMemoryRange）

```c
struct _GumMemoryRange
{
  GumAddress base_address;  // 起始地址
  gsize size;               // 大小
};
```

简单得不能再简单——一个起始地址加一个大小，就描述了内存中的一块连续区域。Frida 还贴心地提供了一个宏来判断某个地址是否在范围内：

```c
#define GUM_MEMORY_RANGE_INCLUDES(r, a) \
    ((a) >= (r)->base_address && \
     (a) < ((r)->base_address + (r)->size))
```

### 页面保护（GumPageProtection）

```c
enum _GumPageProtection
{
  GUM_PAGE_NO_ACCESS = 0,
  GUM_PAGE_READ      = (1 << 0),  // 可读
  GUM_PAGE_WRITE     = (1 << 1),  // 可写
  GUM_PAGE_EXECUTE   = (1 << 2),  // 可执行
};
```

通过位运算组合出 `GUM_PAGE_RW`、`GUM_PAGE_RX`、`GUM_PAGE_RWX` 等常用保护属性。值得注意的是，现代操作系统越来越限制 RWX 页面，Frida 通过 `gum_query_rwx_support()` 查询支持程度。

## 26.3 内存读写：最基本的操作

### 读取内存

```c
guint8 * gum_memory_read (gconstpointer address,
                          gsize len,
                          gsize * n_bytes_read);
```

看起来很简单对吧？但实现可没那么简单。以 Linux 平台为例，Frida 的读取策略分两步：

```
┌─────────────────────────────────────────────┐
│            gum_memory_read 流程              │
├─────────────────────────────────────────────┤
│                                             │
│  1. 优先使用 process_vm_readv 系统调用       │
│     (内核 >= 3.2 才支持)                    │
│     ┌──────────┐     ┌──────────┐           │
│     │ local    │ <-- │ remote   │           │
│     │ iov_base │     │ iov_base │           │
│     │ iov_len  │     │ iov_len  │           │
│     └──────────┘     └──────────┘           │
│                                             │
│  2. 如果系统调用不可用(ENOSYS)，              │
│     回退到检查权限后直接 memcpy              │
│                                             │
└─────────────────────────────────────────────┘
```

为什么要用 `process_vm_readv` 而不是直接 `memcpy`？因为直接 `memcpy` 如果遇到不可读的内存会导致段错误（SIGSEGV）。`process_vm_readv` 是一个安全的系统调用，如果读取失败会返回错误码而不是崩溃。这就像是用一根绝缘的钓鱼竿去触碰电线——即使电线带电，你也不会触电。

### 写入内存

```c
gboolean gum_memory_write (gpointer address,
                           const guint8 * bytes,
                           gsize len);
```

写入内存同样使用 `process_vm_writev` 作为首选方案，回退方案是检查可写性后直接 `memcpy`。

### 修补代码段

代码段通常是只读可执行的（RX），你不能直接写入。Frida 提供了 `gum_memory_patch_code` 来安全地修改代码：

```c
gboolean gum_memory_patch_code (gpointer address, gsize size,
    GumMemoryPatchApplyFunc apply, gpointer apply_data);
```

它的工作原理大致是：先把目标页面改为可写，执行你的修改回调，然后恢复原来的保护属性，最后刷新指令缓存。这个"刷新指令缓存"的步骤（`gum_clear_cache`）在 ARM 架构上尤其重要，因为 ARM 的指令缓存和数据缓存是分离的。

## 26.4 内存扫描：大海捞针的艺术

内存扫描是逆向工程中的常用操作。比如你想找到某个加密密钥在内存中的位置，或者定位某个字符串。Frida 的内存扫描 API 是：

```c
void gum_memory_scan (const GumMemoryRange * range,
                      const GumMatchPattern * pattern,
                      GumMemoryScanMatchFunc func,
                      gpointer user_data);
```

### 模式匹配的两种方式

Frida 支持两种扫描模式：

**十六进制模式（带通配符）：**

```javascript
// JavaScript 层的用法
Memory.scan(address, size, "48 8b ?? 10 ff");
```

`??` 表示任意字节。在 C 层，这种模式被解析为一系列 Token，每个 Token 要么是精确匹配，要么是带掩码的匹配。

**正则表达式模式：**

```c
// 内部支持正则扫描
gum_memory_scan_regex(range, regex, func, user_data);
```

### 扫描算法的优化

看源码中的 `gum_memory_scan_raw` 实现，可以发现一个聪明的优化：

```
┌──────────────────────────────────────────────┐
│         内存扫描优化策略                       │
├──────────────────────────────────────────────┤
│                                              │
│  1. 从所有 Token 中找到最长的精确匹配 Token    │
│  2. 以此 Token 作为"锚点"进行扫描              │
│  3. 找到锚点匹配后，再验证完整模式              │
│                                              │
│  类比：在一本书中找"红色的大象在跳舞"           │
│  - 先快速翻页找"大象"（最长的确定性词）         │
│  - 找到后再看前后文是否匹配完整句子             │
│                                              │
└──────────────────────────────────────────────┘
```

这种"最长锚点优先"的策略大大减少了不必要的完整模式匹配，提升了扫描速度。

## 26.5 内存访问监控（MemoryAccessMonitor）

如果说内存扫描是"主动查找"，那内存访问监控就是"被动等待"。它能告诉你：谁在什么时候读了或写了某块内存。

```c
struct _GumMemoryAccessDetails
{
  GumThreadId thread_id;       // 哪个线程
  GumMemoryOperation operation; // 读、写还是执行
  gpointer from;               // 从哪条指令发起的
  gpointer address;            // 访问的目标地址
  guint range_index;           // 命中了第几个监控范围
  guint page_index;            // 范围内第几页
  guint pages_completed;       // 已完成监控的页数
  guint pages_total;           // 总监控页数
  GumCpuContext * context;     // CPU 上下文快照
};
```

它的工作原理非常巧妙：

```
┌─────────────────────────────────────────────────┐
│       MemoryAccessMonitor 工作原理               │
├─────────────────────────────────────────────────┤
│                                                 │
│  1. 将目标内存页的保护设为 NO_ACCESS             │
│                                                 │
│  2. 当有代码尝试访问时：                          │
│     -> 触发异常/信号 (SIGSEGV/异常)              │
│     -> Frida 捕获异常                            │
│     -> 记录访问详情                              │
│     -> 恢复页面保护                              │
│     -> 调用用户回调                              │
│     -> 继续执行                                  │
│                                                 │
│  类似于：在书页上放一根头发                       │
│  如果有人翻过这页，头发就会掉落                   │
│                                                 │
└─────────────────────────────────────────────────┘
```

`auto_reset` 参数控制是否在每次触发后自动重新设置陷阱。如果设为 `TRUE`，每次访问都会触发回调；如果设为 `FALSE`，则每页只触发一次。

在不同平台上，异常的捕获机制不同：
- **Windows**: 使用 Vectored Exception Handler
- **POSIX (Linux/macOS)**: 使用信号处理器捕获 SIGSEGV

## 26.6 内存分配：在目标进程中开辟空间

Frida 经常需要在目标进程中分配内存。比如写入 Trampoline 代码、存储 Hook 的上下文数据等。

### 基本分配

```c
gpointer gum_alloc_n_pages (guint n_pages, GumPageProtection prot);
```

### 近距离分配

这是一个非常重要的能力。在 x86-64 和 ARM64 上，很多跳转指令只能跳到相对距离有限的地址。所以 Frida 需要在目标地址附近分配内存：

```c
gpointer gum_alloc_n_pages_near (guint n_pages,
    GumPageProtection prot,
    const GumAddressSpec * spec);
```

`GumAddressSpec` 描述了"靠近哪里"和"最远多远"：

```c
struct _GumAddressSpec
{
  gpointer near_address;  // 靠近这个地址
  gsize max_distance;     // 最大距离
};
```

这就像是你要在学校旁边租房，`near_address` 是学校地址，`max_distance` 是你愿意走的最远距离。

### 内存生命周期管理

Frida 还提供了更细粒度的内存管理 API：

```
┌──────────────────────────────────────────┐
│        内存生命周期 API                   │
├──────────────────────────────────────────┤
│ gum_memory_allocate  -- 分配              │
│ gum_memory_recommit  -- 重新提交物理页     │
│ gum_memory_decommit  -- 释放物理页         │
│ gum_memory_discard   -- 标记可丢弃        │
│ gum_memory_release   -- 释放虚拟地址空间   │
│ gum_memory_free      -- 完全释放          │
└──────────────────────────────────────────┘
```

这套 API 对应了操作系统虚拟内存管理的各个阶段，让 Frida 能够精确控制内存的使用。

## 26.7 Frida 自己的堆管理

一个有趣的细节：Frida 没有直接使用系统的 `malloc`，而是嵌入了 `dlmalloc`（Doug Lea 的 malloc 实现），创建了独立的内存空间（mspace）：

```c
gum_mspace_main = create_mspace(0, TRUE);
gum_mspace_internal = create_mspace(0, TRUE);
```

为什么要这样做？因为 Frida 运行在目标进程中，如果和目标进程共用堆分配器，可能会导致：
1. 插桩代码影响目标进程的内存布局
2. 目标进程的堆损坏波及到 Frida 自身
3. 在 Hook `malloc`/`free` 时产生无限递归

使用独立的 mspace 就像是在别人家的厨房里自带了一套锅碗瓢盆——你用你的，他用他的，互不干扰。

## 26.8 实际应用示例

让我们用 Frida 的 JavaScript API 做几个实际的内存操作：

```javascript
// 1. 读取内存
var buf = Memory.readByteArray(ptr("0x12345678"), 16);

// 2. 写入内存
Memory.writeByteArray(ptr("0x12345678"),
    [0x90, 0x90, 0x90, 0x90]);  // NOP sled

// 3. 扫描内存中的特定模式
Memory.scan(module.base, module.size, "48 89 5c 24 ?? 57",
{
    onMatch: function(address, size) {
        console.log("Found at: " + address);
    },
    onComplete: function() {
        console.log("Scan complete");
    }
});

// 4. 监控内存访问
MemoryAccessMonitor.enable([
    { base: ptr("0x12345678"), size: 4096 }
], {
    onAccess: function(details) {
        console.log(details.operation +
            " at " + details.address +
            " from " + details.from);
    }
});

// 5. 在目标进程中分配内存
var page = Memory.alloc(4096);
Memory.protect(page, 4096, 'rwx');
```

## 26.9 本章小结

- Frida 用 `GumMemoryRange` 和 `GumPageProtection` 构建了统一的内存抽象
- 内存读写优先使用安全的系统调用（`process_vm_readv/writev`），避免因访问无效内存而崩溃
- 内存扫描采用"最长精确 Token 锚点"策略优化性能
- `MemoryAccessMonitor` 利用页面保护机制实现访问监控，巧妙地把操作系统的异常处理变成了监控工具
- 近距离内存分配（`alloc_near`）解决了跳转距离限制的问题
- Frida 使用独立的 `dlmalloc` mspace 避免与目标进程的堆管理冲突

## 讨论问题

1. `MemoryAccessMonitor` 通过修改页面保护来监控访问，这种方式对性能有什么影响？在什么场景下这种开销是可接受的？

2. 为什么 Frida 要区分 `gum_memory_decommit` 和 `gum_memory_free`？在插桩场景中，精细的内存生命周期管理有什么好处？

3. 如果目标进程使用了自定义的内存分配器（比如 jemalloc 或 tcmalloc），Frida 使用独立的 dlmalloc mspace 是否足够安全？可能还存在哪些潜在的冲突？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
