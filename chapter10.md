# 第10章：代码生成器 -- 跨架构的机器语言

> 你有没有想过一个问题：Frida 在运行时需要往内存中写入新的机器码（比如跳转指令、跳板代码），这些机器码是怎么生成的？总不能手工一个字节一个字节地拼吧？

## 10.1 为什么 Frida 需要在运行时写机器码？

回忆一下前两章的内容：

- Interceptor 需要在目标函数开头写一条跳转指令
- Interceptor 需要生成跳板代码（保存寄存器、调用回调、恢复寄存器）
- Stalker 需要把原始基本块编译成插桩后的副本

这些操作都需要在运行时动态生成机器码。而且 Frida 是跨平台的，需要支持 x86、x86_64、ARM、ARM64（AArch64）、MIPS 等架构。每种架构的指令编码都不同，手动拼字节简直是噩梦。

所以 Frida 设计了一套 **Writer** 抽象层：你告诉它"我要生成一条 push 指令"，它自动帮你把这条指令编码成对应架构的机器码。

这就像一个多语言翻译器：你用"通用描述"说出你要做的事，它帮你翻译成法语、德语或日语。

## 10.2 Writer 的基本结构

以 `GumX86Writer` 为例，它的结构体：

```c
struct _GumX86Writer
{
  volatile gint ref_count;
  gboolean flush_on_destroy;

  GumCpuType target_cpu;        // 目标 CPU 类型（x86 还是 x64）
  GumAbiType target_abi;        // 目标 ABI

  guint8 * base;                // 代码缓冲区起始地址
  guint8 * code;                // 当前写入位置（游标）
  GumAddress pc;                // 当前 PC 值

  GumMetalHashTable * label_defs;  // 标签定义表
  GumMetalArray label_refs;        // 标签引用列表
};
```

再看 `GumArm64Writer`：

```c
struct _GumArm64Writer
{
  volatile gint ref_count;
  gboolean flush_on_destroy;

  GumArm64DataEndian data_endian;  // 数据端序
  GumOS target_os;                 // 目标操作系统
  GumPtrauthSupport ptrauth_support; // 指针认证支持

  guint32 * base;               // 代码缓冲区（注意是 guint32*）
  guint32 * code;               // 当前写入位置
  GumAddress pc;                // 当前 PC 值

  GumMetalHashTable * label_defs;
  GumMetalArray label_refs;
  GumMetalArray literal_refs;         // 字面量引用
  const guint32 * earliest_literal_insn;
};
```

注意一个重要区别：x86 的 `code` 指针是 `guint8 *`（字节指针），而 ARM64 的是 `guint32 *`（4字节指针）。这是因为 x86 指令变长（1到15字节不等），而 ARM64 指令固定4字节。

```
x86 指令（变长）:
┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
│55│48│89│e5│48│83│ec│20│48│8b│05│xx│xx│ ...
│ 1字节 │    3字节     │    3字节     │
│ push  │  mov rbp,rsp │  sub rsp,32  │
└──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘

ARM64 指令（固定4字节）:
┌──────────┬──────────┬──────────┬──────────┐
│ fd7bbfa9 │ fd030091 │ ff830051 │ e00f40f9 │
│  stp     │  mov     │  sub     │  ldr     │
│ (4字节)  │ (4字节)  │ (4字节)  │ (4字节)  │
└──────────┴──────────┴──────────┴──────────┘
```

## 10.3 Writer 的使用模式

所有 Writer 都遵循相同的使用模式：

```c
// 1. 创建或初始化
GumX86Writer writer;
gum_x86_writer_init (&writer, code_buffer);

// 2. 生成指令
gum_x86_writer_put_push_reg (&writer, GUM_X86_RBP);
gum_x86_writer_put_mov_reg_reg (&writer, GUM_X86_RBP, GUM_X86_RSP);
gum_x86_writer_put_sub_reg_imm (&writer, GUM_X86_RSP, 0x20);

// 3. 刷新（处理延迟的标签引用等）
gum_x86_writer_flush (&writer);

// 4. 清理
gum_x86_writer_clear (&writer);
```

