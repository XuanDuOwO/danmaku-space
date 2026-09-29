<#
.SYNOPSIS
    弹幕空间（danmaku）一键发版：改版本号 → 构建 APK → Gitee + GitHub 双发布。

.DESCRIPTION
    本脚本是**本地**发布流程。之所以不用 CI 流水线：
    APK 附件上传在流水线里不好处理，而且本机跑一次每一步都看得见。

    它会做这几件事（按顺序）：
      1. 校验版本号格式，确认工作区没有未提交改动（除非 -AllowDirty）；
      2. 把 pubspec.yaml 的 version 与 lib/core/updater.dart 的 kAppVersion
         一起改成同一个值 —— 这两处漂移过一次，必须脚本化；
      3. flutter build apk --release；
      4. 推送代码到 Gitee(origin) 与 GitHub(github)；
      5. 在两边各建 tag + Release，并上传同一个 APK 作为附件；
      6. 打印两边地址与 APK 直链。

    客户端只读 Gitee（见 lib/core/updater.dart 的 kGiteeRepo），
    GitHub 那份是**镜像备份** —— 以 Gitee 访问更稳。

.PARAMETER Version
    要发布的版本号，形如 1.0.9（不带 v，也不带 +build）。

.PARAMETER BuildNumber
    Android versionCode。默认 = 上一个 build + 1，从 pubspec 里读。

.PARAMETER Notes
    Release 说明。默认取最近一次 git commit 的标题与正文。

.PARAMETER TokenFile
    Gitee 令牌文件，默认 C:\Users\Administrator\Documents\令牌\gitee令牌.txt
    第一行格式为「私人<token>」。

.PARAMETER GithubTokenFile
    GitHub 令牌文件，默认 C:\Users\Administrator\Documents\github令牌.txt。

.PARAMETER GiteeRepo
    Gitee 仓库 owner/repo。

.PARAMETER GithubRepo
    GitHub 仓库 owner/repo。留空 = 跳过 GitHub。

.PARAMETER AllowDirty
    允许工作区有未提交改动时继续（默认不允许，避免发布了没进版本库的代码）。

.PARAMETER SkipBuild
    跳过构建，直接用已有的 build\app\outputs\flutter-apk\app-release.apk
    （调试上传流程时用）。

.PARAMETER SkipGithub
    只发 Gitee，不发 GitHub。

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
    [string]$GithubTokenFile = 'C:\Users\Administrator\Documents\github令牌.txt',
    [string]$GiteeRepo = 'xuanduckl/danmaku',
    [string]$GithubRepo = 'XuanDuOwO/danmaku-space',
    [switch]$AllowDirty,
    [switch]$SkipBuild,
    [switch]$SkipGithub,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- 常量

$Repo        = $GiteeRepo
$ApiBase     = 'https://gitee.com/api/v5'
$GhApiBase   = 'https://api.github.com'
$Tag         = "v$Version"
$ApkName     = "danmaku-${Tag}.apk"

$Root        = Split-Path -Parent $PSScriptRoot
$Pubspec     = Join-Path $Root 'pubspec.yaml'
$UpdaterDart = Join-Path $Root 'lib\core\updater.dart'
$ApkPath     = Join-Path $Root 'build\app\outputs\flutter-apk\app-release.apk'

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "  !!  $msg" -ForegroundColor Yellow }

# 调用外部程序并返回退出码。
#
# 关键点：**不要**写成 `& $exe ... 2>&1 | Out-Null`。
# PowerShell 5.1 会把重定向进来的 stderr 变成 ErrorRecord，配合
# $ErrorActionPreference='Stop' 会直接抛终止错误 —— git push 在
# "Everything up-to-date" 时会往 stderr 写一行，于是明明成功却报错退出。
# 这里让 stderr 原样打到控制台，只取退出码。
function Invoke-Native([string]$exe, [string[]]$nativeArgs) {
    & $exe @nativeArgs
    return $LASTEXITCODE
}

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

