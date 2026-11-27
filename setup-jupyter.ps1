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
        $dirsToEnsure += $scriptsDir
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
    foreach ($entry in (($machinePath + ";" + $userPath).Split(';', [System.StringSplitOptions]::RemoveEmptyEntries))) {
        if (-not ($combinedParts | Where-Object { $_ -ieq $entry.TrimEnd('\') })) {
            $combinedParts += $entry
        }
    }
    $env:Path = ($combinedParts -join ";")
}

function Find-Real-Python {
    $candidates = @()

    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd -and $pyCmd.Source -and ($pyCmd.Source -notlike "*\Microsoft\WindowsApps\*") -and ($pyCmd.Source -notlike "*\.jupyter-venv\*")) {
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
        (Join-Path $env:LocalAppData "Python"),
        "C:\Python315", "C:\Python314", "C:\Python313", "C:\Python312",
        "C:\Program Files\Python314", "C:\Program Files\Python313", "C:\Program Files\Python312"
    )
    foreach ($root in $commonRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Filter "python.exe" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notlike "*\.jupyter-venv\*" } |
                Select-Object -First 1
            if ($found) {
                $candidates += $found.FullName
            }
        }
    }

    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path $cand) -and ($cand -notlike "*\Microsoft\WindowsApps\*") -and ($cand -notlike "*\.jupyter-venv\*")) {
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
$hasScriptsDir = $allPathEntries -contains $scriptsDir.TrimEnd('\').ToLower()

Write-Host "Python yo'li : $pythonExe" -ForegroundColor Green
Write-Host "Python versiya: $(& $pythonExe --version)" -ForegroundColor Green
Write-Host "PATH tekshiruvi: Python papkasi=$hasPyDir | Scripts papkasi=$hasScriptsDir" -ForegroundColor Green

$packages = @("numpy", "pandas", "matplotlib", "scikit-learn", "seaborn")
$venvDir = Join-Path $HOME ".jupyter-venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$activateCmd = Join-Path $venvDir "Scripts\activate"

Write-Host "=== 2. Toza venv tayyorlanmoqda ($venvDir) ===" -ForegroundColor Cyan
if (-not (Test-Path $venvPython)) {
    & $pythonExe -m venv $venvDir
}

Write-Host "=== 3. Kutubxonalar va Jupyter o'rnatilmoqda ===" -ForegroundColor Cyan
& $venvPython -B -m pip install --no-cache-dir --disable-pip-version-check --upgrade pip --no-warn-script-location
& $venvPython -B -m pip install --no-cache-dir --disable-pip-version-check notebook @packages --no-warn-script-location

try {
    Set-Clipboard -Value $activateCmd
    Write-Host ""
    Write-Host "Venv faollashtirish buyrug'i clipboard'ga nusxalandi:" -ForegroundColor Yellow
    Write-Host $activateCmd -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ""
} catch {
    Write-Host "Venv faollashtirish buyrug'i: $activateCmd" -ForegroundColor Yellow
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
& $venvPython -B -m jupyter notebook
