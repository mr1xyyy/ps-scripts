$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

function Write-UiHeader {
    param([string]$StepText)
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host $StepText -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
}

function Write-UiStatus {
    param(
        [string]$Tag,
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host ("  [{0}] {1}" -f $Tag, $Message) -ForegroundColor $Color
}

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
            Write-UiStatus -Tag "PATH" -Message "User PATH ga qo'shildi: $dir" -Color Green
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

function Ensure-Direct-Packages-And-Test {
    param(
        [string]$PythonExePath,
        [string[]]$Packages
    )

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    # 1. Global pip va asosiy modullarni tekshirish
    $checkBase = & $PythonExePath -B -c "import pip; print('PIP_OK')" 2>&1
    $baseCode = $LASTEXITCODE
    $baseText = ($checkBase | Out-String)

    if ($baseCode -ne 0 -or ($baseText -notmatch "PIP_OK") -or ($baseText -match "null bytes|bad marshal data|EOFError|UnicodeDecodeError|SyntaxError|ValueError|Traceback")) {
        $ErrorActionPreference = $prevErr
        return $false
    }

    # 2. Yetishmayotgan kutubxonalarni global Python ga o'rnatish
    $allToInstall = @("notebook", "ipykernel") + $Packages
    Write-UiStatus -Tag "PIP" -Message "Oddiy muhit uchun kutubxonalar tekshirilmoqda/yuklanmoqda: $($allToInstall -join ', ')" -Color Gray
    $pipOut = & $PythonExePath -B -m pip install --no-cache-dir --disable-pip-version-check @allToInstall --no-warn-script-location 2>&1
    $pipCode = $LASTEXITCODE
    $pipText = ($pipOut | Out-String)

    if ($pipCode -ne 0 -or ($pipText -match "null bytes|bad marshal data|EOFError|UnicodeDecodeError|SyntaxError|ValueError|Traceback")) {
        $ErrorActionPreference = $prevErr
        return $false
    }

    # 3. Hammasi to'g'ri import bo'lishini tasdiqlash
    $verifyOut = & $PythonExePath -B -c "import jupyter_core, jupyter_server, notebook, ipykernel, zmq, tornado, nbconvert, numpy, pandas, matplotlib, sklearn, seaborn; print('JUPYTER_DIRECT_OK')" 2>&1
    $verifyCode = $LASTEXITCODE
    $ErrorActionPreference = $prevErr

    $verifyText = ($verifyOut | Out-String)
    if ($verifyCode -eq 0 -and ($verifyText -match "JUPYTER_DIRECT_OK") -and ($verifyText -notmatch "null bytes|bad marshal data|EOFError|UnicodeDecodeError|SyntaxError|ValueError|Traceback")) {
        return $true
    }
    return $false
}

function Remove-Corrupted-Files-If-Any {
    param([string]$PythonExePath, [string]$VenvPath)

    $corruptedFound = $false
    $checkRoots = @()

    if ($VenvPath -and (Test-Path $VenvPath)) {
        Write-UiStatus -Tag "SCAN" -Message "Venv papkasi tekshirilmoqda: $VenvPath" -Color Gray
        $checkRoots += $VenvPath
    }
    if ($PythonExePath -and (Test-Path $PythonExePath)) {
        $pyRoot = Split-Path -Parent $PythonExePath
        $sitePkgs = Join-Path $pyRoot "Lib\site-packages"
        if (Test-Path $sitePkgs) {
            Write-UiStatus -Tag "SCAN" -Message "Global site-packages tekshirilmoqda: $sitePkgs" -Color Gray
            $checkRoots += $sitePkgs
        }
    }

    foreach ($root in $checkRoots) {
        Write-UiStatus -Tag "PYC" -Message "Buzilgan .pyc fayllar qidirilmoqda -> $root" -Color Gray
        $pycFiles = Get-ChildItem -Path $root -Filter "*.pyc" -Recurse -ErrorAction SilentlyContinue
        foreach ($pyc in $pycFiles) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($pyc.FullName)
                if ($bytes.Length -lt 16) {
                    Write-UiStatus -Tag "DEL" -Message "Qisqa/buzilgan .pyc o'chirildi: $($pyc.FullName)" -Color Yellow
                    Remove-Item -Path $pyc.FullName -Force -ErrorAction SilentlyContinue
                    $corruptedFound = $true
                }
            } catch {
                Write-UiStatus -Tag "DEL" -Message "O'qib bo'lmagan .pyc o'chirildi: $($pyc.FullName)" -Color Yellow
                Remove-Item -Path $pyc.FullName -Force -ErrorAction SilentlyContinue
                $corruptedFound = $true
            }
        }

        Write-UiStatus -Tag "PY" -Message "Null baytli (.py) fayllar qidirilmoqda -> $root" -Color Gray
        $pyFiles = Get-ChildItem -Path $root -Filter "*.py" -Recurse -ErrorAction SilentlyContinue
        foreach ($pyFile in $pyFiles) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($pyFile.FullName)
                if ($bytes -contains 0) {
                    Write-UiStatus -Tag "DEL" -Message "Null baytli .py fayl o'chirildi: $($pyFile.FullName)" -Color Yellow
                    Remove-Item -Path $pyFile.FullName -Force -ErrorAction SilentlyContinue
                    $corruptedFound = $true
                }
            } catch {
                Write-UiStatus -Tag "DEL" -Message "Buzilgan .py fayl o'chirildi: $($pyFile.FullName)" -Color Yellow
                Remove-Item -Path $pyFile.FullName -Force -ErrorAction SilentlyContinue
                $corruptedFound = $true
            }
        }
    }

    if ($PythonExePath -and (Test-Path $PythonExePath)) {
        Write-UiStatus -Tag "CHECK" -Message "Asosiy modullar (pip, tornado, zmq, jupyter_client, nbconvert, notebook, numpy, pandas) tekshirilmoqda..." -Color Gray
        $prevErrAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $testOutput = & $PythonExePath -B -c "import pip, tornado, zmq, jupyter_client, nbconvert, notebook, numpy, pandas" 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevErrAction

        $outText = ($testOutput | Out-String)
        if ($exitCode -ne 0 -or ($outText -match "null bytes|bad marshal data|EOFError|UnicodeDecodeError|Traceback|SyntaxError|ValueError")) {
            Write-UiStatus -Tag "WARN" -Message "Modul importida xato aniqlandi. Buzilgan paket papkalari tozalanmoqda..." -Color Yellow
            $corruptedFound = $true
            $pyRoot = Split-Path -Parent $PythonExePath
            $sitePkgs = Join-Path $pyRoot "Lib\site-packages"
            $suspects = @(
                "pip", "pip-*", "tornado", "tornado-*", "zmq", "pyzmq*",
                "jupyter_client", "jupyter_client-*", "nbconvert", "nbconvert-*",
                "ipykernel", "ipykernel-*", "jupyter_core", "jupyter_core-*",
                "jupyter_server", "jupyter_server-*", "notebook", "notebook-*",
                "jupyterlab", "jupyterlab-*", "jupyterlab_server", "jupyterlab_server-*",
                "traitlets", "traitlets-*", "numpy", "numpy-*", "pandas", "pandas-*",
                "matplotlib", "matplotlib-*", "sklearn", "scikit_learn-*", "seaborn", "seaborn-*"
            )
            foreach ($pattern in $suspects) {
                $matched = Get-ChildItem -Path $sitePkgs -Filter $pattern -ErrorAction SilentlyContinue
                foreach ($item in $matched) {
                    Write-UiStatus -Tag "DEL" -Message "Buzilgan paket o'chirildi: $($item.FullName)" -Color Yellow
                    Remove-Item -Recurse -Force $item.FullName -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-UiStatus -Tag "OK" -Message "Global modullarda buzilish topilmadi." -Color Green
        }
    }

    return $corruptedFound
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "           JUPYTER NOTEBOOK O'RNATISH VA ISHGA TUSHIRISH     " -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

Write-UiHeader -StepText "=== 1. Python versiyasi va PATH tekshirilmoqda ==="

$pythonExe = Find-Real-Python

if (-not $pythonExe) {
    Write-UiStatus -Tag "INFO" -Message "Haqiqiy Python topilmadi. winget orqali o'rnatishga urinilmoqda..." -Color Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install -e --id Python.Python.3.13 --scope user --accept-package-agreements --accept-source-agreements
        $pythonExe = Find-Real-Python
    }
}

if (-not $pythonExe) {
    Write-UiStatus -Tag "ERR" -Message "Python topilmadi. python.org dan 'Add Python to PATH' belgilab o'rnating." -Color Red
    exit 1
}

Refresh-And-Repair-Path -PythonExePath $pythonExe

$pyDir = Split-Path -Parent $pythonExe
$scriptsDir = Join-Path $pyDir "Scripts"
$allPathEntries = $env:Path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.TrimEnd('\').ToLower() }

$hasPyDir = $allPathEntries -contains $pyDir.TrimEnd('\').ToLower()
$hasScriptsDir = $allPathEntries -contains $scriptsDir.TrimEnd('\').ToLower()

Write-UiStatus -Tag "PY" -Message "Python yo'li : $pythonExe" -Color Green
Write-UiStatus -Tag "VER" -Message "Python versiya: $(& $pythonExe -B --version)" -Color Green
Write-UiStatus -Tag "PATH" -Message "Python papkasi=$hasPyDir | Scripts papkasi=$hasScriptsDir" -Color Green

$packages = @("numpy", "pandas", "matplotlib", "scikit-learn", "seaborn")
$venvDir = Join-Path $HOME ".jupyter-venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$pipCacheDir = Join-Path $env:LocalAppData "pip\Cache"
$downloadsPath = Join-Path $HOME "Downloads"

# 1-navbat: Oddiy muhitga kutubxonalarni o'rnatib, oddiy Jupyter orqali ochish
Write-UiHeader -StepText "=== 1B. Kutubxonalar yuklanmoqda va oddiy Jupyter tekshirilmoqda ==="
if (Ensure-Direct-Packages-And-Test -PythonExePath $pythonExe -Packages $packages) {
    Write-UiStatus -Tag "OK" -Message "Barcha kutubxonalar yuklandi! Oddiy Jupyter orqali ochilmoqda..." -Color Green
    if (Test-Path $downloadsPath) {
        Set-Location $downloadsPath
        Write-UiStatus -Tag "DIR" -Message "Joriy papka: $downloadsPath" -Color Green
    }
    & $pythonExe -B -m jupyter notebook
    exit 0
} else {
    Write-UiStatus -Tag "INFO" -Message "Oddiy muhitda o'rnatish yoki ishga tushirishda muammo chiqdi. Tozalash va venv muqobiliga o'tilmoqda..." -Color Yellow
}

# 2-bosqich: Buzilgan fayllarni tekshirish va o'chirish
Write-UiHeader -StepText "=== 2. Buzilgan fayllar tekshirilmoqda va tozalanmoqda ==="
$hadCorruption = Remove-Corrupted-Files-If-Any -PythonExePath $pythonExe -VenvPath $venvDir
if ($hadCorruption) {
    Write-Host "Buzilgan fayllar aniqlandi va o'chirildi." -ForegroundColor Yellow
} else {
    Write-UiStatus -Tag "INFO" -Message "Alohida buzilgan fayl topilmadi, eski venv va pip keshi tozalanmoqda..." -Color Gray
}

if (Test-Path $venvDir) {
    Write-UiStatus -Tag "CLEAN" -Message "Eski venv o'chirilmoqda: $venvDir" -Color Gray
    Remove-Item -Recurse -Force $venvDir -ErrorAction SilentlyContinue
}
if (Test-Path $pipCacheDir) {
    Write-UiStatus -Tag "CLEAN" -Message "Pip keshi o'chirilmoqda: $pipCacheDir" -Color Gray
    Remove-Item -Recurse -Force $pipCacheDir -ErrorAction SilentlyContinue
}

Write-UiHeader -StepText "=== 3. Izolyatsiya qilingan venv yaratilmoqda ($venvDir) ==="
Write-UiStatus -Tag "VENV" -Message "Virtual muhit yaratilmoqda..." -Color Gray
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
    Write-UiStatus -Tag "CFG" -Message "include-system-site-packages = false o'rnatildi." -Color Green
}

Write-UiHeader -StepText "=== 4. Kutubxonalar va Jupyter venv ichiga o'rnatilmoqda ==="
$prevErr = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $venvPython -B -m ensurepip --upgrade 2>$null
$ErrorActionPreference = $prevErr

& $venvPython -B -m pip install --no-cache-dir --disable-pip-version-check --upgrade pip --no-warn-script-location
& $venvPython -B -m pip install --no-cache-dir --disable-pip-version-check notebook ipykernel @packages --no-warn-script-location
& $venvPython -B -m ipykernel install --user --name "jupyter-venv" --display-name "Python (jupyter-venv)" | Out-Null
Write-UiStatus -Tag "OK" -Message "Venv kutubxonalari va kernel tayyor." -Color Green

$runCmd = "& `"$venvPython`" -B -m jupyter notebook"
try {
    Set-Clipboard -Value $runCmd
    Write-Host ""
    Write-UiStatus -Tag "CLIP" -Message "Jupyter ishga tushirish buyrug'i clipboard'ga nusxalandi:" -Color Yellow
    Write-Host "    $runCmd" -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ""
} catch {
    Write-UiStatus -Tag "CMD" -Message "Jupyter ishga tushirish buyrug'i: $runCmd" -Color Yellow
}

Write-UiHeader -StepText "=== 5. Downloads papkasiga o'tilmoqda ==="
if (Test-Path $downloadsPath) {
    Set-Location $downloadsPath
    Write-UiStatus -Tag "DIR" -Message "Joriy papka: $downloadsPath" -Color Green
} else {
    Write-UiStatus -Tag "WARN" -Message "Downloads topilmadi, joriy papka: $(Get-Location)" -Color Yellow
}

Write-UiHeader -StepText "=== 6. Jupyter Notebook (venv) ishga tushmoqda ==="
& $venvPython -B -m jupyter notebook
