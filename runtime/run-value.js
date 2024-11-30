import { Ast } from '../ast/index.js';
import rootEnv from '../env.js';
import { findInStd } from '../std/index.js';
import { PrimeType } from '../type/constant.js';
import { fromNative, toNative } from './native.js';
import runStatements from './run-statements.js';

const runValue = env => value => {
    let result = {};
    let scope = new Map();
    if (!value.env) {
        value.env = env;
    }
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
                value: {
                    type: envResult.value.type,
                    value: envResult.value.value,
                    env: envResult.value.env
                },
            };
            scope = envResult?.scope
        } else {
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: {
                    type: value.type,
                    value: value.value,
                    env: value.env
                }
            }

            //result.value.env = env;
        }

        if (value.arguments) {
            //console.log(result.value)
            if (result.value.value.type === PrimeType.Function) {
                //env = env.push()
                //env.runScope = scope
                //let childEnv = result.value.env.push()
                if (value.value === 'debug') {
                    //debugger;
                }
                const tmpResult = runFunction(env)(result.value)(null)(value.arguments);
                //env = env.pop()//env.parent
                result = {
                    status: {
                        code: 0,
                        message: ''
                    },
                    value: {
                        type: Ast.VALUE,
                        value: tmpResult.value?.value,
                        env: tmpResult.value?.env
                    }, //TODO type
                }
            } else {
                result = {
                    status: {
                        code: 1,
                        message: `${value.value} is not function`,
                        start: value.start,
                        end: value.end
                    },
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
                        let childEnv = env;
                        if (child.type === Ast.VALUE) {
                            childEnv = result.value.env
                        }
                        result = runValue(env)(result.value.value
                            .values[toNative(runValue(env)(child).value)])
                    } else if (child.childType === 'FIELD') {
                        //env.set('this', result)

                        const std = findInStd(result.value.value.type, child.value)
                        if (std) {
                            result = {
                                status: {
                                    code: 0,
                                    message: ''
                                },
                                value: std(result.value.value),
                            }
                        } else {
                            let childEnv = env;
                            //if (child.type === Ast.VALUE) {
                            childEnv = result.value.env
                            //}
                            const field = result.value.value.fields.find(e => e.variable.value === child.value).value
                            result = runValue(field.env)(field);
                        }
                    }

                    if (child.arguments) {
                        //env = createEnv(env);
                        //env = env.push();
                        //env.runScope = scope
                        //TODO nested scope
                        const tmpResult = runFunction(env)(result.value)(root)(child.arguments);
                        //env = env.pop()//env.parent;
                        result = {
                            status: {
                                code: 0,
                                message: ''
                            },
                            value: {
                                type: tmpResult.value.type,
                                value: tmpResult.value.value,
                                env: tmpResult.value.env
                            }
                        }
                    } else {
                        scope = undefined;
                    }
                }
            }
        }


        if (result.value.value.type === PrimeType.Array) {
            let values = result.value.value.values;
            for (let i = 0; i < values.length; i++) {
                //values[i].env = env;
                values[i] = runValue(result.value.env)(values[i]).value
            }
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: {
                    type: Ast.VALUE,
                    value: result.value.value,
                    env: result.value.env
                },
            };

        } else if (result.value.value.type === PrimeType.Object) {
            let fields = result.value.value.fields;
            for (let i = 0; i < fields.length; i++) {
                //fields[i].value.env = result.value.env
                fields[i].value = runValue(result.value.env)(fields[i].value).value
            }
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: {
                    type: Ast.VALUE,
                    value: result.value.value,
                    env: result.value.env
                },
            };
        }

        return result;
    } else if (value.type === Ast.BIN_OP) {
        if (value.op === '+') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Number,
                    value: toNative(lhs.value) + toNative(rhs.value)
                }
            });
        } else if (value.op === '-') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Number,
                    value: toNative(lhs.value) - toNative(rhs.value)
                }
            });
        } else if (value.op === '*') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Number,
                    value: toNative(lhs.value) * toNative(rhs.value)
                }
            });
        } else if (value.op === '/') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Number,
                    value: toNative(lhs.value) / toNative(rhs.value)
                }
            });
        } else if (value.op === '%') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Number,
                    value: toNative(lhs.value) % toNative(rhs.value)
                }
            });
        } else if (value.op === '==') {
            return runBinOp(env)(value)((lhs, rhs) => {
                let compareLhs = lhs.value;
                if (lhs.value.type !== PrimeType.Array && lhs.value.type !== PrimeType.Object && lhs.value.type !== PrimeType.Function) {
                    compareLhs = toNative(lhs.value);
                }
                let compareRhs = rhs.value;
                if (rhs.value.type !== PrimeType.Array && rhs.value.type !== PrimeType.Object && rhs.value.type !== PrimeType.Function) {
                    compareRhs = toNative(rhs.value);
                }
                return {
                    type: PrimeType.Boolean,
                    value: compareLhs === compareRhs
                }
            });
        } else if (value.op === '<') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Boolean,
                    value: toNative(lhs.value) < toNative(rhs.value)
                }
            });
        } else if (value.op === '>') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Boolean,
                    value: toNative(lhs.value) > toNative(rhs.value)
                }
            });
        } else if (value.op === '<=') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Boolean,
                    value: toNative(lhs.value) <= toNative(rhs.value)
                }
            });
        } else if (value.op === '>=') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Boolean,
                    value: toNative(lhs.value) >= toNative(rhs.value)
                }
            });
        } else if (value.op === '&&') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Boolean,
                    value: toNative(lhs.value) && toNative(rhs.value)
                }
            });
        } else if (value.op === '||') {
            return runBinOp(env)(value)((lhs, rhs) => {
                return {
                    type: PrimeType.Boolean,
                    value: toNative(lhs.value) || toNative(rhs.value)
                }
            });
        }
    }
}

const runFunction = env => fun => obj => args => {
    //let fun = f.value
    //TODO is env required?
    let result
    //let childEnv = env
    for (let i = 0; i < args.length; i++) {
        if (!fun.value.system) {
            const childEnv = fun.env.push()
            const f = JSON.parse(JSON.stringify(fun.value))
            for (let j = 0; j < f.parameters.length; j++) {
                childEnv.set(
                    f.parameters[j].variable,
                    //TODO check env
                    runValue(env)(args[i].parameters[j]).value
                );
            }

            const tmpResult = runStatements(childEnv)(f.body);
            fun = tmpResult.value;
            result = tmpResult
        } else {
            let parameters = [];
            if (fun.value.oop) {
                parameters.push(runValue(env)({
                    type: obj.type,
                    value: obj.value,
                    children: []
                }).value)
            }
            if (fun.value.debug) {
                debugger;
            }
            for (let j = 0; j < args[i].parameters.length; j++) {
                parameters.push(
                    runValue(env)(args[i].parameters[j]).value
                );
            }

            fun = fun.value.call.apply(this, parameters);
            result = { value: fun }
        }
    }

    return result;
}

const runBinOp = env => value => callback => {
    const lhsValue = runValue(env)(value.lhs);
    if (lhsValue.status.code === 0) {
        const rhsValue = runValue(env)(value.rhs);
        if (rhsValue.status.code === 0) {
            let result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: { type: Ast.VALUE, value: callback(lhsValue, rhsValue) },
                //env: env
            }
            return result
        } else {
            return {
                status: rhsValue.status,
                //env: env
            }
        }
    } else {
        return {
            status: lhsValue.status,
            //env: env
        }
    }
}

const makeRunValueInput = value => {
    return {
        type: Ast.VALUE,
        value: value
    }
}

export { runValue, makeRunValueInput };
