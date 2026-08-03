const https = require('https');

const API_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJiNTk5YTVkYS05YjQwLTQwOTMtOWQxNy05OGNhNjk0MmI3ZWUiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiNDNmMjQ5OWEtNjlkNC00NTJmLWJjN2UtYzllMTk4Mjg2MzQ3IiwiaWF0IjoxNzg1NzczNDU1fQ.eGA3Qd_uDHI2XzwqWThXaC3HDdjV7oB8DVI49vPgdtU';
const N8N_HOST = 'n8n.srv1333424.hstgr.cloud';
const WF_ID = 'aMFoQ0fCGvKQaSV0';

function req(path, method, data) {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: N8N_HOST,
            path: path,
            method: method || 'GET',
            headers: {
                'X-N8N-API-KEY': API_KEY,
                'Content-Type': 'application/json'
            }
        };
        const r = https.request(options, res => {
            let body = '';
            res.on('data', chunk => body += chunk);
            res.on('end', () => resolve({ status: res.statusCode, body }));
        });
        r.on('error', reject);
        if (data) r.write(JSON.stringify(data));
        r.end();
    });
}

async function run() {
    const getRes = await req('/api/v1/workflows/' + WF_ID, 'GET');
    const wf = JSON.parse(getRes.body);

    // 1. Add Check Cache node
    const checkCacheNode = {
        id: 'node-check-cache-001',
        name: 'Check Cache',
        type: 'n8n-nodes-base.code',
        typeVersion: 2,
        position: [-200, -64],
        parameters: {
            jsCode: `const staticData = $getWorkflowStaticData('global');
const now = Date.now();
const lastFetch = staticData.lastFetch || 0;
const cacheAge = now - lastFetch;

if (staticData.cacheData && cacheAge < 25000) {
    return [{ json: { isCached: true, ...staticData.cacheData } }];
} else {
    return [{ json: { isCached: false } }];
}`
        }
    };

    // 2. Add If Cache Valid node
    const ifCacheNode = {
        id: 'node-if-cache-001',
        name: 'If Cache Valid',
        type: 'n8n-nodes-base.if',
        typeVersion: 2,
        position: [-100, -64],
        parameters: {
            conditions: {
                options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
                conditions: [
                    {
                        id: 'cond-cache-1',
                        leftValue: '={{ $json.isCached }}',
                        rightValue: true,
                        operator: { type: 'boolean', operation: 'true' }
                    }
                ],
                combinator: 'and'
            }
        }
    };

    // 3. Add Invalidate Cache node for writes
    const invalidateCacheNode = {
        id: 'node-invalidate-cache-001',
        name: 'Invalidar Cache',
        type: 'n8n-nodes-base.code',
        typeVersion: 2,
        position: [200, 300],
        parameters: {
            jsCode: `try {
    const staticData = $getWorkflowStaticData('global');
    staticData.lastFetch = 0;
} catch(e) {}
return $input.all();`
        }
    };

    wf.nodes = wf.nodes.filter(n => n.name !== 'Check Cache' && n.name !== 'If Cache Valid' && n.name !== 'Invalidar Cache');
    wf.nodes.push(checkCacheNode);
    wf.nodes.push(ifCacheNode);
    wf.nodes.push(invalidateCacheNode);

    // Update Code in JavaScript1 to save to staticData
    const codeJS = wf.nodes.find(n => n.name === 'Code in JavaScript1');
    if (codeJS) {
        codeJS.parameters.jsCode = `function safeRead(n){try{const r=$items(n);if(!Array.isArray(r)||r.length===0)return[];return r.map(i=>(i&&typeof i.json!=='undefined')?i.json:null).filter(Boolean);}catch(e){return[];}}function safeOne(n){const r=safeRead(n);return r.length>0?r[0]:{};}function parseZonas(raw){try{if(typeof raw==='string'&&raw.trim().startsWith('['))return JSON.parse(raw);if(Array.isArray(raw))return raw;}catch(e){}return[{nombre:'Salon Social',tarifa:150000},{nombre:'Zona BBQ',tarifa:50000},{nombre:'Cancha Multiple',tarifa:20000}];}const configRaw=safeOne('Leer Config');const usuarios=safeRead('Leer Usuarios');const registros=safeRead('Leer Registros');const reservas=safeRead('Leer reservas');const mudanzas=safeRead('Leer mudanzas');const paquetes=safeRead('Leer paquetes');const cfg={tarifaCarro:Number(configRaw.tarifaCarro)||50,tarifaMoto:Number(configRaw.tarifaMoto)||30,minutosGratisCarro:Number(configRaw.minutosGratisCarro)||0,minutosGratisMoto:Number(configRaw.minutosGratisMoto)||0,gratisCarroActivo:(configRaw.gratisCarroActivo==='true'||configRaw.gratisCarroActivo===true),gratisMotoActivo:(configRaw.gratisMotoActivo==='true'||configRaw.gratisMotoActivo===true),correoDestino:configRaw.correoDestino||'admin@conjunto.com',zonas:parseZonas(configRaw.zonas)};const result={usuarios,registros,reservas,mudanzas,paquetes,config:cfg};try{const staticData=$getWorkflowStaticData('global');staticData.cacheData=result;staticData.lastFetch=Date.now();}catch(e){}return[{json:result}];`;
    }

    // Connections setup:
    // Switch (leer_datos) -> Check Cache
    // Check Cache -> If Cache Valid
    // If Cache Valid (true branch index 0) -> (ends, returns cached json)
    // If Cache Valid (false branch index 1) -> Leer Config

    const switchNode = wf.nodes.find(n => n.name === 'Switch');
    const leerDatosIndex = switchNode.parameters.rules.values.findIndex(r => r.renameOutput === 'leer_datos' || r.outputKey === 'leer_datos');

    if (wf.connections['Switch'] && wf.connections['Switch'].main) {
        // Connect leer_datos to Check Cache
        if (leerDatosIndex > -1) {
            wf.connections['Switch'].main[leerDatosIndex] = [{ node: 'Check Cache', type: 'main', index: 0 }];
        }
    }

    wf.connections['Check Cache'] = { main: [[{ node: 'If Cache Valid', type: 'main', index: 0 }]] };
    wf.connections['If Cache Valid'] = {
        main: [
            [], // True branch (cached) -> ends
            [{ node: 'Leer Config', type: 'main', index: 0 }] // False branch (needs fetch) -> Leer Config
        ]
    };

    const cleanWf = {
        name: wf.name,
        nodes: wf.nodes,
        connections: wf.connections,
        settings: {
            executionOrder: 'v1',
            timezone: 'America/Bogota',
            saveExecutionProgress: true
        }
    };

    const putRes = await req('/api/v1/workflows/' + WF_ID, 'PUT', cleanWf);
    console.log('PUT status:', putRes.status);
}

run().catch(console.error);
