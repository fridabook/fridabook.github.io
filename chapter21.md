# 第21章：控制服务——网络上的 Frida

> 当你在电脑上运行 `frida -H 192.168.1.100 -p 1234` 连接到手机上的 frida-server 时，你有没有好奇过：frida-server 到底在监听什么？它是如何把网络上飞来的字节流变成"附加到进程"这样的具体操作的？

## 21.1 ControlService：Frida 的门面

如果把 Frida 比作一家餐厅，那么 ControlService 就是餐厅的大门和前台。它负责：

- 监听网络端口，等待客户端连接
- 验证来客身份（认证）
- 把客户端的请求转发给后厨（HostSession）
- 管理所有正在进行的"用餐"（Agent 会话）

在源码中，`ControlService` 定义在 `control-service.vala` 中。我们先看它的整体架构：

```
┌───────────────────────────────────────────────────────┐
│                   ControlService                       │
│                                                        │
│  ┌──────────────┐    ┌─────────────────────────────┐  │
│  │  WebService   │    │     ConnectionHandler       │  │
│  │  (HTTP/WS)    │───>│                             │  │
│  │  监听端口     │    │  ┌─────────────────────┐    │  │
│  └──────────────┘    │  │ AuthenticationChannel│    │  │
│                       │  │  (验证身份)          │    │  │
│                       │  └─────────┬───────────┘    │  │
│                       │            │ 验证通过        │  │
│                       │            v                 │  │
│                       │  ┌─────────────────────┐    │  │
│                       │  │  ControlChannel      │    │  │
│                       │  │  (正式对话)          │    │  │
│                       │  └─────────────────────┘    │  │
│                       └─────────────────────────────┘  │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │              HostSession (后端服务)               │  │
│  │  DarwinHostSession / LinuxHostSession / ...      │  │
│  └──────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────┘
```

## 21.2 frida-server 的启动流程

让我们从 `server.vala` 的 `main()` 函数开始，看看 frida-server 是如何启动的。

```vala
// server.vala (简化版)
private static int main (string[] args) {
    // 解析命令行参数
    // --listen, --certificate, --token, --origin 等
    var ctx = new OptionContext ();
    ctx.add_main_entries (option_entries, null);
    ctx.parse (ref args);

    // 构建端点参数
    var endpoint_params = new EndpointParameters (
        listen_address,       // 如 "0.0.0.0:27042"
        0,
        parse_certificate (certpath),  // TLS 证书
        origin,               // 允许的 Origin
        auth_service,         // 认证服务
        asset_root            // 静态文件目录
    );

    // 创建并运行 ControlService
    service = new ControlService (endpoint_params, options);
    yield service.start (cancellable);
}
```

默认端口是 `27042`——这是 Frida 的标志性端口号。整个启动过程可以概括为：

```
解析命令行参数
       │
       v
构建 EndpointParameters (地址、证书、Token)
       │
       v
创建 ControlService
       │  ├── 创建平台对应的 HostSession
       │  │   (Darwin/Linux/Windows/FreeBSD)
       │  └── 创建 WebService (HTTP 服务器)
       │
       v
service.start()
       │  ├── 启动 WebService 监听端口
       │  └── 可选: 预加载 (preload)
       │
       v
进入主循环，等待连接
```

## 21.3 WebService：HTTP 与 WebSocket

Frida 的网络传输层基于 HTTP 和 WebSocket。`WebService` 类封装了这一层，定义在 `socket.vala` 中：

```vala
// socket.vala (简化版)
public sealed class WebService : Object {
    public signal void incoming (
        IOStream connection,
        SocketAddress remote_address,
        DynamicInterface? dynamic_iface);

    public WebServiceFlavor flavor;     // CONTROL 或 CLUSTER
    public EndpointParameters endpoint_params;

    public async void start (Cancellable? cancellable);
    public void stop ();
}
```

当一个客户端通过 WebSocket 连接到 frida-server 时，发生了什么？

