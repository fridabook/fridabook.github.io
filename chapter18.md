# 第18章：Windows 后端——远程线程与调试符号

> 在 Windows 的世界里，注入 DLL 几乎是一项"民间传统艺术"。从游戏外挂到安全工具，无数程序都在使用 CreateRemoteThread + LoadLibrary 这个经典组合。Frida 的 Windows 后端也不例外，但它把这个"传统技艺"做到了工程化的极致。让我们揭开 Windows 后端的面纱。

## 18.1 Windows 后端的整体架构

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

Windows 提供了一个堪称"为注入而生"的 API：`CreateRemoteThread`。核心注入流程：

```c
// 简化自 frida-helper-backend-glue.c
void inject_library_file(uint32 pid, const char *path,
        const char *entrypoint, const char *data,
        void **inject_instance, void **thread_handle) {
    frida_enable_debug_privilege();  // 启用调试特权

    HANDLE process = OpenProcess(
        PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE
        | PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION,
        FALSE, pid);

    FridaRemoteWorkerContext rwc;
    frida_remote_worker_context_init(&rwc, &details);

    // 创建远程线程执行注入代码
    HANDLE thread = CreateRemoteThread(process, NULL, 0,
        rwc.entrypoint, rwc.argument, 0, NULL);

    // 如果失败，尝试更底层的 API
    if (thread == NULL) {
        RtlCreateUserThread(process, NULL, FALSE, 0, NULL, NULL,
            rwc.entrypoint, rwc.argument, &thread, &client_id);
    }
}
```

### 18.2.1 RemoteWorkerContext——远程执行上下文

Frida 在目标进程中构建完整的"工作代码"：

```c
struct FridaRemoteWorkerContext {
    gboolean stay_resident;
    gpointer load_library_impl;      // LoadLibraryW
    gpointer get_proc_address_impl;  // GetProcAddress
    gpointer free_library_impl;      // FreeLibrary
    gpointer virtual_free_impl;      // VirtualFree
    WCHAR dll_path[MAX_PATH + 1];
    gchar entrypoint_name[256];
    gchar entrypoint_data[MAX_PATH];
    gpointer entrypoint;             // 远程代码入口
    gpointer argument;               // 远程数据地址
};
```

远程线程在目标进程中执行的伪代码：

```c
// 这段代码在目标进程中执行（简化版）
DWORD WINAPI remote_worker(FridaRemoteWorkerContext *ctx) {
    HMODULE mod = ctx->load_library_impl(ctx->dll_path);
    FARPROC entry = ctx->get_proc_address_impl(mod, ctx->entrypoint_name);
    entry(ctx->entrypoint_data);          // 调用 agent 入口
    if (!ctx->stay_resident)
        ctx->free_library_impl(mod);      // 如果不常驻则卸载
    ctx->virtual_free_impl(ctx, 0, MEM_RELEASE);  // 释放自身
    return 0;
}
```

注意这里的函数指针（load_library_impl 等）是在 Frida 端通过枚举 kernel32.dll 的导出表解析出来的，不是硬编码的地址。

### 18.2.2 RtlCreateUserThread——备用方案

有些受保护的进程会拒绝 CreateRemoteThread。Frida 回退到 ntdll.dll 中未文档化的 `RtlCreateUserThread`——正门进不去就走侧门，这个更底层的 API 有时能绕过限制。

## 18.3 DbgHelp 与符号解析

Windows 后端的一大特色是内置完整的调试符号支持。Frida 为每种架构都捆绑了 `dbghelp.dll` 和 `symsrv.dll`：

```vala
// 简化自 windows-host-session.vala
agent = new AgentDescriptor(
    PathTemplate("<arch>\\frida-agent.dll"),
    new AgentResource[] {
        new AgentResource("arm64\\dbghelp.dll", ...),
        new AgentResource("arm64\\symsrv.dll", ...),
        new AgentResource("x86_64\\dbghelp.dll", ...),
        new AgentResource("x86_64\\symsrv.dll", ...),
        new AgentResource("x86\\dbghelp.dll", ...),
        new AgentResource("x86\\symsrv.dll", ...),
    }
);
```

dbghelp.dll 提供符号查找（SymFromName/SymFromAddr）、符号枚举和栈回溯（StackWalk64）。symsrv.dll 能从 Microsoft 符号服务器自动下载 PDB 文件。Frida 自带这两个 DLL 而不用系统的，是为了确保一致的行为——就像修理工自带全套工具上门，不依赖客户家里有没有工具箱。

