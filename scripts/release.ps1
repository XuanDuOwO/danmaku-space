<#
.SYNOPSIS
    弹幕空间（danmaku）一键发版：改版本号 → 构建 APK → 建 Gitee Release → 上传 APK 附件。

.DESCRIPTION
    本脚本是**本地**发布流程。之所以不用 Gitee Go 流水线：
    Gitee 的 CI 需要额外开通且 APK 附件上传在流水线里不好处理，
    而 Releases API 用私人令牌在本机跑一次就够，且发布的每一步都看得见。

    它会做这几件事（按顺序）：
      1. 校验版本号格式，确认工作区没有未提交改动（除非 -AllowDirty）；
      2. 把 pubspec.yaml 的 version 与 lib/core/updater.dart 的 kAppVersion
         一起改成同一个值 —— 这两处漂移过一次，必须脚本化；
      3. flutter build apk --release；
      4. 调 Gitee API 建 tag + Release，并上传 APK 作为附件；
      5. 打印 Release 地址与 APK 直链。

.PARAMETER Version
    要发布的版本号，形如 1.0.9（不带 v，也不带 +build）。

.PARAMETER BuildNumber
    Android versionCode。默认 = 上一个 build + 1，从 pubspec 里读。

.PARAMETER Notes
    Release 说明。默认取最近一次 git commit 的标题与正文。

.PARAMETER TokenFile
    Gitee 令牌文件，默认 C:\Users\Administrator\Documents\令牌\gitee令牌.txt
    第一行格式为「私人<token>」。

.PARAMETER AllowDirty
    允许工作区有未提交改动时继续（默认不允许，避免发布了没进版本库的代码）。

.PARAMETER SkipBuild
    跳过构建，直接用已有的 build\app\outputs\flutter-apk\app-release.apk
    （调试上传流程时用）。

.EXAMPLE
    pwsh scripts/release.ps1 -Version 1.1.0

.EXAMPLE
    pwsh scripts/release.ps1 -Version 1.1.1 -Notes "修复在线人数偶发不刷新"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [int]$BuildNumber = 0,
    [string]$Notes = '',
    [string]$TokenFile = 'C:\Users\Administrator\Documents\令牌\gitee令牌.txt',
    [switch]$AllowDirty,
    [switch]$SkipBuild,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- 常量

$Repo        = 'xuanduckl/danmaku'
$ApiBase     = 'https://gitee.com/api/v5'
$Tag         = "v$Version"
$ApkName     = "danmaku-$Tag.apk"

$Root        = Split-Path -Parent $PSScriptRoot
$Pubspec     = Join-Path $Root 'pubspec.yaml'
$UpdaterDart = Join-Path $Root 'lib\core\updater.dart'
$ApkPath     = Join-Path $Root 'build\app\outputs\flutter-apk\app-release.apk'

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 前置检查

Write-Step "前置检查"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "版本号必须是 x.y.z 形式，收到：$Version"
}

