#!/usr/bin/env pwsh
<#
.SYNOPSIS
    与 ClassIsland 软件联动：自动读取其配置中的 TimeOffsetSeconds，并调用 UniversalTime.ps1 设置系统时间延迟。
.DESCRIPTION
    本脚本需要 PowerShell 7 或更高版本，并以管理员身份运行。
    工作流程：
    1. 优先从本地配置文件读取 Settings.json 的路径和 Debug 模式。
    2. 若缓存无效，则同时尝试两种方式定位 Settings.json：
       - 非兼容模式（ClassIsland 2.x+）：通过 ClassIsland.Desktop.exe 进程，取父目录下的 data\Settings.json。
       - 兼容模式（ClassIsland 1.x）：通过 ClassIsland.exe 进程，取进程同目录下的 Settings.json。
       若两者都找到，比较 TimeOffsetSeconds，不一致时警告，并使用非兼容模式的值及路径。
    3. 读取选中的 Settings.json 中的 TimeOffsetSeconds 数值。
    4. 调用同目录下的 UniversalTime.ps1，传递 -DelaySeconds 参数。
    5. 成功读取后，将选中的 Settings.json 绝对路径和 Debug 模式保存到配置文件。
    6. 根据 Debug 配置，决定是否显示控制台窗口及记录日志。
    7. 若未能定位有效配置，则尝试通过 classisland://app/ 启动 ClassIsland，循环检测进程并读取配置，
       成功后杀死进程继续执行；若最终失败则弹出图形提示框并退出。
.NOTES
    必须使用管理员权限运行（因为 UniversalTime.ps1 需要修改系统时间）。
    请确保 UniversalTime.ps1 与本脚本放在同一目录下。
#>

# 要求 PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "错误: 本脚本需要 PowerShell 7 或更高版本。请使用 pwsh.exe 运行。" -ForegroundColor Red
    exit 1
}

# ---------- 配置 ----------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFilePath = Join-Path $scriptDir "ClassIslandUniversalTime.json"
$universalScriptPath = Join-Path $scriptDir "UniversalTime.ps1"
$logFilePath = Join-Path $scriptDir "ClassIslandUniversalTime.log"

# 等待 ClassIsland 启动的最大秒数
$maxWaitSeconds = 15

# ---------- 读取配置 ----------
$debugMode = $false   # 默认 false
$cachedSettingsPath = $null
$cachedNtpServer = $null
$cachedCompensationSeconds = $null

if (Test-Path $configFilePath) {
    try {
        $config = Get-Content $configFilePath -Raw | ConvertFrom-Json
        if ($null -ne $config.Debug) {
            $debugMode = [bool]$config.Debug
        }
        $cachedSettingsPath = $config.SettingsJsonPath
        $cachedNtpServer = $config.NtpServer
        if ($null -ne $config.CompensationSeconds) {
            $cachedCompensationSeconds = [double]$config.CompensationSeconds
        }
    }
    catch {
        # 静默失败，后续按默认处理
    }
}

# ---------- 日志函数（仅在 Debug 模式下写入文件）----------
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    if ($debugMode) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logMessage = "[$timestamp] $Message"
        Add-Content -Path $logFilePath -Value $logMessage -ErrorAction SilentlyContinue
        Write-Host $logMessage -ForegroundColor $Color
    }
    else {
        # 非调试模式，不写日志也不输出到控制台（但为了必要的错误提示，可以输出错误）
        if ($Color -eq "Red") {
            Write-Host $Message -ForegroundColor Red
        }
    }
}

# ---------- 根据 Debug 模式控制窗口显示 ----------
if (-not $debugMode) {
    # 调试模式关闭：隐藏控制台窗口
    $isHidden = $false
    $myCommandLine = [Environment]::CommandLine
    if ($myCommandLine -match '-WindowStyle\s+Hidden') {
        $isHidden = $true
    }
    if (-not $isHidden) {
        $scriptPath = $MyInvocation.MyCommand.Path
        $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
        try {
            Start-Process -FilePath "pwsh.exe" -Verb RunAs -ArgumentList $arguments
        }
        catch {
            Start-Process -FilePath "pwsh.exe" -ArgumentList $arguments
        }
        exit 0
    }
}

