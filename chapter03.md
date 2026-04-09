# 第3章：语言基础速览：C、Vala 与 JavaScript

> 如果有人告诉你，一个项目同时使用了 C、Vala、JavaScript、Python 和 C++，你的第一反应是什么？"这也太疯狂了吧！"但 Frida 就是这样一个项目，而且它把这些语言组合得相当优雅。

别担心，你不需要精通所有这些语言才能读懂 Frida 源码。这一章的目标很明确：给你配上刚好够用的"语言眼镜"，让你在后续章节中遇到代码时不至于一头雾水。

## 3.1 C 语言：Frida 的骨骼

frida-gum 这个最底层的引擎完全用 C 语言编写。C 语言在这里被选用的原因很简单：它是最接近硬件的高级语言，能精确控制内存布局和机器指令，而且几乎所有平台都能编译和运行 C 代码。

### 你需要了解的 C 基础

**指针**：在 Frida 源码中，指针无处不在。简单来说，指针就是一个"地址"。

```c
// 一个整数
int value = 42;

// 一个指针，存储的是 value 的内存地址
int *ptr = &value;

// 通过指针读取值
printf("%d\n", *ptr);  // 输出 42

// gpointer 是 GLib 定义的通用指针类型
// 在 Frida 代码中你会经常看到它
gpointer address = (gpointer) 0x12345678;
```

把指针想象成一张写着门牌号的纸条。纸条本身不是房子，但拿着纸条你能找到房子。在 Frida 中，函数地址、内存地址、对象引用几乎都是通过指针来传递的。

**结构体**：C 语言用结构体来组织相关的数据。

```c
// Frida 中典型的结构体定义风格
struct _GumInterceptor {
    GObject parent;           // 继承自 GObject
    GRecMutex mutex;          // 互斥锁
    GHashTable *function_contexts;  // 函数上下文哈希表
    // ...
};
```

结构体就像一个档案袋，把相关的信息装在一起。`GumInterceptor` 这个结构体包含了拦截器运作所需的全部状态。

**函数指针**：这是理解 Frida 回调机制的关键。

```c
// 定义一个函数指针类型
typedef void (* GumInvocationCallback) (GumInvocationContext *context,
                                         gpointer user_data);

// 使用函数指针：注册一个回调
void my_callback(GumInvocationContext *context, gpointer user_data) {
    printf("函数被调用了！\n");
}

// 把 my_callback 当作参数传递
gum_interceptor_attach(interceptor, target_func, listener, NULL, 0);
```

函数指针就像是一个"任务委托"。你把一个函数交给 Frida，说"等那个函数被调用时，帮我执行这段代码"。这是整个 Interceptor 机制的基础。

### GLib/GObject 类型系统

Frida 大量使用了 GLib 库，这是 GNOME 项目的基础库。你需要认识一些常见的 GLib 类型：

```
┌────────────────────────────────────────────┐
│          GLib 常见类型速查                   │
├──────────────┬─────────────────────────────┤
│ GLib 类型     │ 含义                        │
├──────────────┼─────────────────────────────┤
│ gboolean     │ 布尔值 (TRUE/FALSE)          │
│ gint / guint │ 有符号/无符号整数             │
│ gsize        │ 等同于 size_t               │
│ gpointer     │ 通用指针 (void *)           │
│ gchar *      │ 字符串                      │
│ GArray       │ 动态数组                    │
│ GHashTable   │ 哈希表                      │
│ GBytes       │ 不可变字节序列               │
│ GObject      │ 所有 GObject 类的基类        │
│ GError       │ 错误信息结构体               │
└──────────────┴─────────────────────────────┘
```

GObject 是 C 语言实现面向对象编程的一种约定。它不是语言特性，而是一套人为的规范。在 Frida 源码中你会看到这样的模式：

```c
// 声明一个 GObject 类型
G_DECLARE_FINAL_TYPE (GumInterceptor, gum_interceptor,
                      GUM, INTERCEPTOR, GObject)

// 获取拦截器实例（单例模式）
GumInterceptor *interceptor = gum_interceptor_obtain();

// 调用方法（注意命名规范：模块_类名_方法名）
gum_interceptor_attach(interceptor, address, listener, data, flags);

// 释放引用
g_object_unref(interceptor);
```

这里有一个重要的命名约定：GLib/GObject 世界中的函数命名遵循 `模块前缀_类名_方法名` 的模式。所以当你看到 `gum_interceptor_attach` 时，可以解读为"gum 模块的 Interceptor 类的 attach 方法"。

## 3.2 Vala 语言：Frida 的血肉

Vala 可能是你第一次听说的语言，但在 Frida 中它扮演着至关重要的角色。frida-core 的大部分代码都是用 Vala 编写的。

### Vala 是什么

Vala 是 GNOME 社区开发的一种编程语言，语法类似 C#/Java，但它有一个独特的特点：**Vala 编译器不生成机器码，而是先编译为 C 代码，再由 C 编译器编译为机器码。**

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ Vala     │    │ C 代码   │    │ 目标文件  │    │ 可执行   │
│ 源码     │───>│ (自动    │───>│ (.o)     │───>│ 文件     │
│ (.vala)  │    │  生成)   │    │          │    │          │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
  valac 编译      gcc/clang       链接器
