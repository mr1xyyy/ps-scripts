$ErrorActionPreference = 'Stop'
$env:PYTHONDONTWRITEBYTECODE = '1'
$script:UiStep = 0
$script:UiTotalSteps = 6

function Write-UiHeader([string]$Text) {
    $script:UiStep++
    $stepLabel = '[{0}/{1}]' -f $script:UiStep.ToString('00'), $script:UiTotalSteps.ToString('00')
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host (" {0}  {1}" -f $stepLabel, $Text) -ForegroundColor Cyan
    Write-Host ('-' * 68) -ForegroundColor DarkCyan
}

function Write-UiStatus {
    param([string]$Tag, [string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host ("  [{0}] {1}" -f $Tag, $Message) -ForegroundColor $Color
}

function Find-Real-Python {
    $candidates = @()
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and $cmd.Source -notlike '*\Microsoft\WindowsApps\*') { $candidates += $cmd.Source }
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        $resolved = & py -3 -B -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $resolved -and (Test-Path $resolved.Trim())) { $candidates += $resolved.Trim() }
    }
    $roots = @((Join-Path $env:LocalAppData 'Programs\Python'), (Join-Path $env:LocalAppData 'Python'), 'C:\Python313', 'C:\Python312', 'C:\Python311', 'C:\Program Files\Python313', 'C:\Program Files\Python312')
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -LiteralPath $root -Filter python.exe -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $candidates += $found.FullName }
        }
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path) -and $path -notlike '*\Microsoft\WindowsApps\*') { return $path }
    }
    return $null
}

function Set-DownloadsDirectory {
    $downloads = Join-Path $HOME 'Downloads'
    if (Test-Path $downloads) {
        Set-Location $downloads
        Write-UiStatus 'DIR' "Joriy papka: $downloads" Green
    } else {
        Write-UiStatus 'WARN' "Downloads topilmadi; joriy papka: $(Get-Location)" Yellow
    }
}

function Install-And-Check {
    param([string]$Python, [string[]]$Packages)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 converts native stderr output into PowerShell errors.
        # pip can emit resolver warnings to stderr even when installation succeeds.
        $ErrorActionPreference = 'Continue'
        Write-UiStatus 'PIP' ("Paketlar: {0}" -f ($Packages -join ', ')) Gray
        Write-UiStatus 'PIP' "Paketlar ornatilmoqda. Bu bir necha daqiqa olishi mumkin..." Gray
        & $Python -B -m ensurepip --upgrade 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-UiStatus 'ERR' 'Could not prepare pip in this Python environment.' Red
            return $false
        }
        & $Python -B -m pip install --quiet --no-cache-dir --disable-pip-version-check --no-warn-script-location @Packages 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
        Write-UiStatus 'CHECK' 'Kutubxonalar importi tekshirilmoqda...' Gray
        & $Python -B -c 'import notebook, ipykernel, jupyter_server, zmq, tornado, numpy, pandas, matplotlib, sklearn, seaborn' 2>&1 | Out-Host
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Start-Jupyter([string]$Python) {
    Set-DownloadsDirectory
    Write-UiStatus 'READY' 'Sozlash tugadi. Jupyter brauzerda ochilmoqda...' Green
    Write-UiStatus 'INFO' 'Serverni toxtatish uchun terminalda Ctrl+C bosing.' Gray
    Write-UiStatus 'RUN' "Python: $Python" Gray
    & $Python -B -m jupyter notebook | Out-Host
    return $LASTEXITCODE
}

Write-Host ''
Write-Host ('#' * 68) -ForegroundColor Magenta
Write-Host '  JUPYTER NOTEBOOK SOZLASH' -ForegroundColor Magenta
Write-Host '  Python va kutubxonalar tekshiruvi | Jupyter ishga tushirish' -ForegroundColor DarkGray
Write-Host ('#' * 68) -ForegroundColor Magenta

