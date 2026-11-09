# ArcReel local dev launcher for native Windows (fork branch only).
#
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File fork\dev-windows.ps1          sync deps, migrate DB, start backend + frontend
#   powershell -ExecutionPolicy Bypass -File fork\dev-windows.ps1 setup    sync deps, prepare .env, migrate DB; do not start
#
# Prerequisites: uv, Node.js >= 24.12 (ships corepack); the embedded agent also needs Claude Code.
# Open http://localhost:5173. Ctrl-C stops both servers.
# Ports are fixed: backend 1241, frontend 5173 (frontend/vite.config.ts proxies /api and /mcp to 1241).
#
# Tools root: if <ToolsRoot>\uv\bin or <ToolsRoot>\node24 exists, it is put first on PATH and the
# uv / pnpm caches are kept under <ToolsRoot>, so nothing lands on drive C. Default D:\app,
# override with -ToolsRoot or the ARCREEL_TOOLS_ROOT environment variable.
#
# The backend runs without --reload: on native Windows, uvicorn's reloader switches to an event
# loop without subprocess support and the embedded agent cannot launch Claude Code. Restart the
# script after backend code changes.
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI code page.

param(
    [ValidateSet('start', 'setup')]
    [string]$Command = 'start',
    [string]$ToolsRoot = $(if ($env:ARCREEL_TOOLS_ROOT) { $env:ARCREEL_TOOLS_ROOT } else { 'D:\app' })
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Write-Log([string]$Message) { Write-Host "[arcreel] $Message" -ForegroundColor Cyan }

function Invoke-Native([string]$What, [scriptblock]$Block) {
    Write-Log $What
    & $Block
    if ($LASTEXITCODE -ne 0) { throw "[arcreel] failed ($LASTEXITCODE): $What" }
}

function Use-ToolsRoot {
    if (Test-Path "$ToolsRoot\uv\bin") {
        $env:UV_CACHE_DIR = "$ToolsRoot\uv\cache"
        $env:UV_PYTHON_INSTALL_DIR = "$ToolsRoot\uv\python"
        $env:UV_TOOL_DIR = "$ToolsRoot\uv\tools"
        $env:UV_TOOL_BIN_DIR = "$ToolsRoot\uv\bin"
        $env:UV_PYTHON_BIN_DIR = "$ToolsRoot\uv\bin"
        $env:COREPACK_HOME = "$ToolsRoot\corepack"
        $env:npm_config_store_dir = "$ToolsRoot\pnpm-store"
        $env:npm_config_cache = "$ToolsRoot\npm-cache"
        $env:PATH = "$ToolsRoot\uv\bin;$env:PATH"
    }
    if (Test-Path "$ToolsRoot\node24\node.exe") {
        $env:PATH = "$ToolsRoot\node24;$env:PATH"
    }
    # Match CI and the Dockerfile; uv downloads it if missing.
    if (-not $env:UV_PYTHON) { $env:UV_PYTHON = '3.12' }
}

function Test-Prerequisites {
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw '[arcreel] uv not found. Install it, or put it under <ToolsRoot>\uv\bin.' }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw '[arcreel] Node.js not found. Install Node 24, or put it under <ToolsRoot>\node24.' }
    # Single quotes inside the JS: PowerShell 5.1 strips double quotes from native-command arguments.
    & node -e 'const [a,b]=process.versions.node.split(''.'').map(Number);process.exit(a>24||(a===24&&b>=12)?0:1)'
    if ($LASTEXITCODE -ne 0) { throw "[arcreel] Node.js $(& node -v) is too old; the project needs >= 24.12." }
    if (-not (Get-Command corepack -ErrorAction SilentlyContinue)) { throw '[arcreel] corepack not found; it ships with Node 24.' }
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Log 'Note: claude not found. The embedded agent will not work; everything else does.' }
}

# The backend refuses provider secrets in its environment (lib/config/env_keys.py), and the embedded
# agent must not inherit an outer Claude Code session's credentials or nesting markers.
function Clear-AgentEnv {
    Get-ChildItem Env: |
        Where-Object { $_.Name -like 'ANTHROPIC_*' -or $_.Name -like 'CLAUDE*' } |
        ForEach-Object { Remove-Item "Env:$($_.Name)" }
}

function Invoke-Setup {
    Invoke-Native 'Syncing backend deps (uv sync --locked)' { uv sync --locked }
    Push-Location frontend
    try { Invoke-Native 'Syncing frontend deps (pnpm install --frozen-lockfile)' { corepack pnpm install --frozen-lockfile } }
    finally { Pop-Location }
    if (-not (Test-Path .env)) {
        Copy-Item .env.example .env
        Write-Log 'Created .env from .env.example; the login password is generated on first start and written to AUTH_PASSWORD.'
    }
    Invoke-Native 'Migrating database (alembic upgrade head)' { uv run alembic upgrade head }
}

function Invoke-Start {
    Write-Log 'Starting backend on http://127.0.0.1:1241'
    $uv = (Get-Command uv).Source
    $backend = Start-Process -FilePath $uv -NoNewWindow -PassThru `
        -ArgumentList 'run', 'uvicorn', 'server.app:app', '--host', '127.0.0.1', '--port', '1241'
    try {
        Write-Log 'Starting frontend on http://localhost:5173 (Ctrl-C stops both)'
        Push-Location frontend
        try { corepack pnpm dev } finally { Pop-Location }
    }
    finally {
        if (-not $backend.HasExited) {
            Write-Log 'Stopping backend'
            & taskkill.exe /PID $backend.Id /T /F | Out-Null
        }
    }
}

Use-ToolsRoot
Test-Prerequisites
Clear-AgentEnv
Invoke-Setup
if ($Command -eq 'start') { Invoke-Start }
