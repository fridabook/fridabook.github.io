# 第18章：Windows 后端——远程线程与调试符号

> 在 Windows 的世界里，注入 DLL 几乎是一项"民间传统艺术"。从游戏外挂到安全工具，无数程序都在使用 CreateRemoteThread + LoadLibrary 这个经典组合。Frida 的 Windows 后端也不例外，但它把这个"传统技艺"做到了工程化的极致。让我们揭开 Windows 后端的面纱。

## 18.1 Windows 后端的整体架构

Windows 后端的核心文件结构：

```
frida-core/src/windows/
├── windows-host-session.vala       # 主会话管理
├── winjector.vala                  # Windows 注入器
├── winjector-glue.c                # 注入底层实现（C）
├── frida-helper-backend.vala       # Helper 后端
├── frida-helper-backend-glue.c     # Helper 底层实现
├── frida-helper-process.vala       # Helper 进程管理
├── frida-helper-service.vala       # Helper 服务
├── access-helpers.c                # 访问控制辅助
├── wait-handle-source.c            # 等待句柄事件源
└── system-windows.c                # 系统信息获取
```

```
┌───────────────────────────────────────────────┐
│           WindowsHostSession                   │
│  (管理 Windows 本地调试会话)                    │
├───────────┬───────────────────────────────────┤
│ Winjector │  ApplicationEnumerator             │
│ (注入器)  │  ProcessEnumerator                 │
├───────────┴───────────────────────────────────┤
│        WindowsHelperBackend                    │
│  (CreateRemoteThread, DLL注入)                 │
├───────────────────────────────────────────────┤
│  Windows Kernel: Process/Thread/Memory APIs    │
└───────────────────────────────────────────────┘
```

## 18.2 CreateRemoteThread——经典的注入手法

Windows 提供了一个堪称"为注入而生"的 API：`CreateRemoteThread`。它允许你在另一个进程中创建一个线程并指定线程的起始函数。

### 18.2.1 注入流程详解

```c
// 简化自 frida-helper-backend-glue.c
void inject_library_file(uint32 pid, const char *path,
        const char *entrypoint, const char *data,
        void **inject_instance, void **thread_handle)
{
    // 1. 启用调试特权
    frida_enable_debug_privilege();

    // 2. 打开目标进程
    DWORD access = PROCESS_VM_OPERATION
                 | PROCESS_VM_READ
                 | PROCESS_VM_WRITE
                 | PROCESS_CREATE_THREAD
                 | PROCESS_QUERY_INFORMATION;
    HANDLE process = OpenProcess(access, FALSE, pid);

    // 3. 准备远程工作上下文
    FridaRemoteWorkerContext rwc;
    frida_remote_worker_context_init(&rwc, &details);

    // 4. 创建远程线程执行注入代码
    HANDLE thread = CreateRemoteThread(process, NULL, 0,
        (LPTHREAD_START_ROUTINE)rwc.entrypoint,
        rwc.argument, 0, NULL);

    // 5. 如果 CreateRemoteThread 失败，尝试 RtlCreateUserThread
    if (thread == NULL) {
        RtlCreateUserThread(process, NULL, FALSE, 0, NULL, NULL,
            rwc.entrypoint, rwc.argument, &thread, &client_id);
    }
}
```

整个注入过程可以用一张图来理解：

```
┌──────────────────┐                    ┌──────────────────┐
│   Frida Helper   │                    │  Target Process   │
│                  │                    │                  │
│  1. OpenProcess  │───────────────────>│                  │
│                  │   获取进程句柄      │                  │
│                  │                    │                  │
│  2. VirtualAlloc │───────────────────>│  ┌────────────┐  │
│     ExRemote     │   分配远程内存      │  │ 注入的代码  │  │
│                  │                    │  │ 和数据      │  │
│  3. WriteProcess │───────────────────>│  │            │  │
│     Memory       │   写入payload      │  └────────────┘  │
│                  │                    │                  │
│  4. CreateRemote │───────────────────>│  新线程开始执行:  │
│     Thread       │   创建远程线程      │  LoadLibrary()   │
│                  │                    │  GetProcAddress()│
│  5. WaitFor      │<──────────────────│  EntryPoint()    │
│     SingleObject │   等待线程完成      │  FreeLibrary()   │
│                  │                    │                  │
└──────────────────┘                    └──────────────────┘
```

### 18.2.2 RemoteWorkerContext——远程执行上下文

Frida 不是简单地调用 LoadLibrary。它在目标进程中构建一段完整的"工作代码"：

