const findInEnv = env => variable => scope => {
    if (scope) {
        if (env.scope.has(variable.value)) {
            const result = env.scope.get(variable.value);
            return {
                type: 'scope',
                env: env,
                value: result
            };
        }
    }
    while (env) {
        //TODO 
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

        env = env.parent;
    }

    //return notMatch;
};

const createEnv = env => {
    return {
        parent: env,
        context: new Map(),
        scope: new Map(),
    }
}

export {
    findInEnv,
    createEnv
}