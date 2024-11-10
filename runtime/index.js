import parse from '../parser/index.js';
import { Void } from '../value/constant.js';
import { fromNative, toNative } from './native.js';
import runStatements from './run-statements.js';

let context = new Map();

context.set('String', { name: 'String', type: 'Type' });
context.set('Int', { name: 'Int', type: 'Type' });
context.set('Void', { name: 'Void', type: 'Type' });
const print = e => {
    let value = toNative(e.result.value);
    if (typeof (value) !== 'string') {
        value = JSON.stringify(value)
    }
    process.stdout.write(value);

    return Void;
}
context.set('print', fromNative(print).value);
context.set('println', fromNative(e => {
    print(e);
    process.stdout.write('\n')
    return Void;
}).value)
context.set('debug', fromNative(print).value);

context.set('Arrays', fromNative({
    add: (arr, e) => {
        arr.result.value.values.push(e.result);
        return Void
    }
}).value);

runStatements({ context: context, scope: new Map() })(parse('./demo/exp.ql'));