```

这意味着 Vala 代码最终会变成 C 代码，和 frida-gum 的 C 代码无缝对接。Frida 选择 Vala 的理由就很清楚了：既要高级语言的开发效率，又要和 C 底层完美融合。

### Vala 语法快速上手

来看一段 frida-core 中真实存在的代码模式：

```vala
// 命名空间
namespace Frida {

    // 类定义，sealed 表示不可继承
    public sealed class DeviceManager : Object {

        // 信号（类似事件）
        public signal void added(Device device);
        public signal void removed(Device device);

        // 私有成员
        private Gee.ArrayList<Device> devices = new Gee.ArrayList<Device>();

        // 构造函数
        public DeviceManager() {
            service = new HostSessionService.with_default_backends();
        }

        // 异步方法（这是 Vala 的重要特性）
        public async void close(Cancellable? cancellable = null) throws IOError {
            yield stop_service(cancellable);
        }

        // 同步包装
        public void close_sync(Cancellable? cancellable = null) throws IOError {
            // ...
        }
    }
}
```

对比一下，如果你会 C#、Java 或 TypeScript，Vala 的语法应该相当亲切。但有几个 Vala 特有的概念需要注意：

**async/yield**：Vala 内置了异步编程支持。在 frida-core 中，几乎所有的 I/O 操作都是异步的。`async` 和 `yield` 就像餐厅点餐：你发起一个异步操作，然后 `yield` 说"做好了再叫我"，线程就可以去处理别的事了。

```vala
public async Device get_device(string id) throws Error {
    yield ensure_service_started();   // 等待服务启动
    foreach (var device in devices) {
        if (device.id == id)
            return device;
    }
    throw new Error.INVALID_ARGUMENT("Device not found");
}
```

**可空类型与属性**：类型后面加 `?` 表示可以为 null（`Cancellable? cancellable = null`）。属性用 `{ get; construct; }` 语法声明，类似 C#。所有 Vala 类默认继承 GLib.Object，自动获得引用计数和信号机制。

### 编译条件

frida-core 中大量使用了条件编译来处理跨平台差异：

```vala
private void add_local_backends() {
#if WINDOWS
    add_backend(new WindowsHostSessionBackend());
#endif
#if DARWIN
    add_backend(new DarwinHostSessionBackend());
#endif
#if LINUX
    add_backend(new LinuxHostSessionBackend());
#endif
}
```

这和 C 语言的 `#ifdef` 很像，根据编译目标平台选择不同的代码路径。

## 3.3 JavaScript：Frida 的灵魂

当你写 Frida 脚本时，你用的就是 JavaScript。但这个 JavaScript 运行环境有点特殊，它不是浏览器，也不是 Node.js，而是 Frida 自己搭建的一个 JS 运行时。

### Frida 的 JavaScript API

Frida 在标准 JavaScript 的基础上提供了一系列全局对象和函数：

```javascript
// Interceptor：函数拦截
Interceptor.attach(ptr('0x12345678'), {
    onEnter(args) {
        // args[0], args[1] 是函数参数
        console.log('参数1:', args[0].toInt32());
    },
    onLeave(retval) {
        // retval 是返回值
        console.log('返回值:', retval.toInt32());
    }
});

// Module：模块（动态库）操作
var base = Module.getBaseAddress('libc.so');
var exports = Module.enumerateExports('libc.so');

// Memory：内存读写
var value = Memory.readU32(ptr('0x12345678'));
Memory.writeUtf8String(ptr('0x12345678'), 'hello');

// Process：进程信息
var modules = Process.enumerateModules();
var threads = Process.enumerateThreads();
```

### JS 引擎：V8 与 QuickJS

Frida 支持两种 JavaScript 引擎，这也反映在源码结构中：

```
┌────────────────────────────────────────────────┐
│              GumJS 桥接层                       │
├───────────────────────┬────────────────────────┤
│                       │                        │
│   ┌───────────────┐   │   ┌────────────────┐   │
│   │   V8 后端     │   │   │ QuickJS 后端   │   │
│   │ gumv8*.cpp    │   │   │ gumquick*.c    │   │
│   │               │   │   │                │   │
│   │ 功能全面      │   │   │ 体积小巧       │   │
│   │ 性能强大      │   │   │ 启动快速       │   │
│   │ 体积较大      │   │   │ 资源占用少     │   │
│   └───────────────┘   │   └────────────────┘   │
│                       │                        │
└───────────────────────┴────────────────────────┘
```

在源码中，每个 JS API 都有两套实现。比如 Interceptor 的 JS 绑定：
- V8 版本：`gumv8interceptor.cpp`
- QuickJS 版本：`gumquickinterceptor.c`

它们提供完全相同的 JavaScript API，只是底层引擎不同。

### NativePointer 与 NativeFunction

