import {
    Ast,
    NumberValueAst,
    BooleanValueAst
} from '../ast/index.js';
import { createEnv } from '../env.js';
import { notMatch } from '../parser/match.js';
import runStatements from './run-statements.js';

const runValue = env => ast => {
    if (ast.subType === Ast.IDENTITY) {
        let result = findInEnv(ast, env);
        let scope = null;
        if (result.scope) {
            scope = result.scope;
            result = result.value;
            env = createEnv(env);
            env.context = scope.context;
        }

        if (ast.arguments) {
            env = createEnv(env);

            let fun = result
            for (let i = 0; i < ast.arguments.length; i++) {
                if (!fun.system) {
                    for (let j = 0; j < fun.parameters.length; j++) {
                        env.context.set(
                            fun.parameters[j].variable,
                            runValue(env)(ast.arguments[i].parameters[j])
                        );
                    }
                    fun = runStatements(env)(fun.body);
                    //fun.env = env;
                } else {
                    let parameters = [];
                    for (let j = 0; j < fun.parameters.length; j++) {
                        parameters.push(
                            runValue(env)(ast.arguments[i].parameters[j])
                        );
                    }
                    fun = fun.call.apply(this, parameters.map(e => JSON.stringify(e)));
                }
            }

            result = fun;
            
            if (ast.arguments) {
                env.parent.scope.set('_temp', env)
            }

            env = env.parent;
        }

        if (ast.child) {
            while (ast.child) {
                if (ast.child.childType === 'INDEX') {
                    result = runValue(env)(result.value.values[runValue(env)(ast.child).value])
                    ast = ast.child
                } else if (ast.child.childType === 'FIELD') {
                    env = createEnv(env);
                    env.context.set('this', result)

                    result = runValue(env)(result.fields.fields.find(e => e.variable.value === ast.child.value).value);
                    ast = ast.child
                }

                if (ast.arguments) {
                    env = createEnv(env);

                    let fun = result
                    for (let i = 0; i < ast.arguments.length; i++) {
                        if (!fun.system) {
                            for (let j = 0; j < fun.parameters.length; j++) {
                                env.context.set(
                                    fun.parameters[j].variable,
                                    runValue(env)(ast.arguments[i].parameters[j])
                                );
                            }
                            fun = runStatements(env)(fun.body);
                            //fun.env = env;
                            //console.log(env);
                        } else {
                            let parameters = [];
                            for (let j = 0; j < fun.parameters.length; j++) {
                                parameters.push(
                                    runValue(env)(ast.arguments[i].parameters[j])
                                );
                            }
                            fun = fun.call.apply(this, parameters.map(e => JSON.stringify(e)));
                        }
                    }

                    result = fun;
                }
            }
        }

        return result;
    } else if (ast.subType === Ast.FUNCTION_CALL) {
        env = createEnv(env);

        let fun = runValue(env)(ast.fun)
        for (let i = 0; i < ast.parameters.length; i++) {
            if (!fun.system) {
                for (let j = 0; j < fun.parameters.length; j++) {
                    env.context.set(
                        fun.parameters[j].variable,
                        runValue(env)(ast.parameters[i].parameters[j])
                    );
                }
                fun = runStatements(env)(fun.body);
            } else {
                let parameters = [];
                for (let j = 0; j < fun.parameters.length; j++) {
                    parameters.push(
                        runValue(env)(ast.parameters[i].parameters[j])
                    );
                }
                fun = fun.call.apply(this, parameters.map(e => e.value));
            }
        }

        for (const child of ast.children) {
            if (child.type === 'INDEX') {
                fun = runValue(env)(fun.value.values[runValue(env)(child.value).value])
            } else if (child.type === 'FIELD') {
                env = createEnv(env);
                env.context.set('this', fun)
                fun = runValue(env)(fun.fields.fields.find(e => e.variable.value === child.value.value).value);
            }
        }


        return fun;
    } else if (ast.subType === Ast.BIN_OP) {
        if (ast.op === '+') {
            return new NumberValueAst(runValue(env)(ast.lhs).value + runValue(env)(ast.rhs).value);
        } else if (ast.op === '-') {
            return new NumberValueAst(runValue(env)(ast.lhs).value - runValue(env)(ast.rhs).value);
        } else if (ast.op === '*') {
            return new NumberValueAst(runValue(env)(ast.lhs).value * runValue(env)(ast.rhs).value);
        } else if (ast.op === '/') {
            return new NumberValueAst(runValue(env)(ast.lhs).value / runValue(env)(ast.rhs).value);
        } else if (ast.op === '==') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value === runValue(env)(ast.rhs).value);
        } else if (ast.op === '<') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value < runValue(env)(ast.rhs).value);
        } else if (ast.op === '>') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value > runValue(env)(ast.rhs).value);
        } else if (ast.op === '<=') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value <= runValue(env)(ast.rhs).value);
        } else if (ast.op === '>=') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value >= runValue(env)(ast.rhs).value);
        } else if (ast.op === '&&') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value && runValue(env)(ast.rhs).value);
        } else if (ast.op === '||') {
            return new BooleanValueAst(runValue(env)(ast.lhs).value || runValue(env)(ast.rhs).value);
        }
    } else if (ast.subType === Ast.OBJECT) {
        env = createEnv(env);
        //env.context.set('this', ast);
        return ast;
    } else if (ast.subType === Ast.FUNCTION) {
        //env.scope.set('this', ast);
        return ast;
    } else {
        return ast;
    }
}

const findInEnv = (variable, env) => {
    if (variable.subType === Ast.NUMBER) {
        return variable.value;
    } else if (variable.subType === Ast.FUNCTION) {
        return variable;
    } else if (variable.subType === Ast.OBJECT) {
        return variable;
    } else if (variable.subType === Ast.FUNCTION_CALL) {
        env = createEnv(env);
        const fun = findInEnv(variable.fun, env);

        //console.log(fun);
        if (!fun.system) {
            const value = runStatements(env)(fun.body);
            return value;
        }
    }

    if (variable.env) {
        console.log('find env');
    }

    if (variable.subType === Ast.IDENTITY) {
        while (env) {
            let scope = null;
            if (env.scope.has(variable.value)) {
                scope = env.scope.get(variable.value);
            }
            //TODO 
            if (env.context.has(variable.value)) {
                let result = env.context.get(variable.value);
                if (scope) {
                    return {
                        value: result,
                        scope: scope
                    }
                }
                return result;
            }

            env = env.parent;
        }
    }


    return notMatch;
};

const runFunction = env => ast => {
    env = createEnv(env);

    let fun = result
    for (let i = 0; i < ast.arguments.length; i++) {
        if (!fun.system) {
            for (let j = 0; j < fun.parameters.length; j++) {
                env.context.set(
                    fun.parameters[j].variable,
                    runValue(env)(ast.arguments[i].parameters[j])
                );
            }
            fun = runStatements(env)(fun.body);
        } else {
            let parameters = [];
            for (let j = 0; j < fun.parameters.length; j++) {
                parameters.push(
                    runValue(env)(ast.arguments[i].parameters[j])
                );
            }
            fun = fun.call.apply(this, parameters.map(e => e.value));
        }
    }

    result = fun;
}

export default runValue;