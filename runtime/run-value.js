import { Ast } from '../ast/index.js';
import { findInStd } from '../std/index.js';
import { PrimeType } from '../type/constant.js';
import { fromNative, toNative } from './native.js';
import runStatements from './run-statements.js';

const runValueWithScope = env => value => {
    let result = {};
    let scope = new Map();
    if (value.type === Ast.IDENTITY || value.type === Ast.VALUE) {
        if (value.type === Ast.IDENTITY) {
            //result = findInEnv(env)(value)(null).value
            //const envResult = envFind(env)(value)
            const envResult = env.find(value)
            //const envResult = findInEnv(env)(value)(null)
            result = {
                value: envResult?.value,
                env: env
            };
            scope = envResult?.scope
        } else {
            result = {
                value: value.value,
                env: env
            }
        }

        if (value.arguments) {
            //env = createEnv(env);
            env = env.push()
            env.runScope = scope

            const tmpResult = runFunction(env)(result.value)(null)(value.arguments);
            env = env.pop()//env.parent
            result = {
                value: tmpResult.value, //TODO type
                env: env,
                scope: tmpResult.scope
            }
        }

        if (value.children) {
            if (value.children.length > 0) {
                const root = value;

                for (let childIndex = 0; childIndex < value.children.length; childIndex++) {
                    const child = value.children[childIndex];
                    if (child.childType === 'INDEX') {
                        result = runValueWithScope(env)(result.value
                            .values[toNative(runValue(env)(child))])
                    } else if (child.childType === 'FIELD') {
                        env.context.set('this', result)

                        const std = findInStd(result.value.type, child.value)
                        if (std) {
                            result = {
                                value: std(result.value),
                                env: env,
                                scope: scope
                            }
                        } else {
                            result = runValueWithScope(env)(result.value.fields.find(e => e.variable.value === child.value).value);
                        }
                    }

                    if (child.arguments) {
                        //env = createEnv(env);
                        env = env.push();
                        env.runScope = scope
                        const tmpResult = runFunction(env)(result.value)(root)(child.arguments);
                        env = env.pop()//env.parent;
                        scope = tmpResult.scope
                        result = {
                            value: tmpResult.value,
                            env: env,
                            scope: scope
                        }
                    } else {
                        scope = undefined;
                    }
                }
            }
        }

        if (result.value.type === PrimeType.Array) {
            let values = result.value.values;
            for (let i = 0; i < values.length; i++) {
                values[i] = makeRunValueInput(runValue(env)(values[i]))
            }
            const scope = result.scope
            const value = {
                type: PrimeType.Array,
                values: values,
                fields: []
            }
            return {
                value: value,
                env: env,
                scope: scope
            };
        } else if (result.value.type === PrimeType.Object) {
            let fields = result.value.fields;
            for (let i = 0; i < fields.length; i++) {
                fields[i].value = makeRunValueInput(runValue(env)(fields[i].value))
            }
            const scope = result.scope
            const value = {
                type: PrimeType.Object,
                fields: fields,
            }
            return {
                value: value,
                env: env,
                scope: scope
            };
        }

        return result;
    } else if (value.type === Ast.BIN_OP) {
        if (value.op === '+') {
            return {
                value: {
                    type: PrimeType.Number,
                    value: toNative(runValue(env)(value.lhs)) + toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '-') {
            return {
                value: {
                    type: PrimeType.Number,
                    value: toNative(runValue(env)(value.lhs)) - toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '*') {
            return {
                value: {
                    type: PrimeType.Number,
                    value: toNative(runValue(env)(value.lhs)) * toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '/') {
            return {
                value: {
                    type: PrimeType.Number,
                    value: toNative(runValue(env)(value.lhs)) / toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '==') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) === toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '<') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) < toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '>') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) > toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '<=') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) <= toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '>=') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) >= toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '&&') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) && toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        } else if (value.op === '||') {
            return {
                value: {
                    type: PrimeType.Boolean,
                    value: toNative(runValue(env)(value.lhs)) || toNative(runValue(env)(value.rhs))
                },
                env: env
            }
        }
    }
}

const runFunction = env => fun => obj => args => {
    for (let i = 0; i < args.length; i++) {
        //fun = fun.result.value
        if (!fun.system) {
            fun = JSON.parse(JSON.stringify(fun))
            //env = createEnv(env);
            for (let j = 0; j < fun.parameters.length; j++) {
                env.context.set(
                    fun.parameters[j].variable,
                    { value: runValue(env)(args[i].parameters[j]), scope: new Map() }
                );
            }

            fun = runStatements(env)(fun.body);
        } else {
            let parameters = [];
            if (fun.oop) {
                parameters.push(runValue(env)({
                    type: obj.type,
                    value: obj.value,
                    children: []
                }))
            }
            for (let j = 0; j < args[i].parameters.length; j++) {
                parameters.push(
                    runValue(env)(args[i].parameters[j])
                );
            }

            fun = fun.call.apply(this, parameters);
        }
    }

    return {
        value: fun,
        //TODO
        scope: env.context
    };
}

const runValue = env => value => {
    return runValueWithScope(env)(value).value
}

const makeRunValueInput = value => {
    return {
        type: Ast.VALUE,
        value: value
    }
}

export { runValueWithScope, runValue, makeRunValueInput };
