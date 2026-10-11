# Baut die Dienstplan-Seite auf GitHub (laeuft in GitHub Actions).
# Der persoenliche Kalender-Link kommt aus dem Secret ICS_URL und erscheint nirgends in der Seite.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$icsUrl = $env:ICS_URL
if (-not $icsUrl) { throw 'Das Secret ICS_URL fehlt (Settings > Secrets and variables > Actions).' }

$bytes = (Invoke-WebRequest -Uri $icsUrl -UseBasicParsing).RawContentStream.ToArray()
$text = [Text.Encoding]::UTF8.GetString($bytes)
if ($text -notmatch 'BEGIN:VCALENDAR') { throw 'Download ist kein ICS-Kalender.' }
$b64 = [Convert]::ToBase64String($bytes)

$land = (Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/land-110m.json' -UseBasicParsing).RawContentStream.ToArray()
$landJson = [Text.Encoding]::UTF8.GetString($land)

$template = [IO.File]::ReadAllText((Join-Path $dir 'template.html'), [Text.Encoding]::UTF8)
$body = $template.Replace('__ICS_B64__', $b64).Replace('__LAND_JSON__', $landJson)

$head = '<!doctype html><html lang="de"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' +
  '<meta name="robots" content="noindex">' +
  '<style>html,body{margin:0}[hidden]{display:none!important}img{max-width:100%}</style></head><body>'
$html = $head + $body + '</body></html>'

# Seite mit dem Passwort aus dem Secret PAGE_PASSWORD verschluesseln (PBKDF2-SHA256 + AES-GCM),
# damit weder die Webseite noch die Build-Dateien den Plan im Klartext enthalten.
$pw = $env:PAGE_PASSWORD
if (-not $pw) { throw 'Das Secret PAGE_PASSWORD fehlt (Settings > Secrets and variables > Actions).' }
$iter = 600000
$salt = [byte[]]::new(16); $iv = [byte[]]::new(12)
[Security.Cryptography.RandomNumberGenerator]::Fill($salt)
[Security.Cryptography.RandomNumberGenerator]::Fill($iv)
$key = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes($pw), $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256, 32)
$plain = [Text.Encoding]::UTF8.GetBytes($html)
$cipher = [byte[]]::new($plain.Length); $tag = [byte[]]::new(16)
$aes = [Security.Cryptography.AesGcm]::new($key, 16)
$aes.Encrypt($iv, $plain, $cipher, $tag)
$blob = [byte[]]::new($cipher.Length + 16)
[Array]::Copy($cipher, 0, $blob, 0, $cipher.Length)
[Array]::Copy($tag, 0, $blob, $cipher.Length, 16)

$lock = [IO.File]::ReadAllText((Join-Path $dir 'lock.html'), [Text.Encoding]::UTF8)
$page = $lock.Replace('__SALT__', [Convert]::ToBase64String($salt)).Replace('__IV__', [Convert]::ToBase64String($iv)).Replace('__ITER__', "$iter").Replace('__DATA__', [Convert]::ToBase64String($blob))

$outDir = Join-Path $dir 'public'
New-Item -ItemType Directory -Force $outDir | Out-Null
[IO.File]::WriteAllText((Join-Path $outDir 'index.html'), $page, (New-Object Text.UTF8Encoding $false))

$count = ([regex]::Matches($text, 'BEGIN:VEVENT')).Count
Write-Output "Seite gebaut: $count Eintraege"