# 用 .NET 读写，避免 PowerShell 5.1 的 Set-Content 把 UTF-8 中文写成 ANSI 乱码。
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-Text([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Text([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $Utf8NoBom) }

if (-not (Test-Path $Pubspec)) { throw "找不到 pubspec.yaml：$Pubspec" }

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
    # 本机的 git 不在 PATH 上，按已知安装位置兜底。
    foreach ($c in @('C:\DevelopTools\git\cmd\git.exe', "$env:ProgramFiles\Git\cmd\git.exe")) {
        if (Test-Path $c) { $git = Get-Item $c; break }
    }
}
if ($null -eq $git) { throw '找不到 git，请先安装或把 git.exe 加进 PATH。' }
$GitExe = $git.FullName

Push-Location $Root
try {
    $dirty = & $GitExe status --porcelain
    if ($dirty -and -not $AllowDirty) {
        Write-Host $dirty
        throw '工作区有未提交改动。先提交，或加 -AllowDirty 强制继续。'
    }
    Write-Ok "工作区干净（分支 $(& $GitExe rev-parse --abbrev-ref HEAD)）"

    # 读当前 pubspec 版本，推默认 build number
    $pubText = Read-Text $Pubspec
    $m = [regex]::Match($pubText, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $m.Success) { throw 'pubspec.yaml 里没找到形如 "version: 1.0.0+1" 的行。' }
    $oldVer = $m.Groups[1].Value
    $oldBuild = [int]$m.Groups[2].Value
    if ($BuildNumber -le 0) { $BuildNumber = $oldBuild + 1 }
    Write-Ok "版本 $oldVer+$oldBuild  →  $Version+$BuildNumber"

    # ------------------------------------------------------------ 改版本号
    Write-Step "同步版本号"

    $pubText = [regex]::Replace($pubText,
        '(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$',
        "version: $Version+$BuildNumber")
    Write-Text $Pubspec $pubText
    Write-Ok "pubspec.yaml → $Version+$BuildNumber"

    $upd = Read-Text $UpdaterDart
    if ($upd -notmatch "kAppVersion\s*=\s*'[^']*'") {
        throw "updater.dart 里没找到 kAppVersion，无法同步。"
    }
    $upd = [regex]::Replace($upd,
        "kAppVersion\s*=\s*'[^']*'",
        "kAppVersion = '$Version'")
    Write-Text $UpdaterDart $upd
    Write-Ok "lib/core/updater.dart kAppVersion → $Version"

    # ------------------------------------------------------------ 构建
    Write-Step "构建 release APK"
    if ($SkipBuild) {
        Write-Warn2 '已指定 -SkipBuild，跳过构建'
    } else {
        $flutter = Get-Command flutter -ErrorAction SilentlyContinue
        if ($null -eq $flutter) {
            $fb = 'C:\DevelopTools\flutter\bin\flutter.bat'
            if (Test-Path $fb) { $flutter = Get-Item $fb } else { throw '找不到 flutter，请加进 PATH。' }
        }
        & $flutter.FullName pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败' }
        & $flutter.FullName build apk --release
        if ($LASTEXITCODE -ne 0) { throw 'flutter build apk --release 失败' }
    }

    if (-not (Test-Path $ApkPath)) { throw "找不到构建产物：$ApkPath" }
    $apkSize = (Get-Item $ApkPath).Length
    Write-Ok ("APK {0:N1} MB  ({1})" -f ($apkSize / 1MB), $ApkPath)
    if ($apkSize -lt 5MB) { throw "APK 只有 $apkSize 字节，明显不对，已中止发布。" }

    # 校验签名与包名，防止发出去一个装不上的包
    $aapt = Get-ChildItem 'C:\DevelopTools\android-sdk\build-tools\*\aapt2.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
    if ($aapt) {
        $badging = & $aapt.FullName dump badging $ApkPath 2>$null | Select-String '^package:'
        Write-Ok $badging.Line.Trim()
    }

    # ------------------------------------------------------------ 提交版本改动
    Write-Step "提交版本号改动"
    & $GitExe add -- $Pubspec $UpdaterDart
    & $GitExe commit -m "chore(release): $Tag" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn2 '没有可提交的改动（版本号可能已经是这个值）' }
    else { Write-Ok "已提交 chore(release): $Tag" }

    # ------------------------------------------------------------ Gitee Release
    Write-Step "创建 Gitee Release"

    if (-not (Test-Path $TokenFile)) { throw "找不到令牌文件：$TokenFile" }
    $tokenLine = (Read-Text $TokenFile) -split "`r?`n" | Where-Object { $_ -match '^\s*私人' } | Select-Object -First 1
    if (-not $tokenLine) { throw "令牌文件里没找到以「私人」开头的行。" }
    $Token = ($tokenLine -replace '^\s*私人\s*', '').Trim()
    if ($Token.Length -lt 20) { throw '令牌看起来不对（长度过短）。' }

    if ($Notes.Trim().IsEmpty) {
        $Notes = (& $GitExe log -1 --pretty=%B).Trim()
    }
    if ($Notes.Trim().IsEmpty) { $Notes = "弹幕空间 $Tag" }

    # 先推代码，让 tag 指向已经进版本库的 commit
    if (-not $NoPush) {
        & $GitExe push origin HEAD
        if ($LASTEXITCODE -ne 0) { throw 'git push 失败' }
        Write-Ok '代码已推送到 Gitee'
    }

    # 建 Release（Gitee 会顺带建 tag；已存在时会报错，这里做成可重入）
    $releaseId = 0
    $existing = & curl.exe -s "$ApiBase/repos/$Repo/releases/tags/$Tag?access_token=$Token"
    if ($existing -match '"id"\s*:\s*(\d+)') {
        $releaseId = [int]$Matches[1]
        Write-Warn2 "Release $Tag 已存在（id=$releaseId），改为更新说明"
        & curl.exe -s -X PATCH -o NUL `
            --data-urlencode "access_token=$Token" `
            --data-urlencode "name=$Tag" `
            --data-urlencode "body=$Notes" `
            "$ApiBase/repos/$Repo/releases/$releaseId"
    } else {
        $resp = & curl.exe -s -X POST `
            --data-urlencode "access_token=$Token" `
            --data-urlencode "tag_name=$Tag" `
            --data-urlencode "name=$Tag" `
            --data-urlencode "body=$Notes" `
            --data-urlencode "target_commitish=master" `
            "$ApiBase/repos/$Repo/releases"
        if ($resp -match '"id"\s*:\s*(\d+)') {
            $releaseId = [int]$Matches[1]
            Write-Ok "Release $Tag 已创建（id=$releaseId）"
        } else {
            throw "创建 Release 失败：$resp"
        }
    }

    # 上传 APK 附件
    Write-Step "上传 APK 附件"
    $copy = Join-Path ([System.IO.Path]::GetTempPath()) $ApkName
    Copy-Item $ApkPath $copy -Force
    $up = & curl.exe -s -X POST -F "file=@$copy" `
        "$ApiBase/repos/$Repo/releases/$releaseId/attach_files?access_token=$Token"
    Remove-Item $copy -Force -ErrorAction SilentlyContinue
    if ($up -match '"browser_download_url"\s*:\s*"([^"]+)"') {
        $apkUrl = $Matches[1]
        Write-Ok "APK 已上传"
    } else {
        throw "上传 APK 失败：$up"
    }

    # ------------------------------------------------------------ 结果
    Write-Step "发布完成"
    Write-Host "  版本      : $Version (versionCode $BuildNumber)"
    Write-Host "  包名      : cn.local.bili_live_relay"
    Write-Host "  APK 大小  : $([math]::Round($apkSize / 1MB, 1)) MB"
    Write-Host "  Release   : https://gitee.com/$Repo/releases/tag/$Tag"
    Write-Host "  APK 直链  : $apkUrl"
    Write-Host ""
    Write-Host "  客户端「设置 → 检测更新」会读 releases/latest 并比对 kAppVersion。" -ForegroundColor DarkGray
}
finally {
    Pop-Location
}
