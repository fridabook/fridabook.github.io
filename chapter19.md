# 第19章：移动平台——Android 与 iOS 的特殊挑战

> 当 Frida 从桌面走向口袋里的手机，一切都变得更加困难。Android 有 SELinux 和沙箱，iOS 有代码签名和越狱检测。在移动平台上，Frida 不仅要完成注入，还要学会"伪装"和"潜行"。本章我们来看看 Frida 是如何在这两大移动系统上求生存的。

## 19.1 两大移动后端

Frida 为 Android 和 iOS 分别提供了专门的后端：

```
┌──────────────────────────────────┐
│           移动后端总览            │
├──────────────────────────────────┤
│                                  │
│  Android (Droidy后端)            │
│  frida-core/src/droidy/          │
│  ├── droidy-host-session.vala    │
│  ├── droidy-client.vala          │
│  ├── injector.vala               │
│  ├── jdwp.vala                   │
│  └── axml.vala                   │
│                                  │
│  iOS (Fruity后端)                │
│  frida-core/src/fruity/          │
│  ├── fruity-host-session.vala    │
│  ├── usbmux.vala                 │
│  ├── lockdown.vala               │
│  ├── xpc.vala                    │
│  ├── dtx.vala                    │
│  └── usb.vala                    │
│                                  │
└──────────────────────────────────┘
```

两个后端的定位不同：Droidy 通过 ADB 与 Android 设备通信，Fruity 通过 usbmuxd 与 iOS 设备通信。它们都运行在**主机端**（你的电脑上），而不是设备端。

## 19.2 Android：Droidy 后端

### 19.2.1 ADB 集成——与设备对话

Droidy 后端的第一步是发现和连接 Android 设备，这完全建立在 ADB（Android Debug Bridge）协议之上：

```vala
// 简化自 droidy-client.vala
public sealed class DeviceTracker : Object {
    private Client? client;

    public async void open(Cancellable? cancellable) {
        client = yield Client.open(cancellable);

        // 向 ADB 服务器发送设备追踪请求
        var devices_encoded = yield client.request_data(
            "host:track-devices-l", cancellable);
        yield update_devices(devices_encoded, cancellable);
    }

    private async void update_devices(string devices_encoded) {
        // 解析 ADB 返回的设备列表
        // 格式: "<serial>\t<state>\t<model:xxx ...>"
        foreach (var line in devices_encoded.split("\n")) {
            // 提取设备序列号、状态和名称
            string serial = ...;
            string type = ...;
            if (type == "device")
                device_attached(new DeviceDetails(serial, name));
        }
    }

    // 通过 ADB shell 获取设备型号
    private async string detect_name(string serial) {
        return yield ShellCommand.run(
            "getprop ro.product.model", serial);
    }
}
```

Droidy 与 ADB 的通信模型：

```
┌──────────┐     TCP      ┌──────────┐    USB     ┌──────────┐
│  Frida   │<────────────>│  ADB     │<──────────>│ Android  │
│  Client  │  localhost   │  Server  │            │ Device   │
│  (电脑)  │  :5037       │  (电脑)  │            │          │
└──────────┘              └──────────┘            └──────────┘
     │                         │                       │
     │  host:track-devices     │                       │
     │─────────────────────────>                       │
     │                         │  USB protocol         │
     │  host:transport:<serial>│───────────────────────>
     │─────────────────────────>                       │
     │                         │                       │
     │  shell:command          │  adbd                 │
     │─────────────────────────>───────────────────────>
     │                         │                       │
```

### 19.2.2 ShellSession——ADB Shell v2

Frida 使用 ADB 的 Shell v2 协议与设备交互，支持结构化的输入输出：

```vala
// 简化自 droidy-client.vala
public sealed class ShellSession : Object {
    public async void open(string device_serial) {
        var client = yield Client.open();
        yield client.request("host:transport:" + device_serial);
        // 使用 Shell v2 协议，支持分离的 stdin/stdout/stderr
        yield client.request_protocol_change("shell,v2,raw:");
        stream = client.stream;
    }

    public async ShellCommandResult run(string command) {
        // 发送命令，收集标准输出和退出码
        string full_cmd = command + "; echo -n x$?" + session_id;
        write_packet(new Packet(STDIN, full_cmd.data));
        // ... 等待结果
    }
}
```

