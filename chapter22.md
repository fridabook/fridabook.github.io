# 第22章：消息系统——脚本与宿主的对话

> 当你在 Frida 脚本里调用 `send({type: "hook", address: "0x12345"})` 的时候，这条消息是怎么从目标进程里面"飞"到你的 Python 脚本的？中间经历了怎样的旅程？如果消息发得太快，会不会"堵车"？

## 22.1 消息系统的全景

Frida 的消息系统是连接脚本世界（JavaScript）和宿主世界（Python/Node.js/C）的桥梁。它要解决的核心问题是：两个完全不同的运行时环境，如何可靠地交换数据？

想象一下快递系统：你在网上下了一个订单（`send()`），快递公司收到后把包裹装车（序列化），经过分拣中心（消息队列），最终送到你家门口（`on('message', callback)`）。Frida 的消息系统就是这样一套"快递网络"。

```
┌────────────────────────────────────────────────────┐
│                消息系统全景                          │
│                                                     │
│  ┌──────────┐                    ┌──────────────┐  │
│  │ JS 脚本  │                    │  Python 宿主 │  │
│  │          │                    │              │  │
│  │ send()   │                    │ on('message')│  │
│  │ recv()   │                    │ post()       │  │
│  └────┬─────┘                    └──────┬───────┘  │
│       │                                 │          │
│       v                                 ^          │
│  ┌─────────────────────────────────────────────┐   │
│  │           AgentMessageTransmitter           │   │
│  │  ┌───────────────────────────────────────┐  │   │
│  │  │         PendingMessage 队列           │  │   │
│  │  │  [msg1] -> [msg2] -> [msg3] -> ...   │  │   │
│  │  └───────────────────────────────────────┘  │   │
│  │                                             │   │
│  │  批量发送 (Batch)     流量控制 (Batch ID)   │   │
│  └─────────────────────────────────────────────┘   │
│       │                                 ^          │
│       v                                 │          │
│  ┌─────────────────────────────────────────────┐   │
│  │          AgentMessageSink (DBus)            │   │
│  └─────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────┘
```

## 22.2 AgentMessage：消息的结构

每条消息在 Frida 内部用 `AgentMessage` 结构体表示，定义在 `session.vala` 中：

```vala
public struct AgentMessage {
    public AgentMessageKind kind;    // 消息类型
    public AgentScriptId script_id;  // 来源脚本 ID
    public string text;              // JSON 文本内容
    public bool has_data;            // 是否有二进制附件
    public uint8[] data;             // 二进制数据
}

public enum AgentMessageKind {
    SCRIPT = 1,   // 来自脚本的消息
    DEBUGGER      // 来自调试器的消息
}
```

各字段一目了然：`kind` 区分脚本消息和调试器消息，`script_id` 在多脚本场景下标识来源，`text` 承载 JSON 格式的结构化数据，`has_data` + `data` 携带可选的二进制附件。

**为什么把 text 和 data 分开？** 这是一个巧妙的设计决策。JSON 很适合传递结构化的元数据（hook 地址、函数名、参数值等），但传递大量二进制数据时效率很低——需要 Base64 编码，体积膨胀 33%。所以 Frida 允许消息同时携带 JSON 文本和原始二进制数据，各取所长。

在 JavaScript 端，这对应着：

```javascript
// 只发送 JSON
send({type: "log", message: "函数被调用了"});

// 发送 JSON + 二进制数据
var buf = Memory.readByteArray(ptr, 256);
send({type: "dump", address: ptr.toString()}, buf);
```

## 22.3 从脚本到宿主：send() 的旅程

当脚本调用 `send()` 时，消息经历了一段复杂的旅程。让我们逐步追踪：

```
JS 脚本: send({type: "hook"}, binary_data)
       │
       v
ScriptEngine.message_from_script 信号
       │
       v
BaseAgentSession.on_message_from_script()
       │
       v
AgentMessageTransmitter.post_message_from_script()
       │  创建 PendingMessage，加入队列
       │
       v
AgentMessageTransmitter.maybe_deliver_pending_messages()
       │  从队列中取出消息，组装成批次
       │
       v
AgentMessageSink.post_messages(batch, batch_id)
       │  通过 DBus 发送到宿主端
       │
       v
宿主端收到消息，触发 on('message') 回调
```

在 `BaseAgentSession` 中，消息从脚本引擎流向发送器：

