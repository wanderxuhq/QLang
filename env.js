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

        if (env.runScope?.has(variable)) {
            let result = env.runScope.get(variable);
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

/*
const envTransaction = data => () => {
    data.transtaction = true;
    data.backup = data.context
    data.context = JSON.parse(JSON.stringify(data.context));
}

const envCommit = data => () => {
    data.transtaction = false;
}

const envRevert = data => () => {
    data.context = data.backup;
    data.transtaction = false;
}
*/

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

        return Void;
    }
    root.set('print', { value: fromNative(print), scope: new Map() });
    root.set('println', {
        value: fromNative(e => {
            print(e);
            process.stdout.write('\n')
            return Void;
        }), scope: new Map()
    })
    root.set('debug', { value: fromNative(print), scope: new Map() });

    root.set('Arrays', {
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

    return root;
})().push();

export default rootEnv;