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

    // 1. Fix REGISTRAR_SALIDA matchingColumns
    const regSalida = wf.nodes.find(n => n.name === 'REGISTRAR_SALIDA');
    if (regSalida && regSalida.parameters && regSalida.parameters.columns) {
        regSalida.parameters.columns.matchingColumns = ['id'];
        console.log('Fixed REGISTRAR_SALIDA matchingColumns to ["id"]');
    }

    // 2. Fix ENTREGAR_PAQUETE matchingColumns
    const entregPaq = wf.nodes.find(n => n.name === 'ENTREGAR_PAQUETE');
    if (entregPaq && entregPaq.parameters && entregPaq.parameters.columns) {
        entregPaq.parameters.columns.matchingColumns = ['id'];
        console.log('Fixed ENTREGAR_PAQUETE matchingColumns to ["id"]');
    }

    // 3. Fix ACTUALIZAR_CONFIG to include all admin config fields
    const actConfig = wf.nodes.find(n => n.name === 'ACTUALIZAR_CONFIG');
    if (actConfig && actConfig.parameters && actConfig.parameters.columns) {
        actConfig.parameters.columns.value = {
            "ID": "=1",
            "tarifaCarro": "={{ $json.body.data.tarifaCarro }}",
            "tarifaMoto": "={{ $json.body.data.tarifaMoto }}",
            "minutosGratisCarro": "={{ $json.body.data.minutosGratisCarro }}",
            "minutosGratisMoto": "={{ $json.body.data.minutosGratisMoto }}",
            "gratisCarroActivo": "={{ $json.body.data.gratisCarroActivo }}",
            "gratisMotoActivo": "={{ $json.body.data.gratisMotoActivo }}",
            "correoDestino": "={{ $json.body.data.correoDestino }}",
            "zonas": "={{ Array.isArray($json.body.data.zonas) ? JSON.stringify($json.body.data.zonas) : $json.body.data.zonas }}"
        };
        actConfig.parameters.columns.matchingColumns = ['ID'];
        console.log('Fixed ACTUALIZAR_CONFIG mapping');
    }

    // 4. Add ACTUALIZAR_USUARIO rule to Switch if missing
    const switchNode = wf.nodes.find(n => n.name === 'Switch');
    if (switchNode && switchNode.parameters && switchNode.parameters.rules && switchNode.parameters.rules.values) {
        const hasActUser = switchNode.parameters.rules.values.some(r => {
            const val = r.conditions?.conditions?.[0]?.rightValue;
            return val === 'ACTUALIZAR_USUARIO';
        });
        if (!hasActUser) {
            const rule = {
                conditions: {
                    options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 3 },
                    conditions: [
                        {
                            id: 'rule-act-user',
                            leftValue: '={{ $json.body.accion }}',
                            rightValue: 'ACTUALIZAR_USUARIO',
                            operator: { type: 'string', operation: 'equals' }
                        }
                    ],
                    combinator: 'and'
                },
                renameOutput: true,
                outputKey: 'ACTUALIZAR_USUARIO'
            };
            switchNode.parameters.rules.values.push(rule);
            const newIndex = switchNode.parameters.rules.values.length - 1;
            if (!wf.connections['Switch']) wf.connections['Switch'] = { main: [] };
            while (wf.connections['Switch'].main.length <= newIndex) wf.connections['Switch'].main.push([]);
            wf.connections['Switch'].main[newIndex] = [{ node: 'CREAR_USUARIO', type: 'main', index: 0 }];
            console.log('Added ACTUALIZAR_USUARIO rule to Switch');
        }
    }

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
