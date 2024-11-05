import parse from '../parser/index.js';
import runStatements from './run-statements.js';

let context = new Map();

context.set('String', { name: 'String', type: 'Type' });
context.set('Int', { name: 'Int', type: 'Type' });
context.set('Void', { name: 'Void', type: 'Type' });
context.set('print', { type: 'FUNCTION', system: true, call: e => {
    let value = e;
    if (e !== '\n') {
        value = JSON.stringify(e)
    }
    process.stdout.write(value)
}, parameters: [{variable: 'p'}] });

runStatements({ context: context, scope: new Map() })(parse('./demo/obj2.ql'));
