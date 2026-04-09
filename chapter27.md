# 第27章：跨平台设计——一套代码，多个世界

> 你有没有想过，一个软件怎么做到在 Windows、macOS、Linux、iOS、Android 上都能运行？这不是简单地把代码复制五份然后分别改改就行的。Frida 的跨平台设计是一个值得深入学习的工程案例。

## 27.1 跨平台的本质挑战

想象一下，你要写一封信，收件人分别在中国、美国、日本。内容是一样的，但你需要用中文、英文、日文各写一遍。更复杂的是，每个国家的信封格式、邮编规则、地址写法都不一样。

操作系统之间的差异也是如此：

```
┌──────────────────────────────────────────────────┐
│          同一功能，不同平台的实现方式               │
├──────────────┬────────────┬───────────────────────┤
│    功能      │  Linux     │  macOS/iOS            │
├──────────────┼────────────┼───────────────────────┤
│ 读进程内存   │ process_   │ mach_vm_read          │
│              │ vm_readv   │                       │
├──────────────┼────────────┼───────────────────────┤
│ 修改内存保护 │ mprotect   │ mach_vm_protect       │
├──────────────┼────────────┼───────────────────────┤
│ 枚举线程     │ 读/proc/   │ task_threads          │
│              │ self/task  │                       │
├──────────────┼────────────┼───────────────────────┤
│ 枚举模块     │ dl_iterate │ _dyld_image_count +   │
│              │ _phdr      │ _dyld_get_image_*     │
├──────────────┼────────────┼───────────────────────┤
│ TLS操作      │ pthread_   │ pthread_key_create    │
│              │ key_create │ (或自定义实现)         │
├──────────────┼────────────┼───────────────────────┤
│ 页大小查询   │ sysconf    │ getpagesize           │
└──────────────┴────────────┴───────────────────────┘
```

Frida 的策略是：**定义统一的接口，每个平台各自实现**。这听起来像是教科书上的话，但 Frida 的做法有很多值得学习的细节。

## 27.2 后端模式（Backend Pattern）

打开 `frida-gum/gum/` 目录，你会看到这样的目录结构：

```
gum/
├── gummemory.h              <-- 统一接口定义
├── gummemory.c              <-- 跨平台通用逻辑
├── gumprocess.h             <-- 统一接口定义
├── gummodule.h              <-- 统一接口定义
│
├── backend-darwin/
│   ├── gummemory-darwin.c   <-- macOS/iOS 实现
│   ├── gumprocess-darwin.c
│   └── gummodule-darwin.c
│
├── backend-linux/
│   ├── gummemory-linux.c    <-- Linux/Android 实现
│   ├── gumprocess-linux.c
│   └── gummodule-linux.c
│
├── backend-windows/
│   ├── gummemory-windows.c  <-- Windows 实现
│   ├── gumprocess-windows.c
│   └── gummodule-windows.c
│
├── backend-freebsd/         <-- FreeBSD 实现
├── backend-qnx/             <-- QNX 实现
│
├── backend-arm64/           <-- ARM64 架构特定
├── backend-arm/             <-- ARM 架构特定
├── backend-x86/             <-- x86 架构特定
│
└── backend-posix/           <-- POSIX 通用实现
    ├── gumtls-posix.c
    └── gummemoryaccessmonitor-posix.c
```

注意这里有两个维度的后端：**操作系统后端**和**CPU架构后端**。一个运行在 Linux 上的 ARM64 设备，会同时使用 `backend-linux/` 和 `backend-arm64/` 中的代码。

```
┌──────────────────────────────────────────────┐
│           后端的两个维度                      │
│                                              │
│  ┌────────┐   ┌─────────────────────┐        │
│  │ 上层   │   │ gumprocess.h        │        │
│  │ 接口   │   │ gummemory.h         │        │
│  │        │   │ gummodule.h         │        │
│  └────┬───┘   └──────────┬──────────┘        │
│       │                  │                   │
│       v                  v                   │
│  ┌─────────┐  ┌───────────────────────┐      │
│  │ OS 层   │  │ darwin / linux / win   │      │
│  │ 后端    │  │ 内存、进程、模块管理     │      │
│  └─────────┘  └───────────────────────┘      │
│       │                                      │
│       v                                      │
│  ┌─────────┐  ┌───────────────────────┐      │
│  │ 架构层  │  │ arm64 / arm / x86      │      │
│  │ 后端    │  │ 寄存器、指令、Stalker   │      │
│  └─────────┘  └───────────────────────┘      │
│                                              │
└──────────────────────────────────────────────┘
```

## 27.3 GumProcess：进程操作的统一抽象

`gumprocess.h` 定义了跨平台的进程操作接口。我们来看几个关键函数：

```c
// 获取进程 ID —— 每个平台都有，但调用方式不同
GumProcessId gum_process_get_id (void);

// 枚举所有线程 —— Linux 读 /proc，macOS 用 Mach API
void gum_process_enumerate_threads (GumFoundThreadFunc func,
    gpointer user_data, GumThreadFlags flags);

// 枚举所有模块 —— Linux 用 dl_iterate_phdr，macOS 用 dyld API
void gum_process_enumerate_modules (GumFoundModuleFunc func,
    gpointer user_data);

// 枚举内存范围
void gum_process_enumerate_ranges (GumPageProtection prot,
    GumFoundRangeFunc func, gpointer user_data);
```

