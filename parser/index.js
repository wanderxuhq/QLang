import fs from 'fs';
//const source = fs.readFileSync('./demo/declare.ql', 'utf-8');

import {
    parseStatementsAst
} from './parse-statement-ast.js'

let context = new Map();

context.set('String', { name: 'String', type: 'Type' });
context.set('Int', { name: 'Int', type: 'Type' });
context.set('Void', { name: 'Void', type: 'Type' });
context.set('print', { type: 'FUNCTION', system: true, call: console.log, parameters: [{variable: 'o'}] });

//const result = parseStatementsAst({ context: context })(source)(0);
//fs.writeFileSync("output.json", JSON.stringify(result, null, 2));

export default (source) => {
    const result = parseStatementsAst({ context: context })(
        fs.readFileSync(source, 'utf-8')
    )(0);
    fs.writeFileSync("output.json", JSON.stringify(result, null, 2));  
    return result;
};