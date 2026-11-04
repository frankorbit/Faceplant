# Faceplant

用原生 ARKit + Metal 复现 2018 年 Faceplant 的"脸从墙里顶出来"效果。设计文档见 [docs/技术方案.md](docs/技术方案.md)。

## 环境

- Xcode 27.2，iOS 16+ 部署目标
- `brew install xcodegen swiftlint swiftformat just`
- 首次构建需要 Metal 工具链：`xcodebuild -downloadComponent MetalToolchain`

## 常用命令

```bash
just gen      # 重新生成 Faceplant.xcodeproj（改了 project.yml 或增删文件后）
just check    # lint + 格式检查 + 真机 SDK 编译
just format   # 自动格式化
```

`Faceplant.xcodeproj` 不入库，clone 后先执行 `just gen` 生成。人脸追踪不能在模拟器上跑，运行必须用真机。打开工程后在 Signing 里选自己的 Team 即可。

## 当前阶段：M1 录制（代码完成，待真机验收）

流程：首页 → 录制新脸 → 录制页（前置摄像头，实时显示烘焙贴图）→ 按红钮录 5 到 15 秒 → 自动进入 Face Review 回放。

真机验收清单：

| 检查 | 期望 |
|---|---|
| 录制页人脸贴图 | 与 Spike A 一致，五官对齐 |
| 录制 10 秒后 | 自动跳到 Face Review，脸在转台上循环播放，表情与贴图同步，嘴型不脱节 |
| 眼睛和嘴 | 录制页和 Review 页都没有黑洞；张嘴能看到舌头贴在嘴洞的盖子上，眼睛是视频里的真眼睛 |
| Review 页信息 | 时长约 10 秒，帧数约 300（30 fps）或 600（60 fps） |
| 首页"我的脸" | 出现带缩略图的条目，再次进入可回放 |
| 删除 | 条目消失，`Application Support/Recordings` 下目录被移除 |
| Xcode 控制台 | 没有 `retaining N ARFrames` 警告，没有"视频帧追加失败" |

录制包位置：`Application Support/Recordings/<uuid>.faceplant`，格式见技术方案 4.4。

## M0 Spike（已完成）

2026-11-04 在 iPhone 16 上验证完毕，结论已写入技术方案 4.3 与 4.7：

| Spike | 结果 |
|---|---|
| A · 投影烘焙对齐 | 通过。五官对齐无镜像，`flipV = false`，SceneKit 不需额外翻转 |
| B · 前后摄同开 | `userFaceTrackingEnabled` 可用；自开前置 `AVCaptureSession` 会抢走摄像头导致 ARKit 会话失败，方案不可行 |

两个页面保留在工程里作为回归参考，M1 落地后删除。下面是当时的验收说明。

App 启动后是一个菜单，两个 spike 各自回答一个问题。

### Spike A · 投影烘焙对齐验证

回答：按技术方案 4.2 / 4.3 的数学，相机画面能否正确展开到 canonical UV。

操作：进入后对着前置摄像头，看主画面和右下角预览。

| 观察 | 结论 |
|---|---|
| 主画面人脸贴图五官与真人对齐 | 投影矩阵与 `displayTransform` 逆变换正确 |
| 五官左右镜像 | `displayTransform` 方向用反了 |
| 五官整体偏移或缩放不对 | `viewportSize` 与渲染视图不一致 |
| 右下角预览是正立的脸 | 当前 Flip V 设置就是正确的 UV 方向约定，记录下来 |
| 右下角预览倒置 | 点 Flip V 切换，再记录 |

需要记录到技术方案 4.3 的结论：`flipV` 的正确取值，以及 SceneKit 显示 `MTLTexture` 时是否需要额外翻转。

### Spike B · 前后摄同开探针

回答：`ARWorldTrackingConfiguration.userFaceTrackingEnabled` 下，能否再拿到前置画面。

操作：进入后先确认屏幕中央悬浮的黄色线框网格跟着表情动，然后点 Start Front Probe。

| 状态行 | 结论 |
|---|---|
| `probe: running · frames N` 且持续增长 | 方案 B 可行，实时模式可以烘焙贴图 |
| `probe: interrupted · videoDeviceInUseByAnotherClient` | 方案 B 不可行，实时模式按方案 A 规划 |
| `probe: failed · ...` | 记录错误原文 |
| `session: interrupted` 出现在点击探针之后 | 探针把 ARKit 挤掉了，同样视为不可行 |

结论写回技术方案 4.7。

## 目录

```
Faceplant/
├── App/            SwiftUI 入口
├── ARSession/      ARSessionController，唯一持有 ARSession，delegate 跑独立队列
├── FaceMesh/       网格帧、拓扑、blendShape 顺序、FaceMeshSource 协议与实时实现
├── Recording/      .faceplant 包模型、mesh.bin 读写、FaceRecorder、Store
├── Playback/       FaceRecordingPlayer（视频时钟 + 顶点插值）、SceneKit 回放视图
├── Rendering/      Metal 烘焙 pass、像素缓冲纹理缓存、投影数学、共享 shader 类型
├── UI/             Home、Record、Review 三个页面
├── Spikes/         M0 的两个验证页面，M2 后删除
└── Support/        错误类型、二进制读写辅助
```
