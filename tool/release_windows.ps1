<#
  Выпуск новой версии nox.drive для Windows одной командой.

  Перед запуском:
    1. В pubspec.yaml увеличьте version (например 2.0.11+11). Номер после + всегда растёт.
    2. Задайте переменные (service_role только здесь, в программу он не попадает):
         $env:SUPABASE_URL = 'https://<project>.supabase.co'
         $env:SUPABASE_ANON_KEY = '<publishable/anon key>'
         $env:SUPABASE_SERVICE_KEY = '<service_role key>'
    3. Папки adb и scrcpy: либо уже лежат в build\windows\x64\runner\Release,
       либо в windows\adb и windows\scrcpy (скрипт скопирует).

  Запуск:
    powershell -ExecutionPolicy Bypass -File tool\release_windows.ps1 -Notes "Что нового"
    Пробный запуск без публикации: добавить -DryRun
    Обязательное обновление: добавить -Mandatory

  Что делает: тесты -> сборка с ключами -> adb и scrcpy -> zip -> все проверки -> публикация.
  На любой ошибке останавливается и ничего не публикует.
#>
param(
  [string]$Notes = '',
  [switch]$DryRun,
  [switch]$Mandatory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step($text) { Write-Host ''; Write-Host "== $text" }

if (-not $env:SUPABASE_URL -or -not $env:SUPABASE_ANON_KEY) {
  throw 'Задайте SUPABASE_URL и SUPABASE_ANON_KEY, иначе программа соберётся в демо-режиме без входа.'
}
if (-not $DryRun -and -not $env:SUPABASE_SERVICE_KEY) {
  throw 'Для публикации задайте SUPABASE_SERVICE_KEY (или запустите с -DryRun).'
}

$match = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)'
if (-not $match) { throw 'В pubspec.yaml нет строки version: X.Y.Z+N' }
$version = $match.Matches[0].Groups[1].Value
$build = $match.Matches[0].Groups[2].Value

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$dirty = git status --porcelain --untracked-files=no
if ($branch -ne 'main') { Write-Warning "Сборка не из ветки main (сейчас $branch)." }
if ($dirty) { Write-Warning 'В рабочей папке есть незакоммиченные изменения: выпуск будет отличаться от кода в GitHub.' }

Step "Тесты"
flutter test
if ($LASTEXITCODE -ne 0) { throw 'Тесты не прошли, выпуск остановлен.' }

Step "Сборка nox.drive $version (сборка $build)"
flutter build windows --release "--dart-define=SUPABASE_URL=$env:SUPABASE_URL" "--dart-define=SUPABASE_ANON_KEY=$env:SUPABASE_ANON_KEY"
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows завершился с ошибкой' }

$release = 'build\windows\x64\runner\Release'
foreach ($tool in 'adb', 'scrcpy') {
  if (-not (Test-Path "$release\$tool\$tool.exe")) {
    if (Test-Path "windows\$tool\$tool.exe") {
      Copy-Item "windows\$tool" "$release\$tool" -Recurse -Force
    } else {
      throw "Нет $tool\$tool.exe ни в $release, ни в windows\$tool. Положите папку $tool туда."
    }
  }
}

Step 'Упаковка'
$zip = "build\nox-windows-$version+$build.zip"
if (Test-Path $zip) { Remove-Item $zip }
# Не Compress-Archive: в PowerShell 5.1 он пишет пути через «\», такие архивы распаковываются криво.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory(
  (Resolve-Path $release).Path, (Join-Path (Resolve-Path 'build').Path (Split-Path $zip -Leaf)),
  [IO.Compression.CompressionLevel]::Optimal, $false)

Step 'Проверки и публикация'
$publishArgs = @('run', 'tool/publish_release.dart', '--file', $zip, '--platform', 'windows')
if ($Notes) { $publishArgs += @('--notes', $Notes) }
if ($Mandatory) { $publishArgs += '--mandatory' }
if ($DryRun) { $publishArgs += '--dry-run' }
dart @publishArgs
if ($LASTEXITCODE -ne 0) { throw 'Выпуск остановлен (подробности выше).' }