```c
// 简化自 frida-helper-backend-glue.c
struct FridaRemoteWorkerContext {
    gboolean stay_resident;  // 是否常驻

    // 需要的 Kernel32 函数指针
    gpointer load_library_impl;      // LoadLibraryW
    gpointer get_proc_address_impl;  // GetProcAddress
    gpointer free_library_impl;      // FreeLibrary
    gpointer virtual_free_impl;      // VirtualFree
    gpointer get_last_error_impl;    // GetLastError

    // 注入参数
    WCHAR dll_path[MAX_PATH + 1];    // DLL 路径
    gchar entrypoint_name[256];      // 入口函数名
    gchar entrypoint_data[MAX_PATH]; // 传递给入口的数据

    gpointer entrypoint;             // 远程代码入口
    gpointer argument;               // 远程数据地址
};
```

远程线程执行的伪代码如下：

```c
// 这段代码在目标进程中执行
DWORD WINAPI remote_worker(FridaRemoteWorkerContext *ctx) {
    // 1. 加载 DLL
    HMODULE module = ctx->load_library_impl(ctx->dll_path);
    if (module == NULL)
        return ctx->get_last_error_impl();

    // 2. 获取入口函数
    FARPROC entry = ctx->get_proc_address_impl(
        module, ctx->entrypoint_name);

    // 3. 调用入口函数
    entry(ctx->entrypoint_data);

    // 4. 如果不需要常驻，卸载 DLL
    if (!ctx->stay_resident)
        ctx->free_library_impl(module);

    // 5. 释放自身占用的内存
    ctx->virtual_free_impl(ctx, 0, MEM_RELEASE);

    return 0;
}
```

### 18.2.3 RtlCreateUserThread——备用方案

有些进程（特别是受保护的进程）会拒绝 CreateRemoteThread。Frida 有一个备用方案——使用 ntdll.dll 中未文档化的 `RtlCreateUserThread`：

```c
// 当 CreateRemoteThread 失败时的回退
if (thread_handle == NULL) {
    RtlCreateUserThreadFunc rtl_create =
        GetProcAddress(GetModuleHandle("ntdll.dll"),
                       "RtlCreateUserThread");
    rtl_create(process, NULL, FALSE, 0, NULL, NULL,
        entrypoint, argument, &thread_handle, &client_id);
}
```

这就像正门进不去，就走侧门。RtlCreateUserThread 是更底层的 API，有时候能绕过一些限制。

## 18.3 DbgHelp 与符号解析

Windows 后端的一大特色是内置了完整的调试符号支持。注意看 WindowsHostSession 的构造函数：

```vala
// 简化自 windows-host-session.vala
construct {
    agent = new AgentDescriptor(
        PathTemplate("<arch>\\frida-agent.dll"),
        // 三种架构的 agent
        get_frida_agent_arm64_dll_blob().data,
        get_frida_agent_x86_64_dll_blob().data,
        get_frida_agent_x86_dll_blob().data,
        // 依赖项：dbghelp.dll 和 symsrv.dll
        new AgentResource[] {
            new AgentResource("arm64\\dbghelp.dll", ...),
            new AgentResource("arm64\\symsrv.dll", ...),
            new AgentResource("x86_64\\dbghelp.dll", ...),
            new AgentResource("x86_64\\symsrv.dll", ...),
            new AgentResource("x86\\dbghelp.dll", ...),
            new AgentResource("x86\\symsrv.dll", ...),
        }
    );
}
```

Frida 为每种架构都捆绑了 `dbghelp.dll` 和 `symsrv.dll`：

```
┌─────────────────────────────────────────────────────┐
│              Windows 符号解析体系                     │
├─────────────────────────────────────────────────────┤
│                                                     │
│  dbghelp.dll                                        │
│  ├── SymInitialize()     初始化符号处理              │
│  ├── SymFromName()       按名称查找符号              │
│  ├── SymFromAddr()       按地址查找符号              │
│  ├── SymEnumSymbols()    枚举所有符号                │
│  └── StackWalk64()       栈回溯                     │
│                                                     │
│  symsrv.dll                                         │
│  └── 从 Microsoft 符号服务器下载 PDB 文件            │
│      (https://msdl.microsoft.com/download/symbols)  │
│                                                     │
└─────────────────────────────────────────────────────┘
```

为什么 Frida 要自己携带这两个 DLL 而不用系统的？因为：

1. 系统可能没有安装调试工具
2. 不同版本的 dbghelp.dll 行为可能不同
3. Frida 需要确保在目标进程中也能使用符号解析

