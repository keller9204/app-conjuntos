$API_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJiNTk5YTVkYS05YjQwLTQwOTMtOWQxNy05OGNhNjk0MmI3ZWUiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiNDNmMjQ5OWEtNjlkNC00NTJmLWJjN2UtYzllMTk4Mjg2MzQ3IiwiaWF0IjoxNzg1NzczNDU1fQ.eGA3Qd_uDHI2XzwqWThXaC3HDdjV7oB8DVI49vPgdtU"
$N8N_URL = "https://n8n.srv1333424.hstgr.cloud"
$WF_ID   = "aMFoQ0fCGvKQaSV0"
$H = @{ "X-N8N-API-KEY" = $API_KEY; "Content-Type" = "application/json" }

Write-Host "[1] Descargando workflow actual..." -ForegroundColor Cyan
$wf = Invoke-RestMethod -Uri "$N8N_URL/api/v1/workflows/$WF_ID" -Method GET -Headers $H

# Obtener la credencial de GSheets para usarla en los nodos nuevos
$sheetCredId   = $wf.nodes[0].credentials.googleSheetsOAuth2Api.id
$sheetCredName = $wf.nodes[0].credentials.googleSheetsOAuth2Api.name
# Buscar el nodo real con credenciales
foreach ($n in $wf.nodes) {
  if ($n.credentials -and $n.credentials.googleSheetsOAuth2Api) {
    $sheetCredId   = $n.credentials.googleSheetsOAuth2Api.id
    $sheetCredName = $n.credentials.googleSheetsOAuth2Api.name
    break
  }
}
Write-Host "    Creds: id=$sheetCredId, name=$sheetCredName" -ForegroundColor Green

# =====================================================================
# 2. CONSTRUIR JSON COMPLETO DEL WORKFLOW COMO TEXTO (evitar problemas
#    de serialización de PowerShell con tipos numéricos)
# =====================================================================
Write-Host "[2] Construyendo payload JSON como texto..." -ForegroundColor Cyan

# Serializar nodos existentes
$existingNodesJson = $wf.nodes | ConvertTo-Json -Depth 20 -Compress

# JSON de los 5 nodos Wait — escritos directamente como texto para garantizar tipos
$waitNodesJson = @"
,{"id":"wt1","name":"Wait-PostConfig","type":"n8n-nodes-base.wait","typeVersion":1.1,"position":[-5,-300],"parameters":{"resume":"timeInterval","unit":"seconds","amount":2},"webhookId":"wt1"}
,{"id":"wt2","name":"Wait-PostUsuarios","type":"n8n-nodes-base.wait","typeVersion":1.1,"position":[215,-300],"parameters":{"resume":"timeInterval","unit":"seconds","amount":2},"webhookId":"wt2"}
,{"id":"wt3","name":"Wait-PostRegistros","type":"n8n-nodes-base.wait","typeVersion":1.1,"position":[435,-300],"parameters":{"resume":"timeInterval","unit":"seconds","amount":2},"webhookId":"wt3"}
,{"id":"wt4","name":"Wait-PostReservas","type":"n8n-nodes-base.wait","typeVersion":1.1,"position":[655,-300],"parameters":{"resume":"timeInterval","unit":"seconds","amount":2},"webhookId":"wt4"}
,{"id":"wt5","name":"Wait-PostMudanzas","type":"n8n-nodes-base.wait","typeVersion":1.1,"position":[875,-300],"parameters":{"resume":"timeInterval","unit":"seconds","amount":2},"webhookId":"wt5"}
"@

# Insertar antes del ] final del array de nodos
$nodesArrayJson = $existingNodesJson.TrimEnd("]") + $waitNodesJson + "]"

# Serializar las conexiones actuales (ya corregidas en el paso anterior)
$connectionsObj = $wf.connections