# 定位 git.exe。
# 注意 Get-Command 返回的是 ApplicationInfo（有 Source，没有 FullName），
# 而 Get-Item 返回 FileInfo（有 FullName）—— 两个都要能取到路径。
$GitExe = ''
$cmd = Get-Command git -ErrorAction SilentlyContinue
if ($cmd) { $GitExe = $cmd.Source }
if (-not $GitExe) {
    # PATH 上没有就按已知安装位置兜底。
    foreach ($c in @('C:\DevelopTools\git\cmd\git.exe', "$env:ProgramFiles\Git\cmd\git.exe")) {
        if (Test-Path $c) { $GitExe = $c; break }
    }
}
if (-not $GitExe) { throw '找不到 git，请先安装或把 git.exe 加进 PATH。' }

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
        # 同样注意 ApplicationInfo.Source vs FileInfo.FullName 的差异。
        $FlutterExe = ''
        $fc = Get-Command flutter -ErrorAction SilentlyContinue
        if ($fc) { $FlutterExe = $fc.Source }
        if (-not $FlutterExe) {
            $fb = 'C:\DevelopTools\flutter\bin\flutter.bat'
            if (Test-Path $fb) { $FlutterExe = $fb } else { throw '找不到 flutter，请加进 PATH。' }
        }
        & $FlutterExe pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败' }
        & $FlutterExe build apk --release
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
        if ($badging) { Write-Ok $badging.Line.Trim() }
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

    # 注意：PowerShell 5.1 的 String 没有 .IsEmpty 属性（那是 .NET Core 才有的），
    # 这里统一用 .Length -eq 0 判断。
    if ($Notes.Trim().Length -eq 0) {
        # 默认取「最近的、不是发版本身产生的」提交标题，拼成变更列表。
        # 直接用最后一次提交会经常拿到 chore(release) 自己，说明栏毫无信息量。
        $subjects = & $GitExe log -20 --pretty=%s |
            Where-Object { $_ -notmatch '^chore\(release\)' -and $_ -notmatch '^fix\(release\)' } |
            Select-Object -First 12
        if ($subjects) { $Notes = ($subjects | ForEach-Object { "- $_" }) -join "`n" }
    }
    if ($Notes.Trim().Length -eq 0) { $Notes = "弹幕空间 $Tag" }

    # 先推代码，让 tag 指向已经进版本库的 commit
    if (-not $NoPush) {
        & $GitExe push origin HEAD
        if ($LASTEXITCODE -ne 0) { throw 'git push（Gitee）失败' }
        Write-Ok '代码已推送到 Gitee'
    }

    $releaseId = 0
    # 用 ${Tag} 而不是 $Tag —— 紧跟其后的 ? 会被 PowerShell 当成变量名的一部分。
    $existing = & curl.exe -s "$ApiBase/repos/$Repo/releases/tags/${Tag}?access_token=$Token"
    if ($existing -match '"id"\s*:\s*(\d+)') {
        $releaseId = [int]$Matches[1]
        Write-Warn2 "Gitee Release $Tag 已存在（id=$releaseId），改为更新说明"
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
            Write-Ok "Gitee Release $Tag 已创建（id=$releaseId）"
        } else {
            throw "创建 Gitee Release 失败：$resp"
        }
    }

    # 上传 APK 附件到 Gitee
    Write-Step "上传 APK 附件到 Gitee"
    $copy = Join-Path ([System.IO.Path]::GetTempPath()) $ApkName
    Copy-Item $ApkPath $copy -Force
    $up = & curl.exe -s -X POST -F "file=@$copy" `
        "$ApiBase/repos/$Repo/releases/$releaseId/attach_files?access_token=$Token"
    if ($up -match '"browser_download_url"\s*:\s*"([^"]+)"') {
        $apkUrl = $Matches[1]
        Write-Ok "APK 已上传到 Gitee"
    } else {
        throw "上传 APK 到 Gitee 失败：$up"
    }

    # ------------------------------------------------------------ GitHub 镜像
    $ghUrl = ''
    if (-not $SkipGithub -and $GithubRepo.Trim().Length -gt 0) {
        Write-Step "发布 GitHub 镜像（$GithubRepo）"
        try {
            if (-not (Test-Path $GithubTokenFile)) { throw "找不到令牌文件：$GithubTokenFile" }
            $ghToken = (Read-Text $GithubTokenFile).Trim()
            if ($ghToken.Length -lt 20) { throw 'GitHub 令牌看起来不对。' }

            # 推代码（GitHub 默认分支叫 main）
            if (-not $NoPush) {
                $rc = Invoke-Native $GitExe @('-c','http.proxy=','-c','https.proxy=','push','github','HEAD:main')
                if ($rc -ne 0) { throw "git push（GitHub）失败，exit=$rc" }
                Write-Ok '代码已推送到 GitHub'
            }

            $ghHeaders = @(
                '-H', "Authorization: Bearer $ghToken",
                '-H', 'User-Agent: dsh',
                '-H', 'Accept: application/vnd.github+json'
            )
            $ghBody = @{ tag_name = $Tag; name = $Tag; body = $Notes; draft = $false; prerelease = $false } |
                ConvertTo-Json -Compress
            $ghBodyFile = Join-Path ([System.IO.Path]::GetTempPath()) 'gh_release_body.json'
            [System.IO.File]::WriteAllText($ghBodyFile, $ghBody, (New-Object System.Text.UTF8Encoding($false)))

            # 已存在就先删掉重建，保证附件是最新的（GitHub 不支持覆盖同名附件）
            $ghExisting = & curl.exe -s --noproxy '*' @ghHeaders `
                "$GhApiBase/repos/$GithubRepo/releases/tags/$Tag"
            if ($ghExisting -match '"id"\s*:\s*(\d+)') {
                $oldId = [int]$Matches[1]
                & curl.exe -s --noproxy '*' -X DELETE @ghHeaders -o NUL `
                    "$GhApiBase/repos/$GithubRepo/releases/$oldId"
                Write-Warn2 "GitHub Release $Tag 已存在，已删除旧版准备重建"
            }

            $ghResp = & curl.exe -s --noproxy '*' -X POST @ghHeaders `
                -H 'Content-Type: application/json' `
                --data-binary "@$ghBodyFile" `
                "$GhApiBase/repos/$GithubRepo/releases"
            Remove-Item $ghBodyFile -Force -ErrorAction SilentlyContinue
            if ($ghResp -match '"id"\s*:\s*(\d+)') {
                $ghReleaseId = [int]$Matches[1]
                Write-Ok "GitHub Release $Tag 已创建（id=$ghReleaseId）"
            } else {
                throw "创建 GitHub Release 失败：$ghResp"
            }

            $ghUp = & curl.exe -s --noproxy '*' -X POST @ghHeaders `
                -H 'Content-Type: application/vnd.android.package-archive' `
                --data-binary "@$copy" `
                "https://uploads.github.com/repos/$GithubRepo/releases/$ghReleaseId/assets?name=$ApkName"
            if ($ghUp -match '"browser_download_url"\s*:\s*"([^"]+)"') {
                $ghUrl = $Matches[1]
                Write-Ok 'APK 已上传到 GitHub'
            } else {
                throw "上传 APK 到 GitHub 失败：$ghUp"
            }
        } catch {
            # GitHub 只是镜像，失败不该让整次发布失败 —— Gitee 那边已经成了。
            Write-Warn2 "GitHub 镜像发布失败（不影响 Gitee）：$($_.Exception.Message)"
            $ghUrl = ''
        }
    }
    Remove-Item $copy -Force -ErrorAction SilentlyContinue

    # ------------------------------------------------------------ 结果
    Write-Step "发布完成"
    Write-Host "  版本      : $Version (versionCode $BuildNumber)"
    Write-Host "  包名      : cn.local.bili_live_relay"
    Write-Host "  APK 大小  : $([math]::Round($apkSize / 1MB, 1)) MB"
    Write-Host "  Gitee     : https://gitee.com/$Repo/releases/tag/$Tag"
    Write-Host "  APK 直链  : $apkUrl"
    if ($ghUrl) {
        Write-Host "  GitHub    : https://github.com/$GithubRepo/releases/tag/$Tag"
        Write-Host "  镜像直链  : $ghUrl"
    }
    Write-Host ""
    Write-Host "  客户端「设置 → 检测更新」读的是 Gitee 的 releases/latest。" -ForegroundColor DarkGray
}
finally {
    Pop-Location
}