这就像一个修理工自带全套工具上门——不依赖客户家里有没有工具箱。

## 18.4 多架构支持

Windows 后端需要同时支持三种架构：

```vala
// 简化自 frida-helper-backend.vala
public unowned string arch_name_from_pid(uint pid) {
    switch (cpu_type_from_pid(pid)) {
        case CpuType.IA32:   return "x86";
        case CpuType.AMD64:  return "x86_64";
        case CpuType.ARM64:  return "arm64";
    }
}
```

架构判断流程：

```
┌──────────────────────────────────────────┐
│  判断目标进程架构                         │
├──────────────────────────────────────────┤
│                                          │
│  Frida Helper (64-bit)                   │
│       │                                  │
│       ├──> 目标是 x86 进程？              │
│       │    使用 x86\frida-agent.dll      │
│       │                                  │
│       ├──> 目标是 x86_64 进程？           │
│       │    使用 x86_64\frida-agent.dll   │
│       │                                  │
│       └──> 目标是 ARM64 进程？            │
│            使用 arm64\frida-agent.dll    │
│                                          │
└──────────────────────────────────────────┘
```

在 Windows 上，一个 64 位系统可以同时运行 32 位和 64 位进程（WoW64）。Frida 必须为每种目标架构准备对应的 agent DLL。

## 18.5 ACL 与权限控制

Windows 的安全模型基于 ACL（Access Control List）。Frida 在使用临时文件时需要正确设置 ACL：

```c
// 简化自 winjector-glue.c
void frida_winjector_set_acls_as_needed(const char *path) {
    // 获取合适的安全描述符字符串
    LPCWSTR sddl = frida_access_get_sddl_string_for_temp_directory();

    if (sddl != NULL) {
        // 将 SDDL 字符串转换为安全描述符
        SECURITY_DESCRIPTOR *sd;
        ConvertStringSecurityDescriptorToSecurityDescriptor(
            sddl, SDDL_REVISION_1, &sd, NULL);

        // 从安全描述符中获取 DACL
        PACL dacl;
        GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted);

        // 应用到目标路径
        SetNamedSecurityInfo(path, SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION, NULL, NULL, dacl, NULL);
    }
}
```

为什么需要这样做？因为 Frida 的临时目录中存放着 agent DLL，目标进程需要有权限读取这些文件。如果 ACL 设置不当，LoadLibrary 会因为权限不足而失败。

### 18.5.1 SeDebugPrivilege——调试特权

在 Windows 上，要操作其他进程通常需要启用 `SeDebugPrivilege`：

```c
// 简化的特权启用逻辑
static gboolean frida_enable_debug_privilege(void) {
    HANDLE token;
    OpenProcessToken(GetCurrentProcess(),
        TOKEN_ADJUST_PRIVILEGES, &token);

    TOKEN_PRIVILEGES tp;
    LookupPrivilegeValue(NULL, SE_DEBUG_NAME, &tp.Privileges[0].Luid);
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;

    AdjustTokenPrivileges(token, FALSE, &tp, ...);
    CloseHandle(token);
}
```

SeDebugPrivilege 就像一张"万能通行证"——有了它，你就能打开几乎任何进程的句柄。通常只有管理员账户才能获得这个特权。

## 18.6 Winjector——Windows 注入器

`Winjector`（"Win + Injector"）是 Windows 的注入器封装：

```vala
// 简化自 winjector.vala
public sealed class Winjector : Object, Injector {
    public async uint inject_library_file(uint pid, string path,
            string entrypoint, string data) {
        var no_deps = new string[] {};
        return yield inject_library_file_with_template(
            pid, PathTemplate(path), entrypoint, data, no_deps);
    }

    public async uint inject_library_resource(uint pid,
            AgentDescriptor agent, ...) {
        ensure_tempdir_prepared();

        // 收集依赖（dbghelp.dll, symsrv.dll）
        var dependencies = new ArrayList<string>();
        foreach (var dep in agent.dependencies)
            dependencies.add(dep.get_file().path);

        return yield inject_library_file_with_template(
            pid, agent.get_path_template(), entrypoint, data,
            dependencies.to_array());
    }

    private void ensure_tempdir_prepared() {
        if (did_prep_tempdir) return;
        if (tempdir.is_ours)
            set_acls_as_needed(tempdir.path);  // 设置ACL
        did_prep_tempdir = true;
    }
}
```

### 18.6.1 WaitHandleSource——监控注入线程

注入完成后，Frida 需要知道远程线程何时结束。Windows 提供了等待对象（Wait Handle）机制：

