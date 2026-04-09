# 第25章：命令行工具——frida-tools 全家桶

> 你安装 Frida 后第一个敲的命令是什么？大概是 `frida-ps` 看看有哪些进程，或者 `frida -U 目标App` 直接开干。这些命令行工具用起来顺手到让人忘记它们的存在。但你有没有好奇过，这些工具内部是怎么组织的？为什么它们的行为如此一致？

frida-tools 是 Frida 官方提供的命令行工具集合，它构建在 Python 绑定之上。本章我们深入这个"全家桶"，看看它的架构设计和每个工具的实现原理。

## 25.1 全家桶一览

先来看看 frida-tools 提供了哪些工具。在 `setup.py` 的 `entry_points` 中，注册了所有命令行工具：

通过 `setup.py` 的 `entry_points` 注册了 17 个命令，按功能分类：

```
┌────────────────────────────────────────────────────────┐
│                  frida-tools 工具集                      │
├──────────────┬─────────────────────────────────────────┤
│ 交互调试      │ frida          交互式 REPL               │
├──────────────┼─────────────────────────────────────────┤
│ 追踪分析      │ frida-trace    函数追踪                   │
│              │ frida-strace   系统调用追踪                │
│              │ frida-itrace   指令级追踪                  │
│              │ frida-discover 函数发现                    │
├──────────────┼─────────────────────────────────────────┤
│ 设备与进程    │ frida-ls-devices 列出设备                 │
│              │ frida-ps         列出进程                  │
│              │ frida-kill       终止进程                  │
├──────────────┼─────────────────────────────────────────┤
│ 文件操作      │ frida-ls    列出远程文件                  │
│              │ frida-pull  拉取远程文件                   │
│              │ frida-push  推送文件                       │
│              │ frida-rm    删除远程文件                   │
├──────────────┼─────────────────────────────────────────┤
│ 开发工具      │ frida-create  创建项目模板                │
│              │ frida-compile 编译 TypeScript agent       │
│              │ frida-pm      包管理                       │
│              │ frida-apk     APK 操作                    │
└──────────────┴─────────────────────────────────────────┘
```

## 25.2 架构基石：ConsoleApplication

所有工具都继承自同一个基类 `ConsoleApplication`，这是整个工具集一致性的秘密：

```python
# application.py（简化示意）
class ConsoleApplication:
    def __init__(self, run_until_return, on_stop=None):
        self._reactor = Reactor(run_until_return, on_stop)
        self._device = None
        self._session = None
        # 解析命令行参数 ...

    def run(self):
        # 1. 解析参数
        parser = argparse.ArgumentParser()
        self._add_options(parser)       # 子类添加自定义参数
        options = parser.parse_args()
        self._initialize(parser, options, args)

        # 2. 选择设备
        if self._needs_device():
            self._device = self._pick_device()

        # 3. 附加到目标（如果需要）
        if self._needs_target():
            self._attach(target)

        # 4. 启动 Reactor
        self._start()
        self._reactor.run()
```

这个基类处理了所有工具共有的逻辑：

```
┌─────────────────────────────────────────┐
│         ConsoleApplication 基类          │
├─────────────────────────────────────────┤
│ 命令行参数解析     -D 设备ID / -U USB    │
│                   -n 进程名 / -p PID     │
│ 设备选择逻辑       本地/USB/远程          │
│ 进程附加逻辑       by name / by pid      │
│ 信号处理          Ctrl+C 优雅退出        │
│ 输出格式化        终端检测/颜色支持       │
│ Reactor 生命周期  启动/停止/清理          │
└─────────────────────────────────────────┘
         │
    ┌────┴────┬────────┬────────┐
    │         │        │        │
  frida   frida-ps  frida-kill  ...
```

每个具体工具只需要覆写几个方法：

- `_add_options()`: 添加自己特有的命令行参数
- `_initialize()`: 解析参数后的初始化
- `_start()`: 真正的业务逻辑
- `_needs_device()` / `_needs_target()`: 声明是否需要设备/目标

## 25.3 Reactor：异步任务调度器

