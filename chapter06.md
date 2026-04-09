# 第6章：核心数据结构与接口定义

> 两个人要合作，首先得说好"我给你什么，你给我什么"。软件组件之间也一样——接口就是它们之间的"合同"。Frida 的各个组件之间通过一套精心设计的接口和数据结构进行通信。今天我们来读这份"合同"，看看组件之间到底是怎么约定的。

## 6.1 接口定义在哪里？

Frida 的核心接口定义主要集中在两个文件中：

- `frida-core/lib/base/session.vala` —— DBus 接口、ID 类型、消息结构
- `frida-core/src/host-session-service.vala` —— 后端服务接口

这些接口使用 Vala 语言定义，并通过 DBus 协议进行跨进程通信。DBus 是 Linux 世界广泛使用的进程间通信（IPC）机制，Frida 把它用作组件之间的通信协议，即使在非 Linux 平台上也是如此。

## 6.2 三大核心接口

Frida 的 DBus 接口体系由三个核心接口构成，它们各司其职：

```
┌──────────────────────────────────────────────────────┐
│                 Frida 接口体系                        │
├──────────────────────────────────────────────────────┤
│                                                      │
│  ┌──────────────────┐                                │
│  │   HostSession    │  "前台经理"                    │
│  │  re.frida.       │  管理进程、设备级操作           │
│  │  HostSession17   │  枚举进程、spawn、attach       │
│  └────────┬─────────┘                                │
│           │ 创建                                     │
│           v                                          │
│  ┌──────────────────┐                                │
│  │  AgentSession    │  "项目经理"                    │
│  │  re.frida.       │  管理脚本、调试器              │
│  │  AgentSession17  │  创建/加载/卸载脚本            │
│  └────────┬─────────┘                                │
│           │ 通信                                     │
│           v                                          │
│  ┌──────────────────┐                                │
│  │ AgentMessageSink │  "信箱"                        │
│  │  re.frida.       │  接收 Agent 发来的消息         │
│  │  AgentMessage-   │  脚本输出、调试信息            │
│  │  Sink17          │                                │
│  └──────────────────┘                                │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### HostSession：设备级操作接口

HostSession 是最高层的接口，对应一个"设备会话"。它提供的能力包括：

```vala
[DBus (name = "re.frida.HostSession17")]
public interface HostSession : Object {
    // 心跳检测
    async void ping (uint interval_seconds, Cancellable? cancellable);

    // 查询系统信息
    async HashTable<string, Variant> query_system_parameters (...);

    // 进程管理
    async HostApplicationInfo get_frontmost_application (...);
    async HostApplicationInfo[] enumerate_applications (...);
    async HostProcessInfo[] enumerate_processes (...);

    // 进程生命周期
    async uint spawn (string program, HostSpawnOptions options, ...);
    async void resume (uint pid, ...);
    async void kill (uint pid, ...);

    // 核心操作：附加到进程
    async AgentSessionId attach (uint pid, HashTable<string, Variant> options, ...);

    // 注入操作
    async InjectorPayloadId inject_library_file (...);
    async InjectorPayloadId inject_library_blob (...);

    // 信号：异步事件通知
    signal void spawn_added (HostSpawnInfo info);
    signal void process_crashed (CrashInfo crash);
    signal void agent_session_detached (AgentSessionId id, SessionDetachReason reason, CrashInfo crash);
}
```

这个接口就像一个酒店的前台：你可以问它"现在有哪些房间"（枚举进程），可以"预定房间"（spawn 进程），也可以"进入已有房间"（attach 到进程）。

注意接口名称中的 `17`——这是接口版本号。当接口发生不兼容变更时，版本号会递增，确保新旧版本的客户端和服务端不会误连。

### AgentSession：脚本级操作接口

当你 attach 到一个进程后，得到的是一个 `AgentSession`，它管理该进程内的具体操作：

```vala
[DBus (name = "re.frida.AgentSession17")]
public interface AgentSession : Object {
    // 会话生命周期
    async void close (...);
    async void interrupt (...);
    async void resume (uint rx_batch_id, ..., out uint tx_batch_id);

    // 子进程管理
    async void enable_child_gating (...);
    async void disable_child_gating (...);

    // 脚本管理（核心功能）
    async AgentScriptId create_script (string source, HashTable<string, Variant> options, ...);
    async AgentScriptId create_script_from_bytes (uint8[] bytes, ...);
    async uint8[] compile_script (string source, ...);
    async void destroy_script (AgentScriptId script_id, ...);
    async void load_script (AgentScriptId script_id, ...);
    async void eternalize_script (AgentScriptId script_id, ...);

