# Baut die Dienstplan-Seite auf GitHub (laeuft in GitHub Actions).
# Der persoenliche Kalender-Link kommt aus dem Secret ICS_URL und erscheint nirgends in der Seite.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$icsUrl = $env:ICS_URL
if (-not $icsUrl) { throw 'Das Secret ICS_URL fehlt (Settings > Secrets and variables > Actions).' }
$pw = $env:PAGE_PASSWORD
if (-not $pw) { throw 'Das Secret PAGE_PASSWORD fehlt (Settings > Secrets and variables > Actions).' }
$iter = 600000

# --- Verschluesselung (PBKDF2-SHA256 + AES-GCM), passend zu lock.html ---
function New-Key([byte[]]$salt) {
  $k = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2([Text.Encoding]::UTF8.GetBytes($pw), $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256, 32)
  return , $k
}
function Protect-Bytes([byte[]]$plain) {
  $salt = [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
  $iv = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
  $aes = [Security.Cryptography.AesGcm]::new([byte[]](New-Key $salt), 16)
  $cipher = [byte[]]::new($plain.Length); $tag = [byte[]]::new(16)
  $aes.Encrypt($iv, $plain, $cipher, $tag)
  $blob = [byte[]]::new($cipher.Length + 16)
  [Array]::Copy($cipher, 0, $blob, 0, $cipher.Length)
  [Array]::Copy($tag, 0, $blob, $cipher.Length, 16)
  [pscustomobject]@{ salt = [Convert]::ToBase64String($salt); iv = [Convert]::ToBase64String($iv); data = [Convert]::ToBase64String($blob) }
}
function Unprotect-Bytes($o) {
  $salt = [Convert]::FromBase64String($o.salt); $iv = [Convert]::FromBase64String($o.iv); $blob = [Convert]::FromBase64String($o.data)
  $n = $blob.Length - 16
  $cipher = [byte[]]::new($n); $tag = [byte[]]::new(16); $plain = [byte[]]::new($n)
  [Array]::Copy($blob, 0, $cipher, 0, $n)
  [Array]::Copy($blob, $n, $tag, 0, 16)
  $aes = [Security.Cryptography.AesGcm]::new([byte[]](New-Key $salt), 16)
  $aes.Decrypt($iv, $cipher, $tag, $plain)
  return , $plain
}

# --- Dienstplan laden ---
$bytes = (Invoke-WebRequest -Uri $icsUrl -UseBasicParsing).RawContentStream.ToArray()
$text = [Text.Encoding]::UTF8.GetString($bytes)
if ($text -notmatch 'BEGIN:VCALENDAR') { throw 'Download ist kein ICS-Kalender.' }
# Leerer Kalender (z. B. abgelaufener Link): abbrechen, damit die bisherige Seite online bleibt.
if ($text -notmatch 'BEGIN:VEVENT') { throw 'Der Kalender ist leer. Ist der Link in ICS_URL abgelaufen? Bitte den neuen Link aus dem SWISS-Portal eintragen.' }
$b64 = [Convert]::ToBase64String($bytes)

# --- Flug-Historie: vergangene Fluege bleiben erhalten, auch wenn der Monatslink wechselt ---
# Fehler hier duerfen die Seite nie blockieren: dann einfach ohne Historie weiterbauen.
$histJson = '[]'
try {
$unfolded = $text -replace "`r?`n[ `t]", ''
$current = @()
foreach ($ev in [regex]::Matches($unfolded, 'BEGIN:VEVENT(.*?)END:VEVENT', 'Singleline')) {
  $b = $ev.Groups[1].Value
  $summary = [regex]::Match($b, '(?m)^SUMMARY[^:\r\n]*:(.*?)\r?$').Groups[1].Value.Trim()
  $mt = [regex]::Match($summary, '^([A-Z0-9]{2})\s?(\d{1,4}[A-Z]?)\s+([A-Z]{3})\s+\d{4}\s+([A-Z]{3})\s')
  if (-not $mt.Success) { continue }
  $ds = [regex]::Match($b, '(?m)^DTSTART[^:\r\n]*:(\d{8}T\d{6})Z').Groups[1].Value
  $de = [regex]::Match($b, '(?m)^DTEND[^:\r\n]*:(\d{8}T\d{6})Z').Groups[1].Value
  if (-not $ds) { continue }
  $styles = [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal'
  $start = [datetime]::ParseExact($ds, 'yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture, $styles)
  $mins = 0
  if ($de) { $mins = [int]([datetime]::ParseExact($de, 'yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture, $styles) - $start).TotalMinutes }
  $current += [pscustomobject]@{
    # Kompaktes Datumsformat, damit ConvertFrom-Json es nicht in ein DateTime umwandelt
    d = $start.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    f = $mt.Groups[1].Value + $mt.Groups[2].Value; a = $mt.Groups[3].Value; b = $mt.Groups[4].Value; m = $mins
  }
}

$histFile = Join-Path $dir 'history.enc'
$prevJson = $null; $history = @()
if (Test-Path $histFile) {
  try {
    $prevJson = [Text.Encoding]::UTF8.GetString((Unprotect-Bytes (Get-Content $histFile -Raw | ConvertFrom-Json)))
    $history = @($prevJson | ConvertFrom-Json)
  } catch {
    Write-Warning 'Historie konnte nicht entschluesselt werden (Passwort geaendert?). Sie wird neu begonnen.'
    $history = @()
  }
}
$nowIso = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$byKey = [ordered]@{}
# Vergangene Fluege aus der Historie behalten; kuenftige kommen nur aus dem aktuellen Plan (Streichungen fallen weg)
foreach ($h in $history) { if ($h.d -and [string]::CompareOrdinal([string]$h.d, $nowIso) -lt 0) { $byKey["$($h.f)|$($h.d)"] = $h } }
foreach ($c in $current) { $byKey["$($c.f)|$($c.d)"] = $c }
$merged = @($byKey.Values | Sort-Object { $_.d })
$histJson = if ($merged.Count) { ConvertTo-Json -InputObject $merged -Compress -Depth 3 } else { '[]' }
if ($histJson -ne $prevJson) {
  $enc = Protect-Bytes ([Text.Encoding]::UTF8.GetBytes($histJson))
  [IO.File]::WriteAllText($histFile, ($enc | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
  Write-Output "Historie aktualisiert: $($merged.Count) Fluege"
}
} catch {
  Write-Warning "Historie uebersprungen: $($_.Exception.Message)"
  $histJson = '[]'
}

# --- Seite zusammensetzen ---
$land = (Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/land-110m.json' -UseBasicParsing).RawContentStream.ToArray()
$landJson = [Text.Encoding]::UTF8.GetString($land)

$template = [IO.File]::ReadAllText((Join-Path $dir 'template.html'), [Text.Encoding]::UTF8)
$body = $template.Replace('__ICS_B64__', $b64).Replace('__LAND_JSON__', $landJson).Replace('__HISTORY_JSON__', $histJson)

$head = '<!doctype html><html lang="de"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' +
  '<meta name="robots" content="noindex">' +
  '<script>try{if(localStorage.getItem("dienstplan-theme")==="light")document.documentElement.setAttribute("data-theme","light")}catch(e){}</script>' +
  '<style>html,body{margin:0}html{background:#0a1120}html[data-theme="light"]{background:#eef2f7}[hidden]{display:none!important}img{max-width:100%}</style></head><body>'
$html = $head + $body + '</body></html>'

# --- Seite mit PAGE_PASSWORD verschluesseln, damit weder Webseite noch Build-Dateien den Plan im Klartext enthalten ---
$enc = Protect-Bytes ([Text.Encoding]::UTF8.GetBytes($html))
$lock = [IO.File]::ReadAllText((Join-Path $dir 'lock.html'), [Text.Encoding]::UTF8)
$page = $lock.Replace('__SALT__', $enc.salt).Replace('__IV__', $enc.iv).Replace('__ITER__', "$iter").Replace('__DATA__', $enc.data)

$outDir = Join-Path $dir 'public'
New-Item -ItemType Directory -Force $outDir | Out-Null
[IO.File]::WriteAllText((Join-Path $outDir 'index.html'), $page, (New-Object Text.UTF8Encoding $false))

$count = ([regex]::Matches($text, 'BEGIN:VEVENT')).Count
Write-Output "Seite gebaut: $count Eintraege, $($current.Count) Fluege im Plan"
