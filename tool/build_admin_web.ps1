# Сборка сайта админ-панели (Flutter web, lib/main_admin.dart) в build\admin_web.
# Нужны SUPABASE_URL и SUPABASE_ANON_KEY (публичный ключ) в переменных окружения.
# Публикация: vercel deploy --prod из build\admin_web (проект noxdrive-admin).
param(
  [string]$SupabaseUrl = $env:SUPABASE_URL,
  [string]$SupabaseAnonKey = $env:SUPABASE_ANON_KEY
)
$ErrorActionPreference = 'Stop'
if (-not $SupabaseUrl -or -not $SupabaseAnonKey) { throw 'Нужны SUPABASE_URL и SUPABASE_ANON_KEY' }
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\admin_web'
Push-Location $root
try {
  flutter build web -t lib/main_admin.dart --release --output $out `
    --dart-define=SUPABASE_URL=$SupabaseUrl --dart-define=SUPABASE_ANON_KEY=$SupabaseAnonKey
  if ($LASTEXITCODE -ne 0) { throw 'flutter build web упал' }

  # Сборка в свою папку не всегда копирует manifest и значок: берём их из web\.
  foreach ($f in 'manifest.json', 'favicon.png') {
    if (-not (Test-Path (Join-Path $out $f))) { Copy-Item (Join-Path $root "web\$f") $out }
  }

  # Своё имя на главном экране телефона и поворот экрана (трансляция смотрится горизонтально).
  $manifest = Get-Content (Join-Path $out 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $manifest.name = 'nox.drive · Админ'
  $manifest.short_name = 'nox Админ'
  $manifest.description = 'nox.drive: админ-панель'
  $manifest.orientation = 'any'
  $utf8 = New-Object Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $out 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), $utf8)

  $index = Join-Path $out 'index.html'
  $html = Get-Content $index -Raw -Encoding UTF8
  $html = $html -replace '<title>[^<]*</title>', '<title>nox.drive · Админ</title>'
  $html = $html -replace 'content="nox.drive: кабинет мастера"', 'content="nox.drive: админ-панель"'
  $html = $html -replace '(apple-mobile-web-app-title" content=")[^"]*', '${1}nox Админ'
  # Поисковики сайт админки не индексируют.
  $html = $html -replace '</head>', "  <meta name=`"robots`" content=`"noindex, nofollow`">`n</head>"
  [IO.File]::WriteAllText($index, $html, $utf8)

  # Новая версия сайта подхватывается сразу, без «залипания» в кэше браузера.
  @'
{
  "headers": [
    { "source": "/(index.html|flutter_bootstrap.js|flutter_service_worker.js|manifest.json|version.json)?",
      "headers": [{ "key": "Cache-Control", "value": "no-cache" }] },
    { "source": "/(.*)",
      "headers": [{ "key": "X-Robots-Tag", "value": "noindex" }, { "key": "X-Frame-Options", "value": "DENY" }] }
  ]
}
'@ | ForEach-Object { [IO.File]::WriteAllText((Join-Path $out 'vercel.json'), $_, $utf8) }
  # Привязка к проекту Vercel (папка build пересоздаётся при каждой сборке).
  Push-Location $out
  try { npx -y vercel@latest link --yes --project noxdrive-admin | Out-Null } finally { Pop-Location }
  Write-Host "Готово: $out. Публикация: cd build/admin_web; npx vercel deploy --prod --yes"
} finally { Pop-Location }
