import { Ast } from "./ast/index.js";
import { fromNative, wrap } from "./native/fromNative.js";
import toNative from "./native/toNative.js";
//import Type from "./std/type.js";
import Pair from "./std/pair.js";
import { equal, PrimeType } from "./type/constant.js";
import { Void } from "./value/constant.js";
import {std} from "./std/index.js";

const envPush = data => () => {
    const child = {
        parent: data,
        context: new Map(),
        scope: new Map(),
    }
    child.push = envPush(child);
    child.pop = () => {
        return child.parent;
    };

    child.find = variable => {
        let env = child;

        if (env.context.has(variable)) {
            let result = env.context.get(variable);
            return {
                find: true,
                callback: env.set,
                env: result.env,
                value: result,
                scope: result
            };
        }

        env = env.pop();
        if (env) {
            return env.find(variable);
        } else {
            return {
                find: false
            }
        }
    }
    child.set = (variable, value) => {
        child.context.set(variable, value);
    };

    return child;
};

const rootEnv = (() => {
    let root = envPush(null)();

    root.set('test', wrap(() => wrap(() => fromNative(5))));
    //root.set('String', { value: { name: 'String', type: 'Type' }, scope: new Map() });
    //root.set('Int', { value: { name: 'Int', type: 'Type' }, scope: new Map() });
    //root.set('Void', { value: { name: 'Void', type: 'Type' }, scope: new Map() });
    const print = e => {
        let value = toNative(e);
        if (typeof (value) !== 'string') {
            value = JSON.stringify(value, null, 2)
        }
        if (value === undefined) {
            throw new Error(`value is undefined`)
        }
        process.stdout.write(value);

        return {
            status: {
                code: 0
            },
            hasReturn: false,
            value: { type: Ast.VALUE, value: Void }
        };
    }
    root.set('print', { value: wrap(print) });
    root.set('println', {
        value: wrap(e => {
            print(e);
            process.stdout.write('\n')
            return { type: Ast.VALUE, value: Void };
        })
    })
    let debugFuction = wrap(print);
    debugFuction.value.debug = true;
    root.set('debug', { value: debugFuction });

    root.set('std', {value: fromNative(std)});
    //const Type0 = fromNative(Type)
    //Type0.value.type = PrimeType.Type;
    
    //Object.values(PrimeType).forEach(primeType => root.set(primeType.value, { value: Type.create(wrap(v => fromNative(equal(v.value.type, primeType)))) }))
    //root.set('Type', { value: Type0 });
    //root.set('Pair', Pair)
    /*
    root.set('Number', { value: Type.create(wrap(v => fromNative(equal(v.value.type, PrimeType.Number)))) })
    root.set('String', { value: Type.create(wrap(v => fromNative(equal(v.value.type, PrimeType.String)))) })
    root.set('Object', { value: Type.create(wrap(v => fromNative(equal(v.value.type, PrimeType.Object)))) })
    root.set('Array', { value: Type.create(wrap(v => fromNative(equal(v.value.type, PrimeType.Array)))) })
    root.set('Function', { value: Type.create(wrap(v => fromNative(equal(v.value.type, PrimeType.Function)))) })
    root.set('Void', { value: Type.create(wrap(v => fromNative(equal(v.value.type, PrimeType.Void)))) })
    */
    //Type.env = root;

    return root;
})().push();

export default rootEnv;
