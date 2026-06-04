+++
title = "Windows 桌面图标移动的 COM 实现"
description = "基于 rust + windows-rs 移动 Windows 桌面图标"
date = 2026-06-04T18:30:00+08:00
slug = "windows-desktop-icon-move-com"
template = "page.html"

[taxonomies]
tags = ["Windows"]
+++

在 Windows 桌面上移动图标，看起来只是个“改坐标”的操作，但背后实际上是 Shell View + COM 交互。

笔者基于 Rust + windows-rs，实现直接操作桌面 `IFolderView` 的图标管理层，用于枚举、读取信息以及移动桌面图标位置。

该实现在不依赖 UI 自动化或 `ListView` 无文档接口的前提下，直接驱动 Explorer 的图标布局。

项目地址：[win-desktop-icon](https://github.com/mokurin000/win-desktop-icon)

## 桌面图标的来源不是“窗口”，而是 Shell View

很多人一开始会误以为桌面图标属于某个窗口句柄（HWND），但实际上桌面图标属于 Explorer 的 Shell View 层。

关键对象是：

- `IShellWindows`
- `IShellBrowser`
- `IShellView`
- `IFolderView`
- `IShellFolder`

其中 `IFolderView` 才是“图标布局控制器”。

获取流程大致为：

```rust
let shell_windows: IShellWindows =
    CoCreateInstance(&ShellWindows, None, CLSCTX_ALL)?;

let dispatch = shell_windows.FindWindowSW(... SWC_DESKTOP ...)?;

let service_provider: IServiceProvider = dispatch.cast()?;
let browser: IShellBrowser = service_provider.QueryService(&SID_STopLevelBrowser)?;
let shell_view: IShellView = browser.QueryActiveShellView()?;

let folder_view: IFolderView = shell_view.cast()?;
let shell_folder = folder_view.GetFolder()?;
````

这里有两个关键点：

* `IFolderView` 负责“布局操作”
* `IShellFolder` 负责“名字 / PIDL / 元数据”

也就是说，一个负责位置，一个负责语义。

## ITEMIDLIST 才是图标的真实身份

桌面图标并不是用 HWND 或 ID 标识的，而是 `ITEMIDLIST`（PIDL）。

* 文件
* 快捷方式
* 系统对象
* 虚拟目录项

都统一抽象为 PIDL。

枚举图标时，本质是：

```rust
let enumerator = folder_view.Items(SVGIO_ALLVIEW)?;
while let Some(idlist) = next_item(&enumerator)? {
    ...
}
```

这里得到的 `ITEMIDLIST` 是 COM 分配的内存，在 Rust 侧需要谨慎地管理生命周期。

## 移动图标：SelectAndPositionItems

真正的核心 API 是：

```rust
SelectAndPositionItems
```

调用方式类似：

```rust
self.folder_view.SelectAndPositionItems(
    1,
    &(icon.inner.as_ptr() as *const ITEMIDLIST),
    Some(&POINT { x, y }),
    SVSI_POSITIONITEM.0 as _,
)?;
```

此处语义如下：

* 第一个参数：移动的 item 数量
* 第二个参数：PIDL 数组指针
* 第三个参数：目标坐标
* 第四个参数：行为标志（position）

本质就是告诉 Explorer：

“把这个 PIDL 对应的图标移动到这个坐标”。

## Rust 侧内存管理的关键问题

这一块比 COM API 本身更容易出错。

`ITEMIDLIST` 的来源有两种：

### 1. COM 分配

来自 `IEnumIDList` / Shell API：

* 必须 `CoTaskMemFree`
* Rust 不能直接 drop

### 2. Rust 内存映射

来自外部 buffer：

* 不允许释放
* 需要“借用标记”

因此实现中引入了一个关键结构：

```rust
pub struct DesktopIcon<'desktop> {
    inner: NonNull<ITEMIDLIST>,
    mut_ref: Option<&'desktop mut [u8]>,
}
```

核心思想很简单：

* `mut_ref = None` → COM 管理，需要释放
* `mut_ref = Some(...)` → Rust 管理，不可释放

Drop 实现也因此变得安全：

```rust
impl Drop for DesktopIcon<'_> {
    fn drop(&mut self) {
        if self.mut_ref.is_none() {
            unsafe {
                CoTaskMemFree(Some(self.inner.as_ptr() as _));
            }
        }
    }
}
```

这个设计避免了两类经典问题：

* COM 内存泄露
* Rust double free

## 获取图标信息：名字与坐标

图标信息分为两部分：

### 坐标

```rust
folder_view.GetItemPosition(pidl)
```

直接由 Shell View 返回当前 UI 布局坐标。

### 名字

通过 `IShellFolder`：

```rust
GetDisplayNameOf -> STRRET -> StrRetToStrW
```

最终再转换为 Rust String，并手动释放：

```rust
CoTaskMemFree(Some(name_ptr.0 as _));
```

这一部分本质是 Shell 统一的字符串返回机制。

## 小结

* `IFolderView` 控制布局
* `ITEMIDLIST` 作为唯一标识
* COM 语义驱动 UI 状态变化

顺便一提，笔者发现 `SelectAndPositionItems` 似乎无法批量移动多个图标，不过目前实现性能足矣。