### 19.2.3 Gadget 注入——Android 上的特殊手段

在 Android 上，Frida 除了传统的 ptrace 注入（通过设备端的 frida-server），还支持通过 **Gadget** 方式注入。Gadget 利用 JDWP（Java Debug Wire Protocol）将 agent 注入到 Java 应用中：

```vala
// 简化自 droidy/injector.vala
private async GadgetDetails inject_gadget(Cancellable? cancellable) {
    string instance_id = Uuid.string_random().replace("-", "");
    string so_path = "/data/local/tmp/frida-gadget-" + instance_id + ".so";
    string config_path = "/data/local/tmp/frida-gadget-" + instance_id + ".config";
    string unix_socket_path = "frida:" + package;

    // 1. 通过 ADB 将 gadget .so 推送到设备
    yield FileSync.send(gadget, so_meta, so_path, device_serial);

    // 2. 生成配置文件
    var config = new Json.Builder();
    config
        .begin_object()
        .set_member_name("interaction")
        .begin_object()
            .set_member_name("type").add_string_value("listen")
            .set_member_name("address").add_string_value(unix_socket_path)
        .end_object()
        .end_object();

    // 3. 复制到应用目录
    yield shell.check_call("cp " + so_path + " " + app_so_path);
    yield shell.check_call("cp " + config_path + " " + app_config_path);

    // 4. 通过 JDWP 触发加载
    // ...
}
```

Gadget 注入流程：

```
┌──────────────────────────────────────────────┐
│         Android Gadget 注入流程               │
├──────────────────────────────────────────────┤
│                                              │
│  1. 推送 frida-gadget.so 到 /data/local/tmp  │
│                                              │
│  2. 生成配置文件（监听地址等）                 │
│                                              │
│  3. 复制到目标应用的数据目录                   │
│     /data/data/<package>/gadget.so           │
│                                              │
│  4. 通过 JDWP 连接到目标应用                  │
│     (应用需要是 debuggable 的)                │
│                                              │
│  5. 通过 JDWP 断点机制触发 System.loadLibrary │
│     加载 gadget.so                           │
│                                              │
│  6. gadget.so 启动后监听 Unix socket         │
│     等待 Frida 客户端连接                     │
│                                              │
└──────────────────────────────────────────────┘
```

### 19.2.4 SELinux 的挑战

Android 使用 SELinux（Security-Enhanced Linux）进行强制访问控制。这给 Frida 带来了额外的障碍：

```
┌──────────────────────────────────────────────────┐
│           SELinux 对 Frida 的限制                 │
├──────────────────────────────────────────────────┤
│                                                  │
│  问题1: 进程间 ptrace 限制                        │
│  - SELinux 可能禁止非特权进程使用 ptrace           │
│  - 解决: frida-server 以 root 权限运行            │
│                                                  │
│  问题2: 文件访问限制                              │
│  - 不同 SELinux 上下文的进程不能随意读取文件        │
│  - 解决: 使用 memfd_create 避免文件系统操作        │
│                                                  │
│  问题3: 域转换限制                                │
│  - 注入的代码继承了目标进程的 SELinux 上下文        │
│  - 某些操作（如网络访问）可能被拒绝                 │
│  - 解决: 在适当的域中运行，或修改 SELinux 策略      │
│                                                  │
│  问题4: 执行保护                                  │
│  - SELinux 可能禁止执行非标签化的代码               │
│  - 解决: 使用 memfd + 正确的文件标签               │
│                                                  │
└──────────────────────────────────────────────────┘
```

Frida 源码中甚至有专门的 SuperSU 集成（`supersu.vala`），用于在老版本 Android root 方案上处理权限问题。

### 19.2.5 包管理器集成

在 Android 上，Frida 需要与 Android 的包管理系统交互来获取应用信息。在设备端运行的 frida-server 使用 Linux 后端中的 `RoboLauncher` 来管理应用的启动和注入：

