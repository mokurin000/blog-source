+++
title = "Win32 Volume、分区号与硬盘型号"
date = 2026-06-04T11:30:00+08:00
description = "Windows 硬盘操作，不用 WMI 可以多麻烦。"

[taxonomies]
tags = ["windows", "python"]
+++

Windows 下经常需要完成以下映射关系：

```text
盘符
  ↓
Volume GUID
  ↓
Disk Number + Partition Number
  ↓
PhysicalDrive
  ↓
硬盘型号 / SSD-HDD 类型
````

本文使用纯 Win32 API + Python `ctypes` 实现整个查询链路。

需要注意的是，`IOCTL_STORAGE_GET_DEVICE_NUMBER` 等接口通常需要较高权限访问设备对象。

如果希望采用无需管理员权限的实现方式，可以参考：

* PowerShell方式：[win32-drive-letters-deviceid-harddisk-model](https://mokurin000-legacy.github.io/archives/win32-drive-letters-deviceid-harddisk-model/)
* [listdisk-rs](https://github.com/mokurin000/listdisk-rs)
* MSDN 中的 WMI 类（Win32_DiskDrive、Win32_DiskPartition、Win32_LogicalDisk 等）

---

# Win32 Prototype

首先定义需要使用的结构体、常量以及 Win32 API 签名。

```python
from ctypes import (
    addressof,
    byref,
    c_wchar,
    cast,
    create_string_buffer,
    create_unicode_buffer,
    get_last_error,
    POINTER,
    sizeof,
    string_at,
    Structure,
    WinDLL,
    WinError,
    wstring_at,
)
from ctypes.wintypes import (
    HANDLE,
    BOOL,
    BOOLEAN,
    DWORD,
    BYTE,
    LPWSTR,
)

# Load kernel32.dll (Win32 API entry point)
kernel32 = WinDLL("kernel32", use_last_error=True)

INVALID_HANDLE_VALUE = HANDLE(-1).value

# Access flags
GENERIC_READ = 0x80000000

# Share modes
FILE_SHARE_READ = 1
FILE_SHARE_WRITE = 2

# Creation disposition
OPEN_EXISTING = 3

# Maximum path length for legacy Win32 APIs
MAX_PATH = 260

# IOCTL control codes
IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x2D1080
IOCTL_STORAGE_QUERY_PROPERTY = 0x2D1400

# Storage property IDs
StorageDeviceProperty = 0
StorageDeviceSeekPenaltyProperty = 7

PropertyStandardQuery = 0
```

## Structures

```python
class STORAGE_DEVICE_NUMBER(Structure):
    _fields_ = [
        ("DeviceType", DWORD),        # Device type (e.g. disk)
        ("DeviceNumber", DWORD),      # PhysicalDrive number
        ("PartitionNumber", DWORD),   # Partition index
    ]


class STORAGE_PROPERTY_QUERY(Structure):
    _fields_ = [
        ("PropertyId", DWORD),        # Property being queried
        ("QueryType", DWORD),         # Query type (standard query)
        ("AdditionalParameters", BYTE * 1),
    ]


class STORAGE_DESCRIPTOR_HEADER(Structure):
    _fields_ = [
        ("Version", DWORD),           # Descriptor version
        ("Size", DWORD),              # Total size of returned buffer
    ]


class STORAGE_DEVICE_DESCRIPTOR(Structure):
    _fields_ = [
        ("Version", DWORD),
        ("Size", DWORD),

        ("DeviceType", BYTE),
        ("DeviceTypeModifier", BYTE),

        ("RemovableMedia", BOOLEAN),
        ("CommandQueueing", BOOLEAN),

        ("VendorIdOffset", DWORD),
        ("ProductIdOffset", DWORD),
        ("ProductRevisionOffset", DWORD),
        ("SerialNumberOffset", DWORD),

        ("BusType", DWORD),

        ("RawPropertiesLength", DWORD),

        # Variable-length buffer follows this field
        ("RawDeviceProperties", BYTE * 1),
    ]


class DEVICE_SEEK_PENALTY_DESCRIPTOR(Structure):
    _fields_ = [
        ("Version", DWORD),
        ("Size", DWORD),
        ("IncursSeekPenalty", BOOLEAN),  # True = HDD, False = SSD
    ]
```

## Function Prototypes

```python
# Enumerate volumes
FindFirstVolumeW = kernel32.FindFirstVolumeW
FindFirstVolumeW.argtypes = [LPWSTR, DWORD]
FindFirstVolumeW.restype = HANDLE

FindNextVolumeW = kernel32.FindNextVolumeW
FindNextVolumeW.argtypes = [HANDLE, LPWSTR, DWORD]
FindNextVolumeW.restype = BOOL

FindVolumeClose = kernel32.FindVolumeClose
FindVolumeClose.argtypes = [HANDLE]
FindVolumeClose.restype = BOOL

# Volume mount point resolver
GetVolumePathNamesForVolumeNameW = (
    kernel32.GetVolumePathNamesForVolumeNameW
)

# Device access
CreateFileW = kernel32.CreateFileW
CreateFileW.restype = HANDLE

DeviceIoControl = kernel32.DeviceIoControl
CloseHandle = kernel32.CloseHandle
```

## 打开设备对象

```python
def open_device(path):
    """
    Open a Win32 device handle (volume or physical drive).
    """
    h = CreateFileW(
        path,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        None,
        OPEN_EXISTING,
        0,
        None,
    )

    if h == INVALID_HANDLE_VALUE:
        raise WinError(get_last_error())

    return h
