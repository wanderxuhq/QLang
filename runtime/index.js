import parse from '../parser/index.js';
import { Void } from '../value/constant.js';
import { fromNative, toNative } from './native.js';
import runStatements from './run-statements.js';

let context = new Map();

context.set('String', {value: { name: 'String', type: 'Type' }, scope: new Map()});
context.set('Int', {value: { name: 'Int', type: 'Type' }, scope: new Map()});
context.set('Void', {value: { name: 'Void', type: 'Type' }, scope: new Map()});
const print = e => {
    let value = toNative(e);
    if (typeof (value) !== 'string') {
        value = JSON.stringify(value, null, 2)
    }
    process.stdout.write(value);

    return Void;
}
context.set('print', {value: fromNative(print), scope: new Map()});
context.set('println', {value: fromNative(e => {
    print(e);
    process.stdout.write('\n')
    return Void;
}), scope: new Map()})
context.set('debug', {value: fromNative(print), scope: new Map()});

context.set('Arrays', {value: fromNative({
    add: (arr, e) => {
        arr.value.values.push(e);
        return Void
    },
    length: (arr, e) => {
        return toNative(arr.value.values.length)
    }
}), scope: new Map()});

runStatements({ context: context, scope: new Map() })(parse('./demo/exp.ql'));
