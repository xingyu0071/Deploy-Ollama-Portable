# Cleanup-Ollama-Portable.ps1
# 彻底移除便携版 Ollama（只删脚本目录下的内容）
$ErrorActionPreference = "Continue"

$Root        = $PSScriptRoot
$PortableDir = Join-Path $Root "Ollama_Portable"
$ZipPath     = Join-Path $Root "ollama-windows-amd64.zip"
$GgufCache   = Join-Path $Root "gguf-cache"   # 加速源下载的 GGUF 缓存

Write-Host "===== 清理 Ollama 便携版 =====" -ForegroundColor Cyan
Write-Host "将删除以下内容："
Write-Host "  - 进程：便携版目录下的 ollama 进程（不影响系统安装的其他 ollama）"
Write-Host "  - 目录：$PortableDir"
if (Test-Path $GgufCache) { Write-Host "  - 目录：$GgufCache" }
if (Test-Path $ZipPath) { Write-Host "  - 文件：$ZipPath" }
Write-Host ""

$Confirm = Read-Host "确认继续？(y/N)"
if ($Confirm -notmatch '^[yY]') { Write-Host "已取消。"; exit 0 }

Write-Host "`n===== 1. 停止便携版 Ollama 进程 =====" -ForegroundColor Cyan
$stopped = 0
Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | ForEach-Object {
    # 只停止便携版目录下的进程，避免误伤系统安装版
    if ($_.Path -and $_.Path.StartsWith($PortableDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "  停止 PID $($_.Id)（$($_.Path)）" -ForegroundColor Yellow
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        $stopped++
    }
}
if ($stopped -eq 0) {
    # 兜底：无法获取路径时按名称停（老系统/权限受限场景）
    $fallback = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($fallback) {
        Write-Host "  无法确认进程路径，按名称停止 $($fallback.Count) 个 ollama 进程" -ForegroundColor Yellow
        $fallback | Stop-Process -Force -ErrorAction SilentlyContinue
        $stopped = $fallback.Count
    } else {
        Write-Host "  无运行中的 ollama 进程" -ForegroundColor Gray
    }
}
Start-Sleep -Seconds 2

Write-Host "`n===== 2. 删除便携版目录 =====" -ForegroundColor Cyan
if (Test-Path $PortableDir) {
    $Size = (Get-ChildItem $PortableDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host "  目标：$PortableDir" -ForegroundColor Yellow
    Write-Host "  大小：约 $([math]::Round($Size/1GB, 2)) GB" -ForegroundColor Yellow
    Remove-Item -Path $PortableDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $PortableDir) {
        Write-Host "  [警告] 部分文件删除失败（可能有进程占用），请稍后手动删除：" -ForegroundColor Red
        Get-ChildItem $PortableDir -Recurse -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { Write-Host "    残留：$($_.FullName)" -ForegroundColor Red }
    } else {
        Write-Host "  已删除。" -ForegroundColor Green
    }
} else {
    Write-Host "  目录不存在，跳过。" -ForegroundColor Gray
}

Write-Host "`n===== 3. 删除 GGUF 缓存 =====" -ForegroundColor Cyan
if (Test-Path $GgufCache) {
    $Size = (Get-ChildItem $GgufCache -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host "  大小：约 $([math]::Round($Size/1GB, 2)) GB" -ForegroundColor Yellow
    Remove-Item -Path $GgufCache -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $GgufCache) { Write-Host "  [警告] 删除失败，请手动删除：$GgufCache" -ForegroundColor Red }
    else { Write-Host "  已删除。" -ForegroundColor Green }
} else {
    Write-Host "  缓存目录不存在，跳过。" -ForegroundColor Gray
}

Write-Host "`n===== 4. 删除下载的压缩包 =====" -ForegroundColor Cyan
if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force -ErrorAction SilentlyContinue
    if (Test-Path $ZipPath) { Write-Host "  [警告] 删除失败：$ZipPath" -ForegroundColor Red }
    else { Write-Host "  已删除：$ZipPath" -ForegroundColor Green }
} else {
    Write-Host "  压缩包不存在，跳过。" -ForegroundColor Gray
}

Write-Host "`n===== 清理完成 =====" -ForegroundColor Green
Write-Host "便携版未修改系统环境变量、防火墙或默认 .ollama 目录，无需额外清理。" -ForegroundColor DarkGray
Write-Host "（如需连部署日志一起删除，可手动删除 $Root\deploy.log）" -ForegroundColor DarkGray