import { Ast } from "./ast/index.js";
import { fromNative, toNative } from "./runtime/native.js";
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
    child.attach = (scope) => {
        child.scope = scope
    }
    child.deattach = () => {
        child.scope = new Map()
    }
    return child;
};

const findInEnv = (env, scope) => variable => {
    if (scope?.has(variable)) {
        let result = scope.get(variable);
        return {
            find: true,
            callback: (variable, value) => { env.runScope.set(variable, value) },
            env: env,
            value: result.value,
            scope: result.scope
        };
    } else if (env.context.has(variable)) {
        let result = env.context.get(variable);
        return {
            find: true,
            callback: env.set,
            env: env,
            value: result.value,
            scope: result.scope
        };
    }

    if (env) {
        return findInEnv(env, null)(variable);
    } else {
        return {
            find: false
        }
    }
}

const rootEnv = (() => {
    let root = envPush(null)();

    root.set('String', { value: { name: 'String', type: 'Type' }, scope: new Map() });
    root.set('Int', { value: { name: 'Int', type: 'Type' }, scope: new Map() });
    root.set('Void', { value: { name: 'Void', type: 'Type' }, scope: new Map() });
    const print = e => {
        let value = toNative(e);
        if (typeof (value) !== 'string') {
            value = JSON.stringify(value, null, 2)
        }
        process.stdout.write(value);

        return {
            status: {
                code: 0
            }, hasReturn: false,
            value: { type: Ast.VALUE, value: Void }
        };
    }
    root.set('print', fromNative(print));
    root.set('println', fromNative(e => {
        print(e);
        process.stdout.write('\n')
        return { type: Ast.VALUE, value: Void };
    }))
    let debugFuction = fromNative(print);
    debugFuction.value.debug = true;
    root.set('debug', debugFuction);

    return root;
})().push();

export default rootEnv;