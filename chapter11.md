# 第11章：Relocator -- 代码搬迁的艺术

> 假设你家门口有一块路牌，上面写着"前方 500 米右转到公园"。现在城市改造，要把这块路牌搬到 2 公里外的新路口。你能原封不动地搬过去吗？当然不行——因为从新位置出发，500 米后右转到达的根本不是公园了。你必须重新计算距离，改成"前方 2500 米右转到公园"。这就是代码重定位的核心问题。

## 11.1 为什么需要重定位？

回忆第 8 章 Interceptor 的工作原理：Hook 一个函数时，需要把函数开头的几条指令"搬走"，放到 invoke trampoline 里执行，然后在原位置写入跳转指令。

```
原函数:
  地址 0x1000:  push rbp              ─┐
  地址 0x1001:  mov rbp, rsp           │ 被搬走
  地址 0x1004:  sub rsp, 0x20          │
  地址 0x1008:  call 0x2000           ─┘ <-- 这条有问题！
  地址 0x100D:  ...

搬到 trampoline（地址 0x5000）:
  地址 0x5000:  push rbp              -- OK，这条不受地址影响
  地址 0x5001:  mov rbp, rsp          -- OK
  地址 0x5004:  sub rsp, 0x20         -- OK
  地址 0x5008:  call 0x2000           -- 还是 OK 吗？
```

等一下，最后那条 `call 0x2000` 需要仔细看。在 x86 上，`call` 指令实际存储的不是绝对地址 `0x2000`，而是相对偏移量。在原位置 `0x1008`，偏移量是 `0x2000 - 0x100D = 0x0FF3`。但搬到 `0x5008` 后，同样的偏移量会让你跳到 `0x500D + 0x0FF3 = 0x6000`，完全错误。

这就是 Relocator 要解决的问题：**把指令从一个地址搬到另一个地址时，修正所有与地址相关的编码**。

## 11.2 什么指令需要修正？

不是所有指令都需要修正。需要修正的主要是使用 **PC 相对寻址** 的指令：

```
┌──────────────────────────────────────────────────────────────┐
│  需要重定位的指令类型                                        │
│                                                              │
│  x86/x64:                                                    │
│  ├─ call rel32        (相对调用)                             │
│  ├─ jmp rel8/rel32    (相对跳转)                             │
│  ├─ jcc rel8/rel32    (条件跳转)                             │
│  ├─ loop/loopz/loopnz (循环指令)                            │
│  └─ mov/lea [rip+off] (RIP 相对寻址，x64 特有)              │
│                                                              │
│  ARM64:                                                      │
│  ├─ b/bl imm          (分支/调用)                            │
│  ├─ b.cond imm        (条件分支)                             │
│  ├─ cbz/cbnz imm      (比较分支)                            │
│  ├─ tbz/tbnz imm      (测试位分支)                          │
│  ├─ adr/adrp          (PC 相对取地址)                        │
│  └─ ldr literal       (PC 相对加载字面量)                    │
│                                                              │
│  不需要重定位的指令:                                         │
│  ├─ mov reg, reg      (寄存器间操作)                         │
│  ├─ add reg, imm      (立即数运算)                           │
│  ├─ push/pop          (栈操作)                               │
│  └─ ret               (返回)                                 │
└──────────────────────────────────────────────────────────────┘
```

## 11.3 Relocator 的结构

先看 x86 和 ARM64 两种 Relocator 的结构体，它们几乎一致：

```c
struct _GumX86Relocator
{
  volatile gint ref_count;

  csh capstone;             // Capstone 反汇编引擎

  const guint8 * input_start;  // 原始代码起始地址
  const guint8 * input_cur;    // 当前读取位置
  GumAddress input_pc;         // 当前 PC 值
  cs_insn ** input_insns;      // 已读取的指令数组
  GumX86Writer * output;       // 输出 Writer

  guint inpos;              // 输入游标位置
  guint outpos;             // 输出游标位置

  gboolean eob;             // End Of Block（遇到分支）
  gboolean eoi;             // End Of Input（不可继续）
};

struct _GumArm64Relocator
{
  volatile gint ref_count;

  csh capstone;

  const guint8 * input_start;
  const guint8 * input_cur;
  GumAddress input_pc;
  cs_insn ** input_insns;
  GumArm64Writer * output;    // 注意：输出到 ARM64 Writer

  guint inpos;
  guint outpos;

  gboolean eob;
  gboolean eoi;
};
```

