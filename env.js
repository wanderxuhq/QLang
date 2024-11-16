import { fromNative, toNative } from "./runtime/native.js";
import { Void } from "./value/constant.js";

const envPush = data => () => {
    const child = {
        parent: data,
        context: new Map(),
        scope: new Map(),
    }
    child.push = envPush(child);
    child.pop = envPop(child);
    child.find = envFind(child);
    return child;
};
const envPop = data => () => {
    return data.parent;
};
const envFind = data => variable => {
    let env = data;

    while (env) {
        if (env.runScope?.has(variable.value)) {
            let result = env.runScope.get(variable.value);
            return {
                type: 'runScope',
                env: env,
                value: result.value,
                scope: result.scope
            };
        }
        if (env.context.has(variable.value)) {
            let result = env.context.get(variable.value);
            return {
                type: 'context',
                env: env,
                value: result.value,
                scope: result.scope
            };
        }

        env = env.pop();
    }

    return Void
}

const rootEnv = (() => {
    const root = {
        parent: null,
        //context: context,
        scope: new Map()
    }

    let context = new Map();

    context.set('String', { value: { name: 'String', type: 'Type' }, scope: new Map() });
    context.set('Int', { value: { name: 'Int', type: 'Type' }, scope: new Map() });
    context.set('Void', { value: { name: 'Void', type: 'Type' }, scope: new Map() });
    const print = e => {
        let value = toNative(e);
        if (typeof (value) !== 'string') {
            value = JSON.stringify(value, null, 2)
        }
        process.stdout.write(value);

        return Void;
    }
    context.set('print', { value: fromNative(print), scope: new Map() });
    context.set('println', {
        value: fromNative(e => {
            print(e);
            process.stdout.write('\n')
            return Void;
        }), scope: new Map()
    })
    context.set('debug', { value: fromNative(print), scope: new Map() });

    context.set('Arrays', {
        value: fromNative({
            add: (arr, e) => {
                arr.value.values.push(e);
                return Void
            },
            length: (arr, e) => {
                return toNative(arr.value.values.length)
            }
        }), scope: new Map()
    });

    root.context = context;
    root.find = envFind(root);
    root.push = envPush(root);
    root.pop = envPop(root);

    return root;
})().push();

export default rootEnv;