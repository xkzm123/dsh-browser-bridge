# server.ps1 - localhost command bridge for dsh-browser-bridge
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1 -Port 8737
#
# A userscript (bridge/bridge.user.js) polls this server from inside the page and
# evaluates whatever JavaScript the agent enqueues. That gives the agent real DOM
# access in an ALREADY RUNNING browser, without a restart and without CDP.
#
# Protocol (all JSON, all on 127.0.0.1):
#   GET  /ping                -> {"ok":true,"pending":N}
#   GET  /poll                -> {"id":N,"code":"..."} | {"id":0}
#   POST /cmd    {"code":...} -> {"id":N}
#   POST /result {"id":N,"ok":bool,"value":...,"error":...,"url":...}
#   GET  /result?id=N         -> {"status":"pending"} | {"status":"done",...}

param(
    [int]$Port = 8737,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:seq = 0
$script:jobs = @{}        # id -> @{ code; created }
$script:results = @{}     # id -> result hashtable
$script:order = New-Object System.Collections.Queue
$script:lastPoll = $null

function Write-Json($obj) { $obj | ConvertTo-Json -Depth 6 -Compress }

function Read-HttpRequest {
    param([System.Net.Sockets.NetworkStream]$Stream)
    $buf = New-Object byte[] 8192
    $sb = New-Object System.Text.StringBuilder
    $headerEnd = -1
    $total = 0
    while ($headerEnd -lt 0 -and $total -lt 65536) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $total += $n
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $n))
        $headerEnd = $sb.ToString().IndexOf("`r`n`r`n")
    }
    $raw = $sb.ToString()
    if ($raw.Length -eq 0) { return $null }

    $split = $raw.IndexOf("`r`n`r`n")
    $head = if ($split -ge 0) { $raw.Substring(0, $split) } else { $raw }
    $body = if ($split -ge 0) { $raw.Substring($split + 4) } else { '' }

    $lines = $head -split "`r`n"
    $requestLine = $lines[0] -split ' '
    $method = $requestLine[0]
    $path = $requestLine[1]

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $idx = $lines[$i].IndexOf(':')
        if ($idx -gt 0) { $headers[$lines[$i].Substring(0, $idx).Trim().ToLower()] = $lines[$i].Substring($idx + 1).Trim() }
    }

    $len = 0
    if ($headers.ContainsKey('content-length')) { [int]::TryParse($headers['content-length'], [ref]$len) | Out-Null }
    while ($body.Length -lt $len) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $body += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    }

    return @{ method = $method; path = $path; headers = $headers; body = $body }
}

function Send-Response {
    param($Stream, [string]$Body, [string]$Status = '200 OK', [string]$ContentType = 'application/json; charset=utf-8')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $head = "HTTP/1.1 $Status`r`n" +
    "Content-Type: $ContentType`r`n" +
    "Content-Length: $($bytes.Length)`r`n" +
    "Access-Control-Allow-Origin: *`r`n" +
    "Access-Control-Allow-Headers: content-type`r`n" +
    "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    try {
        $Stream.Write($hb, 0, $hb.Length)
        $Stream.Write($bytes, 0, $bytes.Length)
        $Stream.Flush()
    } catch { }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
}
catch {
    Write-Host "cannot bind 127.0.0.1:$Port -> $($_.Exception.Message)"
    exit 1
}