```vala
// base-agent-session.vala (简化版)
private void on_message_from_script (
        AgentScriptId script_id, string json, Bytes? data) {
    // 直接转交给 transmitter
    transmitter.post_message_from_script (script_id, json, data);
}
```

`AgentMessageTransmitter` 是消息的"分拣中心"。它不会立刻发送每条消息，而是先放入队列：

```vala
public void post_message_from_script (
        AgentScriptId script_id, string json, Bytes? data) {
    pending_messages.offer (new PendingMessage (
        next_serial++,           // 递增的序列号
        AgentMessageKind.SCRIPT,
        script_id,
        json,
        data
    ));
    maybe_deliver_pending_messages ();
}
```

## 22.4 批量发送：快递不是一件一件送的

这里有一个关键的性能优化：**批量发送**。Frida 不是每收到一条消息就立刻通过 DBus 发送，而是把多条消息打包成一个批次（batch）一起发。

就像快递公司不会每收到一个包裹就发一趟车，而是凑够一车再发。这样可以大幅减少 DBus 调用的开销。

```vala
private void maybe_deliver_pending_messages () {
    if (state != LIVE)
        return;

    AgentMessageSink? sink = (nice_message_sink != null)
        ? nice_message_sink : message_sink;
    if (sink == null)
        return;

    // 组装批次，限制总大小不超过 4MB
    var batch = new Gee.ArrayList<PendingMessage> ();
    size_t total_size = 0;
    size_t max_size = 4 * 1024 * 1024;  // 4MB 上限

    PendingMessage? m;
    while ((m = pending_messages.peek ()) != null) {
        size_t message_size = m.estimate_size_in_bytes ();
        // 如果加上这条消息会超过限额，并且批次不为空
        if (total_size + message_size > max_size && !batch.is_empty)
            break;
        pending_messages.poll ();
        batch.add (m);
        total_size += message_size;
    }

    // 发送批次
    sink.post_messages (items_arr, batch_id, cancellable);
}
```

注意几个细节：

1. **4MB 的批次上限**——防止单次 DBus 调用传输过多数据导致阻塞
2. **至少发一条消息**——即使单条消息超过 4MB，也会被发送（`!batch.is_empty` 检查）
3. **优先使用 P2P 连接**——如果有 nice_message_sink（ICE/DTLS 直连），优先走这条路

## 22.5 流量控制：Batch ID 机制

消息系统还需要处理一个经典问题：**流量控制**。如果脚本 hook 了一个高频调用的函数，每秒可能产生数千条消息。如果宿主端处理不过来怎么办？

Frida 使用了一套基于 Batch ID 的流量控制机制：

`batch_id` 是批次中最后一条消息的序列号。宿主端通过 `post_messages` 的参数回传 `rx_batch_id`，告诉 Agent 端"我已经处理到了第几批"。在会话中断和恢复时，这个机制尤为重要：

```vala
public void resume (uint rx_batch_id, out uint tx_batch_id) {
    if (rx_batch_id != 0) {
        // 丢弃已确认的消息
        PendingMessage? m;
        while ((m = pending_messages.peek ()) != null
               && m.delivery_attempts > 0
               && m.serial <= rx_batch_id) {
            pending_messages.poll ();
        }
    }

    // 重新开始投递
    delivery_cancellable = new Cancellable ();
    state = LIVE;
    maybe_deliver_pending_messages ();

    // 告诉对方我们收到了哪些
    tx_batch_id = last_rx_batch_id;
}
```

当连接断开后重新恢复时，Agent 端告诉宿主"我上次收到你确认的是 batch X"，然后只重发 X 之后的消息。宿主端也告诉 Agent"我上次收到你的消息到 batch Y"。这样双方都不会丢失消息，也不会重复处理。

## 22.6 从宿主到脚本：recv() 的旅程

消息不仅可以从脚本流向宿主，也可以反向流动。在 JavaScript 端：

```javascript
// 接收来自宿主的消息
recv('poke', function(message) {
    console.log('收到宿主消息:', JSON.stringify(message));
});
```

在 Python 端：

```python
script.post({'type': 'poke', 'data': 'hello'})
```

这条反向消息的路径是：

```
Python: script.post(message)
       │
       v
AgentSession.post_messages([message], batch_id)
       │  通过 DBus 发送到 Agent 端
       │
       v
BaseAgentSession.post_messages()
       │
       v
ScriptEngine.post_to_script(script_id, text, data)
       │
       v
JS 脚本的 recv() 回调被触发
```

