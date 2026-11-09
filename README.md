# Ollama 便携版部署工具

一套面向国内网络环境的 Windows 便携版 Ollama 部署/清理脚本，特点：**不污染系统**（不改环境变量、不动注册表、模型全部放在便携目录内）、**代理自动识别**（Clash / V2Ray / sing-box 等）、**卡死自动降级**、**断点续传**、**无代理时走加速源**。

## 文件清单

| 文件 | 作用 |
|---|---|
| `Deploy-Ollama-Portable.ps1` | 部署脚本：装 Ollama、起服务、下载模型、验证 |
| `Cleanup-Ollama-Portable.ps1` | 清理脚本：停止进程、删除便携目录和下载缓存 |
| `deploy.log` | 部署日志（每次运行追加，含完整时间线） |
| `Ollama_Portable\` | 便携版本体（程序 + 模型 + 启动器），由部署脚本生成 |
| `gguf-cache\` | 加速源下载的 GGUF 缓存（仅无代理时产生） |

生成的便携目录结构：

```
Ollama_Portable\
├─ App\ollama.exe          # 程序本体
├─ Data\models\            # 所有模型（blobs + manifests）
└─ 启动Ollama.bat           # 日常启动器（端口占用时交互处理）
```

## 快速开始

1. **先启动代理**（Clash 或 V2Ray，脚本会自动探测；无代理也能跑，会自动走加速源）
2. 右键 `Deploy-Ollama-Portable.ps1` → 使用 PowerShell 运行，或命令行：

   ```powershell
   powershell -File D:\Ollama\Deploy-Ollama-Portable.ps1
   ```

   无人值守/计划任务加 `-NoPause`（跳过结尾暂停和断点询问，默认续传）：

   ```powershell
   powershell -File D:\Ollama\Deploy-Ollama-Portable.ps1 -NoPause
   ```

3. 部署完成后 API 地址：`http://127.0.0.1:11434`，日常用 `Ollama_Portable\启动Ollama.bat` 启服务

## 部署脚本工作流程

```
1. 创建目录
2. Ollama 程序就绪（已存在则跳过；否则 aria2c 多线程下载 zip + 三重解压兜底）
3. 生成启动器 bat
4. 代理探测（候选端口轮询 + 运行中代理进程端口动态发现）
5. 启动服务（自动清理占用端口的旧 ollama）
   └─ 检测到上次中断的断点缓存 → 询问：[R]续传 / [C]清缓存重下
6. 逐槽位部署模型（主选失败自动切备选，每个模型走下面的策略链）
```

### 下载策略链（每个候选模型依次尝试）

| 顺序 | 策略 | 说明 |
|---|---|---|
| 0（仅无代理时） | 加速源 | hf-mirror.com 下载 GGUF + `ollama create` 注册同名模型 |
| 1 | 便携包原生 `ollama pull` | 主策略，带看门狗 |
| 2 | pullama | 多线程断点续传（需 `pip install pullama-cli`） |
| 3 | aria2c 直连 blob | 最后手段，带 sha256 校验 |

下载完成后自动**复核 + 验证**：`ollama show` 确认 manifest，再用 `/api/generate` 实际推理一次（防止加载即崩的模型蒙混过关）。

### 下载看门狗

下载进程被实时监控，三路信号**任一有变化即视为存活**：

- 进程 IO 字节数（WMI 计数器，**含网络流量**——真实下载必有字节流动，不受 Ollama 0.40 分块文件元数据不更新的影响）
- blobs 目录字节数（增长**或减少**都算活动，合并阶段会删分块）
- 子进程输出文件大小（进度条心跳）

连续 **90 秒**（`$DownloadStallTimeoutSec`）无任何活动才判定卡死：杀进程 → 复核 `ollama show`（收尾阶段误判兜底）→ 降级到下一策略/下一候选模型。

每 10 秒输出一行状态：`本次IO / 落盘 / 速率 / 停滞计时`，同时写入 deploy.log。

## 配置说明（脚本顶部"可修改变量区"）