```vala
// 简化自 linux-host-session.vala (Android 部分)
#if ANDROID
    robo_launcher = new RoboLauncher(this, io_cancellable);
    robo_launcher.spawn_added.connect(on_spawn_added);
    robo_launcher.spawn_removed.connect(on_spawn_removed);

    if (report_crashes) {
        crash_monitor = new CrashMonitor();
        crash_monitor.process_crashed.connect(on_process_crashed);
    }
#endif
```

RoboLauncher 通过 Android 的 Activity Manager 来启动应用：

```
┌────────────────────────────────────────────┐
│  Android 应用启动流程（Frida 视角）         │
├────────────────────────────────────────────┤
│                                            │
│  1. am start -n <package>/<activity>       │
│     (通过 Activity Manager 启动应用)        │
│                                            │
│  2. Zygote fork 出新的应用进程              │
│                                            │
│  3. Frida 检测到新进程                      │
│     (通过 /proc 或 eBPF)                    │
│                                            │
│  4. 在应用执行 Java 代码前注入 agent        │
│                                            │
│  5. Agent 加载完成，执行 hook 脚本          │
│                                            │
└────────────────────────────────────────────┘
```

## 19.3 iOS：Fruity 后端

### 19.3.1 usbmuxd——iOS 设备通信的基石

iOS 设备通过 USB 连接电脑时，Apple 的 `usbmuxd` 守护进程提供了 TCP 隧道功能。Frida 的 Fruity 后端就建立在这个基础上：

```vala
// 简化自 usbmux.vala
public sealed class UsbmuxClient : Object {
    private const uint16 USBMUXD_DEFAULT_SERVER_PORT = 27015;

    private async bool init_async(int io_priority, Cancellable? cancellable) {
        SocketConnectable? connectable = null;

        // 检查环境变量是否指定了自定义地址
        string? env = Environment.get_variable("USBMUXD_SOCKET_ADDRESS");

        if (connectable == null) {
            // 默认连接方式
            #if WINDOWS
                // Windows 上通过 TCP 连接
                connectable = new InetSocketAddress(
                    new InetAddress.loopback(IPV4),
                    USBMUXD_DEFAULT_SERVER_PORT);
            #else
                // Unix 系统上通过 Unix domain socket
                connectable = new UnixSocketAddress("/var/run/usbmuxd");
            #endif
        }

        var client = new SocketClient();
        connection = yield client.connect_async(connectable);
    }

    public async void connect_to_port(uint device_id, uint16 port) {
        // 通过 usbmux 隧道连接到设备上的指定端口
        // ...
    }
}
```

通信架构：

```
┌──────────┐  Unix Socket  ┌──────────┐    USB    ┌──────────┐
│  Frida   │<─────────────>│ usbmuxd  │<─────────>│  iOS     │
│  Client  │ /var/run/     │ (Apple   │           │ Device   │
│  (Mac)   │  usbmuxd     │  daemon) │           │          │
└──────────┘               └──────────┘           └──────────┘

     │                          │                      │
     │  ListDevices             │                      │
     │─────────────────────────>│                      │
     │  [{UDID, ...}]          │                      │
     │<─────────────────────────│                      │
     │                          │                      │
     │  Connect(device, 27042)  │                      │
     │─────────────────────────>│  USB tunnel          │
     │                          │─────────────────────>│ :27042
     │  [TCP stream]            │  [TCP stream]        │(frida-server)
     │<═══════════════════════════════════════════════>│
```

### 19.3.2 Lockdown——设备配对与认证

在连接 iOS 设备之前，需要通过 Lockdown 协议完成配对验证：

```vala
// 简化自 lockdown.vala
public sealed class LockdownClient : Object {
    private const uint16 LOCKDOWN_PORT = 62078;

    public static async LockdownClient open(UsbmuxDevice device) {
        var usbmux = yield UsbmuxClient.open();

        // 读取配对记录（包含证书和密钥）
        Plist pair_record = yield usbmux.read_pair_record(device.udid);

        // 提取认证信息
        string host_id = pair_record.get_string("HostID");
        string system_buid = pair_record.get_string("SystemBUID");

        // 构建 TLS 证书
        var cert = pair_record.get_bytes_as_string("HostCertificate");
        var key = pair_record.get_bytes_as_string("HostPrivateKey");
        tls_certificate = new TlsCertificate.from_pem(cert + "\n" + key);

        // 连接到设备的 Lockdown 端口
        yield usbmux.connect_to_port(device.id, LOCKDOWN_PORT);

        var client = new LockdownClient(usbmux.connection);
        yield client.query_type();  // 验证连接

        return client;
    }

    public async void start_session() {
        // 发送 StartSession 请求，带上 HostID
        var request = create_request("StartSession");
        request.set_string("HostID", host_id);
        request.set_string("SystemBUID", system_buid);

        var response = yield service.query(request);

        // 如果需要，升级到 TLS 加密通信
        if (response.get_boolean("EnableSessionSSL"))
            service.stream = yield start_tls(service.stream);
    }
}
```

