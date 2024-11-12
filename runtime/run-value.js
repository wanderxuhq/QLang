import { Ast } from '../ast/index.js';
import { findInEnv, createEnv } from '../env.js';
import { PrimeType } from '../type/constant.js';
import { Void } from '../value/constant.js';
import { fromNative, toNative } from './native.js';
import runStatements from './run-statements.js';

const runValue = env => value => {
    let result = {};
    let scope = new Map();
    if (value.type === Ast.IDENTITY || value.type === Ast.VALUE) {
        if (value.type === Ast.IDENTITY) {
            //result = findInEnv(env)(value)(null).value
            const envResult = findInEnv(env)(value)(null)
            result = {
                result: { type: Ast.VALUE, value: envResult?.value },
                env: env
            };
            scope = envResult?.scope
        } else {
            result = {
                result: value,
                env: env
            }
        }

        if (value.arguments) {
            env = createEnv(env);
            env.runScope = scope

            const tmpResult = runFunction(env)(result)(null)(value.arguments);
            env = env.parent
            result = {
                result: tmpResult.value, //TODO type
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
                        result = runValue(env)(result.result.value
                            .values[runValue(env)(child).result.value.value])
                    } else if (child.childType === 'FIELD') {
                        env.context.set('this', result)
                        if (result.result.value.type === PrimeType.Array && child.value === 'add') {
                            let func = fromNative((arr, e) => {
                                arr.result.value.values.push(e.result);
                                return arr.result
                            });
                            func.value.oop = true;
                            result = {
                                result: func,
                                env: env,
                                scope: scope
                            }
                        } else if (result.result.value.type === PrimeType.Array && child.value === 'length') {
                            let func = fromNative((arr, e) => {
                                return fromNative(arr.result.value.values.length)
                            });
                            func.value.oop = true;
                            result = {
                                result: func,
                                env: env
                            }
                        } else {
                            result = runValue(env)(result.result.value.fields.find(e => e.variable.value === child.value).value);
                        }

                    }

                    if (child.arguments) {
                        env = createEnv(env);
                        env.runScope = scope
                        const tmpResult = runFunction(env)(result)(root)(child.arguments);
                        env = env.parent;
                        scope = tmpResult.scope
                        result = {
                            result: tmpResult.value,
                            env: env,
                            scope: scope
                        }
                    } else {
                        scope = undefined;
                    }
                }
            }
        }

        if (result.result.value.type === PrimeType.Array) {
            let values = result.result.value.values;
            for (let i = 0; i < values.length; i++) {
                values[i] = runValue(env)(values[i]).result
            }
            const scope = result.scope
            result = {
                type: Ast.VALUE,
                value: {
                    type: PrimeType.Array,
                    values: values,
                    fields: []
                }
            }
            return {
                result: result,
                env: env,
                scope: scope
            };
        } else if (result.result.value.type === PrimeType.Object) {
            let fields = result.result.value.fields;
            for (let i = 0; i < fields.length; i++) {
                fields[i].value = runValue(env)(fields[i].value).result
            }
            const scope = result.scope
            result = {
                type: Ast.VALUE,
                value: {
                    type: PrimeType.Object,
                    fields: fields,
                }
            }
            return {
                result: result,
                env: env,
                scope: scope
            };
        }

        return result;
    } else if (value.type === Ast.BIN_OP) {
        if (value.op === '+') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Number,
                        value: toNative(runValue(env)(value.lhs).result.value) + toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '-') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Number,
                        value: toNative(runValue(env)(value.lhs).result.value) - toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '*') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Number,
                        value: toNative(runValue(env)(value.lhs).result.value) * toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '/') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Number,
                        value: toNative(runValue(env)(value.lhs).result.value) / toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '==') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) === toNative(runValue(env)(value.rhs).result.value)
                    }
                },
                env: env
            }
        } else if (value.op === '<') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) < toNative(runValue(env)(value.rhs).result.value)
                    }
                },
                env: env
            }
        } else if (value.op === '>') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) > toNative(runValue(env)(value.rhs).result.value)
                    }
                },
                env: env
            }
        } else if (value.op === '<=') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) <= toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '>=') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) >= toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '&&') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) && toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        } else if (value.op === '||') {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(runValue(env)(value.lhs).result.value) || toNative(runValue(env)(value.rhs).result.value)
                    },
                    env: env
                }
            }
        }
    }
}

const runFunction = env => fun => obj => args => {
    for (let i = 0; i < args.length; i++) {
        fun = fun.result.value
        if (!fun.system) {
            fun = JSON.parse(JSON.stringify(fun))
            //env = createEnv(env);
            for (let j = 0; j < fun.parameters.length; j++) {
                env.context.set(
                    fun.parameters[j].variable,
                    { value: runValue(env)(args[i].parameters[j]).result.value, scope: new Map() }
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

            fun = { result: fun.call.apply(this, parameters) };
        }
    }

    return {
        value: fun?.result,
        //TODO
        scope: env.context
    };
}

export default runValue;
