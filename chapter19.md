# 第19章：移动平台——Android 与 iOS 的特殊挑战

> 当 Frida 从桌面走向口袋里的手机，一切都变得更加困难。Android 有 SELinux 和沙箱，iOS 有代码签名和越狱检测。在移动平台上，Frida 不仅要完成注入，还要学会"伪装"和"潜行"。本章我们来看看 Frida 是如何在这两大移动系统上求生存的。

## 19.1 两大移动后端概览

```
┌──────────────────┬──────────────────┐
│     Android      │       iOS        │
│   Droidy 后端    │   Fruity 后端     │
├──────────────────┼──────────────────┤
│ droidy-client    │ fruity-host-sess │
│ droidy-host-sess │ usbmux / lockdown│
│ injector / jdwp  │ xpc / dtx        │
├──────────────────┼──────────────────┤
│ ADB Protocol     │ usbmux Protocol  │
│ (TCP :5037)      │ (Unix socket)    │
├──────────────────┼──────────────────┤
│  adb server      │  usbmuxd         │
│  USB / TCP       │  USB / WiFi      │
└──────────────────┴──────────────────┘
```

两个后端都运行在**主机端**（你的电脑上），通过各自的协议与设备通信。

## 19.2 Android：Droidy 后端与 ADB 集成

### 19.2.1 设备发现

Droidy 通过 ADB 协议发现和连接 Android 设备：

```vala
// 简化自 droidy-client.vala
public sealed class DeviceTracker : Object {
    public async void open(Cancellable? cancellable) {
        client = yield Client.open(cancellable);
        var devices = yield client.request_data("host:track-devices-l");
        yield update_devices(devices);
    }

    private async void update_devices(string encoded) {
        foreach (var line in encoded.split("\n")) {
            // 解析: "<serial>\t<state>\t<model:xxx ...>"
            if (type == "device")
                device_attached(new DeviceDetails(serial, name));
        }
    }

    private async string detect_name(string serial) {
        return yield ShellCommand.run("getprop ro.product.model", serial);
    }
}
```

### 19.2.2 ShellSession——ADB Shell v2

Frida 使用 Shell v2 协议与设备交互，支持结构化的输入输出和退出码获取：

```vala
// 简化自 droidy-client.vala
public async void open(string device_serial) {
    var client = yield Client.open();
    yield client.request("host:transport:" + device_serial);
    yield client.request_protocol_change("shell,v2,raw:");
}
```

### 19.2.3 Gadget 注入——JDWP 的妙用

除了传统的 ptrace 注入（需要设备端 frida-server），Frida 还支持通过 Gadget + JDWP 方式注入 Java 应用：

```vala
// 简化自 droidy/injector.vala
private async GadgetDetails inject_gadget() {
    string so_path = "/data/local/tmp/frida-gadget-" + instance_id + ".so";
    string unix_socket = "frida:" + package;

    // 1. 推送 gadget .so 到设备
    yield FileSync.send(gadget, so_meta, so_path, device_serial);

    // 2. 复制到应用数据目录
    yield shell.check_call("cp " + so_path + " /data/data/" + package + "/gadget.so");

    // 3. 通过 JDWP 断点触发 System.loadLibrary 加载 gadget
    // 4. gadget 监听 Unix socket 等待 Frida 连接
}
```

Gadget 模式的优势是不需要 root 权限，只要应用是 debuggable 的就行。

### 19.2.4 SELinux 的挑战

SELinux 给 Frida 带来多重障碍：

- **ptrace 限制**：非特权进程不能使用 ptrace，解决方案是 frida-server 以 root 运行
- **文件访问限制**：不同 SELinux 上下文的进程不能随意读文件，解决方案是 memfd_create
- **域转换限制**：注入的代码继承目标进程的上下文，某些操作可能被拒绝
- **执行保护**：SELinux 可能禁止执行非标签化代码

### 19.2.5 RoboLauncher——Android 应用管理

设备端的 frida-server 使用 `RoboLauncher` 管理应用启动和注入：

```vala
// 简化自 linux-host-session.vala (Android 部分)
#if ANDROID
    robo_launcher = new RoboLauncher(this, io_cancellable);
    robo_launcher.spawn_added.connect(on_spawn_added);
    crash_monitor = new CrashMonitor();
#endif
```

RoboLauncher 通过 Activity Manager（am start）启动应用，在 Zygote fork 出新进程后、Java 代码执行前完成注入。

## 19.3 iOS：Fruity 后端

### 19.3.1 usbmuxd——TCP 隧道

iOS 设备通过 usbmuxd 提供 TCP 隧道功能：