```
┌──────────┐         ┌─────────────────────┐
│  Client  │         │    frida-server      │
│          │         │                      │
└────┬─────┘         └──────────┬───────────┘
     │                          │
     │  1. TCP 连接              │
     │  ──────────────────────> │
     │                          │
     │  2. HTTP Upgrade 请求    │
     │  GET / HTTP/1.1          │
     │  Upgrade: websocket      │
     │  ──────────────────────> │
     │                          │
     │  3. 101 Switching        │
     │  <────────────────────── │
     │                          │
     │  4. WebSocket 帧         │
     │  (承载 DBus 消息)        │
     │  <────────────────────>  │
     │                          │
```

WebSocket 在这里充当了一个"管道"。一旦 WebSocket 连接建立，Frida 就在上面跑 DBus 协议。WebSocket 的帧机制天然支持消息边界，非常适合承载 DBus 的消息格式。

`WebServiceFlavor` 有两个值：`CONTROL`（用于 frida-server 的控制通道）和 `CLUSTER`（用于 Portal 集群模式）。

## 21.4 连接的处理流程

当 WebService 收到一个新连接后，会触发 `incoming` 信号。ControlService 在 `on_server_connection` 中处理这个信号：

```vala
// control-service.vala (简化版)
private void on_server_connection (IOStream connection,
        SocketAddress remote_address,
        DynamicInterface? dynamic_iface) {
    handler.handle_server_connection.begin (connection);
}
```

`ConnectionHandler.handle_server_connection` 是关键方法：

```vala
public async void handle_server_connection (IOStream raw_connection) {
    // 在 WebSocket 流之上创建 DBus 连接
    var connection = yield new DBusConnection (
        raw_connection,
        null,
        DELAY_MESSAGE_PROCESSING,  // 先别处理消息
        null,
        io_cancellable);

    // 根据是否需要认证，创建不同的 Peer
    AuthenticationService? auth_service =
        parent.endpoint_params.auth_service;

    if (auth_service != null)
        peers[connection] = new AuthenticationChannel (
            this, connection, auth_service);
    else
        peers[connection] = new ControlChannel (
            this, connection);

    // 开始处理消息
    connection.start_message_processing ();
}
```

注意 `DELAY_MESSAGE_PROCESSING` 这个标志。创建 DBusConnection 时先不处理消息，等到 Peer 对象（AuthenticationChannel 或 ControlChannel）完全初始化后，再调用 `start_message_processing()`。这避免了初始化过程中的竞态条件。

## 21.5 认证与访问控制

如果 frida-server 启动时指定了 `--token` 参数，连接的处理会多一个认证步骤：

```
┌──────────┐                        ┌──────────────┐
│  Client  │                        │ frida-server │
└────┬─────┘                        └──────┬───────┘
     │                                     │
     │  连接建立                            │
     │  ──────────────────────────────>    │
     │                                     │
     │  此时服务端创建 AuthenticationChannel │
     │  注册 UnauthorizedHostSession       │
     │  (所有方法都返回"未授权")            │
     │                                     │
     │  调用 authenticate(token)           │
     │  path: /re/frida/AuthenticationService
     │  ──────────────────────────────>    │
     │                                     │
     │  [验证 token 的 SHA256 哈希]        │
     │                                     │
     │  认证成功: 返回 "{}"                │
     │  <──────────────────────────────    │
     │                                     │
     │  服务端"升级"连接:                   │
     │  AuthenticationChannel              │
     │      --> ControlChannel             │
     │  注册真正的 HostSession             │
     │                                     │
     │  现在可以正常调用了                   │
     │  attach(pid=1234)                   │
     │  ──────────────────────────────>    │
```

在认证通过之前，服务端注册的是一个 `UnauthorizedHostSession`——这个类实现了 HostSession 的所有方法，但每个方法都简单地抛出"未授权"错误。这种设计很巧妙：客户端看到的接口是一样的，只是在认证前所有操作都被拒绝。

认证通过后，`promote_authentication_channel` 方法把 AuthenticationChannel 替换为 ControlChannel：

```vala
public async void promote_authentication_channel (
        AuthenticationChannel channel) {
    DBusConnection connection = channel.connection;

    peers.unset (connection);
    yield channel.close (io_cancellable);

    // 创建新的 ControlChannel，注册真正的 HostSession
    peers[connection] = new ControlChannel (this, connection);
}
```

## 21.6 ControlChannel：正式的对话