```

---

# 枚举 Volume

```python
def enum_volumes():
    """
    Enumerate all volume GUIDs in the system.
    """
    buf = create_unicode_buffer(MAX_PATH)

    h = FindFirstVolumeW(buf, MAX_PATH)

    if h == INVALID_HANDLE_VALUE:
        raise WinError(get_last_error())

    try:
        yield buf.value

        while FindNextVolumeW(h, buf, MAX_PATH):
            yield buf.value

    finally:
        FindVolumeClose(h)
```

---

# Volume 获取挂载点

```python
def get_mount_points(volume_guid):
    """
    Get all mount points (drive letters / folders) for a volume.
    """
    needed = DWORD()

    # First call to get required buffer size
    GetVolumePathNamesForVolumeNameW(
        volume_guid,
        None,
        0,
        byref(needed),
    )

    if needed.value == 0:
        return []

    buf = create_unicode_buffer(needed.value)

    # Second call to actually retrieve mount points
    if not GetVolumePathNamesForVolumeNameW(
        volume_guid,
        buf,
        needed.value,
        byref(needed),
    ):
        raise WinError(get_last_error())

    result = []
    offset = 0

    # Multi-string parsing (double-null terminated string list)
    while True:
        s = wstring_at(addressof(buf) + offset * sizeof(c_wchar))
        if not s:
            break

        result.append(s)
        offset += len(s) + 1

    return result
```

---

# Volume 获取磁盘号与分区号

```python
def volume_to_disk_info(volume_guid):
    """
    Map a volume GUID to physical disk number and partition number.
    """
    h = open_device(volume_guid.rstrip("\\"))

    try:
        result = STORAGE_DEVICE_NUMBER()
        returned = DWORD()

        ok = DeviceIoControl(
            h,
            IOCTL_STORAGE_GET_DEVICE_NUMBER,
            None,
            0,
            byref(result),
            sizeof(result),
            byref(returned),
            None,
        )

        if not ok:
            raise WinError(get_last_error())

        return result

    finally:
        CloseHandle(h)
```

---

# 获取硬盘型号

```python
def get_disk_model(disk_number):
    """
    Query physical disk model string via StorageDeviceProperty.
    """
    h = open_device(rf"\\.\PhysicalDrive{disk_number}")

    try:
        query = STORAGE_PROPERTY_QUERY()
        query.PropertyId = StorageDeviceProperty
        query.QueryType = PropertyStandardQuery

        header = STORAGE_DESCRIPTOR_HEADER()
        returned = DWORD()

        # First call: get required buffer size
        DeviceIoControl(
            h,
            IOCTL_STORAGE_QUERY_PROPERTY,
            byref(query),
            sizeof(query),
            byref(header),
            sizeof(header),
            byref(returned),
            None,
        )

        buf = create_string_buffer(header.Size)

        # Second call: retrieve full descriptor
        ok = DeviceIoControl(
            h,
            IOCTL_STORAGE_QUERY_PROPERTY,
            byref(query),
            sizeof(query),
            buf,
            len(buf),
            byref(returned),
            None,
        )

        if not ok:
            raise WinError(get_last_error())

        desc = cast(
            buf,
            POINTER(STORAGE_DEVICE_DESCRIPTOR),
        ).contents

        if desc.ProductIdOffset == 0:
            return "<unknown>"

        return (
            string_at(addressof(buf) + desc.ProductIdOffset)
            .decode("ascii", errors="ignore")
            .strip()
        )

    finally:
        CloseHandle(h)
```

---

# 判断 SSD 或 HDD

```python
def get_disk_kind(disk_number):
    """
    Determine disk type using seek penalty property.
    """
    h = open_device(rf"\\.\PhysicalDrive{disk_number}")

    try:
        query = STORAGE_PROPERTY_QUERY()
        query.PropertyId = StorageDeviceSeekPenaltyProperty
        query.QueryType = PropertyStandardQuery

        result = DEVICE_SEEK_PENALTY_DESCRIPTOR()
        returned = DWORD()

        ok = DeviceIoControl(
            h,
            IOCTL_STORAGE_QUERY_PROPERTY,
            byref(query),
            sizeof(query),
            byref(result),
            sizeof(result),
            byref(returned),
            None,
        )

        if not ok:
            return "Unknown"

        return "HDD" if result.IncursSeekPenalty else "SSD"

    finally:
        CloseHandle(h)
```

---

# 综合输出

```python
def main():
    """
    Full mapping pipeline:
    Volume → Disk → Partition → Model → Type
    """
    cache = {}

    for volume in enum_volumes():
        try:
            disk_info = volume_to_disk_info(volume)

            device_num = disk_info.DeviceNumber
            partition_num = disk_info.PartitionNumber

            # Cache disk-level info to avoid repeated IOCTL calls
            if device_num not in cache:
                cache[device_num] = {
                    "model": get_disk_model(device_num),
                    "kind": get_disk_kind(device_num),
                }

            info = cache[device_num]

            print()
            print("Volume    :", volume)

            for mount in get_mount_points(volume):
                print("Mount     :", mount)

            print("Disk      :", device_num)
            print("Partition :", partition_num)
            print("Model     :", info["model"])
            print("Type      :", info["kind"])

        except Exception as e:
            print()
            print(volume)
            print("ERROR:", e)
```

运行示例：

```text
Volume    : \\?\Volume{...}\
Mount     : C:\

Disk      : 0
Partition : 3
Model     : Samsung SSD 990 EVO
Type      : SSD
```

可通过 [gist](https://gist.github.com/mokurin000/6516ee116cb24c63883e682c75c06c48) 获取完整示例代码。
