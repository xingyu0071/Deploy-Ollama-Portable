# Deploy-Ollama-Portable.ps1
# 便携版 Ollama + 代理探测 + 下载看门狗（卡死自动降级）+ 失败缓存清理 + 备用模型链
param([switch]$NoPause)   # 无人值守/计划任务场景加 -NoPause，跳过结尾的暂停

$ErrorActionPreference = "Continue"

# ============ 可修改变量区 ============
# 每个数组是一个"部署槽位"，组内第1个是主选，失败后依次尝试后面的备选
$ModelGroups = @(
    # 槽位1：Gemma 3 12B（只有这一个，没有备选）
    @(
        "gemma3:12b"
    ),
    # 槽位2：翻译模型主选 + 备选链（要求：英/日译中为主，无审查可译 NSFW，≤10G 显存）
    @(
        "huihui_ai/hy-mt1.5-abliterated:7b",     # 主选：混元MT1.5去审查版，33语翻译专精，4.6GB
        "huihui_ai/aya-expanse-abliterated:8b",  # 备选1：去审查版23语通用模型，英/日译中均可，约4.9GB
        "quantumcookie/Sakura-Galtransl-v3.7:7b",# 备选2：Sakura日译中galgame专精，天然无审查
        "kaelri/qwen3.5-mt:2b"                   # 备选3：去审查纯翻译模板，轻量探针 1.9GB
	"ZimaBlueAI/HY-MT1.5-1.8"  #HY-MT1.5 的无审查版
    )
)
$OllamaPort         = 11434
$ProxyCandidates    = @(             # 代理候选列表，从上到下依次探测，第一个可用的胜出
    "http://127.0.0.1:7890",         # Clash / Clash for Windows
    "http://127.0.0.1:7897",         # Clash Verge / Clash Meta
    "http://127.0.0.1:10809",        # v2rayN HTTP 代理
    "http://127.0.0.1:1080"          # v2ray 旧版 / 其他 HTTP 代理
)
$EnableProxy        = $true
# 注意：Ollama 0.40 不存在 OLLAMA_MODEL_SERVER 等 registry 镜像环境变量，
# 代理不可用时下载必然失败（registry.ollama.ai 被墙），请确保 Clash 已启动。
$DeepVerify         = $true
$VerifyTimeoutSec   = 180
$PullamaMaxRetries  = 3
$PullamaRetryDelay  = 5
$ProxyTestTimeout   = 5
$Aria2MaxTries      = 5
$ClearCacheBeforePull = $true   # 下载前清理该模型的失败缓存；检测到断点时会弹出选择（续传/清缓存），-NoPause 时默认续传
$DownloadStallTimeoutSec = 90   # 看门狗：下载停滞超过该秒数判定卡死，杀掉并降级
$DownloadMaxMinutes      = 0    # 单次下载最长分钟数，0=不限
$EnableAccelSource  = $true     # 无代理时的次选：走 hf-mirror 加速源下载 GGUF + ollama create
$AccelBaseUrl       = "https://hf-mirror.com"
# 加速源映射：ollama 模型名 -> HF 仓库（GGUF 内嵌聊天模板，ollama create 会自动提取）
$AccelModelMap = @{
    "gemma3:12b"                         = "ggml-org/gemma-3-12b-it-GGUF"
    "huihui_ai/hy-mt1.5-abliterated:7b"  = "mradermacher/Huihui-HY-MT1.5-7B-abliterated-GGUF"
    "huihui_ai/aya-expanse-abliterated:8b" = "mradermacher/aya-expanse-8b-abliterated-GGUF"
    "quantumcookie/Sakura-Galtransl-v3.7:7b" = "SakuraLLM/Sakura-GalTransl-7B-v3.7"
    # kaelri/qwen3.5-mt:2b 无公开 HF 源，加速源模式下自动跳过该模型
}
# ====================================

$Root        = $PSScriptRoot
$PortableDir = Join-Path $Root "Ollama_Portable"
$AppDir      = Join-Path $PortableDir "App"
$DataDir     = Join-Path $PortableDir "Data"
$ModelsDir   = Join-Path $DataDir "models"
$Launcher    = Join-Path $PortableDir "启动Ollama.bat"
$OllamaExe   = Join-Path $AppDir "ollama.exe"
$ZipPath     = Join-Path $Root "ollama-windows-amd64.zip"
$LogPath     = Join-Path $Root "deploy.log"

try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}

# ==================== 函数 ====================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [$Level] $Message"
}

function Expand-ZipRobust {
    param([string]$ZipPath, [string]$DestPath)
    if (Get-Command tar -ErrorAction SilentlyContinue) {
        Write-Log "尝试 tar 解压..." "INFO"
        & tar -xf $ZipPath -C $DestPath 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $DestPath "ollama.exe"))) { return $true }
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestPath)
        if (Test-Path (Join-Path $DestPath "ollama.exe")) { return $true }
    } catch {}
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        Expand-Archive -Path $ZipPath -DestinationPath $DestPath -Force
    } catch {} finally { $ErrorActionPreference = $prev }
    return (Test-Path (Join-Path $DestPath "ollama.exe"))
}