```vala
// 简化自 usbmux.vala
private async bool init_async(int io_priority, Cancellable? cancellable) {
    #if WINDOWS
        connectable = new InetSocketAddress(
            new InetAddress.loopback(IPV4), 27015);
    #else
        connectable = new UnixSocketAddress("/var/run/usbmuxd");
    #endif
    connection = yield new SocketClient().connect_async(connectable);
}
```

通过 usbmuxd，Frida 可以连接到设备上任意 TCP 端口，比如 frida-server 监听的 27042 端口。

### 19.3.2 Lockdown——设备配对认证

连接 iOS 设备前需要通过 Lockdown 协议完成配对：

```vala
// 简化自 lockdown.vala
public static async LockdownClient open(UsbmuxDevice device) {
    var usbmux = yield UsbmuxClient.open();
    Plist pair_record = yield usbmux.read_pair_record(device.udid);

    // 从配对记录提取 TLS 证书
    var cert = pair_record.get_bytes_as_string("HostCertificate");
    var key = pair_record.get_bytes_as_string("HostPrivateKey");
    tls_certificate = new TlsCertificate.from_pem(cert + "\n" + key);

    yield usbmux.connect_to_port(device.id, 62078);  // Lockdown 端口
    // 发送 StartSession，升级到 TLS 加密通信
}
```

### 19.3.3 XPC 与 DiscoveryService

较新的 iOS 版本上，Frida 使用 XPC 协议发现设备服务：

```vala
// 简化自 xpc.vala
public sealed class DiscoveryService : Object {
    public string query_udid() {
        return new VariantReader(handshake_body)
            .read_member("Properties").read_member("UniqueDeviceID")
            .get_string_value();
    }
    public ServiceInfo get_service(string identifier) {
        // 从握手响应中查找服务的端口号
    }
}
```

### 19.3.4 越狱 vs 非越狱

```
┌──────────────────────────┬──────────────────────────────┐
│       越狱设备            │        非越狱设备             │
├──────────────────────────┼──────────────────────────────┤
│ frida-server root 运行    │ 只能使用 Gadget 模式          │
│ 可以 attach 任意进程      │ 只能注入自己签名的应用         │
│ 支持 spawn gating        │ 不支持 spawn gating           │
│ PolicySoftener 处理限制   │ 受代码签名严格限制            │
│ 完整的系统级控制          │ 功能受限                      │
└──────────────────────────┴──────────────────────────────┘
```

越狱设备上，frida-server 通过 task_for_pid 获取 task port，使用 Mach 端口注入（见第17章）。非越狱设备只能将 Gadget dylib 嵌入应用重新签名后安装。

## 19.4 移动平台的共同挑战

### 19.4.1 资源约束

移动设备 CPU 和内存有限，iOS 的 jetsam 会杀掉内存占用过大的进程。Frida 使用事件驱动模型避免忙等待，消息序列化也要高效。

### 19.4.2 反调试对抗

```
┌────────────────────────────────────────────┐
│  常见 Frida 检测手段         │ Frida 应对   │
├─────────────────────────────┼──────────────┤
│ 扫描 27042 端口              │ 自定义端口    │
│ 查找 frida-server 进程       │ 进程重命名    │
│ 搜索 "LIBFRIDA" 字符串      │ 代码修改      │
│ ptrace(TRACEME) 自保护      │ 绕过检查      │
│ 检查 /proc/self/maps        │ memfd 注入    │
│ dlopen 行为监控              │ Gadget 伪装   │
└─────────────────────────────┴──────────────┘
```

## 19.5 本章小结

- **Droidy 后端** 通过 ADB 协议与 Android 设备通信，支持设备发现和 Shell 交互
- **Gadget 注入** 利用 JDWP 将 agent 注入到 debuggable 的 Java 应用中，不需要 root
- **SELinux** 是 Android 上的主要障碍，Frida 通过 root 权限和 memfd 应对
- **Fruity 后端** 通过 usbmuxd 建立 TCP 隧道，Lockdown 完成设备认证
- **XPC** 用于发现 iOS 设备上的服务
- 越狱 iOS 拥有完整能力，非越狱只能用 Gadget 模式
- 移动应用的**反调试检测**是实际使用中的重要挑战
- 两大平台共同特点是资源受限和安全策略严格

## 讨论问题

1. Android 上 JDWP 注入 Gadget 与 frida-server 的 ptrace 注入相比，各有什么优缺点？

2. iOS 非越狱设备使用 Frida Gadget 需要重签名应用，这在实际工作中会遇到哪些问题？

3. 如果你在开发移动安全应用想检测 Frida，你会采用哪些手段？反过来如何规避？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
