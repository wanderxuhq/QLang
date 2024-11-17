import { Ast } from '../ast/index.js';
import { findInStd } from '../std/index.js';
import { PrimeType } from '../type/constant.js';
import { fromNative, toNative } from './native.js';
import runStatements from './run-statements.js';

const runValue = env => value => {
    let result = {};
    let scope = new Map();
    if (value.type === Ast.IDENTITY || value.type === Ast.VALUE) {
        if (value.type === Ast.IDENTITY) {
            //result = findInEnv(env)(value)(null).value
            //const envResult = envFind(env)(value)
            const envResult = env.find(value.value)
            if (!envResult.find) {
                console.log(`${value.value} not find in env`)
            }
            //const envResult = findInEnv(env)(value)(null)
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: envResult?.value,
                env: env
            };
            scope = envResult?.scope
        } else {
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: value.value,
                env: env
            }
        }

        if (value.arguments) {
            //console.log(result.value)
            if (result.value.type === PrimeType.Function) {
                env = env.push()
                env.runScope = scope

                const tmpResult = runFunction(env)(result.value)(null)(value.arguments);
                env = env.pop()//env.parent
                result = {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: tmpResult.value, //TODO type
                    env: env,
                    scope: tmpResult.scope
                }
            } else {
                result = {
                    status: {
                        code: 1,
                        message: `${value.value} is not function`,
                        start: value.start,
                        end: value.end
                    },
                    env: env,
                }
                return result;
            }
        }

        if (value.children) {
            if (value.children.length > 0) {
                const root = value;

                for (let childIndex = 0; childIndex < value.children.length; childIndex++) {
                    const child = value.children[childIndex];
                    if (child.childType === 'INDEX') {
                        result = runValue(env)(result.value
                            .values[toNative(runValue(env)(child).value)])
                    } else if (child.childType === 'FIELD') {
                        env.set('this', result)

                        const std = findInStd(result.value.type, child.value)
                        if (std) {
                            result = {
                                status: {
                                    code: 0,
                                    message: ''
                                },
                                value: std(result.value),
                                env: env,
                                scope: scope
                            }
                        } else {
                            result = runValue(env)(result.value.fields.find(e => e.variable.value === child.value).value);
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
                            status: {
                                code: 0,
                                message: ''
                            },
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
                values[i] = makeRunValueInput(runValue(env)(values[i]).value)
            }
            const scope = result.scope
            const value = {
                type: PrimeType.Array,
                values: values,
                fields: []
            }
            return {
                status: {
                    code: 0,
                    message: ''
                },
                value: value,
                env: env,
                scope: scope
            };
        } else if (result.value.type === PrimeType.Object) {
            let fields = result.value.fields;
            for (let i = 0; i < fields.length; i++) {
                fields[i].value = makeRunValueInput(runValue(env)(fields[i].value).value)
            }
            const scope = result.scope
            const value = {
                type: PrimeType.Object,
                fields: fields,
            }
            return {
                status: {
                    code: 0,
                    message: ''
                },
                value: value,
                env: env,
                scope: scope
            };
        }

        return result;
    } else if (value.type === Ast.BIN_OP) {
        if (value.op === '+') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Number,
                        value: toNative(lhsValue.value) + toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '-') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Number,
                        value: toNative(lhsValue.value) - toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '*') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Number,
                        value: toNative(lhsValue.value) * toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '/') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Number,
                        value: toNative(lhsValue.value) / toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '==') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) === toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '<') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) < toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '>') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) > toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '<=') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) <= toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '>=') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) >= toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '&&') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) && toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        } else if (value.op === '||') {
            const lhsValue = runValue(env)(value.lhs);
            const rhsValue = runValue(env)(value.rhs);
            if (lhsValue.status.code === 0 && rhsValue.status.code === 0) {
                return {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: PrimeType.Boolean,
                        value: toNative(lhsValue.value) || toNative(rhsValue.value)
                    },
                    env: env
                }
            } else {
                return {
                    status: {
                        code: 1,
                        message: 'Error occurred'
                    },
                    env: env
                }
            }
        }
    }
}

const runFunction = env => fun => obj => args => {
    for (let i = 0; i < args.length; i++) {
        if (!fun.system) {
            fun = JSON.parse(JSON.stringify(fun))
            for (let j = 0; j < fun.parameters.length; j++) {
                env.set(
                    fun.parameters[j].variable,
                    { value: runValue(env)(args[i].parameters[j]).value, scope: new Map() }
                );
            }

            fun = runStatements(env)(fun.body).value;
        } else {
            let parameters = [];
            if (fun.oop) {
                parameters.push(runValue(env)({
                    type: obj.type,
                    value: obj.value,
                    children: []
                }).value)
            }
            for (let j = 0; j < args[i].parameters.length; j++) {
                parameters.push(
                    runValue(env)(args[i].parameters[j]).value
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

const makeRunValueInput = value => {
    return {
        type: Ast.VALUE,
        value: value
    }
}

export { runValue, makeRunValueInput };