function Test-ProxyAvailable {
    param([string]$ProxyUrl, [int]$TimeoutSec = 5)
    try {
        $uri = [System.Uri]$ProxyUrl
        $port = $uri.Port
        $listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if (-not $listen) {
            Write-Log "代理端口 $port 无监听（Clash 可能未启动）" "WARN"
            return $false
        }
        Write-Log "通过代理访问 https://ollama.com（超时 ${TimeoutSec}s）..." "INFO"
        $resp = Invoke-WebRequest -Uri "https://ollama.com" -Proxy $ProxyUrl `
            -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
            Write-Log "代理连通，状态码 $($resp.StatusCode)" "INFO"
            return $true
        }
        Write-Log "代理返回异常状态码：$($resp.StatusCode)" "WARN"
        return $false
    } catch {
        Write-Log "代理测试失败：$($_.Exception.Message)" "WARN"
        return $false
    }
}

# 收集代理候选端口：固定候选 + 动态发现运行中代理进程的所有本地监听端口
function Get-ProxyCandidatePorts {
    $ports = @()
    foreach ($url in $ProxyCandidates) {
        try { $ports += ([System.Uri]$url).Port } catch {}
    }
    $proxyProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match 'v2ray|xray|sing-box|clash|mihomo|hysteria|trojan'
    }
    foreach ($pr in $proxyProcs) {
        $found = Get-NetTCPConnection -State Listen -OwningProcess $pr.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in '127.0.0.1', '0.0.0.0' }
        foreach ($c in $found) {
            Write-Log "发现代理进程 $($pr.ProcessName) (PID $($pr.Id)) 监听端口 $($_.LocalPort)" "INFO"
            $ports += $_.LocalPort
        }
    }
    return ($ports | Sort-Object -Unique)
}

function Get-WorkingProxy {
    param([int]$TimeoutSec = 5)
    foreach ($port in (Get-ProxyCandidatePorts)) {
        $url = "http://127.0.0.1:$port"
        Write-Log "探测代理候选：$url" "INFO"
        if (Test-ProxyAvailable -ProxyUrl $url -TimeoutSec $TimeoutSec) {
            Write-Log "选中代理：$url" "INFO"
            return $url
        }
    }
    return $null
}

# 轻量选择：只看端口监听，不做完整 HTTP 探测（用于正式探测前的 zip 下载等场景）
function Get-ListeningProxy {
    foreach ($port in (Get-ProxyCandidatePorts)) {
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
            return "http://127.0.0.1:$port"
        }
    }
    return $null
}

function Get-PullamaPath {
    # 优先 PATH，其次常见安装位置（通配符解析，不绑定用户名）
    $cmd = Get-Command pullama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:USERPROFILE\.local\bin\pullama.exe",
        "$env:APPDATA\Python\Python3*\Scripts\pullama.exe",
        "$env:APPDATA\Python\Scripts\pullama.exe",
        "$env:LOCALAPPDATA\Packages\PythonSoftwareFoundation.Python.3.*_*\LocalCache\local-packages\Python3*\Scripts\pullama.exe"
    )
    foreach ($p in $candidates) {
        $hit = Get-Item $p -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# ---------- 目录总大小（看门狗用） ----------
function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

# ---------- 进程 IO 字节数（WMI ReadTransferCount+WriteTransferCount，包含网络流量） ----------
function Get-ProcessIoBytes {
    param([int]$ProcessId)
    try {
        $w = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($w) { return [long]($w.ReadTransferCount + $w.WriteTransferCount) }
    } catch {}
    return 0
}

# ---------- 下载看门狗：停滞超时即杀进程，防止"卡死永不降级" ----------
# 判活信号（任一增长即存活）：
#   1. 被监控进程的 IO 字节数（WMI 计数器，含网络流量——真实下载必有字节流动，
#      不受 Ollama 0.40 分块文件 NTFS 长度不更新的影响，网络波动的小流量也算活着）
#   2. 监控目录字节数（pullama/aria2 传统写盘模式）
#   3. 子进程输出文件字节数（进度条刷新）
function Invoke-ProcessWithWatchdog {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WatchDir,                 # 监控此目录字节数增长判断是否在下载
        [int]$StallTimeoutSec = 120,       # 连续无增长多久判定卡死
        [int]$MaxDurationSec = 0,          # 0 = 不限总时长
        [int]$ExtraWatchPid = 0            # 额外监控的进程（如 ollama serve，pull 的实际下载者）
    )
    if (-not (Test-Path $WatchDir)) { New-Item -ItemType Directory -Path $WatchDir -Force | Out-Null }
    $outFile = Join-Path $env:TEMP ("ollama-dl-{0}.out.log" -f [guid]::NewGuid().ToString('N'))
    $errFile = Join-Path $env:TEMP ("ollama-dl-{0}.err.log" -f [guid]::NewGuid().ToString('N'))

    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
         -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    Write-Log "下载进程已启动（PID $($p.Id)），停滞判定 ${StallTimeoutSec}s" "INFO"

    $taskName     = Split-Path $FilePath -Leaf
    $baselineDir  = Get-DirSize $WatchDir          # 基线：已有 blob 不计入本次下载量
    $ioPidSelf    = $p.Id
    $ioBaseline   = Get-ProcessIoBytes $ioPidSelf
    if ($ExtraWatchPid -gt 0) { $ioBaseline += Get-ProcessIoBytes $ExtraWatchPid }

    $lastSig    = -1
    $lastGrowth = Get-Date
    $start      = Get-Date
    $killed     = $false
    $speedSig   = 0
    $speedTime  = Get-Date

    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        $p.Refresh()
        if ($p.HasExited) { break }

        # 汇总所有判活信号
        $dirSize = Get-DirSize $WatchDir
        $ioNow   = Get-ProcessIoBytes $ioPidSelf
        if ($ExtraWatchPid -gt 0) { $ioNow += Get-ProcessIoBytes $ExtraWatchPid }
        foreach ($a in (Get-Process -Name "aria2c" -ErrorAction SilentlyContinue)) { $ioNow += Get-ProcessIoBytes $a.Id }
        $outLen = (Get-Item $outFile,$errFile -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($null -eq $outLen) { $outLen = 0 }
        $sig = $dirSize + $ioNow + $outLen

        if ($lastSig -lt 0) { $lastSig = $sig; $speedSig = $sig }   # 首次采样只建立基线
        # 任何变化都算活动：合并阶段会删除分块文件导致总量变小，也是正常工作信号
        if ($sig -ne $lastSig) { $lastSig = $sig; $lastGrowth = Get-Date }

        # 每 10 秒输出一行状态（真实 IO 速率 + 本次下载量 + 停滞计时）
        $elapsed = (New-TimeSpan $speedTime (Get-Date)).TotalSeconds
        if ($elapsed -ge 10) {
            $speedMBs  = ($sig - $speedSig) / 1MB / $elapsed
            $speedSig  = $sig; $speedTime = Get-Date
            $stallNow  = [int](New-TimeSpan $lastGrowth (Get-Date)).TotalSeconds
            $thisDlMB  = ($dirSize - $baselineDir) / 1MB            # 本次下载落盘量
            $ioTotalMB = ($ioNow - $ioBaseline) / 1MB               # 本次进程 IO 总量（含网络）
            Write-Log ("下载中... 本次IO {0:N0} MB | 落盘 {1:N0} MB | 速率 {2:N1} MB/s | 停滞 {3}s/{4}s" -f $ioTotalMB, $thisDlMB, $speedMBs, $stallNow, $StallTimeoutSec) "INFO"
            Write-Progress -Activity "下载中：$taskName $($Arguments -join ' ')" `
                -Status ("本次IO {0:N0} MB | 速率 {1:N1} MB/s | 停滞 {2}s/{3}s" -f $ioTotalMB, $speedMBs, $stallNow, $StallTimeoutSec) `
                -PercentComplete -1
        }

        $stallSec = (New-TimeSpan $lastGrowth (Get-Date)).TotalSeconds
        if ($stallSec -ge $StallTimeoutSec) {
            Write-Log "看门狗：${StallTimeoutSec}s 无任何活动（进程IO/目录/输出均无增长），判定卡死，终止下载进程" "ERROR"
            $killed = $true; break
        }
        if ($MaxDurationSec -gt 0 -and (New-TimeSpan $start (Get-Date)).TotalSeconds -ge $MaxDurationSec) {
            Write-Log "看门狗：超过最长时长 ${MaxDurationSec}s，终止下载进程" "ERROR"
            $killed = $true; break
        }
    }
    Write-Progress -Activity "下载中：$taskName" -Completed

    if ($killed) {
        foreach ($proc in @($p) + (Get-Process -Name "aria2c" -ErrorAction SilentlyContinue)) {
            try { $proc.Kill() } catch {}
        }
        Start-Sleep -Seconds 2
    } else {
        try { $p.WaitForExit() } catch {}
    }

    # 失败时输出子进程尾部日志便于诊断
    $exitOk = (-not $killed) -and ($p.ExitCode -eq 0)
    if (-not $exitOk) {
        $tail = Get-Content $errFile -Tail 8 -ErrorAction SilentlyContinue
        if ($tail) { Write-Log ("子进程 stderr 尾部：" + ($tail -join ' | ')) "DEBUG" }
    }
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return $exitOk
}

function Get-Aria2Path {
    $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget 默认安装位置兜底
    $wingetBase = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetBase) {
        $aria2Dir = Get-ChildItem $wingetBase -Filter "aria2*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($aria2Dir) {
            $exe = Get-ChildItem $aria2Dir.FullName -Recurse -Filter "aria2c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    return $null
}

function Show-PartialState {
    $blobs = Join-Path $ModelsDir "blobs"
    if (-not (Test-Path $blobs)) { return }
    $partials = Get-ChildItem $blobs -Filter "*partial*" -File -ErrorAction SilentlyContinue
    if (-not $partials) { Write-Log "当前没有 -partial 断点文件" "INFO"; return }
    foreach ($f in $partials) {
        $sizeMB = [math]::Round($f.Length / 1MB, 1)
        Write-Log "断点：$($f.Name)  已下载 $sizeMB MB" "INFO"
    }
}

# ---------- 解析模型名 → manifests 路径 ----------
function Get-ManifestPath {
    param([string]$ModelName)
    $ns = "library"
    $nameTag = $ModelName
    if ($ModelName -match "^([^/]+)/(.+)$") {
        $ns = $matches[1]
        $nameTag = $matches[2]
    }
    $name = $nameTag
    $tag = "latest"
    if ($nameTag -match "^(.+):(.+)$") {
        $name = $matches[1]
        $tag = $matches[2]
    }
    return Join-Path $ModelsDir "manifests\registry.ollama.ai\$ns\$name\$tag"
}

# ---------- 清理该模型的失败缓存 ----------
function Clear-FailedCache {
    param([string]$ModelName)
    if (-not $ClearCacheBeforePull) { return }

    Write-Log "清理 $ModelName 的失败缓存..." "INFO"

    $blobsDir = Join-Path $ModelsDir "blobs"
    $manifestPath = Get-ManifestPath -ModelName $ModelName

    # 1. 尽量从现有 manifest 中解析出该模型的 blob 摘要，精准清理对应断点
    $digests = @()
    if (Test-Path $manifestPath) {
        try {
            $mf = Get-Content $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $digests = @($mf.layers.digest) + @($mf.config.digest) |
                Where-Object { $_ } | ForEach-Object { $_ -replace '^sha256:', '' }
        } catch {
            Write-Log "  manifest 解析失败，将按无 manifest 处理" "WARN"
            $digests = @()
        }
    }

    if (Test-Path $blobsDir) {
        $partials = Get-ChildItem $blobsDir -Filter "*-partial*" -File -ErrorAction SilentlyContinue
        if ($digests.Count -gt 0) {
            # 只删除属于本模型的断点
            $partials = @($partials | Where-Object {
                $pname = $_.Name
                ($digests | Where-Object { $pname -like "*$_*" }).Count -gt 0
            })
        } elseif ($partials) {
            # 无 manifest 可对照时，断点无法归属到具体模型，保守地清理全部中断碎片
            Write-Log "  无 manifest 可对照，清理全部 $($partials.Count) 个中断断点" "WARN"
        }
        if ($partials) {
            foreach ($f in $partials) {
                $mb = [math]::Round($f.Length / 1MB, 1)
                Write-Log "  删除断点：$($f.Name) ($mb MB)" "INFO"
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Log "  无断点文件需要清理" "INFO"
        }
    }

    # 2. 删除该模型不完整的 manifest（保留完整 blob，下次 pull 会复用）
    if (Test-Path $manifestPath) {
        Write-Log "  删除 manifest：$manifestPath" "INFO"
        Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "  manifest 不存在，无需清理" "INFO"
    }
}

# ---------- 策略二：pullama（多线程断点续传后备） ----------
function Invoke-PullamaPull {
    param([string]$ModelName, [int]$MaxRetries, [int]$RetryDelay)
    $pullamaPath = Get-PullamaPath
    if (-not $pullamaPath) { return $false }

    $aria2 = Get-Aria2Path
    if ($aria2) {
        Write-Log "pullama 将使用 aria2c（$aria2）多线程下载" "INFO"
    } else {
        Write-Log "未检测到 aria2c，pullama 使用内置 HTTP 客户端（仍然支持断点续传）" "WARN"
    }

    $blobsWatch = Join-Path $ModelsDir "blobs"
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Log "[pullama 尝试 $i/$MaxRetries] $ModelName" "INFO"
        $ok = Invoke-ProcessWithWatchdog -FilePath $pullamaPath -Arguments @("pull", $ModelName) `
                -WatchDir $blobsWatch -StallTimeoutSec $DownloadStallTimeoutSec `
                -MaxDurationSec ($DownloadMaxMinutes * 60)
        if ($ok) {
            Write-Log "pullama 成功完成" "INFO"
            return $true
        }
        Write-Log "pullama 未完成（失败或被看门狗终止）" "WARN"
        # 复核：可能模型实际已装好，只是进程退出码/看门狗误判
        & $OllamaExe show $ModelName *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "复核通过：$ModelName 实际已存在，视为成功" "WARN"
            return $true
        }
        Show-PartialState
        if ($i -lt $MaxRetries) {
            Write-Log "$RetryDelay 秒后重试（断点续传）..." "INFO"
            Start-Sleep -Seconds $RetryDelay
        }
    }
    return $false
}

# ---------- 策略三：aria2c 直连 blob（后备） ----------
function Invoke-Aria2Pull {
    param([string]$ModelName, [int]$MaxTries)
    $pullamaPath = Get-PullamaPath
    $aria2Path   = Get-Aria2Path
    if (-not $pullamaPath -or -not $aria2Path) { return $false }

    Write-Log "尝试用 pullama get 获取 $ModelName 的 blob 直链..." "INFO"
    $getOutput = & $pullamaPath get $ModelName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "pullama get 失败：$($getOutput -join ' ')" "WARN"
        return $false
    }

    $urls = @()
    foreach ($line in $getOutput) {
        $lineStr = $line.ToString().Trim()
        if ($lineStr -match 'https?://\S+') {
            $urls += $matches[0]
        }
    }
    $urls = $urls | Select-Object -Unique
    if ($urls.Count -eq 0) { Write-Log "未能从 pullama get 提取 URL" "WARN"; return $false }

    Write-Log "提取到 $($urls.Count) 个 blob URL，开始 aria2c 下载..." "INFO"
    $blobsDir = Join-Path $ModelsDir "blobs"
    if (-not (Test-Path $blobsDir)) { New-Item -ItemType Directory -Path $blobsDir -Force | Out-Null }

    $proxyArgs = @()
    if ($env:HTTPS_PROXY -or $env:HTTP_PROXY) {
        $proxyVal = $env:HTTPS_PROXY; if (-not $proxyVal) { $proxyVal = $env:HTTP_PROXY }
        $proxyArgs = @("--all-proxy=$proxyVal")
        Write-Log "aria2c 使用代理：$proxyVal" "INFO"
    }

    foreach ($u in $urls) {
        # 去掉查询串，取最后一段作为文件名
        $fileName = (($u -split '[?#]')[0] -split '/')[-1]
        $expectedHash = $null
        # URL 里的 digest 是 sha256:<hex>，Ollama 本地存储格式是 sha256-<hex>
        if ($fileName -match '^sha256[:=]([a-fA-F0-9]{64})$') {
            $expectedHash = $matches[1].ToLower()
            $fileName = "sha256-$expectedHash"
        } elseif ($fileName -match '^([a-fA-F0-9]{64})$') {
            $expectedHash = $matches[1].ToLower()
            $fileName = "sha256-$expectedHash"
        } else {
            # 兜底：替换 Windows 非法文件名字符
            $fileName = $fileName -replace '[\\/:*?"<>|]', '-'
        }
        $destPath = Join-Path $blobsDir $fileName

        Write-Log "aria2c 下载：$fileName" "INFO"
        & $aria2Path -x 16 -s 16 -k 1M --max-tries=$MaxTries --continue=true `
            --dir=$blobsDir --out=$fileName @proxyArgs $u
        if ($LASTEXITCODE -ne 0) {
            Write-Log "aria2c 下载 $fileName 失败（退出码 $LASTEXITCODE）" "ERROR"
            return $false
        }
        if ($expectedHash) {
            $actualHash = (Get-FileHash $destPath -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedHash) {
                Write-Log "SHA256 校验失败：期望 $expectedHash，实际 $actualHash" "ERROR"
                Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                return $false
            }
            Write-Log "SHA256 校验通过：$fileName" "INFO"
        } else {
            Write-Log "无法从 URL 推断摘要，跳过 SHA256 校验：$fileName" "WARN"
        }
    }

    Write-Log "尝试通过 pullama install 注册 blob..." "INFO"
    & $pullamaPath install --model $ModelName --blobsPath $blobsDir 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    & $OllamaExe show $ModelName *> $null
    return ($LASTEXITCODE -eq 0)
}