| 变量 | 默认 | 说明 |
|---|---|---|
| `$ModelGroups` | 见下表 | 部署槽位，每组第一个是主选，失败依次尝试备选 |
| `$OllamaPort` | `11434` | 服务端口 |
| `$ProxyCandidates` | 7890/7897/10809/1080 | 代理候选端口，按顺序探测；运行中的 v2ray/xray/sing-box/clash/mihomo 进程端口会**自动追加**（自定义端口也能识别） |
| `$EnableProxy` | `$true` | 是否启用代理探测 |
| `$DeepVerify` | `$true` | 下载后是否做 API 推理验证 |
| `$VerifyTimeoutSec` | `180` | 推理验证超时 |
| `$DownloadStallTimeoutSec` | `90` | 看门狗停滞判定秒数（网络差可调大） |
| `$DownloadMaxMinutes` | `0` | 单次下载总时长上限（分钟），0=不限 |
| `$PullamaMaxRetries` / `$PullamaRetryDelay` | `3` / `5` | pullama 重试次数与间隔 |
| `$ClearCacheBeforePull` | `$true` | 清缓存默认策略；检测到断点时会弹窗询问，`-NoPause` 默认续传 |
| `$EnableAccelSource` / `$AccelBaseUrl` | `$true` / hf-mirror | 无代理时的加速源开关与地址 |
| `$AccelModelMap` | 见脚本 | 加速源模式下"ollama 模型名 → HF 仓库"映射 |

### 当前模型槽位

| 槽位 | 候选链（主选 → 备选） |
|---|---|
| 1 | `gemma3:12b`（通用模型） |
| 2 | `huihui_ai/hy-mt1.5-abliterated:7b`（混元 MT1.5 去审查，33 语翻译专精）→ `huihui_ai/aya-expanse-abliterated:8b`（去审查 23 语通用）→ `quantumcookie/Sakura-Galtransl-v3.7:7b`（日译中 galgame 专精）→ `kaelri/qwen3.5-mt:2b`（轻量探针）→ `ZimaBlueAI/HY-MT1.5-1.8`（1.8B 去审查轻量版） |

加新模型时：往 `$ModelGroups` 对应槽位数组里加一行即可；如需加速源支持，同步在 `$AccelModelMap` 里加 HF 仓库映射（没有映射会在加速源模式下自动跳过该模型）。

## 清理脚本

```powershell
powershell -File D:\Ollama\Cleanup-Ollama-Portable.ps1
```

交互确认后执行：停止便携版 ollama 进程（按路径精确匹配，不误伤系统安装版）→ 删除 `Ollama_Portable\`（含全部模型，会显示大小）→ 删除 `gguf-cache\` → 删除下载的 zip。部署日志 `deploy.log` 默认保留，不需要可手动删。

## 常见问题

**Q：日志提示"所有代理候选均不可用"？**
A：代理软件没启动，或端口不在候选列表且进程名不含 v2ray/xray/sing-box/clash/mihomo 关键词。启动代理后重跑即可；无代理时会自动尝试加速源。

**Q：下载很慢怎么办？**
A：看 10 秒一行的状态日志里"速率"字段。慢但在动就让它跑（看门狗只杀完全停滞的）；想中断某模型直接等它被判卡死或 Ctrl+C，断点会保留，重跑选 R 续传。

**Q： blobs 目录里 `-partial-N` 文件显示 0 字节？**
A：Ollama 0.40 多流下载的稀疏分块，元数据长度不反映真实数据，属正常现象，续传有效。

**Q：端口 11434 被占用？**
A：脚本自动清理占用端口的旧 ollama 进程；被非 ollama 程序占用时会报错退出，手动释放端口或改 `$OllamaPort`。

**Q：加速源下载的模型和官方 pull 的有区别吗？**
A：内容相同（同一 GGUF 权重，聊天模板从 GGUF 内嵌元数据自动提取），只是走 hf-mirror 下载 + 本地 `ollama create` 注册。代理恢复后 `ollama pull` 更新会重新走官方 registry。

**Q：退出码约定？**
A：`0` = 全部槽位部署成功；`1` = 任一槽位所有候选均失败 / 程序下载失败 / 服务起不来。可用于计划任务或 CI 判断。
