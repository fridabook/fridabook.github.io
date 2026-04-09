# 第7章：构建系统——Meson 与交叉编译

> 你写了一个 C 程序，在你的 Mac 上编译通过了。但你的目标是让它跑在 Android 手机、iOS 设备、Windows 电脑、甚至路由器上。怎么办？你不可能在每个平台上手动敲编译命令。Frida 面临的就是这个问题——它需要在十几种平台和架构组合上构建。今天我们来看 Frida 是怎么用 Meson 构建系统解决这个难题的。

## 7.1 为什么选择 Meson？

在 Frida 的历史上，构建系统经历过演变，最终选定了 Meson。为什么不用更"传统"的 CMake 或 Autotools？

Meson 的几个特点特别适合 Frida 这样的项目：

```
┌─────────────────────────────────────────────────────┐
│              为什么 Meson 适合 Frida                  │
├─────────────────────────────────────────────────────┤
│                                                     │
│  1. 原生交叉编译支持                                │
│     - cross file 机制简洁直观                       │
│     - 清晰区分 host 和 build 机器                   │
│                                                     │
│  2. 子项目（subproject）管理                        │
│     - frida-gum、frida-core 等天然适合子项目模式    │
│     - 依赖在构建时自动解析                          │
│                                                     │
│  3. 构建速度快                                      │
│     - 后端使用 Ninja，并行编译效率高                │
│     - 配置阶段也比 CMake 快                         │
│                                                     │
│  4. 语法简洁可读                                    │
│     - 没有 CMake 那种"宏地狱"                      │
│     - 不像 Autotools 需要 m4 宏和 shell 脚本       │
│                                                     │
│  5. 多语言支持                                      │
│     - C、C++、Vala、Objective-C 都原生支持          │
│     - Frida 恰好需要所有这些语言                    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

特别是第 5 点——Frida 的代码库同时使用了 C（Gum 核心）、C++（V8 集成）、Vala（frida-core）、Objective-C（Darwin 平台支持），能原生支持所有这些语言的构建系统并不多。

## 7.2 顶层 meson.build 结构

Frida 的顶层 `meson.build` 是整个构建系统的"指挥中心"。我们来逐段解读：

```python
project('frida', 'c',
  version: run_command('releng' / 'frida_version.py', check: true).stdout().strip(),
  meson_version: '>=1.1.0',
)
```

第一行就有一个有趣的设计：版本号不是硬编码的，而是通过 Python 脚本动态获取。这意味着版本号有一个"单一真相源"（single source of truth），避免了多处版本号不一致的问题。

### 子项目编排

接下来是核心的子项目组织：

```python
# 首先构建 Gum（插桩引擎）
gum_options = [
  'frida_version=' + meson.project_version(),
  'gumjs=enabled',
]
subproject('frida-gum', default_options: gum_options)

# 然后构建 Core（核心框架）
core_options = [
  'frida_version=' + meson.project_version(),
]
# 根据条件决定是否构建各组件
foreach component : ['server', 'portal', 'inject']
  core_options += component + '=' + (get_option(component)
    .disable_auto_if(not is_cross_build)
    .disable_auto_if(is_watchos)
    .allowed() ? 'enabled' : 'disabled')
endforeach
subproject('frida-core', default_options: core_options)
```

注意构建顺序：**先 Gum，后 Core**。这是因为 Core 依赖 Gum——Core 中的 Agent 需要用 Gum 来实现插桩功能。

### 条件构建逻辑

最有趣的是组件的条件启用逻辑：

```python
get_option('server')
    .disable_auto_if(not is_cross_build)  // 非交叉编译时禁用
    .disable_auto_if(is_watchos)           // watchOS 上禁用
    .allowed()
```

这段代码表达的意思是：frida-server 默认只在**交叉编译**时构建。为什么？因为 frida-server 是跑在目标设备上的（比如你的 Android 手机），你通常需要在开发机器上交叉编译它。在非交叉编译场景（比如在 Mac 上为 Mac 构建），你通常不需要 server。

类似地，frida-gadget 也是默认只在交叉编译时构建：

```python
core_options += 'gadget=' + (get_option('gadget')
    .disable_auto_if(not is_cross_build)
    .allowed() ? 'enabled' : 'disabled')