# ---------- 加速源策略：hf-mirror 下载 GGUF + ollama create（无代理时的次选） ----------
function Invoke-HfMirrorPull {
    param([string]$ModelName, [int]$MaxTries)
    if (-not $EnableAccelSource) { return $false }
    if (-not $AccelModelMap.ContainsKey($ModelName)) {
        Write-Log "加速源无 $ModelName 的仓库映射，跳过该策略" "WARN"
        return $false
    }
    $repo = $AccelModelMap[$ModelName]

    # 1. 探测加速源可达性并列出仓库文件
    Write-Log "查询加速源仓库：$repo" "INFO"
    try {
        $api = Invoke-RestMethod -Uri "$AccelBaseUrl/api/models/$repo" -TimeoutSec 20 -ErrorAction Stop
    } catch {
        Write-Log "加速源不可达：$($_.Exception.Message)" "WARN"
        return $false
    }
    $files = @($api.siblings | ForEach-Object { $_.rfilename } | Where-Object { $_ -match '\.gguf$' })
    # 优先 Q4_K_M 量化，其次任意 GGUF
    $pick = $files | Where-Object { $_ -match 'Q4_K_M' } | Select-Object -First 1
    if (-not $pick) { $pick = $files | Select-Object -First 1 }
    if (-not $pick) { Write-Log "加速源仓库中未找到 GGUF 文件" "WARN"; return $false }
    Write-Log "加速源选中文件：$pick" "INFO"

    # 2. 下载 GGUF（aria2c 优先，IWR 兜底），看门狗监控
    $dlDir = Join-Path $Root "gguf-cache"
    if (-not (Test-Path $dlDir)) { New-Item -ItemType Directory -Path $dlDir -Force | Out-Null }
    $destPath = Join-Path $dlDir $pick
    $url = "$AccelBaseUrl/$repo/resolve/main/$pick"

    $aria2Path = Get-Aria2Path
    $ok = $false
    if ($aria2Path) {
        Write-Log "加速源下载（aria2c）：$url" "INFO"
        $ok = Invoke-ProcessWithWatchdog -FilePath $aria2Path `
                -Arguments @('-x','16','-s','16','-k','1M',"--max-tries=$MaxTries",'--continue=true',"--dir=$dlDir","--out=$pick",$url) `
                -WatchDir $dlDir -StallTimeoutSec $DownloadStallTimeoutSec -MaxDurationSec ($DownloadMaxMinutes * 60)
    }
    if (-not $ok) {
        Write-Log "aria2c 加速下载失败或不可用，尝试 Invoke-WebRequest" "WARN"
        try {
            Invoke-WebRequest -Uri $url -OutFile $destPath -UseBasicParsing -ErrorAction Stop
            $ok = $true
        } catch { Write-Log "加速源下载失败：$_" "ERROR"; return $false }
    }
    if (-not (Test-Path $destPath) -or (Get-Item $destPath).Length -lt 100MB) {
        Write-Log "加速源下载产物异常（缺失或过小）" "ERROR"
        return $false
    }

    # 3. ollama create 注册为同名本地模型（GGUF 内嵌聊天模板会被自动提取）
    Write-Log "从 GGUF 创建本地模型：$ModelName" "INFO"
    $modelfile = Join-Path $dlDir ("Modelfile." + ($ModelName -replace '[/:]', '_'))
    Set-Content -Path $modelfile -Value "FROM ./$pick" -Encoding ASCII
    & $OllamaExe create $ModelName -f $modelfile 2>&1 | ForEach-Object { Write-Log "  ollama create: $_" "INFO" }
    if ($LASTEXITCODE -ne 0) { Write-Log "ollama create 失败（退出码 $LASTEXITCODE）" "ERROR"; return $false }
    Write-Log "加速源部署成功：$ModelName" "INFO"
    return $true
}