## 18.4 多架构支持

Windows 上一个 64 位系统可以同时运行 32 位和 64 位进程（WoW64），加上 ARM64 Windows，Frida 必须为三种架构准备 agent：

```vala
public unowned string arch_name_from_pid(uint pid) {
    switch (cpu_type_from_pid(pid)) {
        case CpuType.IA32:   return "x86";
        case CpuType.AMD64:  return "x86_64";
        case CpuType.ARM64:  return "arm64";
    }
}
```

这意味着 Frida 的 Windows 发布包中实际包含六个二进制文件（三种架构的 agent DLL 各一个，加上对应的 dbghelp.dll）。Helper 进程在注入前通过 `Gum.Windows.cpu_type_from_pid()` 判断目标架构，选择正确的 DLL 版本。

## 18.5 ACL 与安全控制

Frida 在使用临时文件时需要正确设置 ACL（访问控制列表），否则目标进程可能没权限读取注入的 DLL：

```c
// 简化自 winjector-glue.c
void frida_winjector_set_acls_as_needed(const char *path) {
    LPCWSTR sddl = frida_access_get_sddl_string_for_temp_directory();
    if (sddl != NULL) {
        SECURITY_DESCRIPTOR *sd;
        ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, ...);
        PACL dacl;
        GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted);
        SetNamedSecurityInfo(path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
            NULL, NULL, dacl, NULL);
    }
}
```

**SeDebugPrivilege** 是另一个关键——这张"万能通行证"让 Frida 能打开几乎任何进程的句柄，通常只有管理员才能获得。

## 18.6 Winjector 与异步监控

`Winjector` 封装了注入逻辑，`WaitHandleSource` 将 Windows 句柄等待机制集成到 GLib 事件循环中：

```vala
// 简化自 frida-helper-backend.vala
private void monitor_remote_thread(uint id, void *instance,
        void *waitable_thread_handle) {
    var source = WaitHandleSource.create(waitable_thread_handle, true);
    source.set_callback(() => {
        _free_inject_instance(instance, out is_resident);
        uninjected(id);
        return false;
    });
    source.attach(main_context);
}
```

在提升权限模式下，Frida 将 DLL 复制到安全目录（AssetDirectory），确保目标进程有权限访问。

## 18.7 DEP 与 ASLR 应对

**DEP** 防止数据区域执行代码——Frida 的注入代码分配为 PAGE_EXECUTE_READWRITE 内存。**ASLR** 让每次加载地址不同——Frida 通过枚举 kernel32.dll 的导出表来动态解析函数地址，不依赖硬编码：

```c
static gboolean collect_kernel32_export(const GumExportDetails *details,
        gpointer user_data) {
    FridaRemoteWorkerContext *rwc = user_data;
    if (strcmp(details->name, "LoadLibraryW") == 0)
        rwc->load_library_impl = GSIZE_TO_POINTER(details->address);
    else if (strcmp(details->name, "GetProcAddress") == 0)
        rwc->get_proc_address_impl = GSIZE_TO_POINTER(details->address);
    // ...
    return !has_resolved_all();
}
```

## 18.8 本章小结

- Windows 注入的核心是 **CreateRemoteThread + LoadLibrary**，回退方案是 **RtlCreateUserThread**
- **RemoteWorkerContext** 包含远程执行所需的所有函数指针和数据
- Frida 自带 **dbghelp.dll** 和 **symsrv.dll** 提供完整符号解析
- **ACL** 设置确保目标进程能访问注入的 DLL
- **SeDebugPrivilege** 是操作其他进程的前提
- **WaitHandleSource** 将 Windows 句柄等待集成到 GLib 事件循环
- 通过正确的内存分配和动态地址解析应对 **DEP** 和 **ASLR**

## 讨论问题

1. CreateRemoteThread 和 RtlCreateUserThread 各在什么情况下会失败？Windows 上还有哪些代码注入技术？

2. Frida 为什么要自带 dbghelp.dll？这样做有什么潜在的兼容性问题？

3. Windows 的 Protected Process Light (PPL) 机制对 Frida 的注入有什么影响？

---

*本书由 [everettjf] 使用 Claude Code 分析源码编写 | 保留出处即可自由转载*