`Reactor` 是异步任务调度核心——主线程运行用户交互，后台线程处理异步任务：

```python
class Reactor:
    def __init__(self, run_until_return, on_stop=None):
        self._pending = collections.deque([])  # 任务队列
        self.io_cancellable = frida.Cancellable()

    def run(self):
        worker = threading.Thread(target=self._run)  # 后台线程
        worker.start()
        self._run_until_return(self)  # 主线程：用户交互
        self.stop()
        worker.join()

    def schedule(self, f, delay=None):
        """将任务加入队列，可选延迟执行"""
        when = time.time() + (delay or 0)
        self._pending.append((f, when))
```

就像餐厅的前台接待客人（主线程），后厨按订单做菜（工作线程），`schedule()` 就是下单。

## 25.4 frida-ps：最简单的工具

`frida-ps` 是理解工具架构的最佳入门：

```python
class PSApplication(ConsoleApplication):
    def _add_options(self, parser):
        parser.add_argument("-a", "--applications",
                           action="store_true",
                           help="list only applications")
        parser.add_argument("-j", "--json",
                           dest="output_format", const="json",
                           help="output results as JSON")

    def _start(self):
        if self._list_only_applications:
            self._list_applications()
        else:
            self._list_processes()

    def _list_processes(self):
        # 就这么简单：调用 Python 绑定的 API
        processes = self._device.enumerate_processes()

        for process in sorted(processes, key=cmp):
            print(f"{process.pid:>6}  {process.name}")

        self._exit(0)
```

整个工具不到 100 行核心代码。它所做的事情：
1. 继承 `ConsoleApplication`（自动获得 `-D`、`-U` 等设备选择参数）
2. 添加自己的 `-a`（仅应用）和 `-j`（JSON 输出）参数
3. 在 `_start()` 中调用 `self._device.enumerate_processes()`
4. 格式化输出

## 25.5 frida-kill 和 frida-ls-devices

`frida-kill` 同样精简，只有 30 行代码——解析目标参数，调用 `self._device.kill()`，处理 `ProcessNotFoundError`。`infer_target()` 辅助函数自动判断输入是 PID 还是进程名。

`frida-ls-devices` 则稍有不同，它声明 `_needs_device() = False`（不需要特定设备），使用 `prompt_toolkit` 构建 TUI 界面，异步查询每个设备的系统参数，查询过程中还有旋转动画提示加载状态。

## 25.7 frida：交互式 REPL

`frida` 命令本身是整个工具集中最复杂的，它是一个完整的交互式 JavaScript REPL：

```python
class REPLApplication(ConsoleApplication):
    def __init__(self):
        self._script = None
        self._ready = threading.Event()
        self._completer = FridaCompleter(self)
        self._compilers = {}

        super().__init__(self._process_input, self._on_stop)

        # 构建交互式终端
        self._cli = PromptSession(
            lexer=PygmentsLexer(JavascriptLexer),  # JS 语法高亮
            history=FileHistory(history_file),       # 命令历史
            completer=self._completer,               # 自动补全
            complete_in_thread=True,
            enable_open_in_editor=True,              # 支持用编辑器打开
            tempfile_suffix=".js",
        )
```

用户输入的 JS 代码通过 `Script.post()` 发送到目标进程的 JS 引擎执行，结果通过消息通道返回并格式化显示。REPL 还支持自动补全（`FridaCompleter` 查询目标进程的 API）、TypeScript 实时编译、文件监控（`-l script.js` 修改后自动重载）和 autoperform（自动在 Java/ObjC 运行时上下文中执行）。

## 25.8 frida-trace：自动化追踪

`frida-trace` 是日常使用频率最高的工具之一。它能自动 hook 指定的函数并打印调用日志：

```bash
# 追踪所有 open* 函数
frida-trace -i "open*" 目标进程

# 追踪特定模块的导入
frida-trace -t libssl.so 目标进程

# 追踪 Objective-C 方法
frida-trace -m "-[NSURLSession *]" 目标App
```

`TracerApplication` 继承 `ConsoleApplication` 和 `UI`，通过 `TracerProfileBuilder` 解析 `-i`、`-x`、`-m`、`-a` 等参数构建追踪配置。工作原理：