# ---------- 断点缓存策略：检测到上次中断的下载时，让用户选择续传还是清缓存重下 ----------
function Resolve-CachePolicy {
    $blobsDir = Join-Path $ModelsDir "blobs"
    if (-not (Test-Path $blobsDir)) { return }
    $partials = Get-ChildItem $blobsDir -Filter "*partial*" -File -ErrorAction SilentlyContinue
    if (-not $partials) { return }

    $totalMB = [math]::Round(($partials | Measure-Object Length -Sum).Sum / 1MB)
    Write-Log "检测到上次中断留下的断点缓存：$($partials.Count) 个文件" "WARN"
    Write-Log "（Ollama 0.40 分块模式下文件元数据可能显示为 0，实际数据在稀疏区段内，续传有效）" "INFO"

    if ($NoPause) {
        $script:ClearCacheBeforePull = $false
        Write-Log "无人值守模式：默认保留断点，续传上次下载" "INFO"
        return
    }
    $choice = Read-Host "发现未完成的下载缓存，`n  [R] 恢复续传（默认，回车）  [C] 删除缓存重新下载`n请选择"
    if ($choice -match '^[Cc]') {
        $script:ClearCacheBeforePull = $true
        Write-Log "已选择：删除缓存，重新下载" "WARN"
    } else {
        $script:ClearCacheBeforePull = $false
        Write-Log "已选择：保留断点，恢复续传" "INFO"
    }
}