```

## 7.3 构建选项（meson.options）

Frida 的构建选项定义在 `meson.options` 文件中：

```python
option('server',      type: 'feature', value: 'auto',
  description: 'Build frida-server')
option('portal',      type: 'feature', value: 'disabled',
  description: 'Build frida-portal')
option('inject',      type: 'feature', value: 'auto',
  description: 'Build frida-inject')
option('gadget',      type: 'feature', value: 'auto',
  description: 'Build frida-gadget')

option('frida_python', type: 'feature', value: 'auto',
  description: 'Build Python bindings')
option('frida_node',   type: 'feature', value: 'disabled',
  description: 'Build Node.js bindings')
option('frida_swift',  type: 'feature', value: 'disabled',
  description: 'Build Swift bindings')
```

注意 `value` 的三种取值：

- `auto` —— 让构建系统根据环境自动决定（比如交叉编译时才启用 server）
- `enabled` —— 强制启用
- `disabled` —— 强制禁用

这个三值逻辑非常灵活。大多数用户不需要修改任何选项，`auto` 会做出合理的默认选择。高级用户可以通过 `-Dserver=enabled` 来强制启用或禁用特定组件。

```
┌──────────────────────────────────────────────────┐
│              构建组件与默认策略                    │
├──────────────────────────────────────────────────┤
│                                                  │
│  组件           默认值    典型场景               │
│  ──────────     ──────    ──────────             │
│  server         auto      交叉编译时启用         │
│  inject         auto      交叉编译时启用         │
│  gadget         auto      交叉编译时启用         │
│  portal         disabled  需要时手动启用         │
│                                                  │
│  frida_python   auto      本地编译时启用         │
│  frida_node     disabled  需要时手动启用         │
│  frida_tools    auto      本地编译时启用         │
│  frida_swift    disabled  仅 macOS 可用          │
│  frida_clr      disabled  仅 Windows 可用        │
│  frida_qml      disabled  需要 Qt6              │
│                                                  │
└──────────────────────────────────────────────────┘
```

## 7.4 语言绑定的构建

顶层 `meson.build` 还负责协调各语言绑定的构建：

```python
# Python 绑定
if get_option('frida_python')
    .disable_auto_if(is_cross_build)
    .allowed()
  run_command(ensure_submodules, 'frida-python', check: true)
  subproject('frida-python')
endif

# Node.js 绑定
if get_option('frida_node')
    .disable_auto_if(is_cross_build)
    .allowed()
  run_command(ensure_submodules, 'frida-node', check: true)
  subproject('frida-node')
endif
```

每个绑定在构建前都会先调用 `ensure_submodules` 确保对应的 git submodule 已经被检出。这是一个贴心的设计——你不需要手动 `git submodule update`，构建系统会帮你处理。

语言绑定都有 `disable_auto_if(is_cross_build)` 这个条件。原因很直观：如果你在 Mac 上为 Android 交叉编译，你不会需要 Android 上的 Python 绑定——Python 绑定是给开发机器用的。

## 7.5 交叉编译的工作原理

交叉编译是 Frida 构建系统中最重要的能力之一。Meson 使用 "cross file" 来描述目标平台的信息：

```ini
# 示例：android-arm64 交叉编译配置
[host_machine]
system = 'android'
subsystem = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[binaries]
c = '/path/to/ndk/toolchains/.../aarch64-linux-android-clang'
cpp = '/path/to/ndk/toolchains/.../aarch64-linux-android-clang++'
ar = '/path/to/ndk/toolchains/.../llvm-ar'
strip = '/path/to/ndk/toolchains/.../llvm-strip'

[properties]
sys_root = '/path/to/ndk/sysroot'
```

在 frida-gum 的 `meson.build` 中，可以看到架构检测的逻辑：

```python
host_os_family = host_machine.system()
if host_os_family == 'android'
  host_os_family = 'linux'   # Android 底层是 Linux
endif

if host_machine.cpu_family() == 'aarch64'
  host_arch = 'arm64'
  host_abi = 'arm64'
