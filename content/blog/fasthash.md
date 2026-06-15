---
title: "性能接近理论上限的的大文件 hashing"
date: 2026-06-16T07:00:00+09:00
draft: false
description: "从 compio 到无锁 SPSC queue，逐步逼近 openssl speed 的大文件 hashing 实现"

taxonomies:
    tags:
    - rust
    - hashing
    - optimization
---

## 前言

笔者下载到 SDEZ 1.65 后，发现 7-zip SHA256 计算性能并不理想，于是本着写玩具的念头搓了一个可能是目前最快的 hash 工具。

第一版基于 compio ，但是单纯使用 compio + 同线程 hashing 对于单个大文件顺序读的效果并不理想。

第二版改为完全单线程，read 与 hash 负载集中，达到了 50% 理论吞吐极限。

此时 strace 抓了一下 Linux `sha256sum` syscall ，还引入了 `POSIX_FADV_SEQUENTIAL`，对应 Windows `FILE_FLAG_SEQUENTIAL_SCAN` 。

第三版改为 IO Thread 分离，`crossfire` 无锁 SPSC channel 与无锁 queue buffer pool，终于达到了 `openssl speed` 16k block microbench 性能的 97%。

## 实现

```rust
use std::fs::File;
use std::io::{BorrowedBuf, Read as _};
use std::sync::Arc;

use crossfire::flavor::Queue;
use digest::Digest;

fn hash_file<D: Digest>(
    mut file: File,
    buffer_size: usize,
    queue_len: usize,
) -> std::io::Result<Box<[u8]>> {
    let mut ctx = D::new();

    let queue = Arc::new(crossfire::spsc::Array::new(queue_len));
    let (readed_tx, readed_rx) = crossfire::spsc::bounded_blocking(queue_len);

    for _ in 0..queue_len {
        _ = queue.push(Vec::with_capacity(buffer_size));
    }

    let queue_ = queue.clone();

    let io_result = std::thread::spawn(move || {
        loop {
            let Some(mut buffer) = queue_.pop() else {
                std::thread::yield_now();
                continue;
            };

            let mut cursor = BorrowedBuf::from(buffer.spare_capacity_mut());

            file.read_buf(cursor.unfilled())?;

            if cursor.len() == 0 {
                break std::io::Result::Ok(());
            } else {
                let new_len = cursor.len();
                unsafe { buffer.set_len(new_len) };
                _ = readed_tx.send(buffer);
            }
        }
    });

    while let Ok(mut buffer) = readed_rx.recv() {
        ctx.update(&buffer);

        buffer.clear();
        _ = queue.push(buffer);
    }

    io_result.join().expect("file io thread panicked")?;

    Ok(ctx.finalize().to_vec().into_boxed_slice())
}
```

## 实际测试数据

* OS: Windows 11 x86_64 22620
* CPU: Intel Core i7-12700H
* Storage: Predator GM7000
* File size: 69.8 GiB
* Hash algorithm: SHA-256

| Command                          | Time  | Notes               |
| -------------------------------- | ----- | ------------------- |
| `fasthash sha256 -b 1MiB file`   | 36s   | queue=8             |
| `fasthash sha256 -b 256K file`   | 52s   | queue=8             |
| `sha256sum file`                 | 67s   | uutils 0.9.0        |
| hashlib*                         | 68s   | Python 3.13.5       |
| `openssl sha256 file`            | 78s   | OpenSSL 3.6.0 MSVC  |
| --                               | 85s   | Nanazip 6.0.1742    |
| `Get-FileHash file`              | 96.9s | PowerShell 5.1      |
| `certutil -hashfile file sha256` | 107s  |                     |
| `sha256sum file`                 | 123s  | Microsoft coreutils |
| `open -r file \| hash sha256sum` | 130s  | NuShell 0.112.2     |

### openssl speed -evp sha256

```text
Doing sha256 ops for 3s on 16 size blocks: 15350007 sha256 ops in 2.91s
Doing sha256 ops for 3s on 64 size blocks: 13970470 sha256 ops in 2.97s
Doing sha256 ops for 3s on 256 size blocks: 10049997 sha256 ops in 2.88s
Doing sha256 ops for 3s on 1024 size blocks: 4545898 sha256 ops in 3.00s
Doing sha256 ops for 3s on 8192 size blocks: 743081 sha256 ops in 2.94s
Doing sha256 ops for 3s on 16384 size blocks: 386881 sha256 ops in 2.95s
version: 3.6.0
built on: Wed Oct  8 20:29:58 2025 UTC
options: bn(64,64)
compiler: cl  /Z7 /Fdossl_static.pdb /Gs0 /GF /Gy /MD /W3 /wd4090 /nologo /O2 -DL_ENDIAN -DOPENSSL_PIC -D"OPENSSL_BUILDING_OPENSSL" -D"OPENSSL_SYS_WIN32" -D"WIN32_LEAN_AND_MEAN" -D"UNICODE" -D"_UNICODE" -D"_CRT_SECURE_NO_DEPRECATE" -D"_WINSOCK_DEPRECATED_NO_WARNINGS" -D"NDEBUG" -D_WINSOCK_DEPRECATED_NO_WARNINGS -D_WIN32_WINNT=0x0502
CPUINFO: OPENSSL_ia32cap=0xfffaf38bffcbffff:0x184007a4239c27a9:0x00400810bc18c410:0x0000000000000000:0x0000000000000000
The 'numbers' are in 1000s of bytes per second processed.
type             16 bytes     64 bytes    256 bytes   1024 bytes   8192 bytes  16384 bytes
sha256           84507.57k   301173.92k   894886.69k  1551666.52k  2072279.00k  2146423.98k
```

## 为什么不换算法？

好问题。`gxhash`/`rapidhash`/`xxh3` 这些力大砖飞或 SIMD 优化的新型 non-crypto 算法对于大文件校验是很合适的。

虽然没有人提供。

## 后记

绞尽脑汁的 userspace I/O 优化，第一步应该先看看有没有合适的flag。

内核可以在更底层根据你将要进行的读取策略，进行第一步优化。

Repo：[fasthash](https://github.com/mokurin000/fasthash)