# ---------- 策略一：便携包原生 ollama pull ----------
function Invoke-OllamaPull {
    param([string]$ModelName)
    Write-Log "使用便携包 $OllamaExe 下载" "INFO"
    $blobsWatch = Join-Path $ModelsDir "blobs"
    # 实际下载者是 serve 进程而非 pull 客户端，把它的 PID 交给看门狗监控 IO
    $servePid = 0
    $listen = Get-NetTCPConnection -LocalPort $OllamaPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listen) { $servePid = $listen.OwningProcess }
    if ($servePid -gt 0) { Write-Log "看门狗将同时监控 serve 进程（PID $servePid）的网络 IO" "INFO" }
    $ok = Invoke-ProcessWithWatchdog -FilePath $OllamaExe -Arguments @("pull", $ModelName) `
            -WatchDir $blobsWatch -StallTimeoutSec $DownloadStallTimeoutSec `
            -MaxDurationSec ($DownloadMaxMinutes * 90) -ExtraWatchPid $servePid
    if (-not $ok) {
        # 复核：看门狗可能在"合并/校验/写 manifest"收尾阶段误判；客户端被杀但服务端会继续完成
        Write-Log "等待服务端收尾后复核实际状态..." "INFO"
        Start-Sleep -Seconds 5
        & $OllamaExe show $ModelName *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "复核通过：$ModelName 实际已下载完成（看门狗误判），视为成功" "WARN"
            return $true
        }
    }
    if ($ok) { Write-Log "ollama pull 成功" "INFO"; return $true }
    Write-Log "ollama pull 失败（退出或被看门狗终止）" "ERROR"
    return $false
}

