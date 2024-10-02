import parse from '../parser/index.js';
import runStatements from './run-statements.js';

let context = new Map();

context.set('String', { name: 'String', type: 'Type' });
context.set('Int', { name: 'Int', type: 'Type' });
context.set('Void', { name: 'Void', type: 'Type' });
context.set('print', { type: 'FUNCTION', system: true, call: e => {
    process.stdout.write(e + '')
}, parameters: [{variable: 'p'}] });

runStatements({ context: context })(parse('./demo/exp.ql'));