Writer 就像一支笔，`init` 是告诉它从哪里开始写，每个 `put_*` 调用写入一条指令，写完后 `flush` 确保所有内容都已最终确定。

## 10.4 常用操作对照表

下面这张表列出了常见操作在不同架构下的 Writer API：

```
┌─────────────────┬────────────────────────────┬─────────────────────────────┐
│     操作        │       X86 Writer           │       ARM64 Writer          │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 函数调用        │ put_call_address(addr)     │ put_bl_imm(addr)            │
│                 │ put_call_reg(reg)          │ put_blr_reg(reg)            │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 无条件跳转      │ put_jmp_address(addr)      │ put_b_imm(addr)             │
│                 │ put_jmp_reg(reg)           │ put_br_reg(reg)             │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 函数返回        │ put_ret()                  │ put_ret()                   │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 压栈            │ put_push_reg(reg)          │ put_push_reg_reg(a, b)      │
│                 │                            │ (ARM64 必须成对压栈)        │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 出栈            │ put_pop_reg(reg)           │ put_pop_reg_reg(a, b)       │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 寄存器赋值      │ put_mov_reg_u64(reg, val)  │ put_ldr_reg_u64(reg, val)   │
│                 │ put_mov_reg_reg(dst, src)  │ put_mov_reg_reg(dst, src)   │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 加法            │ put_add_reg_imm(reg, val)  │ put_add_reg_reg_imm(d,s,v)  │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ NOP             │ put_nop()                  │ put_nop()                   │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 断点            │ put_breakpoint()           │ put_brk_imm(0)              │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 保存全部寄存器  │ put_pushax()               │ put_push_all_x_registers()  │
│ 恢复全部寄存器  │ put_popax()                │ put_pop_all_x_registers()   │
├─────────────────┼────────────────────────────┼─────────────────────────────┤
│ 标签定义        │ put_label(id)              │ put_label(id)               │
│ 跳转到标签      │ put_jmp_near_label(id)     │ put_b_label(id)             │
└─────────────────┴────────────────────────────┴─────────────────────────────┘
```

注意 ARM64 的压栈必须成对操作（`push_reg_reg`），这是因为 ARM64 要求栈指针 16 字节对齐，两个 8 字节寄存器正好 16 字节。而 x86 可以单个寄存器压栈。

## 10.5 带参数的函数调用

Writer 最强大的功能之一是生成带参数的函数调用。这在不同架构下差异巨大：

- x86_64 Linux/macOS: 前6个参数通过 rdi, rsi, rdx, rcx, r8, r9 传递
- x86_64 Windows: 前4个参数通过 rcx, rdx, r8, r9 传递
- ARM64: 前8个参数通过 x0-x7 传递

Writer 帮你屏蔽了这些差异：

```c
// X86: 生成一个带参数的调用
gum_x86_writer_put_call_address_with_arguments (&writer,
    GUM_CALL_CAPI,         // 调用约定
    target_address,         // 函数地址
    2,                      // 参数个数
    GUM_ARG_ADDRESS, some_ptr,   // 参数1：地址
    GUM_ARG_REGISTER, GUM_X86_RBX); // 参数2：寄存器值

// ARM64: 同样的操作
gum_arm64_writer_put_call_address_with_arguments (&writer,
    target_address,
    2,
    GUM_ARG_ADDRESS, some_ptr,
    GUM_ARG_REGISTER, ARM64_REG_X19);
```

Writer 内部会自动生成"把参数放到正确位置"的代码，你不需要关心具体的调用约定。

## 10.6 标签系统（Label System）

在生成代码时，经常需要向前跳转到一个还没生成的位置。比如：

```
  cmp rax, 0
  je skip_block      <-- 这里需要跳到 skip_block，但它还没生成
  ... 一些代码 ...
skip_block:           <-- 到这里才定义
  ... 继续 ...
```

Writer 用标签系统来解决这个"先有鸡还是先有蛋"的问题：

