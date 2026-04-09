# 第23章：Python 绑定——最受欢迎的接口

> 你有没有想过，当你在 Python 里写 `import frida` 的时候，这短短一行代码背后到底发生了什么？Python 是怎么和 Frida 的 C 核心对话的？

Python 是 Frida 最受欢迎的语言绑定，也是大多数人接触 Frida 的第一站。无论你是写自动化测试脚本、安全分析工具，还是 CTF 比赛中的快速原型，Python 绑定都是首选。本章我们就来拆解这个绑定层的内部结构，看看它是怎么把 C 语言的底层能力，包装成我们熟悉的 Pythonic API 的。

## 23.1 整体架构：两层包装的艺术

Frida 的 Python 绑定并不是一层简单的封装，而是采用了两层结构：

```
┌─────────────────────────────────────────────────┐
│            你的 Python 脚本                       │
│         import frida                             │
├─────────────────────────────────────────────────┤
│        frida/__init__.py                         │
│    便捷函数: attach(), spawn(), kill()            │
├─────────────────────────────────────────────────┤
│        frida/core.py                             │
│    Python 包装层: Device, Session, Script         │
│    事件处理, RPC 机制, 类型提示                    │
├─────────────────────────────────────────────────┤
│        frida/_frida/                             │
│    C 扩展模块 (extension.c)                      │
│    直接调用 frida-core 的 C API                   │
├─────────────────────────────────────────────────┤
│        frida-core (C 库)                         │
│    Frida 的核心实现                               │
└─────────────────────────────────────────────────┘
```

这就像去餐厅吃饭。`__init__.py` 是菜单上的推荐套餐，让你一句话就能点好菜；`core.py` 是服务员，帮你协调厨房的各种操作；`_frida/extension.c` 是厨房和前台之间的传菜口；而 `frida-core` 就是真正的厨房。

## 23.2 入口：__init__.py 的设计哲学

打开 `frida/__init__.py`，你会发现它的设计理念非常清晰——提供最简单的顶层 API：

```python
# frida/__init__.py 的核心结构

from . import _frida    # 加载 C 扩展
from . import core       # 加载 Python 包装层

__version__ = _frida.__version__

# 便捷函数，全部委托给 core 层
get_device_manager = core.get_device_manager

def attach(target, realm=None, persist_timeout=None):
    """附加到进程"""
    return get_local_device().attach(target, realm=realm,
                                     persist_timeout=persist_timeout)

def spawn(program, argv=None, envp=None, env=None, cwd=None, stdio=None):
    """启动进程并暂停"""
    return get_local_device().spawn(program=program, argv=argv, ...)

def get_local_device():
    return get_device_manager().get_local_device()

def get_usb_device(timeout=0):
    return get_device_manager().get_usb_device(timeout)
```

注意这里的模式：所有顶层函数都是通过 `get_local_device()` 来完成的。这意味着 `frida.attach(pid)` 等价于 `frida.get_local_device().attach(pid)`。这种设计让 80% 的场景（本地调试）变得极其简洁。

同时，十多种异常类型（`ServerNotRunningError`、`ProcessNotFoundError`、`TimedOutError` 等）在 C 扩展中定义，通过 `__init__.py` 统一导出给用户。

## 23.3 C 扩展：_frida 模块的秘密

`_frida` 是整个绑定的心脏，位于 `frida/_frida/extension.c`，直接 `#include <frida-core.h>` 调用 C API。同时提供类型存根文件 `__init__.pyi`，让 IDE 能理解 C 扩展的接口：

```python
# _frida/__init__.pyi（类型存根，简化）
class Device(Object):
    @property
    def id(self) -> Optional[str]: ...
    @property
    def type(self) -> Optional[str]: ...  # "local", "remote", "usb"
    def attach(self, pid: int, ...) -> "Session": ...
    def spawn(self, program: str, ...) -> int: ...

class Session(Object):
    def create_script(self, source: str, ...) -> Script: ...

class Script(Object):
    def load(self) -> None: ...
    def post(self, message: str, ...) -> None: ...
```

所有 C 扩展对象继承自统一的 `Object` 基类，提供 `on()` / `off()` 方法注册信号处理器，与 GObject 信号系统一脉相承。

## 23.4 核心类：Device、Session、Script

`core.py` 中定义的三大核心类构成了 Frida 操作的基本流水线：

