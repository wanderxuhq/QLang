import fs from 'fs';
const source = fs.readFileSync('./demo/test-function.ql', 'utf-8');

import {
    parseStatementsAst
} from './parse-statement-ast.js'

let context = new Map();

context.set('String', { name: 'String', type: 'Type' });
context.set('Int', { name: 'Int', type: 'Type' });
context.set('Void', { name: 'Void', type: 'Type' });

fs.writeFileSync("output.json", JSON.stringify(parseStatementsAst({ context: context })(source)(0), null, 2));
