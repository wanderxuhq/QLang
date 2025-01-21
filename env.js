import { Ast } from "./ast/index.js";
import { fromNative, toNative, wrap } from "./runtime/native.js";
import Type from "./std/type.js";
import { PrimeType } from "./type/constant.js";
import { Void } from "./value/constant.js";

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
    root.set('String', { value: { name: 'String', type: 'Type' }, scope: new Map() });
    root.set('Int', { value: { name: 'Int', type: 'Type' }, scope: new Map() });
    root.set('Void', { value: { name: 'Void', type: 'Type' }, scope: new Map() });
    const print = e => {
        let value = toNative(e);
        if (typeof (value) !== 'string') {
            value = JSON.stringify(value, null, 2)
        }
        if (value === undefined) {
            throw new Error(value)
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
    root.set('print', wrap(print));
    root.set('println', wrap(e => {
        print(e);
        process.stdout.write('\n')
        return { type: Ast.VALUE, value: Void };
    }))
    let debugFuction = wrap(print);
    debugFuction.value.debug = true;
    root.set('debug', debugFuction);
    const Type0 = fromNative(Type)
    Type0.value.type = PrimeType.Type;
    root.set('Type', Type0);
    root.set('Number', Type.create(wrap(v => fromNative(v.value.type === 'Number'))))
    root.set('String', Type.create(wrap(v => fromNative(v.value.type === 'String'))))
    Type.env = root;

    return root;
})().push();

export default rootEnv;