```
┌──────────┐  attach()   ┌──────────┐  create_script()  ┌──────────┐
│  Device   │ ─────────> │  Session  │ ────────────────> │  Script   │
│           │            │           │                   │           │
│ 代表一台  │            │ 代表与目标 │                   │ 代表注入  │
│ 设备      │            │ 进程的会话 │                   │ 的JS脚本  │
└──────────┘             └──────────┘                   └──────────┘
```

每个 Python 包装类内部都持有一个 `_impl` 成员，指向对应的 C 扩展对象：

```python
class Session:
    def __init__(self, impl):
        self._impl = impl   # _frida.Session 的实例

    @cancellable
    def create_script(self, source, name=None, runtime=None):
        kwargs = {"name": name, "runtime": runtime}
        _filter_missing_kwargs(kwargs)   # 移除值为 None 的参数
        return Script(self._impl.create_script(source, **kwargs))

    @cancellable
    def detach(self):
        self._impl.detach()
```

这种 "Python 包装类 + C 实现类" 的模式，让 Python 层可以自由添加功能（比如 RPC 机制、消息路由），而不需要修改 C 代码。

注意 `_filter_missing_kwargs` 这个辅助函数——它把值为 `None` 的参数从字典中移除，这样 C 扩展就能正确使用默认值。这是一个很实用的小技巧。

## 23.5 事件处理与回调机制

Frida 是事件驱动的，Python 绑定中最重要的事件机制就是 `on()` / `off()` 模式：

```python
# Script 类的事件处理
class Script:
    def __init__(self, impl):
        self._impl = impl
        self._on_message_callbacks = []

        # 注册内部消息处理器
        impl.on("destroyed", self._on_destroyed)
        impl.on("message", self._on_message)

    def on(self, signal, callback):
        if signal == "message":
            # message 信号由 Python 层管理
            self._on_message_callbacks.append(callback)
        else:
            # 其他信号直接委托给 C 扩展
            self._impl.on(signal, callback)

    def _on_message(self, raw_message, data):
        message = json.loads(raw_message)
        mtype = message["type"]

        if mtype == "log":
            # 日志消息：调用日志处理器
            self._log_handler(message["level"], message["payload"])
        elif mtype == "send" and is_rpc_message(message):
            # RPC 响应：路由到 RPC 处理器
            self._on_rpc_message(...)
        else:
            # 用户消息：分发给所有注册的回调
            for callback in self._on_message_callbacks[:]:
                callback(message, data)
```

这里有一个关键的设计：`message` 信号没有直接委托给 C 扩展，而是在 Python 层拦截并做了路由。这是因为 Frida 的消息通道承载了三种不同类型的消息：

```
┌─────────────────────────────────────────────┐
│            Script 消息通道                    │
├──────────────┬──────────────┬───────────────┤
│  type="log"  │ type="send"  │ type="send"   │
│  日志消息     │ RPC 响应     │ 用户消息       │
│              │ payload 以    │               │
│  -> 日志处理器│ "frida:rpc"  │ -> 用户回调    │
│              │ 开头          │               │
│              │ -> RPC 处理器 │               │
└──────────────┴──────────────┴───────────────┘
```

## 23.6 RPC 机制：exports 的魔法

RPC 是 Frida Python 绑定中最优雅的功能之一。你可以在 JS 脚本中导出函数，然后直接在 Python 中调用：

```javascript
// JS 端
rpc.exports = {
    add: function(a, b) { return a + b; },
    readMemory: function(addr, size) { return Memory.readByteArray(ptr(addr), size); }
};
```

```python
# Python 端
script.load()
api = script.exports_sync
result = api.add(1, 2)        # 直接调用！
data = api.read_memory(addr, 64)  # camelCase 自动转 snake_case
```

这是怎么实现的？关键在 `ScriptExportsSync` 类：

```python
class ScriptExportsSync:
    def __init__(self, script):
        self._script = script

    def __getattr__(self, name):
        script = self._script
        js_name = _to_camel_case(name)  # read_memory -> readMemory

        def method(*args, **kwargs):
            request, data = make_rpc_call_request(js_name, args)
            return script._rpc_request(request, data, **kwargs)

        return method
```

它利用 Python 的 `__getattr__` 魔术方法，把任意属性访问转化为 RPC 调用。`_to_camel_case` 函数负责把 Python 风格的 `snake_case` 转成 JavaScript 风格的 `camelCase`。

