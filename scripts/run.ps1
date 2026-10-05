<#
.SYNOPSIS
    Helper script for local VDB development on Windows (PowerShell 5.1+).
    Unix equivalent: scripts/run.sh

.EXAMPLE
    .\scripts\run.ps1 setup      # first run: install deps + create database
    .\scripts\run.ps1 dev        # run backend + frontend, each in a new window
    .\scripts\run.ps1 help       # list all commands
#>
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

# Backend opens JSON files without an explicit encoding; on Windows that defaults to cp1252
$env:PYTHONUTF8 = "1"

$Root = Split-Path -Parent $PSScriptRoot
$Frontend = Join-Path $Root "frontend"
$Backend = Join-Path $Root "backend"
$CardsUpdate = Join-Path $Root "misc\cards-update"

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Run a native command in a directory and stop if it fails.
# Uses exit codes: in PowerShell 5.1, "Stop" would treat any stderr output as fatal.
function Invoke-In([string]$Dir, [scriptblock]$Block) {
    Push-Location $Dir
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Block
        if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE" }
    }
    finally {
        $ErrorActionPreference = $prev
        Pop-Location
    }
}

function Assert-Tool([string]$Name, [string]$Hint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' not found in PATH. $Hint"
    }
}

function Assert-Prerequisites {
    Assert-Tool "uv" "Install it from https://docs.astral.sh/uv/"
    Assert-Tool "npm" "Install Node.js from https://nodejs.org/"
}

function Find-Bash {
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw "Git Bash not found. Install Git for Windows or use WSL for card updates."
}

# --- Install -----------------------------------------------------------------

function Install-Backend {
    Write-Step "Installing backend dependencies (uv sync)"
    Invoke-In $Backend { uv sync }
}

function Install-Frontend {
    Write-Step "Installing frontend dependencies (npm install)"
    # xlsx is fetched from cdn.sheetjs.com; npm 12+ refuses remote tarballs by default
    Invoke-In $Frontend { npm install --allow-remote=all }
}

function Initialize-Db {
    # migrations/ is gitignored, so it must be created locally on first run
    if (-not (Test-Path (Join-Path $Backend "migrations"))) {
        Write-Step "Initializing migrations"
        Invoke-In $Backend { uv run flask db init }
    }
    Update-Db
}

function Update-Db {
    Write-Step "Generating and applying database migrations"
    Invoke-In $Backend { uv run flask db migrate }
    Invoke-In $Backend { uv run flask db upgrade }
}

function New-EnvFile {
    $envFile = Join-Path $Backend ".env"
    if (Test-Path $envFile) { return }
    Write-Step "Creating backend/.env with random secrets"
    $secret = -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    $playtest = -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    Set-Content -Path $envFile -Encoding ascii -Value @(
        "SECRET_KEY = `"$secret`"",
        "PLAYTEST_KEY = `"$playtest`""
    )
}

# --- Run ---------------------------------------------------------------------

function Start-Backend {
    Write-Step "Starting backend on http://localhost:5000"
    Invoke-In $Backend { uv run flask --debug run }
}

function Start-Frontend {
    Write-Step "Starting frontend on http://localhost:5173"
    Invoke-In $Frontend { npm start }
}

# Open a new PowerShell window running $Cmd (it inherits $env:PYTHONUTF8)
function Start-Window([string]$Title, [string]$Dir, [string]$Cmd) {
    Start-Process powershell -WorkingDirectory $Dir -ArgumentList @(
        "-NoExit", "-Command", "`$Host.UI.RawUI.WindowTitle = '$Title'; $Cmd"
    )
}

function Start-Dev {
    Write-Step "Launching backend in a new window (http://localhost:5000)"
    Start-Window "VDB backend" $Backend "uv run flask --debug run"
    Write-Step "Launching frontend in a new window (http://localhost:5173)"
    Start-Window "VDB frontend" $Frontend "npm start"
}

# --- Quality -----------------------------------------------------------------