elif host_machine.cpu_family() == 'arm'
  host_arch = 'arm'
  host_abi = 'arm'
elif host_machine.cpu_family() == 'mips'
  host_arch = 'mips'
  if host_machine.endian() == 'little'
    host_abi = 'mipsel'
  else
    host_abi = 'mips'
  endif
```

这段代码将 Meson 提供的通用架构信息转换为 Frida 内部使用的架构/ABI 标识。注意 MIPS 的特殊处理——同一个 CPU family 根据字节序不同有不同的 ABI。

Meson 的交叉编译能力意味着在配置阶段就确定了"我要为谁编译"。构建系统会自动区分哪些代码需要用本机编译器（比如代码生成工具），哪些需要用交叉编译器（目标平台的产物）。

## 7.6 平台差异的处理

Frida 需要在多种平台上运行，每个平台都有自己的特殊需求。构建系统通过多种方式处理这些差异：

### 编译条件宏

在源码中通过预处理器宏区分平台：

```c
#if DARWIN
    // macOS / iOS 特有逻辑
#elif LINUX
    // Linux / Android 特有逻辑
#elif WINDOWS
    // Windows 特有逻辑
#endif
```

### Darwin 平台的语言支持

macOS/iOS 需要 Objective-C 支持，frida-gum 的构建文件中特别处理了这个：

```python
languages = ['c', 'cpp']
if host_os_family == 'darwin'
  languages += ['objc', 'objcpp']
  add_languages('objc', 'objcpp', native: false)
endif
```

### 条件编译后端

回顾 host-session-service.vala 中的后端选择：

```vala
private void add_local_backends () {
#if WINDOWS
    add_backend (new WindowsHostSessionBackend ());
#endif
#if DARWIN
    add_backend (new DarwinHostSessionBackend ());
#endif
#if LINUX
    add_backend (new LinuxHostSessionBackend ());
#endif
}
```

构建系统负责定义这些条件编译宏（WINDOWS、DARWIN、LINUX 等），使得源码可以根据目标平台包含或排除特定后端。

## 7.7 子项目依赖与版本管理

Frida 的子项目形成清晰的依赖链：frida-gum (底层) -> frida-core (中层) -> frida-python/node/swift 等绑定 (上层)。Meson 的子项目机制自动处理构建顺序。

版本号由 Python 脚本从 git 信息动态计算，通过 `frida_version` 选项传递给每个子项目，确保所有组件版本一致。

## 7.8 实际构建命令

对于想要自己构建 Frida 的读者，以下是常用的构建命令：

```bash
# 本地构建（开发用，包含 Python 绑定和 CLI 工具）
meson setup build
ninja -C build

# 为 Android arm64 交叉编译
meson setup build-android-arm64 \
    --cross-file cross/android-arm64.txt
ninja -C build-android-arm64

# 只构建特定组件
meson setup build -Dserver=enabled -Dfrida_python=disabled

# 查看所有可用选项
meson configure build
```

每次 `meson setup` 都会创建一个独立的构建目录，你可以同时维护多个构建配置互不干扰。

## 本章小结

- Frida 选择 Meson 是因为它原生支持交叉编译、多语言（C/C++/Vala/ObjC）、子项目管理，且语法简洁
- 顶层 meson.build 通过 subproject() 编排 frida-gum、frida-core 和各语言绑定的构建顺序
- 构建选项使用 auto/enabled/disabled 三值逻辑，配合 disable_auto_if 实现智能的条件构建
- 交叉编译通过 cross file 描述目标平台，构建系统自动区分本机工具和目标产物
- 平台差异通过条件编译宏、语言支持检测、后端选择等多种机制处理
- 版本号通过 Python 脚本统一计算，确保所有组件版本一致

## 思考题

1. 为什么 frida-server 默认在交叉编译时才构建，而 frida-python 默认在本地编译时才构建？这个设计背后的使用场景假设是什么？

2. 如果你要为一个新的嵌入式平台（比如 RISC-V 架构的 Linux 设备）添加 Frida 支持，你需要在构建系统中做哪些改动？

3. Frida 把版本号从 git 信息动态生成而不是硬编码在文件中。这种做法的好处是什么？有没有潜在的问题？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
