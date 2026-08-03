const fs = require('fs');

let content = fs.readFileSync('current_workflow.json', 'utf8');
if (content.charCodeAt(0) === 0xFEFF) content = content.slice(1);
const wf = JSON.parse(content);

const switchNode = wf.nodes.find(n => n.name === 'Switch');
if (!switchNode) throw new Error("Switch node not found");

// Update all existing Switch conditions from `action` to `accion`
if (switchNode.parameters && switchNode.parameters.rules && switchNode.parameters.rules.values) {
    switchNode.parameters.rules.values.forEach(rule => {
        if (rule.conditions && rule.conditions.conditions) {
            rule.conditions.conditions.forEach(cond => {
                if (cond.leftValue === "={{ $json.body.action }}") {
                    cond.leftValue = "={{ $json.body.accion }}";
                }
            });
        }
    });

    // Add 'leer_datos' condition at the end
    const newRule = {
        conditions: {
            options: {
                caseSensitive: true,
                leftValue: "",
                typeValidation: "strict",
                version: 3
            },
            conditions: [
                {
                    id: "new-rule-leer-datos",
                    leftValue: "={{ $json.body.accion }}",
                    rightValue: "leer_datos",
                    operator: {
                        type: "string",
                        operation: "equals"
                    }
                }
            ],
            combinator: "and"
        },
        renameOutput: true,
        outputKey: "leer_datos"
    };
    switchNode.parameters.rules.values.push(newRule);
}
const leerDatosIndex = switchNode.parameters.rules.values.length - 1;

// Reconnect Webhook1 to Switch
wf.connections['Webhook1'] = {
    main: [
        [
            {
                node: "Switch",
                type: "main",
                index: 0
            }
        ]
    ]
};

// Reconnect Switch to Leer Config for the leer_datos route
if (!wf.connections['Switch']) wf.connections['Switch'] = { main: [] };
while (wf.connections['Switch'].main.length <= leerDatosIndex) {
    wf.connections['Switch'].main.push([]);
}
wf.connections['Switch'].main[leerDatosIndex] = [
    {
        node: "Leer Config",
        type: "main",
        index: 0
    }
];

fs.writeFileSync('new_workflow.json', JSON.stringify(wf, null, 2));
console.log("Transformation complete. Switch rules: " + switchNode.parameters.rules.values.length);