function Invoke-Lint {
    # Run both linters even if the first one fails
    $failed = $false
    Write-Step "Frontend: biome check"
    try { Invoke-In $Frontend { npm run check } } catch { $failed = $true }
    Write-Step "Backend: ruff check"
    try { Invoke-In $Backend { uvx ruff check . } } catch { $failed = $true }
    if ($failed) { throw "Lint found issues (run '.\scripts\run.ps1 fix' to auto-fix some)" }
}

function Invoke-Fix {
    Write-Step "Frontend: biome check --write"
    Invoke-In $Frontend { npm run fix }
    Write-Step "Backend: ruff check --fix + ruff format"
    Invoke-In $Backend { uvx ruff check --fix . }
    Invoke-In $Backend { uvx ruff format . }
}

# --- Card data ---------------------------------------------------------------

function Update-Cards {
    $bash = Find-Bash
    Write-Step "Installing cards-update dependencies"
    Invoke-In $CardsUpdate { uv sync }
    Invoke-In $CardsUpdate { npm install }
    Write-Step "Downloading upstream resources"
    Invoke-In $CardsUpdate { & $bash ./download_resources.sh }
    Write-Step "Generating resources"
    Invoke-In $CardsUpdate { & $bash ./create_resources.sh }
}

# --- Help --------------------------------------------------------------------

function Show-Help {
    Write-Host @"
Usage: .\scripts\run.ps1 <command> [args]

Setup
  setup           Install all deps, create backend/.env and the database
  install         Install backend (uv) and frontend (npm) dependencies
  db              Create migrations folder if needed, then migrate + upgrade
  db-upgrade      Generate and apply migrations after model changes

Run
  dev             Backend and frontend, each in its own window (http://localhost:5173)
  backend         Flask dev server only (http://localhost:5000)
  frontend        Vite dev server only (http://localhost:5173)

Build
  build           Production build of the frontend (frontend/dist)
  preview         Serve the production build locally
  analyze         Bundle size visualizer

Quality
  lint            Biome check (frontend) + ruff check (backend)
  fix             Auto-fix/format with biome and ruff

Maintenance
  update-cards    Download upstream card data and regenerate resources (needs Git Bash)
  password <account> [password|x]   Change a user password (x = random)
  playtest-admin <account>          Toggle playtest admin status
  clean           Remove node_modules, .venv, dist (keeps app.db)
"@
}

# --- Dispatch ----------------------------------------------------------------

switch ($Command) {
    "setup" {
        Assert-Prerequisites
        Install-Backend
        Install-Frontend
        New-EnvFile
        Initialize-Db
        Write-Step "Done. Run '.\scripts\run.ps1 dev' to start."
    }
    "install" { Assert-Prerequisites; Install-Backend; Install-Frontend }
    "db" { Initialize-Db }
    "db-upgrade" { Update-Db }
    "dev" { Start-Dev }
    "backend" { Start-Backend }
    "frontend" { Start-Frontend }
    "build" { Write-Step "Building frontend"; Invoke-In $Frontend { npm run build } }
    "preview" { Invoke-In $Frontend { npx vite preview } }
    "analyze" { Invoke-In $Frontend { npm run analyze } }
    "lint" { Invoke-Lint }
    "fix" { Invoke-Fix }
    "update-cards" { Update-Cards }
    "password" {
        if (-not $Rest) { throw "Usage: .\scripts\run.ps1 password <account> [password|x]" }
        Invoke-In $Backend { uv run change_password.py @Rest }
    }
    "playtest-admin" {
        if (-not $Rest) { throw "Usage: .\scripts\run.ps1 playtest-admin <account>" }
        Invoke-In $Backend { uv run change_playtest_admin.py @Rest }
    }
    "clean" {
        Write-Step "Removing build artifacts and dependencies"
        foreach ($p in @(
                (Join-Path $Frontend "node_modules"),
                (Join-Path $Frontend "dist"),
                (Join-Path $Backend ".venv"),
                (Join-Path $CardsUpdate "node_modules"),
                (Join-Path $CardsUpdate ".venv")
            )) {
            if (Test-Path $p) { Remove-Item -Recurse -Force $p }
        }
    }
    default { Show-Help }
}