    // 调试器
    async void enable_debugger (AgentScriptId script_id, ...);
    async void disable_debugger (AgentScriptId script_id, ...);

    // 消息传递
    async void post_messages (AgentMessage[] messages, uint batch_id, ...);

    // P2P 连接（性能优化）
    async void offer_peer_connection (string offer_sdp, ..., out string answer_sdp);
    async void add_candidates (string[] candidate_sdps, ...);
}
```

这个接口就像酒店房间里的电话——你可以通过它请求各种服务（创建脚本），控制灯光空调（加载/卸载脚本），甚至打长途电话（P2P 连接）。

### AgentMessageSink：消息接收接口

这是最简单但很关键的接口：

```vala
[DBus (name = "re.frida.AgentMessageSink17")]
public interface AgentMessageSink : Object {
    async void post_messages (AgentMessage[] messages, uint batch_id, ...);
}
```

它只有一个方法——接收消息。这种极简设计是有意为之的：消息接收是高频操作，接口越简单越好。

## 6.3 辅助接口

除了三大核心接口，还有两个辅助接口值得了解：

### AgentSessionProvider

```vala
[DBus (name = "re.frida.AgentSessionProvider17")]
public interface AgentSessionProvider : Object {
    async void open (AgentSessionId id, HashTable<string, Variant> options, ...);
    async void migrate (AgentSessionId id, GLib.Socket to_socket, ...);
    async void unload (...);

    signal void opened (AgentSessionId id);
    signal void closed (AgentSessionId id);
    signal void eternalized ();
}
```

这是 Agent（注入到目标进程中的那部分代码）向 Host（frida-server）提供的接口。当 Host 需要在目标进程里开启一个新的 AgentSession 时，就通过这个接口告诉 Agent。

### AgentController

```vala
[DBus (name = "re.frida.AgentController17")]
public interface AgentController : Object {
    async HostChildId prepare_to_fork (uint parent_pid, ...);
    async HostChildId prepare_to_specialize (uint pid, string identifier, ...);
    async void recreate_agent_thread (uint pid, uint injectee_id, ...);
    async void wait_for_permission_to_resume (HostChildId id, HostChildInfo info, ...);
    async void prepare_to_exec (HostChildInfo info, ...);
    async void acknowledge_spawn (HostChildInfo info, SpawnStartState start_state, ...);
}
```

这个接口处理子进程相关的复杂场景：fork、exec、Android 的 zygote specialize 等。这些都是多进程环境下的关键操作。

## 6.4 ID 类型体系

Frida 定义了多种 ID 类型来标识不同的实体。这些 ID 分为两类：

### 基于 uint 的 ID（局部唯一）

```vala
public struct InjectorPayloadId {
    public uint handle;
}

public struct HostChildId {
    public uint handle;
}

public struct AgentScriptId {
    public uint handle;
}

public struct PortalMembershipId {
    public uint handle;
}
```

这类 ID 是简单的递增整数，在某个组件内部唯一即可。比如 `AgentScriptId` 只需要在一个 AgentSession 内唯一。

### 基于 string 的 ID（全局唯一）

```vala
public struct AgentSessionId {
    public string handle;

    public AgentSessionId.generate () {
        this.handle = Uuid.string_random ().replace ("-", "");
    }
}

public struct ChannelId {
    public string handle;

    public ChannelId.generate () {
        this.handle = Uuid.string_random ().replace ("-", "");
    }
}

