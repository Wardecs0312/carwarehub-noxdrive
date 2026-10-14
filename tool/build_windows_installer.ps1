<#
  Сборка установщика nox.drive для Windows одной командой.

  Что нужно на компьютере: Flutter, Visual Studio Build Tools (C++), Inno Setup 6,
  папка windows\adb с adb.exe, AdbWinApi.dll, AdbWinUsbApi.dll (из Android platform-tools).

  Запуск (из любой папки):
    $env:SUPABASE_URL = 'https://<project>.supabase.co'
    $env:SUPABASE_ANON_KEY = '<publishable/anon key>'
    powershell -ExecutionPolicy Bypass -File tool\build_windows_installer.ps1

  Результат: installer\Output\nox.drive-Setup-<версия>.exe и строка SQL для таблицы app_releases.
  Версия берётся из pubspec.yaml (version: 1.0.0+1). Для нового выпуска увеличьте её там.
  Ключ service_role здесь не нужен и не используется.
#>
param(
  [string]$SupabaseUrl = $env:SUPABASE_URL,
  [string]$SupabaseAnonKey = $env:SUPABASE_ANON_KEY
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $SupabaseUrl -or -not $SupabaseAnonKey) {
  throw 'Задайте SUPABASE_URL и SUPABASE_ANON_KEY, иначе программа соберётся в демо-режиме без входа.'
}
foreach ($f in 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll') {
  if (-not (Test-Path "windows\adb\$f")) {
    throw "Нет файла windows\adb\$f. Скопируйте его из Android platform-tools."
  }
}

$match = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)'
if (-not $match) { throw 'В pubspec.yaml нет строки version: X.Y.Z+N' }
$version = $match.Matches[0].Groups[1].Value
$build = $match.Matches[0].Groups[2].Value

# Библиотеки Visual C++ из установленных Build Tools
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -property installationPath
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT" -Directory |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'Не найдены библиотеки Visual C++ (Microsoft.VC14x.CRT). Установите Visual Studio Build Tools с C++.' }

$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Не найден Inno Setup 6 (ISCC.exe).' }

Write-Host "Сборка nox.drive $version (сборка $build)..."
flutter build windows --release "--dart-define=SUPABASE_URL=$SupabaseUrl" "--dart-define=SUPABASE_ANON_KEY=$SupabaseAnonKey"
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows завершился с ошибкой' }

Write-Host 'Упаковка установщика...'
& $iscc /Q "/DAppVersion=$version" "/DBuildNumber=$build" "/DVcRedistDir=$($crt.FullName)" 'installer\nox_drive.iss'
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup завершился с ошибкой' }

$out = "installer\Output\nox.drive-Setup-$version.exe"
$hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $out).Length

Write-Host ''
Write-Host "Готово: $out"
Write-Host "Размер: $([math]::Round($size / 1MB, 1)) МБ"
Write-Host "SHA-256: $hash"
Write-Host ''
Write-Host 'Чтобы мастера получили обновление:'
Write-Host "1. Загрузите файл в Supabase Storage, bucket 'releases', путь windows/nox.drive-Setup-$version.exe"
Write-Host '2. Выполните в SQL Editor:'
Write-Host "insert into app_releases (platform, channel, version, build_number, download_path, sha256, size_bytes) values ('windows', 'stable', '$version', $build, 'windows/nox.drive-Setup-$version.exe', '$hash', $size);"
