$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

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
            $resolvedFromPy = & py -3 -B -c "import sys; print(sys.executable)" 2>$null
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

function Remove-Corrupted-Files-If-Any {
    param([string]$PythonExePath, [string]$VenvPath)

    $corruptedFound = $false
    $checkRoots = @()

    if ($VenvPath -and (Test-Path $VenvPath)) {
        $checkRoots += $VenvPath
    }
    if ($PythonExePath -and (Test-Path $PythonExePath)) {
        $pyRoot = Split-Path -Parent $PythonExePath
        $sitePkgs = Join-Path $pyRoot "Lib\site-packages"
        if (Test-Path $sitePkgs) {
            $checkRoots += $sitePkgs
        }
    }

    # Buzilgan .pyc fayllarni tekshirish va o'chirish
    foreach ($root in $checkRoots) {
        $pycFiles = Get-ChildItem -Path $root -Filter "*.pyc" -Recurse -ErrorAction SilentlyContinue
        foreach ($pyc in $pycFiles) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($pyc.FullName)
                if ($bytes.Length -lt 16) {
                    Remove-Item -Path $pyc.FullName -Force -ErrorAction SilentlyContinue
                    $corruptedFound = $true
                }
            } catch {
                Remove-Item -Path $pyc.FullName -Force -ErrorAction SilentlyContinue
                $corruptedFound = $true
            }
        }

        # Null baytli (.py) fayllarni tekshirish va o'chirish
        $pyFiles = Get-ChildItem -Path $root -Filter "*.py" -Recurse -ErrorAction SilentlyContinue
        foreach ($pyFile in $pyFiles) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($pyFile.FullName)
                if ($bytes -contains 0) {
                    Remove-Item -Path $pyFile.FullName -Force -ErrorAction SilentlyContinue
                    $corruptedFound = $true
                }
            } catch {
                Remove-Item -Path $pyFile.FullName -Force -ErrorAction SilentlyContinue
                $corruptedFound = $true
            }
        }
    }

    # Asosiy modullarni import qilib ko'rish; xato chiqsa global site-packages dagi buzilgan paketlarni tozalash
    if ($PythonExePath -and (Test-Path $PythonExePath)) {
        $testOutput = & $PythonExePath -B -c "import pip, tornado, zmq, jupyter_client, nbconvert" 2>&1
        if ($LASTEXITCODE -ne 0 -or ($testOutput -match "null bytes|bad marshal data|EOFError|UnicodeDecodeError")) {
            $corruptedFound = $true
            $pyRoot = Split-Path -Parent $PythonExePath
            $sitePkgs = Join-Path $pyRoot "Lib\site-packages"
            $suspects = @(
                "pip", "pip-*", "tornado", "tornado-*", "zmq", "pyzmq*",
                "jupyter_client", "jupyter_client-*", "nbconvert", "nbconvert-*",
                "ipykernel", "ipykernel-*", "jupyter_core", "jupyter_core-*",
                "jupyter_server", "jupyter_server-*", "notebook", "notebook-*"
            )
            foreach ($pattern in $suspects) {
                Get-ChildItem -Path $sitePkgs -Filter $pattern -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $corruptedFound
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
Write-Host "Python versiya: $(& $pythonExe -B --version)" -ForegroundColor Green
Write-Host "PATH tekshiruvi: Python papkasi=$hasPyDir | Scripts papkasi=$hasScriptsDir" -ForegroundColor Green

$packages = @("numpy", "pandas", "matplotlib", "scikit-learn", "seaborn")
$venvDir = Join-Path $HOME ".jupyter-venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$pipCacheDir = Join-Path $env:LocalAppData "pip\Cache"

Write-Host "=== 2. Buzilgan fayllar tekshirilmoqda va tozalanmoqda ===" -ForegroundColor Cyan
$hadCorruption = Remove-Corrupted-Files-If-Any -PythonExePath $pythonExe -VenvPath $venvDir
if ($hadCorruption) {
    Write-Host "Buzilgan fayllar aniqlandi va o'chirildi." -ForegroundColor Yellow
}

if (Test-Path $venvDir) {
    Remove-Item -Recurse -Force $venvDir -ErrorAction SilentlyContinue
}
if (Test-Path $pipCacheDir) {
    Remove-Item -Recurse -Force $pipCacheDir -ErrorAction SilentlyContinue
}

Write-Host "=== 3. Izolyatsiya qilingan venv yaratilmoqda ($venvDir) ===" -ForegroundColor Cyan
& $pythonExe -B -m venv --clear $venvDir

$pyvenvCfg = Join-Path $venvDir "pyvenv.cfg"
if (Test-Path $pyvenvCfg) {
    $cfgContent = Get-Content -Path $pyvenvCfg -Raw
    if ($cfgContent -match "include-system-site-packages\s*=\s*true") {
        $cfgContent = $cfgContent -replace "include-system-site-packages\s*=\s*true", "include-system-site-packages = false"
    } elseif ($cfgContent -notmatch "include-system-site-packages") {
        $cfgContent = $cfgContent.TrimEnd() + "`r`ninclude-system-site-packages = false`r`n"
    }
    Set-Content -Path $pyvenvCfg -Value $cfgContent -NoNewline
}

Write-Host "=== 4. Kutubxonalar va Jupyter o'rnatilmoqda ===" -ForegroundColor Cyan
& $venvPython -B -m ensurepip --upgrade 2>$null
& $venvPython -B -m pip install --no-cache-dir --disable-pip-version-check --upgrade pip --no-warn-script-location
& $venvPython -B -m pip install --no-cache-dir --disable-pip-version-check notebook ipykernel @packages --no-warn-script-location
& $venvPython -B -m ipykernel install --user --name "jupyter-venv" --display-name "Python (jupyter-venv)" | Out-Null

$runCmd = "& `"$venvPython`" -B -m jupyter notebook"
try {
    Set-Clipboard -Value $runCmd
    Write-Host ""
    Write-Host "Jupyter ishga tushirish buyrug'i clipboard'ga nusxalandi:" -ForegroundColor Yellow
    Write-Host $runCmd -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ""
} catch {
    Write-Host "Jupyter ishga tushirish buyrug'i: $runCmd" -ForegroundColor Yellow
}

Write-Host "=== 5. Downloads papkasiga o'tilmoqda ===" -ForegroundColor Cyan
$downloadsPath = Join-Path $HOME "Downloads"
if (Test-Path $downloadsPath) {
    Set-Location $downloadsPath
    Write-Host "Joriy papka: $downloadsPath" -ForegroundColor Green
} else {
    Write-Host "Downloads topilmadi, joriy papka: $(Get-Location)" -ForegroundColor Yellow
}

Write-Host "=== 6. Jupyter Notebook ishga tushmoqda ===" -ForegroundColor Cyan
& $venvPython -B -m jupyter notebook