# ---------- 管理员权限检查与提升 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Log "正在请求管理员权限..." -Color Yellow
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    if (-not $debugMode) {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    }
    try {
        Start-Process -FilePath "pwsh.exe" -Verb RunAs -ArgumentList $arguments -Wait
    }
    catch {
        Write-Log "无法提升权限，请手动以管理员身份运行 PowerShell 7。" -Color Red
        exit 1
    }
    exit 0
}

# ---------- 辅助函数：从 Settings.json 读取 TimeOffsetSeconds ----------
function Get-TimeOffsetFromSettingsJson {
    param([string]$settingsJsonPath)
    if (-not (Test-Path $settingsJsonPath)) {
        Write-Log "文件不存在: $settingsJsonPath" -Color Red
        return $null
    }
    try {
        $settings = Get-Content $settingsJsonPath -Raw | ConvertFrom-Json
        $offset = $settings.TimeOffsetSeconds
        if ($null -eq $offset) {
            Write-Log "Settings.json 中未找到 TimeOffsetSeconds 字段: $settingsJsonPath" -Color Yellow
            return $null
        }
        $offsetNum = 0.0
        if ([double]::TryParse($offset, [ref]$offsetNum)) {
            Write-Log "成功读取 TimeOffsetSeconds = $offsetNum 从 $settingsJsonPath" -Color Green
            return $offsetNum
        }
        else {
            Write-Log "TimeOffsetSeconds 值 '$offset' 不是有效数字，视为无效。路径: $settingsJsonPath" -Color Red
            return $null
        }
    }
    catch {
        Write-Log "读取 Settings.json 失败: $_，路径: $settingsJsonPath" -Color Red
        return $null
    }
}

# ---------- 主逻辑：确定 Settings.json 路径和 TimeOffsetSeconds ----------
$settingsPath = $null
$timeOffset = $null

# 优先使用缓存路径
if ($cachedSettingsPath -and (Test-Path $cachedSettingsPath)) {
    $settingsPath = $cachedSettingsPath
    Write-Log "尝试使用缓存的 Settings.json 路径: $settingsPath" -Color Cyan
    $timeOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $settingsPath
    if ($null -eq $timeOffset) {
        Write-Log "缓存的 Settings.json 读取失败或 TimeOffsetSeconds 无效，将重新检测。" -Color Yellow
        $settingsPath = $null
    }
}