结构完全对称。Relocator 的设计模式是：**用 Capstone 读取（反汇编）原始指令，用 Writer 写入（重新编码）修正后的指令**。

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────┐
│  原始代码    │     │    Relocator     │     │  新位置代码  │
│  (地址 A)    │────>│                  │────>│  (地址 B)    │
│              │     │  Capstone 读取   │     │              │
│  push rbp    │     │  分析指令类型    │     │  push rbp    │
│  mov rbp,rsp │     │  修正地址引用    │     │  mov rbp,rsp │
│  call 0x2000 │     │  Writer 写入     │     │  call 0x2000 │
│              │     │                  │     │  (偏移已修正)│
└──────────────┘     └──────────────────┘     └──────────────┘
```

## 11.4 read_one / write_one 模式

Relocator 的核心 API 是两个简洁的操作：`read_one` 和 `write_one`。

```c
// 从输入读取一条指令（用 Capstone 反汇编）
guint gum_x86_relocator_read_one (GumX86Relocator * self,
    const cs_insn ** instruction);

// 把读取的指令重定位后写入输出
gboolean gum_x86_relocator_write_one (GumX86Relocator * self);

// 跳过一条指令（读了但不写）
void gum_x86_relocator_skip_one (GumX86Relocator * self);

// 一次性读取并写入所有指令
void gum_x86_relocator_write_all (GumX86Relocator * self);
```

典型的使用方式：

```c
GumX86Relocator relocator;
GumX86Writer writer;
const cs_insn * insn;

// 初始化
gum_x86_writer_init (&writer, trampoline_buffer);
gum_x86_relocator_init (&relocator, original_function, &writer);

// 循环读取指令，直到搬够了需要的字节数
guint total_bytes = 0;
while (total_bytes < required_bytes)
{
  total_bytes = gum_x86_relocator_read_one (&relocator, &insn);

  // 你可以在这里检查指令
  // 比如打印: printf("  %s %s\n", insn->mnemonic, insn->op_str);
}

// 把所有读取的指令写入输出（自动修正地址）
gum_x86_relocator_write_all (&relocator);

// 在末尾加一条跳转，回到原函数的剩余部分
gum_x86_writer_put_jmp_address (&writer,
    GUM_ADDRESS (original_function + total_bytes));

gum_x86_writer_flush (&writer);
gum_x86_relocator_clear (&relocator);
gum_x86_writer_clear (&writer);
```

这段代码就是 Interceptor 构建 invoke trampoline 的核心逻辑（简化版）。

## 11.5 EOB 和 EOI

Relocator 有两个重要的状态标志：

```c
gboolean eob;   // End Of Block
gboolean eoi;   // End Of Input
```

- **EOB (End Of Block)**: 遇到了分支指令（jmp、call、ret 等），表示当前基本块结束了。后续指令可能不会被执行到。
- **EOI (End Of Input)**: 遇到了无法继续读取的情况。比如一条无条件跳转 `jmp` 之后，原始代码流就断了，不应该再继续读取。

```
  mov rax, 1
  cmp rax, 0
  je somewhere      <-- EOB = true (条件跳转，可能跳走)
  add rax, 1        <-- 还可以继续读取
  jmp elsewhere     <-- EOB = true, EOI = true (无条件跳转，后面不再可达)
  ???               <-- 不应该继续读取了
```

Interceptor 在搬移指令时会检查这些标志：如果还没搬够需要的字节数就遇到了 EOI，说明目标函数的开头包含一条无条件跳转，这种情况需要特殊处理。

## 11.6 不同架构的重定位挑战

### x86/x64 的挑战

x86 的主要难点是变长指令。你不知道一条指令有多长，直到你完全解码它。而且 x86 有很多种寻址模式，重定位逻辑相当复杂。

另外，x64 引入了 RIP 相对寻址，很多全局变量访问都使用这种方式：

```asm
; 原始位置 0x1000:
mov rax, [rip + 0x1234]    ; 实际访问 0x1000 + 7 + 0x1234 = 0x223B