ControlChannel 是认证后的核心通信通道。它在 DBus 连接上注册各种服务对象，让客户端可以正常操作：

```
ControlChannel 注册的 DBus 对象
┌──────────────────────────────────────────────┐
│                                               │
│  /re/frida/HostSession                       │
│    -> 进程枚举、attach、spawn 等              │
│                                               │
│  /re/frida/TransportBroker                   │
│    -> TCP 传输协商 (用于 P2P 优化)            │
│                                               │
│  /re/frida/BusSession                        │
│    -> Bus 消息通道                            │
│                                               │
│  /re/frida/AgentMessageSink/{session_id}     │
│    -> 每个 Agent 会话的消息接收端             │
│                                               │
└──────────────────────────────────────────────┘
```

当客户端调用 `attach()` 附加到某个进程后，ControlService 会：

1. 调用底层 HostSession 的 `attach()` 方法，注入 Agent
2. 获取 Agent 的 `AgentSession` 对象
3. 在客户端的 DBus 连接上注册该 AgentSession
4. 获取客户端侧的 `AgentMessageSink` 代理

这样，后续的脚本操作和消息传递就可以直接在 AgentSession 上进行了。

## 21.7 TLS 加密

frida-server 支持 TLS 加密，只需启动时指定证书：

```bash
frida-server --certificate /path/to/cert.pem
```

在源码中，证书通过 `EndpointParameters` 传递：

```vala
var endpoint_params = new EndpointParameters (
    listen_address,
    0,
    parse_certificate (certpath),  // TLS 证书
    origin,
    auth_service,
    asset_root
);
```

有了 TLS，WebSocket 连接就变成了 WSS（WebSocket Secure），所有通信内容都被加密。这在远程调试时尤其重要——你可不希望你的调试流量在网络上被嗅探。

## 21.8 远程调试的完整工作流

让我们把所有知识串起来，看看远程调试的完整工作流：

```
手机端                                     电脑端
┌─────────────────┐                  ┌─────────────────┐
│  frida-server   │                  │  frida CLI      │
│                 │                  │                 │
│  1. 启动        │                  │                 │
│  监听 27042     │                  │                 │
│                 │  2. TCP 连接     │                 │
│                 │ <────────────────│  frida -H phone │
│                 │                  │                 │
│                 │  3. WebSocket    │                 │
│                 │  升级 + TLS      │                 │
│                 │ <───────────────>│                 │
│                 │                  │                 │
│  4. DBus 连接   │  5. authenticate │                 │
│  建立           │ <────────────────│  --token=secret │
│                 │                  │                 │
│  6. 认证通过    │                  │                 │
│  注册真实       │  7. attach(pid)  │                 │
│  HostSession    │ <────────────────│  -p 1234        │
│                 │                  │                 │
│  8. 注入 Agent  │  9. session_id   │                 │
│  到目标进程     │ ────────────────>│                 │
│                 │                  │                 │
│                 │  10. 创建/加载   │                 │
│                 │  脚本、收发消息   │                 │
│                 │ <───────────────>│                 │
└─────────────────┘                  └─────────────────┘
```

## 21.9 小结

本章我们深入分析了 Frida 的控制服务架构。核心要点：

- **ControlService 是 frida-server 的核心**，负责接受连接、认证客户端、管理会话
- **WebService 提供 HTTP/WebSocket 传输**，DBus 消息在 WebSocket 之上传输
- **认证采用两阶段设计**：先用 UnauthorizedHostSession 拒绝一切，认证后升级为真正的 ControlChannel
- **默认端口 27042**，支持 TLS 加密和 Token 认证
- **ConnectionHandler 管理所有 Peer（连接对）**，每个 DBus 连接对应一个 Peer
- **frida-server 支持守护进程模式**（`--daemonize`），使用经典的 Unix fork + pipe 模式

## 讨论问题

1. 为什么 Frida 选择 WebSocket 而不是直接的 TCP 作为传输层？WebSocket 带来了哪些额外的好处？
2. 认证失败时，为什么不直接断开连接，而是要注册一个 UnauthorizedHostSession？从协议设计的角度思考。
3. 在真实的渗透测试场景中，如果你发现目标机器上运行着没有开启认证的 frida-server，意味着什么？如何利用，又该如何防范？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
