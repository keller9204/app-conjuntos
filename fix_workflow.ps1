$API_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJiNTk5YTVkYS05YjQwLTQwOTMtOWQxNy05OGNhNjk0MmI3ZWUiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiNDNmMjQ5OWEtNjlkNC00NTJmLWJjN2UtYzllMTk4Mjg2MzQ3IiwiaWF0IjoxNzg1NzczNDU1fQ.eGA3Qd_uDHI2XzwqWThXaC3HDdjV7oB8DVI49vPgdtU"
$N8N_URL = "https://n8n.srv1333424.hstgr.cloud"
$WF_ID   = "aMFoQ0fCGvKQaSV0"
$H = @{ "X-N8N-API-KEY" = $API_KEY; "Content-Type" = "application/json" }

# ====== 1. DESCARGAR ======
Write-Host "[1] Descargando workflow..." -ForegroundColor Cyan
$wf = Invoke-RestMethod -Uri "$N8N_URL/api/v1/workflows/$WF_ID" -Method GET -Headers $H
$nodes = [System.Collections.ArrayList]($wf.nodes)
Write-Host "    $($nodes.Count) nodos descargados." -ForegroundColor Green

# ====== 2. CORREGIR CÓDIGO JS ======
Write-Host "[2] Corrigiendo nodo Code in JavaScript1..." -ForegroundColor Cyan
$codeNode = $nodes | Where-Object { $_.name -eq "Code in JavaScript1" }
$codeNode.parameters.jsCode = @'
// ================================================================
// LECTURA GET - Consolida datos del Sheet y responde a la PWA
// safeRead() evita errores si un nodo no retorna datos validos
// ================================================================
function safeRead(nodeName) {
  try {
    const res = $items(nodeName);
    if (!Array.isArray(res) || res.length === 0) return [];
    return res.map(i => (i && typeof i.json !== 'undefined') ? i.json : null).filter(Boolean);
  } catch(e) { return []; }
}
function safeReadOne(nodeName) {
  const rows = safeRead(nodeName);
  return rows.length > 0 ? rows[0] : {};
}
function parseZonas(raw) {
  try {
    if (typeof raw === 'string' && raw.trim().startsWith('[')) return JSON.parse(raw);
    if (Array.isArray(raw)) return raw;
  } catch(e) {}
  return [
    { nombre: 'Salon Social',    tarifa: 150000 },
    { nombre: 'Zona BBQ',        tarifa: 50000  },
    { nombre: 'Cancha Multiple', tarifa: 20000  }
  ];
}

// Leer datos de cada hoja
const configRaw = safeReadOne('Leer Config');
const usuarios  = safeRead('Leer Usuarios');
const registros = safeRead('Leer Registros');
const reservas  = safeRead('Leer reservas');
const mudanzas  = safeRead('Leer mudanzas');
const paquetes  = safeRead('Leer paquetes');

// Sanitizar config (soporta tanto tarifa por hora legacy como por minuto)
const configSaneada = {
  tarifaCarro:        Number(configRaw.tarifaCarro)        || 50,
  tarifaMoto:         Number(configRaw.tarifaMoto)         || 30,
  minutosGratisCarro: Number(configRaw.minutosGratisCarro) || 0,
  minutosGratisMoto:  Number(configRaw.minutosGratisMoto)  || 0,
  gratisCarroActivo:  (configRaw.gratisCarroActivo === 'true' || configRaw.gratisCarroActivo === true),
  gratisMotoActivo:   (configRaw.gratisMotoActivo  === 'true' || configRaw.gratisMotoActivo  === true),
  correoDestino:      configRaw.correoDestino || 'admin@conjunto.com',
  zonas:              parseZonas(configRaw.zonas)
};

return [{
  json: { usuarios, registros, reservas, mudanzas, paquetes, config: configSaneada }
}];
'@
Write-Host "    JS actualizado con safeRead() y nombres corregidos." -ForegroundColor Green