每个平台的 `gumprocess-xxx.c` 文件实现相同的函数签名，但内部实现完全不同。以 `gum_process_enumerate_ranges` 为例：

- **Linux**: 解析 `/proc/self/maps` 文件
- **macOS**: 使用 `mach_vm_region` 迭代虚拟内存区域
- **Windows**: 使用 `VirtualQuery` 遍历地址空间

这些实现细节被完全封装在后端文件中，上层代码只需要调用统一的接口。

## 27.4 GumModule：模块抽象的接口模式

`GumModule` 使用了 GObject 的接口（Interface）机制，这是一个更优雅的跨平台设计：

```c
struct _GumModuleInterface
{
  GTypeInterface parent;

  const gchar * (* get_name) (GumModule * self);
  const gchar * (* get_path) (GumModule * self);
  const GumMemoryRange * (* get_range) (GumModule * self);
  void (* enumerate_imports) (GumModule * self, ...);
  void (* enumerate_exports) (GumModule * self, ...);
  void (* enumerate_symbols) (GumModule * self, ...);
  GumAddress (* find_export_by_name) (GumModule * self, ...);
  // ...
};
```

这是一个虚函数表（vtable）。不同平台创建不同的 GumModule 实现：

```
┌──────────────────────────────────────────────┐
│         GumModule 的平台实现                  │
│                                              │
│           GumModule (接口)                    │
│           ┌──────────────┐                   │
│           │ get_name     │                   │
│           │ get_path     │                   │
│           │ enum_imports │                   │
│           │ enum_exports │                   │
│           │ find_export  │                   │
│           └──────┬───────┘                   │
│                  │                           │
│    ┌─────────────┼──────────────┐            │
│    v             v              v            │
│  Darwin        Linux         Windows        │
│  (Mach-O)     (ELF)         (PE)            │
│  ┌────────┐  ┌────────┐   ┌────────┐       │
│  │解析     │  │解析     │   │解析     │       │
│  │load     │  │.dynsym │   │export  │       │
│  │commands │  │.symtab │   │table   │       │
│  └────────┘  └────────┘   └────────┘       │
│                                              │
└──────────────────────────────────────────────┘
```

这样设计的好处是：当你在 JavaScript 中调用 `Module.enumerateExports()` 时，底层会自动分发到正确的平台实现，而你完全不需要关心目标是 ELF、Mach-O 还是 PE 格式。

## 27.5 Meson 构建系统中的条件编译

Frida 使用 Meson 构建系统来管理跨平台编译。看看 `gum/meson.build` 中的关键片段：

```python
# 根据目标操作系统选择后端源文件
if host_os_family == 'windows'
  gum_sources += [
    'backend-windows' / 'gummemory-windows.c',
    'backend-windows' / 'gumprocess-windows.c',
    'backend-windows' / 'gummodule-windows.c',
    'backend-windows' / 'gumtls-windows.c',
    # ...
  ]
elif host_os_family == 'darwin'
  gum_sources += [
    'backend-darwin' / 'gummemory-darwin.c',
    'backend-darwin' / 'gumprocess-darwin.c',
    'backend-darwin' / 'gummodule-darwin.c',
    # ...
  ]
elif host_os_family == 'linux'
  gum_sources += [
    'backend-linux' / 'gummemory-linux.c',
    'backend-linux' / 'gumprocess-linux.c',
    'backend-linux' / 'gummodule-linux.c',
    'backend-posix' / 'gumtls-posix.c',
    # ...
  ]
endif
```

注意 `backend-posix/` 目录的存在。POSIX 是 Unix 系操作系统的公共标准，Linux 和 macOS 都遵循。所以有些功能（比如 TLS、异常处理）可以共享 POSIX 实现，不需要每个平台都写一遍。

```
┌──────────────────────────────────────────────┐
│          代码复用的层次                       │
│                                              │
│  最上层：gummemory.c (完全通用)               │
│          所有平台共享的逻辑                   │
│          如：内存扫描、模式匹配                │
│                                              │
│  中间层：backend-posix/ (Unix 通用)           │
│          Linux + macOS + FreeBSD 共享         │
│          如：TLS、异常处理器                   │
│                                              │
│  底层：backend-linux/ 或 backend-darwin/      │
│        平台专属实现                           │
│        如：内存读写、进程枚举                  │
│                                              │
└──────────────────────────────────────────────┘
```

## 27.6 C 预处理器中的平台分支

除了构建系统层面的文件选择，Frida 在代码内部也大量使用预处理器来处理平台差异：

```c
// gummemory.c 中的平台分支示例
gpointer
gum_sign_code_pointer (gpointer value)
{
#ifdef HAVE_PTRAUTH
  return ptrauth_sign_unauthenticated (value,
      ptrauth_key_asia, 0);
#else
  return value;
#endif
}
```