function Test-OllamaModel {
    param([string]$Exe, [string]$ModelName, [int]$Port)
    Write-Log "验证 manifest：ollama show $ModelName" "INFO"
    $show = & $Exe show $ModelName 2>&1
    if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Reason = "ollama show 失败：$($show -join ' ')" } }
    if (-not $DeepVerify) { return @{ Ok = $true; Reason = "仅 manifest 验证" } }

    Write-Log "深度验证：/api/generate（最长 ${VerifyTimeoutSec}s）..." "INFO"
    if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Reason = "Ollama serve 未监听端口 $Port" }
    }
    $body = @{ model = $ModelName; prompt = "Say OK"; stream = $false; options = @{ num_predict = 3; temperature = 0 } } | ConvertTo-Json -Depth 4
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec $VerifyTimeoutSec -ErrorAction Stop
        if ($resp -and $null -ne $resp.response) { return @{ Ok = $true; Reason = "API 推理成功" } }
        return @{ Ok = $false; Reason = "API 返回为空" }
    } catch {
        $serveProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
        $state = if ($serveProc) { "serve 仍在运行" } else { "serve 已退出（加载崩溃）" }
        return @{ Ok = $false; Reason = "API 失败：$($_.Exception.Message) / $state" }
    }
}

function Resolve-PortConflict {
    param([int]$Port)
    $occupied = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $occupied) { return $true }
    $pidVal = $occupied[0].OwningProcess
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -like "*ollama*") {
        Write-Log "清理旧 ollama PID $pidVal ..." "WARN"
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        return $true
    }
    $name = if ($proc) { $proc.ProcessName } else { "Unknown" }
    Write-Log "端口 $Port 被 $name (PID $pidVal) 占用" "WARN"
    return $false
}

