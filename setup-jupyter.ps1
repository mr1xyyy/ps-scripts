$ErrorActionPreference = "Stop"

function Refresh-And-Repair-Path {
    param([string]$PythonExePath)

    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")

    $dirsToEnsure = @()
    if ($PythonExePath -and (Test-Path $PythonExePath)) {
        $pyDir = Split-Path -Parent $PythonExePath
        $scriptsDir = Join-Path $pyDir "Scripts"
        $dirsToEnsure += $pyDir
        if (Test-Path $scriptsDir) {
            $dirsToEnsure += $scriptsDir
        }
    }

    $currentUserParts = @()
    if ($userPath) {
        $currentUserParts = $userPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    $changedUserPath = $false
    foreach ($dir in $dirsToEnsure) {
        $existsInUser = $currentUserParts | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') }
        if (-not $existsInUser) {
            $currentUserParts += $dir
            $changedUserPath = $true
            Write-Host "PATH (User) ga qo'shildi: $dir" -ForegroundColor Green
        }
    }

    if ($changedUserPath) {
        $newUserPath = ($currentUserParts -join ";")
        [System.Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        $userPath = $newUserPath
    }

    $combinedParts = @()
    foreach ($entry in ($machinePath + ";" + $userPath).Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if (-not ($combinedParts | Where-Object { $_ -ieq $entry.TrimEnd('\') })) {
            $combinedParts += $entry
        }
    }
    $env:Path = ($combinedParts -join ";")
}

function Find-Real-Python {
    $candidates = @()

    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -and ($pyCmd.Source -notlike "*\Microsoft\WindowsApps\*")) {
        $candidates += $pyCmd.Source
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $resolvedFromPy = & py -3 -c "import sys; print(sys.executable)" 2>$null
            if ($resolvedFromPy -and (Test-Path $resolvedFromPy.Trim())) {
                $candidates += $resolvedFromPy.Trim()
            }
        } catch {}
    }

    $commonRoots = @(
        (Join-Path $env:LocalAppData "Programs\Python"),
        "C:\Python315", "C:\Python314", "C:\Python313", "C:\Python312", "C:\Program Files\Python313", "C:\Program Files\Python312"
    )
    foreach ($root in $commonRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Filter "python.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $candidates += $found.FullName
            }
        }
    }

    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path $cand) -and ($cand -notlike "*\Microsoft\WindowsApps\*")) {
            return $cand
        }
    }
    return $null
}

Write-Host "=== 1. Python versiyasi va PATH tekshirilmoqda ===" -ForegroundColor Cyan

$pythonExe = Find-Real-Python

if (-not $pythonExe) {
    Write-Host "Haqiqiy Python topilmadi. winget orqali o'rnatishga urinilmoqda..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Python.Python.3.13 --scope user --accept-package-agreements --accept-source-agreements
        $pythonExe = Find-Real-Python
    }
}

if (-not $pythonExe) {
    Write-Host "XATO: Python topilmadi. python.org dan 'Add Python to PATH' belgilab o'rnating." -ForegroundColor Red
    exit 1
}

Refresh-And-Repair-Path -PythonExePath $pythonExe

$pyDir = Split-Path -Parent $pythonExe
$scriptsDir = Join-Path $pyDir "Scripts"
$allPathEntries = $env:Path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.TrimEnd('\').ToLower() }

$hasPyDir = $allPathEntries -contains $pyDir.TrimEnd('\').ToLower()
$hasScriptsDir = (-not (Test-Path $scriptsDir)) -or ($allPathEntries -contains $scriptsDir.TrimEnd('\').ToLower())

Write-Host "Python yo'li : $pythonExe" -ForegroundColor Green
Write-Host "Python versiya: $(& $pythonExe --version)" -ForegroundColor Green
Write-Host "PATH tekshiruvi: Python papkasi=$hasPyDir | Scripts papkasi=$hasScriptsDir" -ForegroundColor Green

$packages = @("numpy", "pandas", "matplotlib", "scikit-learn")

Write-Host "=== 2. Asosiy muhitda Jupyter tekshirilmoqda ===" -ForegroundColor Cyan
$globalJupyterOk = $false
try {
    & $pythonExe -m pip install --upgrade pip | Out-Null
    & $pythonExe -m pip install notebook @packages
    & $pythonExe -m jupyter --version | Out-Null

    $jupyterCmd = Get-Command jupyter -ErrorAction SilentlyContinue
    if ($jupyterCmd) {
        & jupyter --version | Out-Null
        $globalJupyterOk = $true
        Write-Host "Asosiy muhitda ham, buyruq satrida ham Jupyter tayyor!" -ForegroundColor Green
    }
} catch {
    Write-Host "Asosiy muhitda Jupyter ishga tushmadi. Venv muqobil yo'liga o'tilmoqda..." -ForegroundColor Yellow
}

$activePython = $pythonExe
$venvDir = Join-Path $HOME ".jupyter-venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$activateCmd = Join-Path $venvDir "Scripts\activate"

if (-not $globalJupyterOk) {
    Write-Host "=== 3. Muqobil usul: venv yaratilmoqda ($venvDir) ===" -ForegroundColor Cyan
    if (-not (Test-Path $venvPython)) {
        & $pythonExe -m venv $venvDir
    }

    & $venvPython -m pip install --upgrade pip
    & $venvPython -m pip install notebook @packages
    & $venvPython -m jupyter --version

    $activePython = $venvPython

    try {
        Set-Clipboard -Value $activateCmd
        Write-Host ""
        Write-Host "Venv faollashtirish buyrug'i clipboard'ga nusxalandi:" -ForegroundColor Yellow
        Write-Host $activateCmd -ForegroundColor White -BackgroundColor DarkBlue
        Write-Host ""
    } catch {
        Write-Host "Venv faollashtirish buyrug'i: $activateCmd" -ForegroundColor Yellow
    }
}

Write-Host "=== 4. Downloads papkasiga o'tilmoqda ===" -ForegroundColor Cyan
$downloadsPath = Join-Path $HOME "Downloads"
if (Test-Path $downloadsPath) {
    Set-Location $downloadsPath
    Write-Host "Joriy papka: $downloadsPath" -ForegroundColor Green
} else {
    Write-Host "Downloads topilmadi, joriy papka: $(Get-Location)" -ForegroundColor Yellow
}

Write-Host "=== 5. Jupyter Notebook ishga tushmoqda ===" -ForegroundColor Cyan
if ($globalJupyterOk) {
    jupyter notebook
} else {
    & $activePython -m jupyter notebook
}
