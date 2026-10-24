# Holt den Live-Status (Verspaetungen, Gate) fuer Joels aktuelle Fluege bei AeroDataBox
# und speichert ihn verschluesselt als status.enc. Laeuft alle 10 Minuten in GitHub Actions,
# fragt die API aber nur rund um Fluege und gedrosselt ab, damit das Gratis-Kontingent reicht.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$icsUrl = $env:ICS_URL; $pw = $env:PAGE_PASSWORD; $apiKey = $env:AERODATABOX_KEY
if (-not $icsUrl -or -not $pw) { throw 'Secrets ICS_URL oder PAGE_PASSWORD fehlen.' }
if (-not $apiKey) { Write-Output 'Kein AERODATABOX_KEY hinterlegt - nichts zu tun.'; exit 0 }
$iter = 600000

# --- Verschluesselung wie in build-github.ps1 / lock.html ---
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
function To-Ms([datetime]$d) { return [DateTimeOffset]::new($d.ToUniversalTime()).ToUnixTimeMilliseconds() }
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# --- Fluege aus dem Dienstplan ---
$text = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest -Uri $icsUrl -UseBasicParsing).RawContentStream.ToArray())
$unfolded = $text -replace "`r?`n[ `t]", ''
$styles = [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal'
$inv = [Globalization.CultureInfo]::InvariantCulture
$flights = @()
foreach ($ev in [regex]::Matches($unfolded, 'BEGIN:VEVENT(.*?)END:VEVENT', 'Singleline')) {
  $b = $ev.Groups[1].Value
  $summary = [regex]::Match($b, '(?m)^SUMMARY[^:\r\n]*:(.*?)\r?$').Groups[1].Value.Trim()
  $mt = [regex]::Match($summary, '^([A-Z0-9]{2})\s?(\d{1,4}[A-Z]?)\s+([A-Z]{3})\s+(\d{4})\s+([A-Z]{3})\s')
  if (-not $mt.Success) { continue }
  $ds = [regex]::Match($b, '(?m)^DTSTART[^:\r\n]*:(\d{8}T\d{6})Z').Groups[1].Value
  $de = [regex]::Match($b, '(?m)^DTEND[^:\r\n]*:(\d{8}T\d{6})Z').Groups[1].Value
  if (-not $ds -or -not $de) { continue }
  $start = [datetime]::ParseExact($ds, 'yyyyMMddTHHmmss', $inv, $styles)
  $end = [datetime]::ParseExact($de, 'yyyyMMddTHHmmss', $inv, $styles)
  # Lokales Abflugdatum: Differenz zwischen Ortszeit (aus dem Titel) und UTC
  $locMin = [int]$mt.Groups[4].Value.Substring(0, 2) * 60 + [int]$mt.Groups[4].Value.Substring(2, 2)
  $utcMin = $start.Hour * 60 + $start.Minute
  $off = $locMin - $utcMin
  if ($off -gt 840) { $off -= 1440 } elseif ($off -lt -720) { $off += 1440 }
  $flights += [pscustomobject]@{
    key = ($mt.Groups[1].Value + $mt.Groups[2].Value) + '|' + $start.ToString("yyyyMMdd'T'HHmmss'Z'", $inv)
    fno = $mt.Groups[1].Value + $mt.Groups[2].Value; from = $mt.Groups[3].Value
    dep = To-Ms $start; arr = To-Ms $end; localDate = $start.AddMinutes($off).ToString('yyyy-MM-dd', $inv)
  }
}

# --- Bisherigen Status laden ---
$file = Join-Path $dir 'status.enc'
$state = @{}
if (Test-Path $file) {
  try {
    $prev = [Text.Encoding]::UTF8.GetString((Unprotect-Bytes (Get-Content $file -Raw | ConvertFrom-Json))) | ConvertFrom-Json
    foreach ($p in $prev.flights.PSObject.Properties) { $state[$p.Name] = $p.Value }
  } catch { Write-Warning 'Bisheriger Status nicht lesbar, beginne neu.' }
}

function Get-Ms($t) {
  if (-not $t -or -not $t.utc) { return $null }
  $v = $t.utc
  if ($v -is [datetime]) { return To-Ms $v }
  return [DateTimeOffset]::Parse(([string]$v), $inv).ToUnixTimeMilliseconds()
}
function Get-Local($t) {
  if (-not $t -or -not $t.local) { return $null }
  $v = $t.local
  if ($v -is [datetime]) { return $v.ToString('HH:mm', $inv) }
  $m = [regex]::Match([string]$v, '(\d{2}:\d{2})'); if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

$calls = 0; $changed = $false
foreach ($f in $flights) {
  $s = $state[$f.key]
  if ($s -and $s.fin) { continue }
  $depEff = $f.dep; $arrEff = $f.arr
  if ($s) { if ($s.dAct) { $depEff = $s.dAct } elseif ($s.dRev) { $depEff = $s.dRev }; if ($s.aAct) { $arrEff = $s.aAct } elseif ($s.aRev) { $arrEff = $s.aRev } }
  # Zeitfenster: 2 Std vor Abflug bis 1 Std nach Ankunft
  if ($nowMs -lt $f.dep - 2 * 3600000 -or $nowMs -gt $arrEff + 3600000) { continue }
  # Drosselung: vor Abflug alle 30 Min, im Flug alle 90 Min, letzte Stunde vor Landung alle 30 Min
  $interval = 30
  if ($nowMs -ge $depEff -and $nowMs -lt $arrEff - 3600000) { $interval = 90 }
  if ($s -and $s.at -and ($nowMs - $s.at) -lt $interval * 60000) { continue }

  $url = "https://aerodatabox.p.rapidapi.com/flights/number/$($f.fno)/$($f.localDate)?withAircraftImage=false&withLocation=false&dateLocalRole=Departure"
  try {
    $res = Invoke-RestMethod -Uri $url -Headers @{ 'X-RapidAPI-Key' = $apiKey; 'X-RapidAPI-Host' = 'aerodatabox.p.rapidapi.com' } -TimeoutSec 30
    $calls++
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    Write-Warning "Abfrage $($f.fno) fehlgeschlagen ($code)."
    if ($code -eq 429 -or $code -eq 403) { Write-Warning 'Kontingent aufgebraucht oder Schluessel ungueltig - fuer diesen Lauf Schluss.'; break }
    continue
  }
  $items = @($res)
  $it = ($items | Where-Object { $_.departure.airport.iata -eq $f.from } | Select-Object -First 1)
  if (-not $it) { $it = $items | Select-Object -First 1 }
  if (-not $it) { continue }
  $d = $it.departure; $a = $it.arrival
  $st = [string]$it.status
  $entry = [ordered]@{
    st = $st
    dRev = Get-Ms $d.revisedTime; dAct = Get-Ms $d.runwayTime; dLoc = Get-Local $d.revisedTime
    aRev = Get-Ms $a.revisedTime; aAct = Get-Ms $a.runwayTime; aLoc = Get-Local $a.revisedTime
    dGate = $d.gate; dTerm = $d.terminal; aGate = $a.gate; aTerm = $a.terminal; belt = $a.baggageBelt
    at = $nowMs
    fin = ($st -match 'Arrived|Landed|Canceled|Diverted')
  }
  $state[$f.key] = [pscustomobject]$entry
  $changed = $true
  Write-Output "$($f.fno) $($f.localDate): $st"
}

# Alte Eintraege (Ankunft vor mehr als 2 Tagen) aufraeumen
foreach ($k in @($state.Keys)) {
  $f = $flights | Where-Object { $_.key -eq $k } | Select-Object -First 1
  if (-not $f -or $f.arr -lt $nowMs - 2 * 86400000) { $state.Remove($k); $changed = $true }
}

if ($changed) {
  $json = ConvertTo-Json -InputObject ([ordered]@{ updated = $nowMs; flights = $state }) -Compress -Depth 5
  $enc = Protect-Bytes ([Text.Encoding]::UTF8.GetBytes($json))
  [IO.File]::WriteAllText($file, ($enc | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
  Write-Output "Status gespeichert ($calls API-Abfragen)."
} else {
  Write-Output 'Keine Fluege im Zeitfenster - keine Abfrage.'
}
