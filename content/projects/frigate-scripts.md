+++
title = "Frigate + NVIDIA 显卡笔记本的部署"
description = "在 Arch Linux NVIDIA 笔记本上部署 Frigate、RTSP 摄像头与 ONNX 检测模型的记录。"
date = 2025-08-18
template = "page.html"
weight = 1

[taxonomies]
tags = ["webcam", "frigate"]

[extra]
+++

在 Arch Linux + NVIDIA 独显笔记本上部署 Frigate 的一些记录。

## 软件前置

```bash
sudo pacman -Syu docker docker-compose nvidia-container-toolkit
sudo systemctl enable --now docker
# 确保 docker0 已经被代理或已设置好连接代理
```

## 硬件要求

该方案相比于之前的丐版方案，需要更新的硬件才能解决种种兼容或性能问题。

笔者测试环境：

```text
OS: Arch Linux x86_64
Host: Dell G15 5520
Kernel: 6.15.2-arch1-1
CPU: Intel i7-12700H
GPU: Intel Iris Xe Graphics
GPU: NVIDIA GeForce RTX 3060 Mobile
Memory: 16 GB
```

## 使用的文件

### init.sh

```bash
mkdir -p config storage
mkdir -p config/model_cache/jinaai/jina-clip-v1

# btrfs 改善 sqlite 的性能
chattr -R +C config storage

cp --reflink=auto config.yaml config/
cp --reflink=auto yolo_nas_s.onnx config/

# optional, useless semantic search
# cp --reflink=auto *_fp16.onnx config/model_cache/jinaai/jina-clip-v1/

docker-compose up -d
```

### yolo_nas_s.onnx

由于禁止分发转换后的模型，建议使用 Colab 运行官方 Notebook 获取：

https://colab.research.google.com/github/blakeblackshear/frigate/blob/dev/notebooks/YOLO_NAS_Pretrained_Export.ipynb

### docker-compose.yml

> `-tensorrt` 镜像仅 NVIDIA GPU 加速需要，AMD / Intel GPU 不需要。

```yaml
services:
  frigate:
    container_name: frigate
    restart: unless-stopped
    stop_grace_period: 30s
    image: ghcr.io/blakeblackshear/frigate:stable-tensorrt

    volumes:
      - ./config:/config
      - ./storage:/media/frigate

      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000

    cap_add:
      - CAP_PERFMON

    ports:
      - "8971:8971"
      - "8554:8554"

    runtime: nvidia

    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["0"]
              capabilities: [gpu, video]
```

### config.yaml

> 此处以乐橙（IMOU）摄像头为例。
>
> 大多数摄像头对应的 RTSP 地址都能在 iSpy 文档中找到。
>
> 另外，乐橙摄像头要求 Wi-Fi 密码同时包含字母和数字，否则无法连接。

Frigate 在配置方面的文档较为零散，需要同时参考完整参考配置和相关 Issue。

```yaml
version: 0.15-1

mqtt:
  enabled: false

tls:
  enabled: false

auth:
  # 如果启用，admin 密码会在首次启动时输出到日志。
  # 错过了也没关系，可以查看 docker-compose logs。
  enabled: false

ffmpeg:
  # 如果遇到 hardware capacity xxxx 问题，
  # 可以尝试让摄像头使用 H264 编码。
  hwaccel_args: preset-nvidia

  # IMOU 摄像头使用 UDP 时容易丢包、重复包、断流。
  input_args: -rtsp_transport tcp

record:
  enabled: true

  retain:
    days: 1
    mode: all

  alerts:
    retain:
      days: 30
      mode: motion

  detections:
    retain:
      days: 30
      mode: motion

cameras:
  backyard:
    enabled: true

    ffmpeg:
      inputs:
        - path: rtsp://admin:PASSWORD@CAMIP:554/cam/realmonitor?channel=1&subtype=0
          roles:
            - detect

    detect:
      enabled: true

    # 上下左右控制。
    # 不建议对乐橙使用 ONVIF autotracking，容易导致摄像头死机。
    onvif:
      host: CAMIP
      port: 80
      user: admin
      password: PASSWORD

    motion:
      # mask 掉乐橙时间戳区域
      mask: 0.015,0.041,0.268,0.041,0.267,0.086,0.014,0.089

      threshold: 40
      contour_area: 10
      improve_contrast: true

# 部分旧显卡可能会遇到 onnxruntime kernel 支持问题。
# 如果有 Intel CPU，也可以考虑 OpenVINO + CPU 推理。
detectors:
  onnx:
    type: onnx

model:
  model_type: yolonas

  width: 320
  height: 320

  input_pixel_format: bgr
  input_tensor: nchw

  path: /config/yolo_nas_s.onnx
  labelmap_path: /labelmap/coco-80.txt
```

## 如何彻底关闭服务

```bash
docker-compose down
```

## 如何通过命令行重启服务（不推荐）

```bash
docker-compose stop
sleep 2
docker-compose start
```