在 Frida 的 JavaScript 世界中，有两个核心类型：

```javascript
// NativePointer：表示一个内存地址
var addr = ptr('0x7fff12345678');
var value = addr.readU32();        // 读取该地址的 32 位无符号整数

// NativeFunction：把一个地址当作函数来调用
var open = new NativeFunction(
    Module.getExportByName(null, 'open'),
    'int', ['pointer', 'int']   // 返回值类型, 参数类型列表
);
var fd = open(Memory.allocUtf8String('/etc/hosts'), 0);
```

`NativePointer` 就像一个万能遥控器，指向内存中的任何位置。`NativeFunction` 则更进一步，它不仅知道地址在哪，还知道怎么调用那个地址上的函数。

## 3.4 三种语言如何协作

现在让我们把三种语言串起来，看看当你执行一行 `Interceptor.attach(...)` 时，代码是如何跨越语言边界的：

```
┌─────────────────────────────────────────────────┐
│ 第1层：JavaScript（你写的脚本）                    │
│                                                 │
│   Interceptor.attach(target, callbacks)          │
│         │                                       │
│         v                                       │
├─────────────────────────────────────────────────┤
│ 第2层：GumJS 绑定（C/C++）                        │
│                                                 │
│   gumv8interceptor.cpp 或 gumquickinterceptor.c │
│   解析 JS 参数，转换为 C 类型                     │
│         │                                       │
│         v                                       │
├─────────────────────────────────────────────────┤
│ 第3层：Gum 引擎（C）                              │
│                                                 │
│   guminterceptor.c                              │
│   gum_interceptor_attach(self, addr, listener)  │
│   修改目标函数的机器指令，建立蹦床跳转              │
│         │                                       │
│         v                                       │
├─────────────────────────────────────────────────┤
│ 第4层：平台相关代码（C）                           │
│                                                 │
│   修改内存页权限、写入跳转指令                     │
│   处理缓存一致性（ARM 平台）                       │
└─────────────────────────────────────────────────┘
```

在管理层面，Vala 代码负责更高级别的协调：你的 Python 脚本调用 frida-core（Vala）的 DeviceManager/Device/Session 来管理进程附加和脚本创建，frida-core 再把 JS 脚本送入目标进程的 Agent 中，Agent 加载 GumJS 运行时并执行你的脚本。

所以三种语言各司其职：

- **C**：干脏活累活，直接和 CPU 指令、内存打交道
- **Vala**：做管理和协调，处理网络通信、进程管理等中间层逻辑
- **JavaScript**：面向用户，提供灵活友好的脚本接口

这就像一个公司：C 是一线工人，在车间里操作机器；Vala 是中层管理者，负责调度和协调；JavaScript 是面向客户的销售代表，提供友好的服务界面。

## 3.5 阅读源码的实用技巧

知道了这三种语言的基本特征后，这里再给你几个阅读 Frida 源码时的实用技巧：

1. **看函数命名推断功能。** `gum_interceptor_attach` 就是 GumInterceptor 的 attach 方法，命名规范让你几乎不需要注释就能理解代码意图。
2. **从头文件入手。** 先看 `.h` 了解接口，再看 `.c` 了解实现。头文件是"菜单"，源文件是"厨房"。
3. **关注 `_init` 和 `_dispose`。** GObject 的初始化和销毁函数会告诉你一个对象管理着哪些资源。
4. **用 `vapi` 文件作为索引。** vapi 描述了 C 库的 Vala 绑定接口，是理解跨语言关系的好起点。
5. **善用搜索跨越语言边界。** 从 JS 的 `Interceptor.attach` 搜索 `gumv8interceptor`，再搜索 `gum_interceptor_attach`，就能沿着调用链从顶到底。

## 本章小结

- **C 语言** 用于 frida-gum 底层引擎，需要理解指针、结构体、函数指针和 GLib/GObject 类型系统
- **Vala 语言** 用于 frida-core 框架层，语法类似 C#，编译时先转换为 C 代码，天然与 GObject 集成
- **JavaScript** 是用户编写注入脚本的语言，Frida 提供了 V8 和 QuickJS 两种引擎的支持
- 三种语言各有分工：C 负责底层操作，Vala 负责管理协调，JavaScript 负责用户接口
- GumJS 绑定层（`gumv8*.cpp` 和 `gumquick*.c`）是连接 JavaScript 和 C 引擎的桥梁
- 阅读源码时，善用命名规范、头文件和 vapi 文件来快速定位代码

## 思考与讨论

1. Vala 编译为 C 再编译为机器码，这种"两步编译"的方式和 TypeScript 编译为 JavaScript 有什么相似之处？你觉得这种设计的核心优势是什么？
2. Frida 同时支持 V8 和 QuickJS 两种 JS 引擎，在什么场景下你会选择 QuickJS 而非 V8？
3. 如果你想追踪 `Interceptor.attach` 的完整执行路径，从 JavaScript 到最终修改目标函数的机器指令，你会怎么规划你的源码阅读路线？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