### 19.3.3 XPC 与 DiscoveryService

在较新的 iOS 版本上，Frida 使用 XPC（跨进程通信）协议来发现设备上的服务：

```vala
// 简化自 xpc.vala
public sealed class DiscoveryService : Object {
    private XpcConnection connection;

    public static async DiscoveryService open(IOStream stream) {
        var service = new DiscoveryService(stream);
        // XPC 握手
        service.connection = new XpcConnection(stream);
        service.connection.activate();
        // 等待设备返回服务列表
        var body = yield service.handshake_promise.future.wait_async();
        return service;
    }

    public string query_udid() {
        // 从握手响应中获取设备 UDID
        var reader = new VariantReader(handshake_body);
        reader.read_member("Properties").read_member("UniqueDeviceID");
        return reader.get_string_value();
    }

    public ServiceInfo get_service(string identifier) {
        // 查找指定服务的端口
        var reader = new VariantReader(handshake_body);
        reader.read_member("Services").read_member(identifier);
        var port = reader.read_member("Port").get_string_value();
        return new ServiceInfo() { port = (uint16)uint.parse(port) };
    }
}
```

### 19.3.4 越狱 vs 非越狱

iOS 上 Frida 的能力取决于设备是否越狱：

```
┌─────────────────────────────────────────────────────────┐
│               iOS 上 Frida 的两种模式                    │
├──────────────────────────┬──────────────────────────────┤
│       越狱设备            │        非越狱设备             │
├──────────────────────────┼──────────────────────────────┤
│ frida-server 以 root     │ 只能使用 Gadget 模式          │
│ 权限运行在设备上          │ (需要重打包应用)              │
│                          │                              │
│ 可以 attach 到任意进程    │ 只能注入到自己签名的应用       │
│                          │                              │
│ 支持 spawn gating        │ 不支持 spawn gating           │
│                          │                              │
│ PolicySoftener 处理       │ 受代码签名严格限制            │
│ 内存和权限限制            │                              │
│                          │                              │
│ 完整的系统级控制          │ 功能受限                      │
├──────────────────────────┴──────────────────────────────┤
│  共同点：都通过 usbmux + Fruity 后端进行通信             │
└─────────────────────────────────────────────────────────┘
```

越狱设备上的架构：

```
┌────────┐   usbmux    ┌────────────────────────────────┐
│ 电脑   │<────────────>│         iOS 设备                │
│ Frida  │   TCP隧道    │                                │
│ Client │              │  ┌──────────────────────────┐  │
│        │              │  │  frida-server (root)     │  │
│        │              │  │  监听 27042 端口          │  │
│        │              │  └──────────┬───────────────┘  │
│        │              │             │ task_for_pid     │
│        │              │             │ + Mach 端口注入   │
│        │              │  ┌──────────v───────────────┐  │
│        │              │  │  Target App              │  │
│        │              │  │  + frida-agent.dylib     │  │
│        │              │  └──────────────────────────┘  │
└────────┘              └────────────────────────────────┘
```

### 19.3.5 FruitController——iOS 应用管理

在越狱的 iOS 设备上，`FruitController` 负责管理应用的 spawn 和 crash 监控：

```vala
// 简化自 darwin-host-session.vala
#if IOS || TVOS
    fruit_controller = new FruitController(this, io_cancellable);
    fruit_controller.spawn_added.connect(on_spawn_added);
    fruit_controller.spawn_removed.connect(on_spawn_removed);
    fruit_controller.process_crashed.connect(on_process_crashed);
#endif
```

## 19.4 移动平台的共同挑战

### 19.4.1 电量与性能