# ==================== 主流程 ====================
$ExitCode = 0
try {
    Write-Log "===== 1. 创建目录 =====" "INFO"
    foreach ($d in @($AppDir, $ModelsDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Write-Log "  $d" "INFO"
    }

    Write-Log "===== 2. Ollama 程序就绪 =====" "INFO"
    $needUnzip = $true
    if (Test-Path $OllamaExe) {
        $ver = & $OllamaExe --version 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log "已存在：$($ver -join ' ')" "INFO"; $needUnzip = $false }
    }
    if ($needUnzip) {
        if (-not (Test-Path $ZipPath)) {
            $url = "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip"
            Write-Log "下载 Ollama..." "INFO"
            $zipOk = $false
            # 此时代理尚未正式探测，用"端口在监听"的轻量方式挑一个候选
            $zipProxy = $null
            if ($EnableProxy) { $zipProxy = Get-ListeningProxy }
            # 优先 aria2c：多线程 + 断点续传，适合大文件
            $aria2ForZip = Get-Aria2Path
            if ($aria2ForZip) {
                $zipProxyArgs = @()
                if ($zipProxy) { $zipProxyArgs = @("--all-proxy=$zipProxy"); Write-Log "zip 下载使用代理：$zipProxy" "INFO" }
                Write-Log "使用 aria2c 下载（支持断点续传）..." "INFO"
                & $aria2ForZip -x 8 -s 8 -k 1M --max-tries=5 --continue=true `
                    --dir=$Root --out="ollama-windows-amd64.zip" @zipProxyArgs $url
                $zipOk = ($LASTEXITCODE -eq 0)
                if (-not $zipOk) { Write-Log "aria2c 下载失败，回退 Invoke-WebRequest" "WARN" }
            }
            if (-not $zipOk) {
                try {
                    if ($zipProxy) { Invoke-WebRequest -Uri $url -OutFile $ZipPath -Proxy $zipProxy -UseBasicParsing -ErrorAction Stop }
                    else { Invoke-WebRequest -Uri $url -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop }
                } catch { Write-Log "下载失败：$_" "ERROR"; $ExitCode = 1; return }
            }
        }
        Expand-ZipRobust -ZipPath $ZipPath -DestPath $AppDir | Out-Null
        if (-not (Test-Path $OllamaExe)) {
            $Nested = Get-ChildItem $AppDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($Nested -and (Test-Path (Join-Path $Nested.FullName "ollama.exe"))) {
                Get-ChildItem $Nested.FullName | Move-Item -Destination $AppDir -Force
                Remove-Item $Nested.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not (Test-Path $OllamaExe)) { Write-Log "解压后未找到 ollama.exe" "ERROR"; $ExitCode = 1; return }
    }

    Write-Log "===== 3. 创建启动器 =====" "INFO"
    $LauncherContent = @'
@echo off
setlocal enabledelayedexpansion
title Ollama Portable
cd /d "%~dp0"
set "OLLAMA_MODELS=%~dp0Data\models"
set "OLLAMA_PORT=11434"
set "OLLAMA_EXE=%~dp0App\ollama.exe"
if not exist "%OLLAMA_MODELS%" mkdir "%OLLAMA_MODELS%"
if not exist "%OLLAMA_EXE%" ( echo [ERROR] ollama.exe not found & pause & exit /b 1 )
:check_port
set "OCCUPIED_PID="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%OLLAMA_PORT% " ^| findstr "LISTENING"') do set "OCCUPIED_PID=%%a"
if not defined OCCUPIED_PID goto start_ollama
echo [WARN] Port %OLLAMA_PORT% used by PID !OCCUPIED_PID!
tasklist /FI "PID eq !OCCUPIED_PID!" /FO LIST
set "IS_OLLAMA="
for /f "tokens=1" %%b in ('tasklist /FI "PID eq !OCCUPIED_PID!" /NH /FO CSV 2^>nul') do ( echo %%~b | findstr /I "ollama" >nul && set "IS_OLLAMA=1" )
if defined IS_OLLAMA ( taskkill /F /PID !OCCUPIED_PID! >nul 2>&1 & timeout /t 2 /nobreak >nul & goto check_port )
echo   [1] Kill  [2] Change port  [3] Exit
choice /C 123 /N /M "Choice: "
if errorlevel 3 exit /b 1
if errorlevel 2 goto change_port
taskkill /F /PID !OCCUPIED_PID! & timeout /t 2 /nobreak >nul & goto check_port
:change_port
set "NEW_PORT="
set /p "NEW_PORT=New port (default 11435): "
if not defined NEW_PORT set "NEW_PORT=11435"
echo !NEW_PORT!| findstr /R "^[0-9][0-9]*$" >nul || ( echo [ERROR] Invalid port & goto change_port )
if !NEW_PORT! GTR 65535 ( echo [ERROR] Port out of range & goto change_port )
set "OLLAMA_PORT=!NEW_PORT!"
goto check_port
:start_ollama
rem Ollama reads OLLAMA_HOST, not OLLAMA_PORT
set "OLLAMA_HOST=127.0.0.1:%OLLAMA_PORT%"
echo Starting on %OLLAMA_HOST% ...
"%OLLAMA_EXE%" serve
pause
'@
    Set-Content -Path $Launcher -Value $LauncherContent -Encoding ASCII
    Write-Log "启动器：$Launcher" "INFO"

    Write-Log "===== 4. 代理探测（Clash / V2Ray 候选轮询） =====" "INFO"
    $ProxyUrl = $null
    if ($EnableProxy) { $ProxyUrl = Get-WorkingProxy -TimeoutSec $ProxyTestTimeout }

    Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:ALL_PROXY -ErrorAction SilentlyContinue

    if ($ProxyUrl) {
        $env:HTTP_PROXY  = $ProxyUrl
        $env:HTTPS_PROXY = $ProxyUrl
        $env:NO_PROXY    = "localhost,127.0.0.1,::1"
        Write-Log "代理可用，设置 HTTP_PROXY/HTTPS_PROXY = $ProxyUrl" "INFO"
    } else {
        Write-Log "所有代理候选均不可用！registry.ollama.ai 在国内无法直连" "WARN"
        if ($EnableAccelSource) {
            Write-Log "将走加速源次选方案：$AccelBaseUrl 下载 GGUF + ollama create" "WARN"
        } else {
            Write-Log "加速源已禁用，下载大概率失败，建议先启动 Clash 或 V2Ray" "WARN"
        }
    }

    Write-Log "===== 5. 启动服务 =====" "INFO"
    $portOk = Resolve-PortConflict -Port $OllamaPort
    if (-not $portOk) { Write-Log "端口冲突，无法启动服务" "ERROR"; $ExitCode = 1; return }

    $env:OLLAMA_MODELS = $ModelsDir
    $env:OLLAMA_HOST   = "http://127.0.0.1:$OllamaPort"
    $env:OLLAMA_DEBUG  = "1"

    Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
    if (-not (Get-NetTCPConnection -LocalPort $OllamaPort -State Listen -ErrorAction SilentlyContinue)) {
        Write-Log "端口未监听，请手动运行 启动Ollama.bat 检查" "ERROR"
        $ExitCode = 1; return
    }
    Write-Log "Ollama 已监听 $OllamaPort" "INFO"

    # 检测到上次中断的断点缓存时，询问续传还是清缓存重下
    Resolve-CachePolicy

    Write-Log "===== 6. 逐槽位部署（主选失败自动切换备选） =====" "INFO"
    $slotIndex = 0
    foreach ($group in $ModelGroups) {
        $slotIndex++
        Write-Log "" "INFO"
        Write-Log "### 槽位 $slotIndex / $($ModelGroups.Count)，候选模型：$($group -join ', ')" "INFO"

        $deployedModel = $null
        foreach ($M in $group) {
            Write-Log ">>> 尝试模型：$M" "INFO"

            # 检查是否已经存在且完整
            & $OllamaExe show $M *> $null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "已存在且完整，跳过下载" "INFO"
            } else {
                # 下载前清理该模型的失败缓存
                Clear-FailedCache -ModelName $M

                # 多策略降级下载（便携包原生 ollama pull 优先）
                $pulled = $false

                # 无代理时直连 registry 必死，优先走加速源
                if (-not $ProxyUrl -and $EnableAccelSource) {
                    Write-Log "--- 加速源策略：hf-mirror GGUF + ollama create（无代理次选） ---" "INFO"
                    $pulled = Invoke-HfMirrorPull -ModelName $M -MaxTries $Aria2MaxTries
                }

                if (-not $pulled) {
                    Write-Log "--- 策略一：便携包原生 ollama pull ---" "INFO"
                    $pulled = Invoke-OllamaPull -ModelName $M
                }

                if (-not $pulled) {
                    Write-Log "--- 策略二：pullama（多线程断点续传） ---" "INFO"
                    $pulled = Invoke-PullamaPull -ModelName $M -MaxRetries $PullamaMaxRetries -RetryDelay $PullamaRetryDelay
                }

                if (-not $pulled) {
                    Write-Log "--- 策略三：aria2c 直连 blob ---" "INFO"
                    $pulled = Invoke-Aria2Pull -ModelName $M -MaxTries $Aria2MaxTries
                }

                if (-not $pulled) {
                    Write-Log "[跳过] $M 所有下载策略均失败，尝试下一个候选模型" "WARN"
                    continue
                }
            }

            # 验证
            $result = Test-OllamaModel -Exe $OllamaExe -ModelName $M -Port $OllamaPort
            if ($result.Ok) {
                Write-Log "[成功] $M 部署完成" "INFO"
                $deployedModel = $M
                break
            } else {
                Write-Log "[跳过] $M 验证失败：$($result.Reason)，尝试下一个候选模型" "WARN"
                continue
            }
        }

        if (-not $deployedModel) {
            Write-Log "[失败] 槽位 $slotIndex 的所有候选模型均不可用" "ERROR"
            $ExitCode = 1
            return
        }

        Write-Log "槽位 $slotIndex 最终部署：$deployedModel" "INFO"
    }

    Write-Log "" "INFO"
    Write-Log "===== 部署完成 =====" "INFO"
    Write-Log "模型目录：$ModelsDir" "INFO"
    Write-Log "启动器：  $Launcher" "INFO"
    Write-Log "API：     http://127.0.0.1:$OllamaPort" "INFO"
} catch {
    Write-Log "未捕获异常：$_" "ERROR"
    Write-Log $_.ScriptStackTrace "DEBUG"
    $ExitCode = 1
} finally {
    try { Stop-Transcript | Out-Null } catch {}
    Write-Log "日志已写入：$LogPath" "INFO"
    if (-not $NoPause) {
        Write-Host "按回车关闭..." -ForegroundColor Cyan
        Read-Host | Out-Null
    }
    # 放在 finally 里：即使主流程用 return 提前退出，退出码也能正确传出
    exit $ExitCode
}