# Añadir conexiones de los nodos Wait al objeto de conexiones existente
$connectionsObj | Add-Member -NotePropertyName "Wait-PostConfig"    -NotePropertyValue ([PSCustomObject]@{main=@(,@(@{node="Leer Usuarios";type="main";index=0}))}) -Force
$connectionsObj | Add-Member -NotePropertyName "Wait-PostUsuarios"  -NotePropertyValue ([PSCustomObject]@{main=@(,@(@{node="Leer Registros";type="main";index=0}))}) -Force
$connectionsObj | Add-Member -NotePropertyName "Wait-PostRegistros" -NotePropertyValue ([PSCustomObject]@{main=@(,@(@{node="Leer reservas";type="main";index=0}))}) -Force
$connectionsObj | Add-Member -NotePropertyName "Wait-PostReservas"  -NotePropertyValue ([PSCustomObject]@{main=@(,@(@{node="Leer mudanzas";type="main";index=0}))}) -Force
$connectionsObj | Add-Member -NotePropertyName "Wait-PostMudanzas"  -NotePropertyValue ([PSCustomObject]@{main=@(,@(@{node="Leer paquetes";type="main";index=0}))}) -Force

# Modificar conexiones de los nodos de lectura para pasar por Wait primero
$connectionsObj."Leer Config"    = [PSCustomObject]@{main=@(,@(@{node="Wait-PostConfig";    type="main";index=0}))}
$connectionsObj."Leer Usuarios"  = [PSCustomObject]@{main=@(,@(@{node="Wait-PostUsuarios";  type="main";index=0}))}
$connectionsObj."Leer Registros" = [PSCustomObject]@{main=@(,@(@{node="Wait-PostRegistros"; type="main";index=0}))}
$connectionsObj."Leer reservas"  = [PSCustomObject]@{main=@(,@(@{node="Wait-PostReservas";  type="main";index=0}))}
$connectionsObj."Leer mudanzas"  = [PSCustomObject]@{main=@(,@(@{node="Wait-PostMudanzas";  type="main";index=0}))}

$connectionsJson = $connectionsObj | ConvertTo-Json -Depth 15 -Compress

# Settings limpios
$settingsJson = '{"executionOrder":"v1","timezone":"America/Bogota","saveExecutionProgress":true}'

# Construir payload completo como string JSON
$payloadJson = "{`"name`":`"$($wf.name)`",`"nodes`":$nodesArrayJson,`"connections`":$connectionsJson,`"settings`":$settingsJson}"

# Guardar para debug
$payloadJson | Out-File "payload_waits.json" -Encoding UTF8
Write-Host "    Payload guardado ($($payloadJson.Length) chars)" -ForegroundColor Yellow

# =====================================================================
# 3. ENVIAR A N8N
# =====================================================================
Write-Host "[3] Enviando a n8n..." -ForegroundColor Cyan
try {
  $result = Invoke-WebRequest `
    -Uri "$N8N_URL/api/v1/workflows/$WF_ID" `
    -Method PUT `
    -Headers $H `
    -Body $payloadJson `
    -ContentType "application/json" `
    -UseBasicParsing

  $resultObj = $result.Content | ConvertFrom-Json
  Write-Host ""
  Write-Host "SUCCESS!" -ForegroundColor Green
  Write-Host "  Nombre: $($resultObj.name)"
  Write-Host "  Nodos:  $($resultObj.nodes.Count)"

  # Verificar cadena GET
  Write-Host ""
  Write-Host "=== CADENA GET FINAL ===" -ForegroundColor Cyan
  $chain = @("Webhook1","Leer Config","Wait-PostConfig","Leer Usuarios","Wait-PostUsuarios","Leer Registros","Wait-PostRegistros","Leer reservas","Wait-PostReservas","Leer mudanzas","Wait-PostMudanzas","Leer paquetes","Code in JavaScript1","Respond to Webhook")
  foreach($n in $chain) {
    $conn = $resultObj.connections.$n
    if ($conn) { $dest = $conn.main[0][0].node } else { $dest = "(fin)" }
    Write-Host "  $n -> $dest"
  }

} catch {
  Write-Host "ERROR $($_.Exception.Response.StatusCode)" -ForegroundColor Red
  $stream = $_.Exception.Response.GetResponseStream()
  $reader = New-Object System.IO.StreamReader($stream)
  Write-Host $reader.ReadToEnd() -ForegroundColor Red
}
