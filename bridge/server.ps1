# server.ps1 - localhost command bridge for dsh-browser-bridge (v1.5.0)
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
    # 不再发 Access-Control-Allow-Origin: *。
    # 那个头等于对整台机器的浏览器宣告「任何站点都能读这个本地服务的响应」，
    # 配合无鉴权的 /cmd 就是一条从任意网页到页面脚本执行的链路。
    # 油猴用 GM_xmlhttpRequest 发请求，不走 CORS，不需要这个头。
    $head = "HTTP/1.1 $Status`r`n" +
    "Content-Type: $ContentType`r`n" +
    "Content-Length: $($bytes.Length)`r`n" +
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

        # 白名单外的路径一律要求桥头；/install.user.js 是浏览器直接导航，
        # 不带头，它只回一段公开脚本，不需要保护。
        if ($pathOnly -notmatch '^/install\.user\.js$') {
            $hdr = [string]$req.headers['x-dsh-bridge']
            if ($hdr -ne '1') {
                Send-Response $stream (Write-Json @{ ok = $false; error = 'missing X-DSH-Bridge header' }) '403 Forbidden'
                $client.Close()
                continue
            }
        }

        switch -Regex ($pathOnly) {

            # 鉴权：除取用油猴脚本本身，所有请求都必须带 X-DSH-Bridge 头。
            # 普通网页想带自定义头必须先过 CORS 预检，而下面刻意不实现 OPTIONS，
            # 于是任意页面的 fetch('http://127.0.0.1:8737/cmd') 都到不了队列。
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
                # 长期挂着的桥不能无界增长：旧实现 jobs/results 只增不减，
                # 跑几万次任务后内存一直涨。超过阈值就整体回收。
                if ($script:jobs.Count -gt 800) {
                    $script:jobs.Clear()
                    $script:order.Clear()
                }
                if ($script:results.Count -gt 800) { $script:results.Clear() }
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