移动设备资源有限。Frida 需要注意：

```
┌────────────────────────────────────────────┐
│        移动平台资源约束                     │
├────────────────────────────────────────────┤
│                                            │
│  CPU：agent 不能占用太多 CPU 周期           │
│  └─> Frida 使用事件驱动模型，避免忙等待     │
│                                            │
│  内存：移动设备内存有限                     │
│  └─> Agent 内存占用需要控制                 │
│  └─> iOS 的 jetsam 会杀掉内存占用过大的进程  │
│                                            │
│  网络：USB 带宽是瓶颈                       │
│  └─> 消息需要高效序列化                     │
│  └─> 批量操作比频繁小请求更好               │
│                                            │
└────────────────────────────────────────────┘
```

### 19.4.2 反调试对抗

很多移动应用会检测 Frida 的存在：

```
┌────────────────────────────────────────────────────────┐
│           常见的 Frida 检测手段                         │
├────────────────────────────────────────────────────────┤
│                                                        │
│  1. 端口扫描：检测 27042 端口是否开放                    │
│  2. 进程名检测：查找 frida-server 进程                   │
│  3. 内存扫描：搜索 "LIBFRIDA" 等字符串                   │
│  4. ptrace 自保护：对自己调用 ptrace(TRACEME)            │
│  5. /proc/self/maps 检查：查找 frida-agent.so            │
│  6. 命名管道检测：查找 frida 相关的管道                   │
│  7. dlopen 检测：监控库加载行为                           │
│                                                        │
├────────────────────────────────────────────────────────┤
│           Frida 的应对措施                              │
├────────────────────────────────────────────────────────┤
│                                                        │
│  1. 自定义端口：可以指定非默认端口                       │
│  2. 进程重命名：frida-server 可以改名运行                │
│  3. memfd 注入：不在文件系统中留下痕迹                   │
│  4. Gadget 模式：伪装成普通 .so/.dylib                  │
│  5. 代码混淆：Frida 的字符串可以被修改                   │
│                                                        │
└────────────────────────────────────────────────────────┘
```

### 19.4.3 两个平台的设备发现对比

```
┌──────────────────┬──────────────────┐
│     Android      │       iOS        │
├──────────────────┼──────────────────┤
│ DroidyBackend    │ FruityBackend    │
│       │          │       │          │
│ DeviceTracker    │ DeviceMonitor    │
│       │          │       │          │
│  ADB Protocol    │ usbmux Protocol  │
│  (TCP :5037)     │ (Unix socket /   │
│                  │  TCP :27015)     │
│       │          │       │          │
│  adb server      │  usbmuxd         │
│       │          │       │          │
│  USB / TCP       │  USB / WiFi      │
│       │          │       │          │
│  Android Device  │  iOS Device      │
└──────────────────┴──────────────────┘
```

## 19.5 本章小结

- **Android Droidy 后端** 通过 ADB 协议与设备通信，支持设备发现、Shell 命令和文件传输
- **Gadget 注入** 是 Android 上的特殊方案，利用 JDWP 将 agent 注入到 Java 应用中
- **SELinux** 是 Android 上的主要安全障碍，Frida 通过 root 权限和 memfd 来应对
- **iOS Fruity 后端** 通过 usbmuxd 建立 TCP 隧道，使用 Lockdown 协议完成设备认证
- **XPC** 和 **DiscoveryService** 用于发现 iOS 设备上的可用服务
- 越狱 iOS 设备上 Frida 拥有完整能力，非越狱设备只能使用 Gadget 模式
- 移动应用的**反调试检测**是实际使用中的重要挑战
- 两大平台的共同特点是资源受限和安全策略严格，Frida 需要在性能和隐蔽性之间取得平衡

## 讨论问题

1. Android 上通过 JDWP 注入 Gadget 的方式，与直接使用 frida-server 的 ptrace 注入相比，各有什么优缺点？

2. iOS 非越狱设备上使用 Frida Gadget 需要重签名应用，这在实际工作中会遇到哪些问题？有没有不需要重签名的方案？

3. 如果你在开发一个移动安全应用，想要检测 Frida 的存在，你会采用哪些手段？反过来，作为 Frida 用户，你会如何规避这些检测？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