public struct ServiceSessionId {
    public string handle;
    // 同样使用 UUID 生成
}
```

这类 ID 使用 UUID（去掉连字符）作为值，保证全局唯一。`AgentSessionId` 需要全局唯一，因为一个客户端可能同时连接多个设备上的多个进程。

两类 ID 的设计体现了一个原则：**够用就好**。不需要全局唯一的地方用简单的整数，需要全局唯一的地方才用 UUID。

```
┌──────────────────────────────────────────────────────┐
│                    ID 类型体系                        │
├──────────────────────────────────────────────────────┤
│                                                      │
│  全局唯一 (UUID string):                             │
│  ├─ AgentSessionId    会话标识                       │
│  ├─ ChannelId         通道标识                       │
│  └─ ServiceSessionId  服务会话标识                   │
│                                                      │
│  局部唯一 (uint):                                    │
│  ├─ AgentScriptId     脚本标识 (会话内唯一)          │
│  ├─ InjectorPayloadId 注入载荷标识                   │
│  ├─ HostChildId       子进程标识                     │
│  └─ PortalMembershipId Portal成员标识                │
│                                                      │
└──────────────────────────────────────────────────────┘
```

## 6.5 AgentMessage 与消息传输

`AgentMessage` 是 Agent 和 Host 之间传递消息的载体：

```vala
public struct AgentMessage {
    public AgentMessageKind kind;   // SCRIPT 或 DEBUGGER
    public AgentScriptId script_id; // 来源脚本
    public string text;             // 文本内容 (通常是 JSON)
    public bool has_data;           // 是否有二进制数据
    public uint8[] data;            // 二进制数据
}
```

`text` 承载结构化数据（JSON），`data` 承载二进制数据，对应 Frida 脚本中 `send(message, data)` 的两个参数。消息通过批量传输优化性能——`post_messages` 接收的是 `AgentMessage[]` 数组，配合 `batch_id` 实现断线重连时的消息不丢失。

`AgentMessageTransmitter` 管理传输状态，它有一个简洁的状态机：LIVE（正常） -> INTERRUPTED（中断，等待恢复） -> CLOSED（超时关闭）。`persist_timeout` 特性让连接中断时不会立即关闭，而是等待一段时间。这就像打电话信号不好断了，你不会马上挂电话，而是等一会儿看能不能重新接通。

## 6.6 HostSessionProvider 与后端架构

`HostSessionProvider` 定义了设备后端的统一接口，每种连接方式（LOCAL/REMOTE/USB）都实现它。`HostSessionService` 管理所有 Provider——当新设备被发现（比如插入 USB），Backend 发出 `provider_available` 信号，DeviceManager 收到后就知道有新设备可用了。

## 6.7 会话管理的数据流

让我们把这些接口串起来，看一个完整的操作流程——从 Python 客户端 attach 到进程并创建脚本：

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Python  │    │  frida-  │    │  Host    │    │  Agent   │
│  Client  │    │  server  │    │ Session  │    │ (目标进程)│
└────┬─────┘    └────┬─────┘    └────┬─────┘    └────┬─────┘
     │               │               │               │
     │  attach(pid)  │               │               │
     │──────────────>│               │               │
     │               │ attach(pid)   │               │
     │               │──────────────>│               │
     │               │               │  注入 Agent   │
     │               │               │──────────────>│
     │               │               │  Provider.open│
     │               │               │<──────────────│
     │  session_id   │               │               │
     │<──────────────│               │               │
     │               │               │               │
     │ create_script │               │               │
     │──────────────>│               │               │
     │               │ create_script │               │
     │               │──────────────────────────────>│
     │               │               │   script_id   │
     │  script_id    │<──────────────────────────────│
     │<──────────────│               │               │
     │               │               │               │
     │  load_script  │               │               │
     │──────────────>│  load_script  │               │
     │               │──────────────────────────────>│
     │               │               │  执行 JS 代码 │
     │               │               │               │
```

在这个流程中，HostSession 接口负责 attach 和进程管理，AgentSession 接口负责脚本的创建和加载，AgentMessageSink 负责后续的消息回传。每个接口在数据流中的角色清晰明确。

## 本章小结

- Frida 的核心通信基于三大 DBus 接口：HostSession（设备级）、AgentSession（进程级）、AgentMessageSink（消息传递）
- ID 类型分为全局唯一（UUID string）和局部唯一（uint）两类，按需选择
- AgentMessage 结构支持文本（JSON）和二进制数据的混合传输，采用批量发送优化性能
- AgentMessageTransmitter 通过状态机管理连接的中断和恢复
- HostSessionProvider 接口统一了不同连接方式（本地、USB、网络）的设备后端
- 接口版本号机制确保了协议的向前兼容性

## 思考题

1. 为什么 `AgentSessionId` 使用 UUID 字符串而 `AgentScriptId` 使用简单的 uint？如果把 `AgentScriptId` 也改成 UUID，会有什么利弊？

2. `AgentMessageTransmitter` 的 `persist_timeout` 功能在什么实际场景下特别有用？如果没有这个功能，用户体验会受到什么影响？

3. 如果你要为 Frida 添加一个新的子系统（比如"网络流量监控"），你会在哪个接口中添加新方法？还是应该定义一个全新的接口？为什么？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