1. 根据用户指定的模式（`-i`, `-m`, `-a` 等），构建一个追踪配置 `TracerProfile`
2. 在目标进程中枚举匹配的函数
3. 为每个函数生成一个 handler 脚本（自动生成在 `__handlers__/` 目录）
4. 用 `Interceptor.attach()` 挂钩这些函数
5. 函数被调用时，通过消息通道把参数、返回值等信息发回
6. Python 端格式化并彩色输出

用户可以编辑自动生成的 handler 脚本来自定义行为：

```javascript
// __handlers__/libc.so/open.js（自动生成）
{
    onEnter(log, args, state) {
        log(`open("${args[0].readUtf8String()}")`);
    },
    onLeave(log, retval, state) {
        log(`=> ${retval}`);
    }
}
```

frida-trace 还内置了一个 WebSocket 服务器，提供了 Web UI 来可视化追踪结果。

## 25.9 frida-discover：函数发现

`frida-discover` 通过采样来发现目标进程中活跃的函数：

```python
class Discoverer:
    def start(self, session, runtime, ui):
        script = session.create_script(
            name="discoverer",
            source=self._create_discover_script(),
            runtime=runtime
        )
        script.on("message", on_message)
        script.load()

        # 通过 RPC 启动采样
        params = script.exports_sync.start()
        ui.on_sample_start(params["total"])

    def stop(self):
        # 停止采样，获取结果
        result = self._script.exports_sync.stop()
        # 解析结果：模块函数 + 动态函数
```

它的原理是利用 Stalker（Frida 的代码追踪引擎）对代码执行进行采样，统计哪些函数被调用了，按调用频率排序输出。这对于逆向一个不熟悉的程序特别有用——你可以快速知道"这个程序主要在跑哪些函数"。

## 25.10 工具设计模式总结

三个核心模式贯穿整个 frida-tools：(1) **继承 + 模板方法**：`ConsoleApplication` 定义工作流骨架，子类只实现差异部分；(2) **Reactor 异步调度**：主线程处理交互，工作线程执行回调；(3) **Script + RPC**：Python 端控制流程，JavaScript agent 端在目标进程中执行。

这三个模式的组合让添加新工具变得非常简单：

```python
from frida_tools.application import ConsoleApplication

class MyToolApplication(ConsoleApplication):
    def _add_options(self, parser):
        parser.add_argument("--my-option", help="我的选项")

    def _start(self):
        # 你的逻辑
        script = self._session.create_script("""
            // 你的 JavaScript agent
        """)
        script.on("message", self._on_message)
        script.load()

    def _on_message(self, message, data):
        print(message)

def main():
    app = MyToolApplication()
    app.run()
```

几十行代码，你就拥有了一个完整的命令行工具，自带设备选择、进程附加、Ctrl+C 处理等所有功能。

## 本章小结

- frida-tools 提供了 17 个命令行工具，覆盖调试、追踪、设备管理、文件操作、开发等场景
- 所有工具继承自 `ConsoleApplication` 基类，共享参数解析、设备选择、生命周期管理等公共逻辑
- `Reactor` 是异步任务调度的核心，协调主线程交互和后台任务执行
- frida（REPL）使用 prompt_toolkit 提供语法高亮、自动补全、命令历史等交互功能
- frida-trace 通过 TracerProfile 构建追踪配置，自动生成可编辑的 handler 脚本
- 复杂工具都遵循 "Script + RPC" 模式：Python 端控制，JavaScript agent 端执行
- 创建自定义工具只需继承 ConsoleApplication 并实现几个方法

## 讨论问题

1. frida-tools 的所有工具都是 Python 实现的，这在性能上会有什么限制？有没有可能用其他语言重写某些工具？
2. Reactor 模式和 Python 的 asyncio 有什么异同？为什么 frida-tools 没有直接使用 asyncio？
3. 如果你要设计一个新的 Frida 命令行工具（比如 `frida-heap` 用于堆内存分析），你会如何组织 Python 端和 JavaScript agent 端的职责划分？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
