# kg.ps1 - open a Krang plugin from PowerShell on Windows.
#
#   kg WIDGET [ARGS...]
#   ls *.jpeg | kg img
#   "main", "dev" | kg pick
#
# Request: ESC ] 7777 ; TOKEN ; open ; ID ; WIDGET ; BASE64(cwd \x1e payload) BEL
# Parts  : ESC ] 7777 ; TOKEN ; part ; ID ; BASE64 CHUNK BEL   (before open, if long)
# Ack    : 7777 ; ID ; opened BEL
# Reply  : 7777 ; ID ; result ; BASE64 BEL  |  7777 ; ID ; cancel BEL
#          (typed in as plain characters: ConPTY drops escape sequences
#           it doesn't know from its input)
#
# Exit status: 0 answered, 1 cancelled, 2 could not ask.

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Widget,
  [Parameter(ValueFromPipeline = $true)][object]$InputObject,
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

begin {
  $items = New-Object System.Collections.Generic.List[string]

  function Fail($msg) {
    [Console]::Error.WriteLine("kg: $msg")
    exit 2
  }
}

# once per piped object: files become absolute paths, anything else a string
process {
  if ($null -eq $InputObject) { return }

  if ($InputObject -is [System.IO.FileSystemInfo]) {
    $items.Add($InputObject.FullName)
  } else {
    $items.Add("$InputObject")
  }
}

end {
  # pwsh on macOS/Linux: the POSIX script does the job
  if ($env:OS -ne 'Windows_NT') {
    $sh = Join-Path $PSScriptRoot 'hk'
    if ($items.Count -gt 0) { $items | & sh $sh $Widget @Rest } else { & sh $sh $Widget @Rest }
    exit $LASTEXITCODE
  }

  if (-not $Widget) { [Console]::Error.WriteLine("usage: kg WIDGET [ARGS...]"); exit 2 }
  if (-not $env:HOKUSAI_TOKEN) { Fail "not running inside Krang" }
  if ($env:SSH_CONNECTION) { Fail "only works in a local Krang shell" }

  if ($Rest) {
    $payload = $Rest -join ' '
  } elseif ($items.Count -gt 0) {
    $payload = $items -join "`n"
  } else {
    $payload = ''
  }

  $esc = [char]27
  $bel = [char]7
  $rs = [char]0x1e
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $cwd = (Get-Location).ProviderPath
  $body = [Convert]::ToBase64String($utf8.GetBytes("$cwd$rs$payload"))
  $id = "$PID-$(Get-Random)"
  $token = $env:HOKUSAI_TOKEN

  # Reads typed-in characters up to BEL. With a deadline, returns $null if
  # nothing complete arrived in time.
  function Read-Frame($deadline) {
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
      if ($deadline -and -not [Console]::KeyAvailable) {
        if ([DateTime]::Now -gt $deadline) { return $null }
        Start-Sleep -Milliseconds 20
        continue
      }
      $key = [Console]::ReadKey($true)
      if ($key.KeyChar -eq $bel) { return $sb.ToString() }
      [void]$sb.Append($key.KeyChar)
    }
  }

  # Ctrl+C arrives as a key instead of killing us mid-read
  $oldTreat = [Console]::TreatControlCAsInput
  [Console]::TreatControlCAsInput = $true

  $reply = $null
  try {
    # conhost drops OSC sequences past a certain length (and prints the rest),
    # so the payload goes out in small frames that Krang reassembles
    $chunk = 128
    for ($i = 0; $i + $chunk -lt $body.Length; $i += $chunk) {
      [Console]::Write("$esc]7777;$token;part;$id;$($body.Substring($i, $chunk))$bel")
    }
    $last = $body.Substring([Math]::Floor(($body.Length - 1) / $chunk) * $chunk)
    [Console]::Write("$esc]7777;$token;open;$id;$Widget;$last$bel")

    # ConPTY only forwards a passed-through sequence along with screen output,
    # so draw something or the request sits in ConPTY while we wait
    [Console]::Write("kg: waiting for $Widget...")

    # Krang acknowledges a request it received. No ack in time means it never
    # arrived, so fail instead of waiting forever.
    $first = Read-Frame ([DateTime]::Now.AddSeconds(2))
    if ($null -eq $first) {
      $reply = ''
      [Console]::Write("`r$esc[2K")
      Fail "Krang didn't receive the request"
    }

    # the ack, then the answer (a plugin can also answer at once, or there's
    # no such plugin: then the first frame is already the answer)
    $reply = if ($first -like "*;$id;opened") { Read-Frame $null } else { $first }
  }
  finally {
    [Console]::TreatControlCAsInput = $oldTreat
    # no answer read: close the widget
    if ($null -eq $reply) { [Console]::Write("$esc]7777;$token;cancel;$id$bel") }
    # clear the waiting line
    [Console]::Write("`r$esc[2K")
  }

  if ($reply -like "*;$id;result;*") {
    $b64 = $reply.Substring($reply.LastIndexOf(';') + 1)
    $utf8.GetString([Convert]::FromBase64String($b64))
    exit 0
  }
  if ($reply -like "*;$id;unsupported*") { Fail "no plugin named '$Widget'" }
  exit 1
}