# 如果没有有效缓存，则同时尝试两种模式
if (-not $settingsPath) {
    Write-Log "未找到有效缓存，正在检测 ClassIsland 进程..." -Color Cyan

    # 非兼容模式: ClassIsland.Desktop.exe -> ..\data\Settings.json
    $modernSettingsPath = $null
    $modernProcess = Get-Process -Name "ClassIsland.Desktop" -ErrorAction SilentlyContinue
    if ($modernProcess) {
        $modernExePath = $modernProcess[0].Path
        if ($modernExePath) {
            $modernDir = Split-Path -Parent $modernExePath
            $parentDir = Split-Path -Parent $modernDir
            $modernSettingsPath = Join-Path $parentDir "data\Settings.json"
            Write-Log "非兼容模式（2.x）预期路径: $modernSettingsPath" -Color Gray
        }
    }

    # 兼容模式: ClassIsland.exe -> 同目录 Settings.json
    $legacySettingsPath = $null
    $legacyProcess = Get-Process -Name "ClassIsland" -ErrorAction SilentlyContinue
    if ($legacyProcess) {
        $legacyExePath = $legacyProcess[0].Path
        if ($legacyExePath) {
            $legacyDir = Split-Path -Parent $legacyExePath
            $legacySettingsPath = Join-Path $legacyDir "Settings.json"
            Write-Log "兼容模式（1.x）预期路径: $legacySettingsPath" -Color Gray
        }
    }

    # 读取两种模式的偏移值
    $modernOffset = $null
    $legacyOffset = $null
    $modernValid = $false
    $legacyValid = $false

    if ($modernSettingsPath -and (Test-Path $modernSettingsPath)) {
        $modernOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $modernSettingsPath
        if ($null -ne $modernOffset) {
            $modernValid = $true
            Write-Log "非兼容模式读取成功，TimeOffsetSeconds = $modernOffset" -Color Green
        }
    }
    if ($legacySettingsPath -and (Test-Path $legacySettingsPath)) {
        $legacyOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $legacySettingsPath
        if ($null -ne $legacyOffset) {
            $legacyValid = $true
            Write-Log "兼容模式读取成功，TimeOffsetSeconds = $legacyOffset" -Color Green
        }
    }

    # 决策逻辑
    if ($modernValid -and $legacyValid) {
        if ($modernOffset -ne $legacyOffset) {
            Write-Log "警告: 两种模式读取的 TimeOffsetSeconds 不一致！非兼容模式: $modernOffset, 兼容模式: $legacyOffset" -Color Yellow
            Write-Log "将使用非兼容模式的值: $modernOffset" -Color Cyan
        }
        $timeOffset = $modernOffset
        $settingsPath = $modernSettingsPath
    }
    elseif ($modernValid) {
        $timeOffset = $modernOffset
        $settingsPath = $modernSettingsPath
        Write-Log "仅非兼容模式有效，使用该配置。" -Color Cyan
    }
    elseif ($legacyValid) {
        $timeOffset = $legacyOffset
        $settingsPath = $legacySettingsPath
        Write-Log "仅兼容模式有效，使用该配置。" -Color Cyan
    }
    else {
        # ---------- 新增功能：尝试启动 ClassIsland 并等待配置文件生成 ----------
        Write-Log "未检测到有效的 Settings.json，尝试启动 ClassIsland..." -Color Yellow

        # 1. 尝试通过协议 URI 启动 ClassIsland
        try {
            Start-Process "classisland://app/"
            Write-Log "已通过 classisland://app/ 尝试启动 ClassIsland" -Color Cyan
        }
        catch {
            Write-Log "无法启动 ClassIsland (协议未注册或启动失败): $_" -Color Red
            # 继续下面的逻辑，但进程检测会失败，最终弹出提示框
        }

        # 2. 循环检测进程，最多等待 $maxWaitSeconds 秒
        $startTime = Get-Date
        $processFound = $false
        $foundSettingsPath = $null
        $foundTimeOffset = $null

        while ((Get-Date) - $startTime -lt [TimeSpan]::FromSeconds($maxWaitSeconds)) {
            $modernProc = Get-Process -Name "ClassIsland.Desktop" -ErrorAction SilentlyContinue
            $legacyProc = Get-Process -Name "ClassIsland" -ErrorAction SilentlyContinue
            $targetProc = $null
            $isModern = $false

            if ($modernProc) {
                $targetProc = $modernProc[0]
                $isModern = $true
                Write-Log "检测到 ClassIsland.Desktop 进程" -Color Cyan
            }
            elseif ($legacyProc) {
                $targetProc = $legacyProc[0]
                $isModern = $false
                Write-Log "检测到 ClassIsland 进程" -Color Cyan
            }

            if ($targetProc) {
                # 获取 Settings.json 路径
                $exePath = $targetProc.Path
                if ($exePath) {
                    if ($isModern) {
                        $procDir = Split-Path -Parent $exePath
                        $parentDir = Split-Path -Parent $procDir
                        $candidatePath = Join-Path $parentDir "data\Settings.json"
                    }
                    else {
                        $procDir = Split-Path -Parent $exePath
                        $candidatePath = Join-Path $procDir "Settings.json"
                    }

                    Write-Log "尝试读取配置: $candidatePath" -Color Gray
                    # 给文件一点写入时间
                    Start-Sleep -Milliseconds 500
                    $candidateOffset = Get-TimeOffsetFromSettingsJson -settingsJsonPath $candidatePath

                    if ($null -ne $candidateOffset) {
                        $foundSettingsPath = $candidatePath
                        $foundTimeOffset = $candidateOffset
                        Write-Log "成功从启动的 ClassIsland 获取到 TimeOffsetSeconds = $foundTimeOffset" -Color Green

                        # 杀死进程
                        try {
                            Stop-Process -Id $targetProc.Id -Force -ErrorAction Stop
                            Write-Log "已杀死 ClassIsland 进程 (PID: $($targetProc.Id))" -Color Cyan
                        }
                        catch {
                            Write-Log "警告: 无法杀死进程: $_" -Color Yellow
                        }
                        $processFound = $true
                        break
                    }
                    else {
                        Write-Log "当前进程的配置文件无效或尚未生成，继续等待..." -Color Gray
                    }
                }
                else {
                    Write-Log "无法获取进程路径" -Color Gray
                }
            }

            Start-Sleep -Seconds 1
        }

        if ($processFound -and $foundSettingsPath -and $null -ne $foundTimeOffset) {
            $settingsPath = $foundSettingsPath
            $timeOffset = $foundTimeOffset
            Write-Log "通过启动 ClassIsland 成功获得有效配置，继续执行。" -Color Green
        }
        else {
            # 最终失败：弹出 WinForms 提示框（支持高 DPI），然后退出
            Write-Log "无法通过任何方式获取有效的 Settings.json，即将弹出提示框并退出。" -Color Red

            Add-Type -AssemblyName System.Windows.Forms
            # 启用视觉样式以支持高 DPI 缩放
            [System.Windows.Forms.Application]::EnableVisualStyles()

            $message = "未能识别到有效的 ClassIsland 配置文件（Settings.json）。`n`n" +
            "请确保 ClassIsland 已正确安装，且配置文件包含 TimeOffsetSeconds 字段。`n" +
            "您可以手动启动 ClassIsland 后再运行此脚本。"

            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "ClassIsland 联动 - 错误",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )

            exit 2
        }
    }
}