; 搬到 0x5000 后，必须修改偏移量:
mov rax, [rip + 0xD234]    ; 保证还是访问 0x223B
```

### ARM64 的挑战

ARM64 的指令虽然固定 4 字节，但它的 PC 相对寻址范围比较有限：

```
┌────────────────┬──────────────────────┐
│  指令          │  PC 相对寻址范围     │
├────────────────┼──────────────────────┤
│ B (分支)       │ +/- 128 MB           │
│ B.cond         │ +/- 1 MB             │
│ CBZ/CBNZ       │ +/- 1 MB             │
│ TBZ/TBNZ       │ +/- 32 KB            │
│ ADR            │ +/- 1 MB             │
│ ADRP           │ +/- 4 GB             │
│ LDR (literal)  │ +/- 1 MB             │
└────────────────┴──────────────────────┘
```

如果指令搬移后，原始目标超出了新位置的寻址范围怎么办？Relocator 需要将一条简单的指令"展开"成多条指令：

```
原始（在 0x1000）:
  b.eq 0x2000          ; 条件跳转，目标在 1MB 内

搬到 0x80000000（很远的地方）后:
  b.ne skip            ; 反转条件，跳过下面的跳转
  ldr x17, [pc, #8]    ; 从附近的字面量池加载目标地址
  br x17               ; 间接跳转
skip:
  ...
  .quad 0x2000          ; 字面量池中存放原始目标地址
```

一条指令变成了好几条，这就是为什么 ARM64 Relocator 的 `can_relocate` 函数需要一个 `available_scratch_reg` 参数：

```c
gboolean gum_arm64_relocator_can_relocate (
    gpointer address,
    guint min_bytes,
    GumRelocationScenario scenario,
    guint * maximum,
    arm64_reg * available_scratch_reg);  // 需要一个临时寄存器
```

而 x86 版本不需要这个参数，因为 x86 的间接跳转可以直接用内存地址，不需要额外的寄存器。

## 11.7 can_relocate：预检查

在实际搬移代码之前，Frida 会先检查能否成功重定位：

```c
// x86 版本：简洁
gboolean gum_x86_relocator_can_relocate (
    gpointer address,
    guint min_bytes,     // 至少需要搬移多少字节
    guint * maximum);    // 输出：最多能搬多少字节

// ARM64 版本：更复杂
gboolean gum_arm64_relocator_can_relocate (
    gpointer address,
    guint min_bytes,
    GumRelocationScenario scenario,
    guint * maximum,
    arm64_reg * available_scratch_reg);
```

为什么需要预检查？因为有些指令可能无法安全重定位：

- 指令引用了相邻指令的地址（循环指令等）
- 代码中间有数据混杂（ARM Thumb 模式常见）
- 搬移后超出了可能的修正范围

## 11.8 Writer、Relocator 和 Interceptor 的协作

让我们看看这三者如何在 Hook 过程中协同工作：

```
┌─────────────────────────────────────────────────────────────┐
│  Interceptor Hook 流程中的角色分工                          │
│                                                             │
│  1. Interceptor 决定要 Hook 函数 foo()                      │
│     │                                                       │
│  2. Relocator 检查: can_relocate(foo, 跳转指令长度)         │
│     │                                                       │
│  3. Writer 创建 on_enter trampoline:                        │
│     │  ├─ put_push_all_registers()                          │
│     │  ├─ put_call(begin_invocation)                        │
│     │  ├─ put_pop_all_registers()                           │
│     │  └─ put_jmp(on_invoke_trampoline)                     │
│     │                                                       │
│  4. Relocator + Writer 创建 on_invoke trampoline:           │
│     │  ├─ Relocator: read_one() -- 读原始指令               │
│     │  ├─ Relocator: write_one() -- 修正后写入              │
│     │  ├─ (重复直到搬够字节)                                │
│     │  └─ Writer: put_jmp(foo + 偏移) -- 跳回原函数        │
│     │                                                       │
│  5. Writer 创建 on_leave trampoline:                        │
│     │  ├─ put_push_all_registers()                          │
│     │  ├─ put_call(end_invocation)                          │
│     │  ├─ put_pop_all_registers()                           │
│     │  └─ put_ret() 或 put_jmp(返回地址)                    │
│     │                                                       │
│  6. Writer 改写原函数入口:                                  │
│     │  └─ put_jmp(on_enter_trampoline)                      │
│     │                                                       │
│  7. 刷新指令缓存，Hook 生效                                 │
└─────────────────────────────────────────────────────────────┘
```

三者的关系简单来说：

- **Writer** 是"笔"，负责写入机器码
- **Relocator** 是"搬运工"，负责把代码从一个地方搬到另一个地方并修正地址
- **Interceptor** 是"总指挥"，决定搬什么、往哪搬、怎么连接

## 11.9 overwritten_prologue 的秘密

回顾 `GumFunctionContext` 中的字段：

```c
guint8 overwritten_prologue[32];
guint overwritten_prologue_len;
```

为什么是 32 字节？

在 x86_64 上，一条 `jmp` 跳转指令通常需要 5 字节（1 字节操作码 + 4 字节偏移）。但如果目标太远（超过 2GB），可能需要 14 字节（6 字节操作码 + 8 字节绝对地址）。所以 Frida 需要搬走至少这么多字节的原始代码。

在 ARM64 上，最简单的跳转是 4 字节的 `B` 指令，但如果距离超过 128MB，可能需要更长的指令序列。

32 字节的缓冲区足以覆盖所有架构的最坏情况。

## 11.10 一个完整的重定位例子

假设我们要 Hook 这个函数：

```asm
; 原始函数在 0x401000
0x401000: push rbp
0x401001: mov rbp, rsp
0x401004: call 0x402000      ; 相对偏移 = 0x402000 - 0x401009 = 0x0FF7
0x401009: pop rbp
0x40100A: ret
```

Interceptor 需要用 5 字节的 `jmp` 替换开头。我们需要搬走前 9 字节（到 `call` 指令结束）：

```asm
; trampoline 在 0x700000
0x700000: push rbp           ; 原样复制，无需修正
0x700001: mov rbp, rsp       ; 原样复制，无需修正
0x700004: call 0x402000      ; 偏移需要修正！
                             ; 新偏移 = 0x402000 - 0x700009 = 0xFFF01FF7
                             ; (在 32 位偏移范围内，可以修正)
0x700009: jmp 0x401009       ; Writer 生成：跳回原函数剩余部分

; 原函数被改写为:
0x401000: jmp on_enter_trampoline  ; 5 字节
0x401005: nop                      ; 填充
0x401006: nop
0x401007: nop
0x401008: nop
0x401009: pop rbp                  ; 不变
0x40100A: ret                      ; 不变
```

Relocator 在这个过程中自动完成了 `call` 指令偏移量的修正。

## 11.11 静态重定位辅助函数

Relocator 还提供了一个简便的静态函数，不需要手动管理 Reader/Writer 的生命周期：

```c
// 一步到位：从 from 复制至少 min_bytes 到 to，返回实际复制的字节数
guint gum_x86_relocator_relocate (
    gpointer from,
    guint min_bytes,
    gpointer to);

guint gum_arm64_relocator_relocate (
    gpointer from,
    guint min_bytes,
    gpointer to);
```

这个函数内部创建临时的 Writer 和 Relocator，完成重定位后自动清理。适合简单场景。

## 11.12 本章小结

- Relocator 解决的核心问题是：将指令从一个地址搬到另一个地址时，修正所有 PC 相对寻址
- 内部使用 Capstone 反汇编引擎解析指令，使用 Writer 生成修正后的指令
- `read_one` / `write_one` 是核心操作模式，逐条读取、逐条写入
- `eob` 和 `eoi` 标志帮助判断是否到达基本块或代码流的边界
- ARM64 的重定位比 x86 更复杂，因为 PC 相对寻址范围有限，可能需要将一条指令展开为多条
- Writer、Relocator、Interceptor 三者协作完成整个 Hook 流程

## 讨论问题

1. 如果目标函数的前几条指令中包含一条 `jmp` 到自身的指令（比如一个 spin loop），Relocator 搬移后这条指令应该跳到哪里？跳到 trampoline 中的新位置还是原来的位置？

2. 为什么 ARM64 Relocator 的 `can_relocate` 需要一个 `available_scratch_reg` 参数而 x86 版本不需要？结合两种架构的间接跳转机制来分析。

3. 在现代操作系统中，代码段通常是不可写的。Interceptor 在改写函数入口时需要先修改内存保护属性。这个操作在 Frida 的源码中是由谁负责的？（提示：回顾第8章的 `GumCodeAllocator` 和事务机制）

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
