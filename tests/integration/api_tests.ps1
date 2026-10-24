# IronLink API Integration Tests - PowerShell Edition
# Verifies all backend API endpoints for Sprint 1:
# Register, Login, Request verification, Verify OTP, Verify Link, Nodos CRUD (Create, List, Join)

$baseUrl = "http://localhost:8080"
$psqlPath = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$env:PGPASSWORD = "Ludwin1611"

# Helper for HTTP Requests
function Invoke-Request {
    param (
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = $null,
        [hashtable]$Headers = @{}
    )
    
    $params = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
    }
    
    if ($Body) {
        $params["Body"] = $Body
        $params["ContentType"] = "application/json"
    }
    
    try {
        $response = Invoke-WebRequest @params -UseBasicParsing
        $parsedContent = $null
        if ($response.Content) {
            try { $parsedContent = $response.Content | ConvertFrom-Json } catch { $parsedContent = $response.Content }
        }
        return [PSCustomObject]@{
            StatusCode = $response.StatusCode
            Content = $parsedContent
            Success = $true
        }
    } catch {
        $ex = $_
        $statusCode = 0
        $content = $null
        if ($ex.Exception.Response) {
            $statusCode = [int]$ex.Exception.Response.StatusCode
            $reader = New-Object System.IO.StreamReader($ex.Exception.Response.GetResponseStream())
            $rawContent = $reader.ReadToEnd()
            try { $content = $rawContent | ConvertFrom-Json } catch { $content = $rawContent }
        }
        return [PSCustomObject]@{
            StatusCode = $statusCode
            Content = $content
            Success = $false
        }
    }
}

# Helper Database Queries
function Get-UserId {
    param ([string]$email)
    $sql = "SELECT id FROM users WHERE email = '$email';"
    $res = & $psqlPath -U postgres -d IronLink -t -A -c $sql
    return $res.Trim()
}

function Get-OTP {
    param ([string]$userId)
    $sql = "SELECT code FROM verification_tokens WHERE user_id = '$userId' AND method = 'code' ORDER BY created_at DESC LIMIT 1;"
    $res = & $psqlPath -U postgres -d IronLink -t -A -c $sql
    return $res.Trim()
}

function Get-LinkToken {
    param ([string]$userId)
    $sql = "SELECT token FROM verification_tokens WHERE user_id = '$userId' AND method = 'link' ORDER BY created_at DESC LIMIT 1;"
    $res = & $psqlPath -U postgres -d IronLink -t -A -c $sql
    return $res.Trim()
}

# Generate random user credentials
$rand = Get-Random -Minimum 1000 -Maximum 9999
$emailA = "usera_$rand@example.com"
$phoneA = "555" + (Get-Random -Minimum 1000000 -Maximum 9999999)
$password = "Password123!"

$emailB = "userb_$rand@example.com"
$phoneB = "555" + (Get-Random -Minimum 1000000 -Maximum 9999999)

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  RUNNING IRONLINK API INTEGRATION TESTS  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "User A: $emailA / $phoneA"
Write-Host "User B: $emailB / $phoneB"
Write-Host "---------------------------------------------"

$passed = 0
$failed = 0

function Assert {
    param (
        [string]$testName,
        [bool]$condition,
        [string]$message = ""
    )
    if ($condition) {
        Write-Host "[ PASS ] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "[ FAIL ] $testName" -ForegroundColor Red
        if ($message) { Write-Host "         Reason: $message" -ForegroundColor Yellow }
        $script:failed++
    }
}

# 1. Register User A
$regBodyA = @{ name = "User A"; email = $emailA; phone = $phoneA; password = $password } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/register" -Method "POST" -Body $regBodyA
Assert "1. Register User A (status 201)" ($res.StatusCode -eq 201) "Expected status 201, got $($res.StatusCode). Response: $($res.Content | ConvertTo-Json -Depth 5)"

# 2. Request OTP Verification for User A
$reqBodyA = @{ email = $emailA; method = "code" } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/request-verification" -Method "POST" -Body $reqBodyA
Assert "2. Request OTP Verification for User A" ($res.StatusCode -eq 200 -and $res.Content.success -eq $true) "Got status $($res.StatusCode), success=$($res.Content.success)"

# 3. Verify Email OTP for User A
$userIdA = Get-UserId -email $emailA
$otp = Get-OTP -userId $userIdA
Write-Host "         Retrieved OTP for User A from DB: $otp" -ForegroundColor Gray