# ====== 3. ELIMINAR NODOS PROBLEMÁTICOS DE LA CADENA GET ======
Write-Host "[3] Eliminando nodos redundantes: 'Leer config 2' y 'Leer turnos'..." -ForegroundColor Cyan
$toRemove = @("Leer config 2", "Leer turnos")
$keepNodes = $nodes | Where-Object { $_.name -notin $toRemove }
$nodes = [System.Collections.ArrayList]($keepNodes)
Write-Host "    Nodos restantes: $($nodes.Count)" -ForegroundColor Green

# ====== 4. INSERTAR NODOS WAIT ENTRE LECTURAS ======
Write-Host "[4] Insertando nodos Wait (2s) entre lecturas de Google Sheets..." -ForegroundColor Cyan

# Obtener sheetCred del primer nodo de sheets
$sheetCred = ($nodes | Where-Object { $_.type -eq "n8n-nodes-base.googleSheets" } | Select-Object -First 1).credentials

function New-Wait($wName, $wId, $x, $y) {
  [PSCustomObject]@{
    id          = $wId
    name        = $wName
    type        = "n8n-nodes-base.wait"
    typeVersion = 1.1
    position    = @($x, $y)
    parameters  = [PSCustomObject]@{
      resume = "timeInterval"
      unit   = "seconds"
      amount = 2
    }
    webhookId   = $wId
  }
}

# Crear los 5 nodos Wait (uno entre cada lectura)
$wt1 = New-Wait "Wait-PostConfig"    "wt-cfg-usr" 100  -200
$wt2 = New-Wait "Wait-PostUsuarios"  "wt-usr-reg" 320  -200
$wt3 = New-Wait "Wait-PostRegistros" "wt-reg-rsv" 540  -200
$wt4 = New-Wait "Wait-PostReservas"  "wt-rsv-mud" 760  -200
$wt5 = New-Wait "Wait-PostMudanzas"  "wt-mud-paq" 980  -200

# Reposicionar nodos de lectura en la fila GET
$posMap = @{
  "Leer Config"    = @(-60,  -200)
  "Leer Usuarios"  = @(220,  -200)
  "Leer Registros" = @(440,  -200)
  "Leer reservas"  = @(660,  -200)
  "Leer mudanzas"  = @(880,  -200)
  "Leer paquetes"  = @(1100, -200)
}
foreach ($node in $nodes) {
  if ($posMap.ContainsKey($node.name)) {
    $node.position = $posMap[$node.name]
  }
}

# Reposicionar Webhook1 (GET) y Code+Respond
($nodes | Where-Object { $_.name -eq "Webhook1" }).position = @(-300, -200)
($nodes | Where-Object { $_.name -eq "Code in JavaScript1" }).position = @(1300, -200)
($nodes | Where-Object { $_.name -eq "Respond to Webhook" }).position = @(1520, -200)

# Añadir los Wait al array de nodos
$nodes.Add($wt1) | Out-Null
$nodes.Add($wt2) | Out-Null
$nodes.Add($wt3) | Out-Null
$nodes.Add($wt4) | Out-Null
$nodes.Add($wt5) | Out-Null

Write-Host "    5 nodos Wait añadidos. Total nodos: $($nodes.Count)" -ForegroundColor Green

# ====== 5. RECONSTRUIR CONEXIONES GET ======
Write-Host "[5] Reconstruyendo conexiones del flujo GET..." -ForegroundColor Cyan

function Conn($target) {
  @{ node = $target; type = "main"; index = 0 }
}

# Mantener conexiones POST existentes del Switch
$switchConns = $wf.connections.Switch
$registrarSalidaConns = $wf.connections."REGISTRAR_SALIDA"
$webhookPostConns = $wf.connections."Webhook"