Write-UiHeader '1. Python versiyasi va PATH tekshirilmoqda'
$pythonExe = Find-Real-Python
if (-not $pythonExe) {
    Write-UiStatus 'ERR' "Python topilmadi. Python 3.11+ ni o'rnating va qayta urinib ko'ring." Red
    exit 1
}
$version = & $pythonExe -B --version 2>&1
if ($LASTEXITCODE -ne 0) { Write-UiStatus 'ERR' "Python ishga tushmadi: $version" Red; exit 1 }
Write-UiStatus 'PY' "Python: $pythonExe ($version)" Green
$pathEntries = @($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') })
$pythonDir = Split-Path -Parent $pythonExe
$scriptsDir = Join-Path $pythonDir 'Scripts'
$pythonInPath = $pathEntries -contains $pythonDir.TrimEnd('\')
$scriptsInPath = $pathEntries -contains $scriptsDir.TrimEnd('\')
Write-UiStatus 'PATH' "Python papkasi=$pythonInPath | Scripts papkasi=$scriptsInPath (PATH o'zgartirilmadi)." Gray

$packages = @('notebook', 'ipykernel', 'numpy', 'pandas', 'matplotlib', 'scikit-learn', 'seaborn')
$venvDir = Join-Path $HOME '.jupyter-venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'

Write-UiHeader '2. Jupyter bilan bogliq buzilgan kesh fayllari tekshirilmoqda'
$sitePackages = Join-Path (Split-Path -Parent $pythonExe) 'Lib\site-packages'
$jupyterRoots = @('jupyter', 'notebook', 'notebook-*', 'jupyter_*', 'jupyter-*', 'ipykernel', 'ipykernel-*', 'tornado', 'tornado-*', 'zmq', 'pyzmq-*')
$scanRoots = @()
if (Test-Path $sitePackages) { $scanRoots += $sitePackages }
$venvSitePackages = Join-Path $venvDir 'Lib\site-packages'
if (Test-Path $venvSitePackages) { $scanRoots += $venvSitePackages }
$removed = 0
foreach ($root in $scanRoots) {
    foreach ($pattern in $jupyterRoots) {
        foreach ($packageDir in (Get-ChildItem -LiteralPath $root -Filter $pattern -Directory -ErrorAction SilentlyContinue)) {
            foreach ($pyc in (Get-ChildItem -LiteralPath $packageDir.FullName -Filter '*.pyc' -Recurse -File -ErrorAction SilentlyContinue)) {
                try {
                    if ((Get-Item -LiteralPath $pyc.FullName).Length -lt 16) {
                        Remove-Item -LiteralPath $pyc.FullName -Force -ErrorAction Stop
                        $removed++
                    }
                } catch { Write-UiStatus 'WARN' "Kesh faylini o'chirib bo'lmadi: $($pyc.FullName)" Yellow }
            }
        }
    }
}
if ($removed) { Write-UiStatus 'CLEAN' "$removed ta yaroqsiz Jupyter .pyc fayli olib tashlandi." Yellow }
else { Write-UiStatus 'OK' 'Yaroqsiz Jupyter .pyc fayli topilmadi.' Green }
Write-UiStatus 'INFO' 'Python manba fayllari va paket papkalari avtomatik ochirilmaydi.' Gray

Write-UiHeader '3. Oddiy Python muhitiga paketlar ornatilib tekshirilmoqda'
$directOk = $false
try { $directOk = Install-And-Check -Python $pythonExe -Packages $packages }
catch { Write-UiStatus 'WARN' "Oddiy muhitda o'rnatish xatosi: $($_.Exception.Message)" Yellow }
if ($directOk) {
    Write-UiStatus 'OK' 'Oddiy Python muhiti va Jupyter import tekshiruvi muvaffaqiyatli.' Green
    Write-UiHeader '4. Downloads papkasidan oddiy Jupyter ishga tushirilmoqda'
    $serverCode = Start-Jupyter -Python $pythonExe
    if ($serverCode -eq 0) { exit 0 }
    Write-UiStatus 'WARN' "Oddiy Jupyter xato kodi bilan yopildi ($serverCode); venv muhitiga o'tiladi." Yellow
} else {
    Write-UiStatus 'WARN' 'Oddiy Python muhiti ishlamadi; izolyatsiyalangan venv yaratiladi.' Yellow
}

Write-UiHeader "5. Venv yaratilmoqda va paketlar ornatilmoqda: $venvDir"
if (Test-Path $venvDir) {
    $pythonTag = (& $pythonExe -B -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])').Trim()
    $candidateVenv = Join-Path $HOME ('.jupyter-venv-' + $pythonTag)
    if (Test-Path $candidateVenv) {
        $candidateVenv = Join-Path $HOME ('.jupyter-venv-' + $pythonTag + '-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    }
    if (Test-Path $candidateVenv) {
        $candidateVenv = Join-Path $HOME ('.jupyter-venv-' + $pythonTag + '-' + [guid]::NewGuid().ToString('N'))
    }
    $venvDir = $candidateVenv
    $venvPython = Join-Path $venvDir 'Scripts\python.exe'
    Write-UiStatus 'INFO' "Oldingi venv o'chirilmaydi; yangi toza muhit: $venvDir" Yellow
}
& $pythonExe -B -m venv $venvDir
if ($LASTEXITCODE -ne 0) {
    Write-UiStatus 'ERR' 'Venv yaratilishi muvaffaqiyatsiz tugadi.' Red
    exit 1
}
if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-UiStatus 'ERR' 'Venv yaratilmadi. Python sozlamasi yoki Windows ruxsatlarini tekshiring.' Red
    exit 1
}
$venvOk = $false
try { $venvOk = Install-And-Check -Python $venvPython -Packages $packages }
catch { Write-UiStatus 'ERR' "Venv ichida paket o'rnatish xatosi: $($_.Exception.Message)" Red }
if (-not $venvOk) { Write-UiStatus 'ERR' "Venv ichida paketlar o'rnatilmadi yoki import tekshiruvi xato berdi." Red; exit 1 }

# Kernel spesifikatsiyasi shu venv ichida saqlanadi va server ham shu Python bilan ochiladi.
& $venvPython -B -m ipykernel install --sys-prefix --name python3 --display-name 'Python (Jupyter venv)'
if ($LASTEXITCODE -ne 0) { Write-UiStatus 'ERR' 'Venv kernelini royxatdan otkazib bolmadi.' Red; exit 1 }
$runCmd = [string][char]38 + ' "' + $venvPython + '" -B -m jupyter notebook'
try { Set-Clipboard -Value $runCmd; Write-UiStatus 'CLIP' 'Qayta ishga tushirish buyrugi clipboardga nusxalandi.' Green }
catch { Write-UiStatus 'CMD' "Qayta ishga tushirish buyrugi: $runCmd" Yellow }

Write-UiHeader '6. Downloads papkasidan Jupyter (venv) ishga tushirilmoqda'
$venvCode = Start-Jupyter -Python $venvPython
if ($venvCode -ne 0) { Write-UiStatus 'ERR' "Jupyter venv muhitida ham xato kodi bilan yopildi: $venvCode" Red; exit $venvCode }