ARM64 上的指针认证（PAC）只在支持的硬件上存在，所以用 `#ifdef` 来区分。

再看 Linux 内存后端中，不同 CPU 架构的系统调用号差异：

```c
// gummemory-linux.c
#if defined (HAVE_I386) && GLIB_SIZEOF_VOID_P == 4
# define GUM_SYS_PROCESS_VM_READV   347
#elif defined (HAVE_I386) && GLIB_SIZEOF_VOID_P == 8
# define GUM_SYS_PROCESS_VM_READV   310
#elif defined (HAVE_ARM)
# define GUM_SYS_PROCESS_VM_READV   (__NR_SYSCALL_BASE + 376)
#elif defined (HAVE_ARM64)
# define GUM_SYS_PROCESS_VM_READV   270
#endif
```

同一个操作系统上，不同的 CPU 架构连系统调用号都不一样。这就是跨平台开发的残酷现实。

## 27.7 TLS 抽象：一个简洁的例子

线程局部存储（TLS）是跨平台抽象的理想教学案例。`gumtls.h` 定义了四个函数：`gum_tls_key_new`、`gum_tls_key_free`、`gum_tls_key_get_value`、`gum_tls_key_set_value`。POSIX 实现（`gumtls-posix.c`）用 `pthread_key_create`/`pthread_getspecific`，Windows 实现用 `TlsAlloc`/`TlsGetValue`，macOS 还有独立的 `gumtls-darwin.c` 处理 Darwin 特有细节。四个函数，三个平台，每个平台几十行代码——接口简单，实现清晰。

## 27.8 抽象泄漏：跨平台的代价

但现实没有那么美好。在某些地方，平台差异大到无法完全抽象掉。这就是所谓的"抽象泄漏"（Leaky Abstraction）。

**例子1：macOS 的 Mach 端口**

macOS 的进程间通信基于 Mach 端口。很多 Darwin 特有的功能（如 `gumdarwinmapper.c`、`gumdarwinsymbolicator.c`）没有跨平台的对应物，只能作为平台专属模块存在。

**例子2：Android 的特殊性**

虽然 Android 是 Linux 内核，但它的用户空间差异很大。所以 Frida 专门有 `gumandroid.c` 来处理 Android 特有的问题，比如 linker namespace、SELinux 策略等。

**例子3：符号类型的差异**

`GumSymbolType` 枚举把 Mach-O 特有的类型（`GUM_SYMBOL_UNDEFINED`、`GUM_SYMBOL_INDIRECT` 等）和 ELF 特有的类型（`GUM_SYMBOL_OBJECT`、`GUM_SYMBOL_FUNCTION` 等）放在同一个枚举里。接口统一了，但数据模型必须包含所有平台的并集——这是务实的妥协。

同样，Stalker 的每种 CPU 架构都有数千行的独立实现（`gumstalker-x86.c`、`gumstalker-arm.c`、`gumstalker-arm64.c`），因为指令编码差异太大，无法用 `#ifdef` 解决。

## 27.9 给你自己项目的启示

从 Frida 的跨平台设计中，我们可以提炼出几个实用原则：

```
┌──────────────────────────────────────────────┐
│        跨平台设计的实用原则                    │
├──────────────────────────────────────────────┤
│                                              │
│  1. 接口先行：先定义 .h 文件，再写各平台 .c   │
│                                              │
│  2. 分层复用：通用 > POSIX > 平台专属          │
│     能共享的尽量共享，不能共享的才分开          │
│                                              │
│  3. 构建系统做大切分（选文件）                 │
│     预处理器做小切分（选代码段）               │
│                                              │
│  4. 接受抽象泄漏：有些平台特性无法完美抽象     │
│     用注释标明，而不是硬往接口里塞             │
│                                              │
│  5. 目录结构即架构：一眼就能看出哪些是通用的   │
│     哪些是平台专属的                          │
│                                              │
└──────────────────────────────────────────────┘
```

## 27.10 本章小结

- Frida 使用"统一接口 + 多后端实现"的模式处理跨平台差异
- 后端分为两个维度：操作系统后端（darwin/linux/windows）和 CPU 架构后端（arm64/arm/x86）
- `GumModule` 使用 GObject 接口机制实现多态，`GumProcess` 使用同名函数的不同实现文件
- Meson 构建系统负责根据目标平台选择正确的源文件
- `backend-posix/` 提供了 Unix 系平台的共享实现，减少重复代码
- 抽象泄漏不可避免，务实的做法是在保持接口统一的前提下，用注释标明平台特有的部分
- 好的目录结构本身就是最好的架构文档

## 讨论问题

1. Frida 的后端模式和经典的"策略模式"有什么异同？在 C 语言中没有虚函数的情况下，GumModule 是如何通过 GObject 接口实现多态的？

2. 如果你要给 Frida 添加一个新的操作系统后端（比如 Fuchsia），你需要实现哪些文件？从 meson.build 的结构中能得到什么指引？

3. Frida 选择在构建系统层面（而非运行时）切换平台实现，这种静态分发策略相比运行时策略（如动态加载插件）有什么优缺点？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