$newConnections = [PSCustomObject]@{
  # Flujo GET: Webhook1 → LC → Wait → LU → Wait → LR → Wait → LRs → Wait → LM → Wait → LP → JS → Respond
  "Webhook1"              = [PSCustomObject]@{ main = @(,@(Conn "Leer Config")) }
  "Leer Config"           = [PSCustomObject]@{ main = @(,@(Conn "Wait-PostConfig")) }
  "Wait-PostConfig"       = [PSCustomObject]@{ main = @(,@(Conn "Leer Usuarios")) }
  "Leer Usuarios"         = [PSCustomObject]@{ main = @(,@(Conn "Wait-PostUsuarios")) }
  "Wait-PostUsuarios"     = [PSCustomObject]@{ main = @(,@(Conn "Leer Registros")) }
  "Leer Registros"        = [PSCustomObject]@{ main = @(,@(Conn "Wait-PostRegistros")) }
  "Wait-PostRegistros"    = [PSCustomObject]@{ main = @(,@(Conn "Leer reservas")) }
  "Leer reservas"         = [PSCustomObject]@{ main = @(,@(Conn "Wait-PostReservas")) }
  "Wait-PostReservas"     = [PSCustomObject]@{ main = @(,@(Conn "Leer mudanzas")) }
  "Leer mudanzas"         = [PSCustomObject]@{ main = @(,@(Conn "Wait-PostMudanzas")) }
  "Wait-PostMudanzas"     = [PSCustomObject]@{ main = @(,@(Conn "Leer paquetes")) }
  "Leer paquetes"         = [PSCustomObject]@{ main = @(,@(Conn "Code in JavaScript1")) }
  "Code in JavaScript1"   = [PSCustomObject]@{ main = @(,@(Conn "Respond to Webhook")) }
  # Flujo POST (sin cambios)
  "Webhook"               = $webhookPostConns
  "Switch"                = $switchConns
  "REGISTRAR_SALIDA"      = $registrarSalidaConns
}

Write-Host "    Conexiones GET reconstruidas." -ForegroundColor Green

# ====== 6. ENVIAR A N8N ======
Write-Host "[6] Enviando workflow actualizado..." -ForegroundColor Cyan

$cleanSettings = [PSCustomObject]@{
  executionOrder        = "v1"
  timezone              = "America/Bogota"
  saveExecutionProgress = $true
}

$payload = [PSCustomObject]@{
  name        = $wf.name
  nodes       = @($nodes)
  connections = $newConnections
  settings    = $cleanSettings
}

$json = $payload | ConvertTo-Json -Depth 25 -Compress
$json | Out-File "workflow_final.json" -Encoding UTF8
Write-Host "    Payload guardado en workflow_final.json ($($json.Length) chars)" -ForegroundColor Yellow

try {
  $result = Invoke-WebRequest `
    -Uri "$N8N_URL/api/v1/workflows/$WF_ID" `
    -Method PUT `
    -Headers $H `
    -Body $json `
    -ContentType "application/json" `
    -UseBasicParsing

  $resultObj = $result.Content | ConvertFrom-Json
  Write-Host ""
  Write-Host "SUCCESS! Workflow actualizado." -ForegroundColor Green
  Write-Host "  Nombre: $($resultObj.name)"
  Write-Host "  Nodos:  $($resultObj.nodes.Count)"

  # Activar
  try {
    Invoke-RestMethod -Uri "$N8N_URL/api/v1/workflows/$WF_ID/activate" -Method POST -Headers $H | Out-Null
    Write-Host "  Activado: SI" -ForegroundColor Green
  } catch {
    Write-Host "  Activacion manual requerida en n8n." -ForegroundColor Yellow
  }

} catch {
  Write-Host "ERROR $($_.Exception.Response.StatusCode)" -ForegroundColor Red
  $stream  = $_.Exception.Response.GetResponseStream()
  $reader  = New-Object System.IO.StreamReader($stream)
  $errBody = $reader.ReadToEnd()
  Write-Host "Detail: $errBody" -ForegroundColor Red
}
