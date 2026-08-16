# TTS 本地代理：支持 Google Cloud TTS + OpenAI TTS
# 用法：在本目录运行后保持窗口不要关
#   powershell -ExecutionPolicy Bypass -File .\tts-proxy.ps1
# 浏览器请求: http://127.0.0.1:18765/synthesize

param(
    [int]$Port = 18765
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "TTS 代理已启动: $prefix" -ForegroundColor Green
Write-Host "支持 provider=google / openai。保持窗口开启。Ctrl+C 结束。" -ForegroundColor Yellow

function Send-Json($res, $status, $obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $status
    $res.ContentType = "application/json; charset=utf-8"
    $res.Headers.Add("Access-Control-Allow-Origin", "*")
    $res.Headers.Add("Access-Control-Allow-Methods", "POST, OPTIONS")
    $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Read-Body($req) {
    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

function Invoke-GoogleTts([string]$text, [string]$apiKey, [string]$voice, [double]$rate, [string]$lang) {
    $url = "https://texttospeech.googleapis.com/v1/text:synthesize?key=$apiKey"
    $bodyObj = @{
        input = @{ text = $text }
        voice = @{
            languageCode = $lang
            name = $voice
        }
        audioConfig = @{
            audioEncoding = "MP3"
            speakingRate = $rate
        }
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10
    $google = Invoke-RestMethod -Uri $url -Method Post -Body $bodyJson -ContentType "application/json; charset=utf-8"
    if (-not $google.audioContent) { throw "Google returned empty audioContent" }
    return [string]$google.audioContent
}

function Invoke-OpenAiTts([string]$text, [string]$apiKey, [string]$voice, [double]$rate, [string]$model) {
    $url = "https://api.openai.com/v1/audio/speech"
    $bodyObj = @{
        model = $model
        input = $text
        voice = $voice
        speed = $rate
        response_format = "mp3"
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Compress -Depth 8

    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $apiKey)
        $content = New-Object System.Net.Http.StringContent($bodyJson, [System.Text.Encoding]::UTF8, "application/json")
        $resp = $client.PostAsync($url, $content).Result
        $bytes = $resp.Content.ReadAsByteArrayAsync().Result
        if (-not $resp.IsSuccessStatusCode) {
            $errText = [System.Text.Encoding]::UTF8.GetString($bytes)
            throw "OpenAI TTS failed ($([int]$resp.StatusCode)): $errText"
        }
        if (-not $bytes -or $bytes.Length -eq 0) { throw "OpenAI returned empty audio" }
        return [Convert]::ToBase64String($bytes)
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-DeepSeekSubtitleClean([object[]]$items, [string]$apiKey, [string]$model) {
    $url = "https://api.deepseek.com/chat/completions"
    $itemsJson = $items | ConvertTo-Json -Compress -Depth 8
    $systemPrompt = @"
你是日文字幕清洗器。请只输出合法 JSON。
任务：删除汉字后面重复标注的平假名读音（字幕内联注音），保留真正的送假名、助词、语法、原意和标点。
不要翻译，不要改写，不要润色，不要合并或拆分句子，不要增加解释。
例：
目暮めぐれ警部 → 目暮警部
工藤新一くどうしんいち → 工藤新一
八菱やつびし銀行 → 八菱銀行
山崎やまざき頭取 → 山崎頭取
飛び移る → 飛び移る
以上つきあってる暇はないんだ → 以上つきあってる暇はないんだ
返回格式必须是：{"items":[{"id":0,"text":"清洗后的原句"}]}
每个输入 id 必须原样返回且只返回一次。
"@
    $userPrompt = "请清洗以下 JSON 数组：`n$itemsJson"
    $bodyObj = @{
        model = $model
        messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user"; content = $userPrompt }
        )
        response_format = @{ type = "json_object" }
        temperature = 0
        max_tokens = 8192
        stream = $false
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Compress -Depth 12
    $headers = @{ Authorization = "Bearer $apiKey" }
    $response = Invoke-RestMethod `
        -Uri $url `
        -Method Post `
        -Headers $headers `
        -Body $bodyJson `
        -ContentType "application/json; charset=utf-8"

    $content = [string]$response.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "DeepSeek returned empty content"
    }
    $parsed = $content | ConvertFrom-Json
    if (-not $parsed.items) {
        throw "DeepSeek response does not contain items"
    }
    return @($parsed.items)
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        try {
            if ($req.HttpMethod -eq "OPTIONS") {
                $res.StatusCode = 204
                $res.Headers.Add("Access-Control-Allow-Origin", "*")
                $res.Headers.Add("Access-Control-Allow-Methods", "POST, OPTIONS")
                $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
                $res.Close()
                continue
            }

            $path = $req.Url.AbsolutePath
            if ($req.HttpMethod -ne "POST" -or @("/synthesize", "/deepseek-clean") -notcontains $path) {
                Send-Json $res 404 @{ error = "Not found. POST /synthesize or /deepseek-clean" }
                continue
            }

            $raw = Read-Body $req
            $payload = $raw | ConvertFrom-Json
            if ($path -eq "/deepseek-clean") {
                $apiKey = [string]$payload.apiKey
                $model = if ($payload.model) { [string]$payload.model } else { "deepseek-v4-flash" }
                $items = @($payload.items)
                if ([string]::IsNullOrWhiteSpace($apiKey)) {
                    Send-Json $res 400 @{ error = "DeepSeek apiKey is empty" }
                    continue
                }
                if (-not $items -or $items.Count -eq 0) {
                    Send-Json $res 400 @{ error = "DeepSeek items are empty" }
                    continue
                }

                Write-Host ("[deepseek] 清理中: {0} 句…" -f $items.Count) -ForegroundColor Cyan
                $cleaned = Invoke-DeepSeekSubtitleClean `
                    -items $items `
                    -apiKey $apiKey `
                    -model $model
                Send-Json $res 200 @{ items = $cleaned }
                Write-Host "DeepSeek 清理成功" -ForegroundColor Green
                continue
            }

            $provider = if ($payload.provider) { ([string]$payload.provider).ToLowerInvariant() } else { "google" }
            $text = [string]$payload.text
            $apiKey = [string]$payload.apiKey
            $rate = if ($payload.speakingRate) { [double]$payload.speakingRate } else { 0.88 }
            $lang = if ($payload.languageCode) { [string]$payload.languageCode } else { "en-US" }

            if ([string]::IsNullOrWhiteSpace($text)) {
                Send-Json $res 400 @{ error = "text is empty" }
                continue
            }
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                Send-Json $res 400 @{ error = "apiKey is empty" }
                continue
            }

            Write-Host ("[{0}] 合成中: {1} 字…" -f $provider, $text.Length) -ForegroundColor Cyan

            if ($provider -eq "openai") {
                $voice = if ($payload.voice) { [string]$payload.voice } else { "onyx" }
                $model = if ($payload.model) { [string]$payload.model } else { "tts-1-hd" }
                $audio = Invoke-OpenAiTts -text $text -apiKey $apiKey -voice $voice -rate $rate -model $model
            }
            else {
                $voice = if ($payload.voice) { [string]$payload.voice } else { "en-US-Neural2-J" }
                $audio = Invoke-GoogleTts -text $text -apiKey $apiKey -voice $voice -rate $rate -lang $lang
            }

            Send-Json $res 200 @{ audioContent = $audio }
            Write-Host "合成成功" -ForegroundColor Green
        }
        catch {
            Write-Host $_ -ForegroundColor Red
            try {
                Send-Json $res 500 @{ error = $_.Exception.Message }
            } catch {}
        }
    }
}
finally {
    if ($listener) { $listener.Stop(); $listener.Close() }
}