每个 RPC 调用都有唯一的 `request_id`，Python 通过 `post()` 发送请求 `["frida:rpc", id, "call", "add", [1, 2]]`，JS 端执行后通过 `send()` 返回结果，Python 端的 `_on_rpc_message` 根据 `request_id` 匹配并唤醒等待的条件变量。异步版本 `ScriptExportsAsync` 则使用 `asyncio.Future` 替代条件变量。

## 23.7 Cancellable：优雅取消的艺术

Frida 的几乎所有 I/O 操作都支持取消，这通过 `@cancellable` 装饰器和 `Cancellable` 类实现：

```python
def cancellable(f):
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        cancellable = kwargs.pop("cancellable", None)
        if cancellable is not None:
            with cancellable:   # push_current / pop_current
                return f(*args, **kwargs)
        return f(*args, **kwargs)
    return wrapper
```

使用方式很简单：

```python
cancellable = frida.Cancellable()

# 在另一个线程中：
cancellable.cancel()

# 在主线程中，这个调用会被取消：
try:
    device.attach(pid, cancellable=cancellable)
except frida.OperationCancelledError:
    print("操作已取消")
```

这个模式来自 GLib 的 `GCancellable`，被 Python 绑定完整保留了下来。

## 23.8 类型提示的细致处理

Frida 的 Python 绑定充分利用 `typing` 高级特性。消息类型用 `TypedDict` + `Literal` 精确定义，`on()` 方法用 `@overload` 让 IDE 能根据信号名推断回调类型：

```python
class ScriptErrorMessage(TypedDict):
    type: Literal["error"]
    description: str
    stack: NotRequired[str]

class Script:
    @overload
    def on(self, signal: Literal["destroyed"],
           callback: ScriptDestroyedCallback) -> None: ...
    @overload
    def on(self, signal: Literal["message"],
           callback: ScriptMessageCallback) -> None: ...
```

为兼容不同 Python 版本，代码做了条件导入（`NotRequired` 在 3.11 之前从 `typing_extensions` 导入），确保从 Python 3.7 到最新版本都有良好的类型检查体验。

## 23.9 常见使用模式

把上面的知识串起来，最经典的 Frida Python 使用模式是这样的：

```python
import frida
import sys

# 1. 附加到目标进程
session = frida.attach("目标进程")

# 2. 创建并加载脚本
script = session.create_script("""
    Interceptor.attach(Module.findExportByName(null, 'open'), {
        onEnter: function(args) {
            send({type: 'open', path: args[0].readUtf8String()});
        }
    });
""")

# 3. 注册消息回调
def on_message(message, data):
    if message['type'] == 'send':
        print(f"[*] {message['payload']}")

script.on('message', on_message)

# 4. 加载脚本（此时 hook 生效）
script.load()

# 5. 保持运行
sys.stdin.read()
```

这四个步骤——attach、create_script、on('message')、load——构成了 Frida 最基本的工作流。整个流程背后，Python 绑定帮你处理了 C API 调用、线程安全、消息路由、JSON 序列化等所有复杂细节。

## 本章小结

- Frida Python 绑定采用两层架构：C 扩展 `_frida` 负责与 frida-core 通信，`core.py` 提供 Pythonic 的包装
- `__init__.py` 通过便捷函数让 80% 的使用场景只需一行代码
- 三大核心类 Device -> Session -> Script 构成操作流水线
- 消息通道承载三种消息（日志、RPC、用户消息），由 Python 层路由分发
- RPC 机制通过 `__getattr__` 魔术方法和请求/响应模式实现透明调用
- `@cancellable` 装饰器为所有 I/O 操作提供取消支持
- 类型提示使用了 TypedDict、Literal、overload 等高级特性

## 讨论问题

1. 为什么 Frida 选择在 Python 层而不是 C 扩展层实现 RPC 机制？这种设计有什么优缺点？
2. `ScriptExportsSync` 使用 `__getattr__` 实现动态方法调用，这种模式在什么场景下可能带来问题（比如自动补全、类型检查）？Frida 是如何缓解这些问题的？
3. 如果你要为 Frida 的 Python 绑定添加一个新功能（比如支持异步 `async for` 遍历进程列表），你会在哪一层实现？为什么？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