# 此时应有有效的时间和路径
if ($null -eq $timeOffset) {
    Write-Log "错误: 未能获取有效的 TimeOffsetSeconds，脚本退出。" -Color Red
    exit 4
}

Write-Log "最终使用的 TimeOffsetSeconds = $timeOffset 秒" -Color Green
Write-Log "使用的 Settings.json 路径: $settingsPath" -Color Cyan

# ---------- 保存配置（包含 Settings.json 路径、Debug 模式、NTP 服务器和补偿值）----------
try {
    $configToSave = @{
        Debug                 = $debugMode
        SettingsJsonPath      = $settingsPath
        NtpServer             = if ($cachedNtpServer) { $cachedNtpServer } else { "ntp.aliyun.com" }
        CompensationSeconds   = if ($null -ne $cachedCompensationSeconds) { $cachedCompensationSeconds } else { 0.0 }
    }
    $configToSave | ConvertTo-Json | Set-Content $configFilePath -Force
    Write-Log "已将配置保存到: $configFilePath" -Color Green
}
catch {
    Write-Log "警告: 保存配置文件失败: $_" -Color Yellow
}

# ---------- 调用 UniversalTime.ps1 ----------
if (-not (Test-Path $universalScriptPath)) {
    Write-Log "错误: 未找到 UniversalTime.ps1 脚本，请确保它与本脚本放在同一目录下。" -Color Red
    exit 5
}

Write-Log "正在调用 UniversalTime.ps1 -DelaySeconds $timeOffset ..." -Color Cyan
try {
    # 构建参数列表
    $params = @{ DelaySeconds = $timeOffset }
    if ($cachedNtpServer) {
        $params.NtpServer = $cachedNtpServer
    }
    if ($null -ne $cachedCompensationSeconds) {
        $params.CompensationSeconds = $cachedCompensationSeconds
    }
    # 使用 splatting 方式调用，避免参数解析问题
    & $universalScriptPath @params
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Log "UniversalTime.ps1 执行返回非零退出码: $exitCode" -Color Yellow
    }
    else {
        Write-Log "UniversalTime.ps1 执行成功。" -Color Green
    }
    exit $exitCode
}
catch {
    Write-Log "执行 UniversalTime.ps1 时发生错误: $_" -Color Red
    exit 6
}
