# Token Pet

基于 [FoloToy AI Passport](https://github.com/FoloToy/ai-passport) 的真实 Token 宠物，包含 Mac 账本／网页／USB与蓝牙桥和 ESP32-C3 固件。当前版本已编译、刷入连接的硬件并完成双向通信与存档验证，具体范围见 [verification.json](evidence/verification.json)。

六条培养进化链：小火龙→火恐龙→喷火龙、皮丘→皮卡丘→雷丘、妙蛙种子→妙蛙草→妙蛙花、杰尼龟→卡咪龟→水箭龟、迷你龙→哈克龙→快龙、鬼斯→鬼斯通→耿鬼。共有 **12个成长等级**，每个物种4级，在第5和第9级真实进化。梦幻无进化链，作为图鉴访客。

## 运行

在本目录执行：

```bash
./scripts/run.sh
```

打开 **http://127.0.0.1:18785/**，选择伙伴和食物来源。默认使用本机 Codex JSONL 的新用量；也可以切换到已登录 Codex 的账户 Token 增量。网页显示今日食谱、今日摄入、领养后累计和进化进度。账户历史累计单列参考，不与本地相加。服务首次接入建立基线，不把旧日志直接喂满宠物。

```bash
./scripts/run.sh --root /path/to/codex-jsonl-directory
./scripts/run.sh --no-usb --no-account
```

`--root`可以重复传入目录或单个JSONL。当前支持Codex的 `event_msg/token_count` 格式。每5秒扫描本地新记录，每5分钟只读刷新账户；无模型推理调用。运行数据仅存于 `.local/state/`，不保存对话正文或凭据。

网页的“设备连接”可以选择 **自动、USB、蓝牙**。当前已配置并选中蓝牙，同步数据经BLE发送；USB可以用于供电。自动模式优先USB，在USB断开后尝试蓝牙。首次连接通过USB配置本机独有密钥，BLE使用加密链路与密钥验证，不需要在系统蓝牙列表手动配对。Mac程序须保持运行，设备也需要电池或外接电源。

蓝牙依赖Bleak3.0.1，已安装在本目录的 `.local/ble-env`；run.sh自动使用它。重新部署时：

```bash
python3 -m venv .local/ble-env
.local/ble-env/bin/python -m pip install -r host/requirements-bluetooth.txt
```

USB和网页路径仍可仅用Python标准库，`--no-bluetooth`禁用蓝牙线程。硬件同步后可离线保留画面。双击OK循环宠物、最近三个会话和食谱；UP/DOWN选择列表项，单击OK打开会话，长按OK进入/退出设置。主机退出后设备显示离线，重新启动服务会自动补同步。

## 验证与构建

```bash
PYTHONPATH=host python3 -m unittest discover -s tests
./firmware/tools/test_pet.sh
./scripts/build.sh --static # 使用本目录已安装的工具链
./scripts/build.sh          # 完整固件门禁，不自动烧录
```

固件使用ESP-IDF **5.5.3**；激活环境后在 `firmware` 中运行 `./tools/validate.sh`，完成仓库检查、主机测试、固件构建、8MB分区／完整镜像校验与ELF/MAP归档。产物为 `firmware/build/FoloToy-AI-Passport-full.bin`，配套归档在 `firmware/build/firmware/<SHA256>/`。烧录前核验归档，完整镜像在明确授权后写入0x0。当前原CODO固件已按用户授权覆盖。

`device_check.py`默认会用合成Token改变设备存档，用于验收72个物种／等级映射及协议恢复。查看实际状态仅用 `--state-only`。带 `--capture output.png`需要Pillow，可导出设备实际渲染像素；面板亮度、色彩与实体按键仍需实机人工确认。

详见 [实现与计数口径](docs/IMPLEMENTATION.md)、[素材来源](docs/ASSETS.md)、[早期通信调研](docs/RESEARCH.md)、[合成设备测试](evidence/device-tests.json) 、[重启验证](evidence/device-reboot.json) 与 [蓝牙验收](evidence/bluetooth-tests.json)。调研文档中的“待实现”代表当时状态，当前交付以本README和验证摘要为准。

账户日桶可能延迟，不能冒充当天实时Token。账户来源的“今日摄入”按本机收到增量的日期归属。每日本地数值按记录时间归入 `Asia/Shanghai`，只覆盖本机可读日志。切换来源重新建基线，避免重复喂食；可能略过基线建立期间的用量。

新版设备素材已裁去动画公共留白，使用120×120帧，源素材本体最大112px，显示时按1.5倍放大并随成长增大；网页主图约230px。已检查设备实际渲染及390px窄屏。当前更新通过兼容布局的应用镜像写入0x10000，保留NVS存档与蓝牙配置。

### 游戏操作

打开面板或设备后先选择初始伙伴，再确认领养。确认后不能更换；既有摄入与等级保留。待选择期间不会补喂新Token。

- 双击OK循环：宠物、最近三个换台会话、今日食谱。
- 会话页：上/下选择，单击OK在Mac打开来源会话。
- 长按OK进入/退出设置，上/下查看换台额度进度、重置倒计时与伙伴详情。

会话和额度要求Mac上的换台正在运行（本地端口18784）；宠物面板与USB/BLE桥继续使用18785。会话与额度接口断开会显示未连接，宠物存档继续保留。初次选择可在网页完成，也可在硬件上完成；两端以同一账本锁定。

### 声音互动

板载ES8311麦克风只在设备内检测音量波动。宠物平时静止，明显超过环境底噪时跳一下（约0.48秒），随后回到静止；持续背景声不会反复触发。启动约2秒用于校准。每次只读取20ms音频，立即计算音量并丢弃，不录音、不上传、不消耗Token。设置详情显示麦克风是否就绪。网页主宠物也停止自动跳动；声音触发由硬件执行。

主页显示宠物名字与等级，去除“伙伴已锁定”常驻提示；今日和累计摄入合成一行。声音与页面操作不会改变Token账本或存档。

状态栏左侧显示BLE／USB／离线，右侧显示板载电量计的百分比和图标，每5秒刷新；读取失败显示--%。名字只保留在成长行。麦克风灵敏度已提高，较轻的说话声更容易触发，仍过滤恒定背景声和孤立噪点。

设备三档设置：长按OK进入，UP/DOWN选择额度、详情、亮度或麦克风门槛；单击OK循环调档。亮度低20%／中40%／高75%，默认中；麦克风低门槛更灵敏，默认低。选择立即生效并保存在设备NVS，重启保留，不影响伙伴、Token或蓝牙密钥。