if (-not $Quiet) { Write-Host "dsh-browser-bridge listening on http://127.0.0.1:$Port/" }

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 3000
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $req = Read-HttpRequest -Stream $stream
        if (-not $req) { $client.Close(); continue }

        $pathOnly = ($req.path -split '\?')[0]
        $query = @{}
        if ($req.path -match '\?(.+)$') {
            foreach ($kv in ($matches[1] -split '&')) {
                $p = $kv -split '=', 2
                if ($p.Count -eq 2) { $query[$p[0]] = [System.Uri]::UnescapeDataString($p[1]) }
            }
        }

        switch -Regex ($pathOnly) {

            '^/ping$' {
                Send-Response $stream (Write-Json @{ ok = $true; pending = $script:order.Count; version = 1 })
            }

            '^/poll$' {
                $job = $null
                if ($script:order.Count -gt 0) {
                    $id = $script:order.Dequeue()
                    if ($script:jobs.ContainsKey($id)) { $job = $script:jobs[$id] }
                }
                $script:lastPoll = Get-Date
                if ($job) { Send-Response $stream (Write-Json @{ id = $id; code = $job.code; op = $job.op; args = $job.args }) }
                else { Send-Response $stream (Write-Json @{ id = 0 }) }
            }

            '^/cmd$' {
                try { $payload = $req.body | ConvertFrom-Json } catch { Send-Response $stream (Write-Json @{ ok = $false; error = 'bad json' }) '400 Bad Request'; break }
                $script:seq++
                $id = $script:seq
                $script:jobs[$id] = @{ code = $payload.code; op = $payload.op; args = $payload.args; created = (Get-Date) }
                $script:order.Enqueue($id) | Out-Null
                Send-Response $stream (Write-Json @{ ok = $true; id = $id })
            }

            '^/requeue$' {
                # 隐藏标签页把任务还回来，交给当前可见的那个执行
                try { $payload = $req.body | ConvertFrom-Json } catch { Send-Response $stream (Write-Json @{ ok = $false }) '400 Bad Request'; break }
                $rid = [int]$payload.id
                if ($script:jobs.ContainsKey($rid) -and -not $script:results.ContainsKey($rid)) {
                    $script:order.Enqueue($rid) | Out-Null
                    Send-Response $stream (Write-Json @{ ok = $true; requeued = $rid })
                }
                else { Send-Response $stream (Write-Json @{ ok = $true; requeued = 0 }) }
            }

            '^/result$' {
                if ($req.method -eq 'POST') {
                    try { $payload = $req.body | ConvertFrom-Json } catch { Send-Response $stream (Write-Json @{ ok = $false }) '400 Bad Request'; break }
                    $rid = [int]$payload.id
                    $script:results[$rid] = @{
                        ok    = [bool]$payload.ok
                        value = $payload.value
                        error = $payload.error
                        url   = $payload.url
                        title = $payload.title
                        at    = (Get-Date).ToString('HH:mm:ss')
                    }
                    Send-Response $stream (Write-Json @{ ok = $true })
                }
                else {
                    $rid = [int]$query['id']
                    if ($script:results.ContainsKey($rid)) {
                        $r = $script:results[$rid]
                        Send-Response $stream (Write-Json @{ status = 'done'; ok = $r.ok; value = $r.value; error = $r.error; url = $r.url; title = $r.title })
                    }
                    else { Send-Response $stream (Write-Json @{ status = 'pending' }) }
                }
            }

            '^/install\.user\.js$' {
                # serve the userscript itself so Tampermonkey can auto-install it
                $scriptPath = Join-Path $PSScriptRoot 'bridge.user.js'
                if (Test-Path $scriptPath) {
                    Send-Response $stream ([System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)) '200 OK' 'text/javascript; charset=utf-8'
                }
                else {
                    Send-Response $stream 'userscript not found' '404 Not Found' 'text/plain; charset=utf-8'
                }
            }

            '^/stats$' {
                Send-Response $stream (Write-Json @{
                        issued      = $script:seq
                        pending     = $script:order.Count
                        completed   = $script:results.Count
                        lastPollUtc = if ($script:lastPoll) { $script:lastPoll.ToString('s') } else { $null }
                    })
            }

            default {
                Send-Response $stream (Write-Json @{ ok = $false; error = 'not found' }) '404 Not Found'
            }
        }
    }
    catch {
        if (-not $Quiet) { Write-Host "loop error: $($_.Exception.Message)" }
    }
    finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