```vala
// 简化自 frida-helper-backend.vala
private void monitor_remote_thread(uint id, void *instance,
        void *waitable_thread_handle) {
    // 创建 GLib 事件源来监控 Windows 句柄
    var source = WaitHandleSource.create(
        waitable_thread_handle, true);
    source.set_callback(() => {
        bool is_resident;
        _free_inject_instance(instance, out is_resident);
        uninjected(id);
        return false;
    });
    source.attach(main_context);
}
```

`WaitHandleSource` 是 Frida 自己实现的一个 GLib 事件源，它把 Windows 的 WaitForSingleObject 集成到了 GLib 的事件循环中，让异步编程模型统一。

## 18.7 安全机制应对

### 18.7.1 DEP（Data Execution Prevention）

DEP 防止数据区域的代码执行。Frida 的注入代码必须分配为可执行内存：

```
┌────────────────────────────────────────────┐
│  内存分配策略                               │
├────────────────────────────────────────────┤
│  代码区域: VirtualAllocEx(..., PAGE_EXECUTE_READWRITE)  │
│  数据区域: VirtualAllocEx(..., PAGE_READWRITE)          │
│                                            │
│  或者分两步：                               │
│  1. 分配为 PAGE_READWRITE（写入代码）       │
│  2. VirtualProtectEx 改为 PAGE_EXECUTE_READ │
└────────────────────────────────────────────┘
```

### 18.7.2 ASLR（Address Space Layout Randomization）

ASLR 让每次加载的地址都不同。Frida 不依赖硬编码地址，而是动态解析函数地址：

```c
// Frida 在 RemoteWorkerContext 初始化时动态查找函数
static gboolean frida_remote_worker_context_collect_kernel32_export(
        const GumExportDetails *details, gpointer user_data) {
    FridaRemoteWorkerContext *rwc = user_data;

    if (strcmp(details->name, "LoadLibraryW") == 0)
        rwc->load_library_impl = GSIZE_TO_POINTER(details->address);
    else if (strcmp(details->name, "GetProcAddress") == 0)
        rwc->get_proc_address_impl = GSIZE_TO_POINTER(details->address);
    else if (strcmp(details->name, "FreeLibrary") == 0)
        rwc->free_library_impl = GSIZE_TO_POINTER(details->address);
    // ... 等等

    return !has_resolved_all();  // 全部找到后停止
}
```

## 18.8 Helper 进程的权限提升

Windows 后端的 Helper 支持不同的权限级别：

```vala
// 简化自 frida-helper-backend.vala
public sealed class WindowsHelperBackend : Object, WindowsHelper {
    public PrivilegeLevel level { get; construct; }

    public async void inject_library_file(uint pid, ...) {
        string target_path;
        if (level == ELEVATED) {
            // 提升权限模式：复制 DLL 到安全目录
            if (asset_dir == null)
                asset_dir = new AssetDirectory();
            var bundle = new AssetBundle.with_copy_of(
                path, dependencies, asset_dir);
            target_path = bundle.files.first().get_path();
        } else {
            target_path = path;
        }

        _inject_library_file(pid, target_path, entrypoint, data, ...);
    }
}
```

在提升权限模式下，Frida 会将 DLL 复制到一个安全的目录，确保目标进程有权限访问。

## 18.9 本章小结

- Windows 注入的核心是 **CreateRemoteThread + LoadLibrary** 这个经典组合
- 当 CreateRemoteThread 失败时，Frida 会回退到 **RtlCreateUserThread**
- **RemoteWorkerContext** 结构体包含了远程执行所需的所有函数指针和数据
- Frida 自带 **dbghelp.dll** 和 **symsrv.dll** 以提供完整的符号解析能力
- **ACL** 设置确保目标进程能访问注入的 DLL 文件
- **SeDebugPrivilege** 是操作其他进程的前提条件
- **WaitHandleSource** 将 Windows 句柄等待机制集成到 GLib 事件循环
- 需要应对 **DEP** 和 **ASLR** 等安全机制，通过正确的内存分配和动态地址解析来解决

## 讨论问题

1. CreateRemoteThread 和 RtlCreateUserThread 在什么情况下会失败？除了这两种方式，Windows 上还有哪些代码注入技术？

2. Frida 为什么要自带 dbghelp.dll 而不是使用系统自带的版本？这样做有什么潜在的兼容性问题？

3. Windows 的 Protected Process Light (PPL) 机制对 Frida 的注入有什么影响？Frida 是否有办法绕过？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