```c
// 定义一个标签 ID
const gchar * skip_label = "skip_block";

// 生成跳转到标签的指令（此时目标地址未知）
gum_x86_writer_put_jcc_near_label (&writer,
    X86_INS_JE, skip_label, GUM_NO_HINT);

// 生成其他代码 ...
gum_x86_writer_put_nop (&writer);

// 定义标签（记录当前位置）
gum_x86_writer_put_label (&writer, skip_label);

// flush 时，Writer 回填之前跳转指令中的偏移量
gum_x86_writer_flush (&writer);
```

内部实现的原理：

```
┌────────────────────────────────────────────────────┐
│  Writer 标签解析过程                                │
│                                                    │
│  第1步：遇到 jcc_near_label("skip")               │
│    - 写入 jcc 操作码                               │
│    - 偏移量暂时填 0                                │
│    - 记录到 label_refs: {id="skip", 位置=0x10}     │
│                                                    │
│  第2步：遇到 put_label("skip")                     │
│    - 记录到 label_defs: {id="skip", 地址=0x20}     │
│                                                    │
│  第3步：flush()                                    │
│    - 遍历 label_refs                               │
│    - 找到 "skip" 的定义地址 0x20                   │
│    - 计算偏移量: 0x20 - 0x10 - 指令长度            │
│    - 回填到第1步写入的位置                          │
└────────────────────────────────────────────────────┘
```

ARM64 Writer 还有一个额外的 `literal_refs` 机制，用于处理字面量池。因为 ARM64 没有大立即数指令，加载一个 64 位常量需要从附近内存读取，Writer 会在代码末尾放置一个字面量池。

## 10.7 距离限制与处理

不同架构的跳转指令有不同的距离限制：

```
┌──────────────┬──────────────────────────────────────┐
│   架构       │  直接跳转最大距离                     │
├──────────────┼──────────────────────────────────────┤
│ x86 short jmp│  +/- 127 字节                        │
│ x86 near jmp │  +/- 2GB                             │
│ ARM64 B      │  +/- 128MB (GUM_ARM64_B_MAX_DISTANCE)│
│ ARM64 ADRP   │  +/- 4GB (GUM_ARM64_ADRP_MAX_DISTANCE)│
└──────────────┴──────────────────────────────────────┘
```

Writer 提供了辅助函数来检查距离：

```c
// x86: 判断能否直接跳转
gboolean gum_x86_writer_can_branch_directly_between (
    GumAddress from, GumAddress to);

// ARM64: 判断能否直接跳转
gboolean gum_arm64_writer_can_branch_directly_between (
    GumArm64Writer * self, GumAddress from, GumAddress to);
```

如果超出直接跳转范围，Frida 需要使用间接跳转：先把目标地址加载到寄存器，再通过寄存器跳转。ARM64 Writer 的 `put_branch_address` 函数会自动处理这种情况：

```c
// 这个函数会自动选择最优策略：
// 距离近 -> 直接 B 指令
// 距离远 -> LDR + BR 组合
void gum_arm64_writer_put_branch_address (
    GumArm64Writer * self, GumAddress address);
```

## 10.8 x86 的 Meta 寄存器

`GumX86Writer` 定义了一组有趣的"Meta 寄存器"：

```c
enum _GumX86Reg
{
  GUM_X86_EAX,    // 32位
  GUM_X86_RAX,    // 64位
  GUM_X86_XAX,    // Meta: 32位模式下是 EAX，64位模式下是 RAX
  GUM_X86_XCX,    // Meta: ECX 或 RCX
  GUM_X86_XSP,    // Meta: ESP 或 RSP
  GUM_X86_XIP,    // Meta: EIP 或 RIP
  // ...
};
```

Meta 寄存器以 `X` 开头（如 `XAX`, `XSP`），它们会根据 Writer 的目标 CPU 类型自动选择 32 位或 64 位版本。这让同一段代码生成逻辑可以同时支持 x86 和 x64。

## 10.9 ARM64 的特殊考虑

ARM64 Writer 还需要处理一些 ARM64 特有的问题：

**指针认证（Pointer Authentication）**：Apple Silicon 支持 PAC，指针在使用前需要签名验证。Writer 提供了：

