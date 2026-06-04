+++
title = "用 Tauri 注入 UserScript"
date = 2026-06-04T17:30+08:00
slug = "tauri-userscript-injection"

[taxonomies]
tags = ["tauri", "rust", "userscript"]
+++

[append_invoke_initialization_script]: https://docs.rs/tauri/latest/tauri/struct.Builder.html?utm_source=chatgpt.com#method.append_invoke_initialization_script

> 注意：该方式注入的脚本具备接近页面最高权限的执行能力。 
> 如若涉及远程加载，必须实现签名、证书检查等完整性保护机制，否则可导致页面被完全接管。

在使用 Tauri 构建桌面 WebView 应用时，笔者偶然发现
[`Builder::append_invoke_initialization_script`][append_invoke_initialization_script] 这个 API。

它允许在 WebView 初始化阶段注入 JavaScript，在页面业务代码执行之前运行。这使得将 UserScript 直接内置进应用成为可能。

## 注入机制

Tauri 提供的注入方式如下：

```rust
tauri::Builder::default()
    // Example script
    // or: include_str!("script.js")
    .append_invoke_initialization_script(r#"
        // modify window properties directly
        window.__APP__ = true;
        // Overriding `fetch()`
        window.fetch = () => {};
        // inject custom stylesheets on the document, e.g.
        window.addEventListener(
            "DOMContentLoaded",
            () => {}
        );
    "#)
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
```

这个阶段发生在 WebView 初始化早期，比
[DOMContentLoaded](https://developer.mozilla.org/zh-CN/docs/Web/API/Document/DOMContentLoaded_event)
更靠前，因此可以影响页面最初的运行环境。

## UserScript 兼容性的处理方式

UserScript 通常运行在 TamperMonkey / GreaseMonkey 环境中，依赖 `GM_*` API 或 `unsafeWindow` 等扩展能力。而在普通 WebView 环境中，这些对象不存在。

```javascript
const unsafeWindow = 'undefined' === typeof GM_info ? window : unsafeWindow;
```

在必要时，我们可以手动提供兼容的对象，供 UserScript 使用。

## 使用价值

这种方式本质上是在把 UserScript 作为应用内置能力使用。

相比传统 UserScript 流程，它减少了外部依赖：

* 不需要用户安装油猴类扩展
* 不需要依赖 GreasyFork / OpenUserJS / jsDelivr 等脚本托管站
* 在网络受限环境下更稳定

在分发层面，它更接近：

> “带脚本能力的桌面 Web 应用”

## 安全边界

该模式的关键风险在于：注入脚本等同于页面最高权限执行环境。

需要注意：

* 只加载可信脚本或本地内置脚本
* 远程脚本必须具备签名或完整性校验机制
* 避免将其作为普通前端逻辑入口
* 必要时进行能力拆分或隔离执行环境

## 总结

[append_invoke_initialization_script] 提供了一个非常直接的能力：在 WebView 初始化阶段注入 JavaScript。

借助这一机制，可以将 UserScript 作为应用内部逻辑层进行封装，实现：

* 桌面应用内置脚本能力
* 与 UserScript 生态兼容的脚本复用
* 减少对外部脚本托管与浏览器扩展的依赖

这是一种将“浏览器扩展式能力”迁移到桌面应用分发体系中的实现路径。

示例项目：[fknc-calculator](https://github.com/mokurin000/fknc-calculator/)
