import { Ast } from '../ast/index.js';
import rootEnv from '../env.js';
import { findInStd } from '../std/index.js';
//import Type from '../std/type.js';
import { equal, PrimeType } from '../type/constant.js';
import { Void } from '../value/constant.js';
import { fromNative } from '../native/fromNative.js';
import toNative from '../native/toNative.js';
import runStatements from './run-statements.js';
import copyAst from '../util/copy-ast.js';

const runValue = env => value => {
    if (!value) {
        return {
            status: {
                code: 1,
                message: 'Invalid value'
            }
        };
    }

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

                return result = {
                    status: {
                        code: 0,
                        message: '',
                    },
                    value: {
                        value: Ast.VALUE,
                        value: Void
                    },
                };
            }
            //const envResult = findInEnv(env)(value)(null)
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: envResult.value.value,
            };
            scope = envResult?.scope
        } else {
            result = {
                status: {
                    code: 0,
                    message: ''
                },
                value: value
            }

            //result.value.env = env;
        }

        if (value.arguments) {
            result = runFunction(env)(result)(value.arguments)
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
                        //child.value as a Value
                        result = runValue(env)(result.value.value
                            .values[toNative(runValue(env)(child.value).value)])
                    } else if (child.childType === 'FIELD') {
                        let childEnv = env;
                        //if (child.type === Ast.VALUE) {
                        childEnv = result.value.env
                        //}
                        //child.value as String
                        //runValue(result.value, result.value.env)
                        const field = result.value.value.fields.find(e => e.key.value === child.value).value
                        //TODO enrich env
                        /*
                        if (!field.env) {
                            field.env = result.value.env
                        }
                        */
                        result = runValue(field.env)(field);

                        //}
                    }

                    if (child.arguments) {
                        //env = createEnv(env);
                        //env = env.push();
                        //env.runScope = scope
                        //TODO nested scope
                        const tmpResult = runFunction(env)(result)(child.arguments);
                        //env = env.pop()//env.parent;
                        result = {
                            status: {
                                code: 0,
                                message: ''
                            },
                            value: tmpResult.value
                        }
                    } else {
                        scope = undefined;
                    }
                }
            }
        }


        if (!result.value.native) {
            if (equal(result.value.value.type, PrimeType.Array)) {
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

            } else if (equal(result.value.value.type, PrimeType.Object)) {
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
        }

        return result;
    } else if (value.type === Ast.BIN_OP) {
        if (value.op === '+') {
            const lhsValue = runValue(env)(value.lhs);
            if (lhsValue.status.code === 0) {
                const rhsValue = runValue(env)(value.rhs);
                if (rhsValue.status.code === 0) {
                    if (equal(lhsValue.value.value.type, PrimeType.Number) && equal(rhsValue.value.value.type, PrimeType.Number)) {
                        return {
                            status: {
                                code: 0,
                                message: ''
                            },
                            value: {
                                type: Ast.VALUE, value: {
                                    type: PrimeType.Number,
                                    value: toNative(lhsValue.value) + toNative(rhsValue.value)
                                }
                            }
                        }
                    } else {
                        return {
                            status: {
                                code: -1,
                                start: lhsValue.start,
                                message: "Type mismatch"
                            },
                            stack: {
                                position: lhsValue.start
                            }
                        }
                    }
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
                if (!equal(lhs.value.type, PrimeType.Array) && !equal(lhs.value.type, PrimeType.Object) && !equal(lhs.value.type, PrimeType.Function)) {
                    compareLhs = toNative(lhs.value);
                }
                let compareRhs = rhs.value;
                if (!equal(rhs.value.type, PrimeType.Array) && !equal(rhs.value.type, PrimeType.Object) && !equal(rhs.value.type, PrimeType.Function)) {
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

const runFunction = env => rootFn => args => {
    let fn = rootFn
    if (!fn.value.native) {
        if (equal(fn.value.value.type, PrimeType.Function)) {
            for (let i = 0; i < args.length; i++) {
                fn = fn.value;
                if (!fn.value.system) {
                    const childEnv = fn.env.push()
                    const f = copyAst(fn.value)//JSON.parse(JSON.stringify(fn.value))
                    for (let j = 0; j < f.parameters.length; j++) {
                        childEnv.set(
                            f.parameters[j].variable,
                            //TODO check env
                            //TODO type
                            { value: runValue(env)(args[i].parameters[j]).value }
                        );
                    }

                    fn = runStatements(childEnv)(f.body);
                    //console.log(fn)
                } else {
                    let parameters = [];
                    /*
                    if (fun.value.oop) {
                        parameters.push(runValue(env)({
                            type: obj.type,
                            value: obj.value,
                            children: []
                        }).value)
                    }
                        */
                    if (fn.value.debug) {
                        debugger;
                    }
                    for (let j = 0; j < args[i].parameters.length; j++) {
                        parameters.push(
                            runValue(env)(args[i].parameters[j]).value
                        );
                    }

                    fn = fn.value.call.apply(this, parameters);
                    fn = {
                        status: {
                            code: 0,
                            message: '',
                        },
                        value: fn
                    }
                }
            }
        } else {
            fn = {
                status: {
                    code: 1,
                    message: `${value.value} is not function`,
                    start: value.start,
                    end: value.end
                },
            }
            return fn;
        }
    } else {
        if (fn.value.value.debug) {
            debugger;
        }

        for (let i = 0; i < args.length; i++) {
            let parameters = [];
            /*
                        if (fun.value.oop) {
                            parameters.push(runValue(env)({
                                type: obj.type,
                                value: obj.value,
                                children: []
                            }).value)
                        }
                        */
            for (let j = 0; j < args[i].parameters.length; j++) {
                parameters.push(runValue(env)(args[i].parameters[j]).value)
            }
            fn = {
                status: {
                    code: 0,
                    message: '',
                },
                value: fn.value.value.apply(this, parameters)
            }
        }
    }

    return fn
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

export { runValue, runFunction };