$verifyBodyA = @{ email = $emailA; code = $otp } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/verify-email" -Method "POST" -Body $verifyBodyA
Assert "3. Verify Email OTP for User A" ($res.StatusCode -eq 200 -and $res.Content.success -eq $true) "Got status $($res.StatusCode), success=$($res.Content.success)"

# 4. Register User B
$regBodyB = @{ name = "User B"; email = $emailB; phone = $phoneB; password = $password } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/register" -Method "POST" -Body $regBodyB
Assert "4. Register User B (status 201)" ($res.StatusCode -eq 201) "Expected status 201, got $($res.StatusCode)"

# 5. Request Link Verification for User B
$reqBodyB = @{ email = $emailB; method = "link" } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/request-verification" -Method "POST" -Body $reqBodyB
Assert "5. Request Link Verification for User B" ($res.StatusCode -eq 200 -and $res.Content.success -eq $true) "Got status $($res.StatusCode), success=$($res.Content.success)"

# 6. Verify Link for User B
$userIdB = Get-UserId -email $emailB
$linkToken = Get-LinkToken -userId $userIdB
Write-Host "         Retrieved Verification Link Token from DB: $linkToken" -ForegroundColor Gray

$res = Invoke-Request -Uri "$baseUrl/verify-link/$linkToken" -Method "GET"
Assert "6. Verify Link for User B" ($res.StatusCode -eq 200 -and $res.Content.success -eq $true) "Got status $($res.StatusCode), success=$($res.Content.success)"

# 7. Login User A
$loginBodyA = @{ email = $emailA; password = $password } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/login" -Method "POST" -Body $loginBodyA
$tokenA = $res.Content.access_token
Assert "7. Login User A" ($res.StatusCode -eq 200 -and $tokenA) "Expected token in login response. Got status $($res.StatusCode)"

# 8. Login User B
$loginBodyB = @{ email = $emailB; password = $password } | ConvertTo-Json
$res = Invoke-Request -Uri "$baseUrl/login" -Method "POST" -Body $loginBodyB
$tokenB = $res.Content.access_token
Assert "8. Login User B" ($res.StatusCode -eq 200 -and $tokenB) "Expected token in login response. Got status $($res.StatusCode)"

# 9. Create Node by User A
$nodeBody = @{ nombre = "Node de User A"; descripcion = "Workspace para pruebas" } | ConvertTo-Json
$headersA = @{ Authorization = "Bearer $tokenA" }
$res = Invoke-Request -Uri "$baseUrl/nodos" -Method "POST" -Body $nodeBody -Headers $headersA
$nodo = $res.Content.nodo
$access_token = $nodo.token_acceso
Assert "9. Create Node by User A" ($res.StatusCode -eq 201 -and $access_token) "Expected status 201 with access_token. Got status $($res.StatusCode)"

# 10. List Nodes of User A (should find 1)
$res = Invoke-Request -Uri "$baseUrl/nodos" -Method "GET" -Headers $headersA
Assert "10. List Nodes of User A" ($res.StatusCode -eq 200 -and $res.Content.nodos.Count -eq 1) "Expected 1 node in list. Got status $($res.StatusCode) and count $($res.Content.nodos.Count)"

# 11. Join Node by User B
$headersB = @{ Authorization = "Bearer $tokenB" }
$res = Invoke-Request -Uri "$baseUrl/nodos/join/$access_token" -Method "POST" -Headers $headersB
Assert "11. Join Node by User B" ($res.StatusCode -eq 200 -and $res.Content.success -eq $true) "Expected status 200. Got status $($res.StatusCode). Response: $($res.Content | ConvertTo-Json -Depth 5)"

# 12. List Nodes of User B (should find 1 joined)
$res = Invoke-Request -Uri "$baseUrl/nodos" -Method "GET" -Headers $headersB
Assert "12. List Nodes of User B" ($res.StatusCode -eq 200 -and $res.Content.nodos.Count -eq 1) "Expected 1 joined node in B's list. Got status $($res.StatusCode) and count $($res.Content.nodos.Count)"

$summaryColor = "Green"
if ($failed -gt 0) { $summaryColor = "Red" }
Write-Host "SUMMARY: Passed: $passed, Failed: $failed" -ForegroundColor $summaryColor
Write-Host "=============================================" -ForegroundColor Cyan

if ($failed -gt 0) {
    exit 1
} else {
    exit 0
}
