import {
    Ast,
    NumberValueAst,
    BooleanValueAst,
    ArrayValueAst
} from '../ast/index.js';
import { findInEnv, createEnv } from '../env.js';
import { PrimeType } from '../type/constant.js';
import { toNative } from './native.js';
import runStatements from './run-statements.js';

const runValue = env => value => {
    //console.log(ast.value)
    if (value.type === Ast.VALUE) {
        if (value.value.type === PrimeType.Array) {
            return {
                result: {
                    type: Ast.VALUE,
                    value: {
                        type: PrimeType.Array,
                        values: value.value.values.map(e => runValue(env)(e))
                    }
                },
                env: env
            };
        }

        return {
            result: {
                type: Ast.VALUE,
                value: value.value
            },
            env: env
        }
    } else if (value.type === Ast.IDENTITY) {
        let result = {
            result: { type: Ast.VALUE, value: findInEnv(env)(value)(null)?.value },
            env: env
        };
        //console.trace()
        if (value.arguments) {
            env.runScope = new Map();
            if (env.scope.has(value.value)) {
                for (const [key, value] of env.scope.get(value.value)) {
                    env.runScope.set(key, value)
                }
            }

            const tmpResult = runFunction(env)(result.result.value)(value);
            result = {
                result: tmpResult.value, //TODO type
                env: env,
                context: tmpResult.context
            }
        }

        if (value.children.length > 0) {
            const root = value;

            for (let childIndex = 0; childIndex < value.children.length; childIndex++) {
                const child = value.children[childIndex];
                if (child.childType === 'INDEX') {
                    //runValue(env)(makeValue(result.value)).value.values[runValue(env)(child).value.value]
                    result = result.result.value
                        .values[runValue(env)(child).result.value.value]
                    //ast = child
                } else if (child.childType === 'FIELD') {
                    //env = createEnv(env);
                    env.context.set('this', result)

                    result = runValue(env)(result.result.value.fields.find(e => e.variable.value === child.value).value);
                }

                if (child.arguments) {
                    env.runScope = new Map();
                    if (env.scope.has(root.value)) {
                        env.runScope = env.scope.get(root.value)
                    }
                    const tmpResult = runFunction(env)(result.result.value)(child);
                    result = {
                        result: tmpResult.value,
                        env: env,
                        context: tmpResult.context
                    }
                }
            }
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

const runFunction = env => fun => ast => {
    for (let i = 0; i < ast.arguments.length; i++) {
        //fun = fun.value
        //TODO
        if (!fun.system) {
            //if (true) {
            //TODO move up
            env = createEnv(env);
            for (let j = 0; j < fun.parameters.length; j++) {
                env.context.set(
                    fun.parameters[j].variable,
                    runValue(env)(ast.arguments[i].parameters[j]).result.value
                );
            }

            //env.runScope = env.parent.runScope
            fun = runStatements(env)(fun.body);
            //env = env.parent;
            //fun.env = env;
        } else {
            let parameters = [];
            for (let j = 0; j < fun.parameters.length; j++) {
                parameters.push(
                    runValue(env)(ast.arguments[i].parameters[j])
                );
            }
            fun = fun.call.apply(this, parameters.map(e => toNative(e.result.value)));
        }
    }

    /*
    for (const [key, value] of env.context) {
        env.scope.set(key, value);
    }
    */
    //env.scope = env.context

    return {
        value: fun?.result,
        context: env.context
    };
}

const makeValue = (value) => {
    return {
        type: Ast.VALUE,
        value: value
    }
}

export default runValue;