```c
// 去除指针签名
gboolean gum_arm64_writer_put_xpaci_reg (
    GumArm64Writer * self, arm64_reg reg);

// 对地址进行签名
GumAddress gum_arm64_writer_sign (
    GumArm64Writer * self, GumAddress value);
```

**端序（Endianness）**：虽然 ARM64 指令总是小端序，但数据可以是大端序。Writer 的 `data_endian` 字段控制写入数据时的端序。

## 10.10 实际例子：生成一段完整的跳板代码

让我们看看 Interceptor 可能生成的 on_enter 跳板代码（简化版）：

```c
// ARM64 版本的 on_enter trampoline 伪代码
void generate_enter_trampoline (GumArm64Writer * cw,
                                 GumFunctionContext * ctx)
{
  // 保存所有通用寄存器
  gum_arm64_writer_put_push_all_x_registers (cw);

  // 保存所有浮点寄存器
  gum_arm64_writer_put_push_all_q_registers (cw);

  // 把 FunctionContext 指针作为第一个参数
  gum_arm64_writer_put_ldr_reg_address (cw, ARM64_REG_X0,
      GUM_ADDRESS (ctx));

  // 把 CPU 上下文指针作为第二个参数
  gum_arm64_writer_put_mov_reg_reg (cw,
      ARM64_REG_X1, ARM64_REG_SP);

  // 调用 C 函数处理回调
  gum_arm64_writer_put_call_address_with_arguments (cw,
      GUM_ADDRESS (_gum_function_context_begin_invocation),
      2,
      GUM_ARG_REGISTER, ARM64_REG_X0,
      GUM_ARG_REGISTER, ARM64_REG_X1);

  // 恢复浮点寄存器
  gum_arm64_writer_put_pop_all_q_registers (cw);

  // 恢复通用寄存器
  gum_arm64_writer_put_pop_all_x_registers (cw);

  // 跳到 on_invoke_trampoline 执行原函数
  gum_arm64_writer_put_b_imm (cw,
      GUM_ADDRESS (ctx->on_invoke_trampoline));
}
```

这段代码展示了 Writer 的典型使用方式：一条一条地"说出"你想要的指令，Writer 把它们编码成真正的机器码。

## 10.11 辅助工具函数

Writer 还提供了一些方便的辅助函数：

```c
// 获取当前写入位置
gpointer gum_x86_writer_cur (GumX86Writer * self);

// 获取已写入的偏移量
guint gum_x86_writer_offset (GumX86Writer * self);

// 直接写入原始字节
void gum_x86_writer_put_bytes (GumX86Writer * self,
    const guint8 * data, guint n);

// 写入填充（padding）
void gum_x86_writer_put_nop_padding (GumX86Writer * self, guint n);

// 获取第 N 个参数对应的寄存器
GumX86Reg gum_x86_writer_get_cpu_register_for_nth_argument (
    GumX86Writer * self, guint n);
```

最后一个函数很巧妙：它根据当前的 ABI（调用约定）告诉你第 N 个参数应该放在哪个寄存器里。

## 10.12 本章小结

- Writer 是 Frida 的代码生成抽象层，将"生成指令"的操作与具体的指令编码解耦
- 每种架构有对应的 Writer：`GumX86Writer`、`GumArm64Writer` 等
- x86 指令变长，ARM64 指令固定 4 字节，这导致两者的 Writer 实现细节不同
- 标签系统解决了前向引用的问题，通过 flush 时回填偏移量实现
- Writer 自动处理调用约定、距离限制、指针认证等平台差异
- 每个 `put_*` 调用直接在缓冲区中写入编码后的机器码字节

## 讨论问题

1. 为什么 ARM64 Writer 需要一个 `literal_refs` 机制而 x86 Writer 不需要？这和两种架构的立即数处理方式有什么关系？

2. 在使用标签系统时，如果一个标签被引用了但从未被定义，`flush` 时会发生什么？Frida 如何处理这种错误？

3. 假设你需要在 ARM64 上生成一段代码，跳转到一个 200MB 之外的地址。`put_b_imm` 会失败（超出 128MB 限制），你会怎么用 Writer API 来实现这个跳转？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