在 `BaseAgentSession` 中处理接收到的消息：

```vala
public async void post_messages (AgentMessage[] messages,
        uint batch_id, Cancellable? cancellable) {
    // 检查当前状态是否允许接收
    transmitter.check_okay_to_receive ();

    foreach (var m in messages) {
        switch (m.kind) {
            case SCRIPT:
                script_engine.post_to_script (
                    m.script_id,
                    m.text,
                    m.has_data ? new Bytes (m.data) : null);
                break;
            case DEBUGGER:
                script_engine.post_to_debugger (
                    m.script_id, m.text);
                break;
        }
    }

    // 确认接收批次
    transmitter.notify_rx_batch_id (batch_id);
}
```

注意这里的 `check_okay_to_receive()`——如果会话处于中断状态（INTERRUPTED），就拒绝接收消息并抛出异常。这是流量控制的一部分。

## 22.7 错误处理：消息不能丢

每条待发送的消息被包装为 `PendingMessage`，记录了序列号（`serial`）、投递尝试次数（`delivery_attempts`）等元数据。消息管道中的错误处理设计得很谨慎：

```vala
private async void deliver_batch (AgentMessageSink sink,
        Gee.ArrayList<PendingMessage> messages, void * items) {
    bool success = false;
    pending_deliveries++;
    try {
        foreach (var message in messages)
            message.delivery_attempts++;

        yield sink.post_messages (items_arr, batch_id,
            delivery_cancellable);
        success = true;
    } catch (GLib.Error e) {
        // 发送失败！把消息放回队列
        pending_messages.add_all (messages);
        // 按序列号重新排序，保证顺序
        pending_messages.sort ((a, b) => a.serial - b.serial);
    } finally {
        pending_deliveries--;
        // 所有投递完成且成功，重置序列号
        if (pending_deliveries == 0 && success)
            next_serial = 1;
    }
}
```

这里有三个关键设计：

1. **失败后放回队列**——消息不会因为一次网络故障就丢失
2. **排序保证顺序**——放回的消息按序列号排序，确保消费者收到的消息顺序正确
3. **序列号重置**——当所有消息都成功投递后，序列号重置为 1，避免无限增长

## 22.9 AgentMessageSink：消息的终点

`AgentMessageSink` 是消息链的最后一环，定义为一个 DBus 接口：

```vala
[DBus (name = "re.frida.AgentMessageSink17")]
public interface AgentMessageSink : Object {
    public abstract async void post_messages (
        AgentMessage[] messages,
        uint batch_id,
        Cancellable? cancellable) throws GLib.Error;
}
```

这个接口有两个实现位置：

1. **宿主端**——在 ControlService 中，当客户端调用 `attach()` 后，服务端获取客户端 DBus 连接上的 AgentMessageSink 代理。Agent 发出的消息通过这个代理传递到客户端。

2. **P2P 端**——如果建立了 WebRTC（ICE/DTLS）直连，消息会走 `nice_message_sink`，绕过 frida-server 直接从 Agent 传到客户端。Transmitter 中通过 `nice_message_sink != null` 判断优先走 P2P 路径。

## 22.10 小结

本章我们深入探索了 Frida 的消息系统。核心要点：

- **AgentMessage 结构体**包含消息类型、脚本 ID、JSON 文本和可选的二进制数据，text + data 分离设计兼顾了灵活性和效率
- **AgentMessageTransmitter 是消息的分拣中心**，维护 PendingMessage 队列，负责批量发送和重试
- **批量发送**将多条消息打包成一个 DBus 调用，单批上限 4MB，大幅减少通信开销
- **Batch ID 机制**实现流量控制和可靠传输，支持断线后的消息恢复
- **失败后消息放回队列**并按序列号排序，保证消息不丢失、不乱序
- **中断/恢复机制**（`interrupt`/`resume`）允许短暂断线后继续会话，`persist_timeout` 超时后才彻底关闭

## 讨论问题

1. 为什么 Frida 选择 JSON 作为消息的文本格式而不是 Protocol Buffers 或 MessagePack？从 JavaScript 运行时的角度思考。
2. 4MB 的批次大小限制是如何确定的？如果你需要 dump 一段 100MB 的内存，消息系统会如何处理？
3. 在 `deliver_batch` 中，失败后把消息放回队列并重新排序。如果排序本身的开销很大（比如队列中有上万条消息），你会如何优化？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
