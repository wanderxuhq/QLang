import {
    Ast,
    NumberExprAst,
    BooleanExprAst
} from '../ast/index.js';
import { notMatch } from '../parser/match.js';
import runStatements from './run-statements.js';

const runValue = env => ast => {
    if (ast.type === Ast.IDENTITY) {
        //TODO
        let result = findInEnv(ast, env);

        for(const child of ast.children) {
            if (child.type === 'INDEX') {
                result = runValue(env)(result.value.values[runValue(env)(child.value).value])
            } else if (child.type === 'FIELD') {
                env = {
                    parent: env,
                    context: new Map()
                };
                env.context.set('this', result)
                result = runValue(env)(result.fields.fields.find(e => e.variable.value === child.value.value).value);
            }
        }

        return result;
    } else if (ast.type === Ast.FUNCTION_CALL) {
        env = {
            parent: env,
            context: new Map()
        };

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

        for(const child of ast.children) {
            if (child.type === 'INDEX') {
                fun = runValue(env)(fun.value.values[runValue(env)(child.value).value])
            } else if (child.type === 'FIELD') {
                env = {
                    parent: env,
                    context: new Map()
                };
                env.context.set('this', fun)
                fun = runValue(env)(fun.fields.fields.find(e => e.variable.value === child.value.value).value);
            }
        }

        /*
        if (ast.index) {
            fun = runValue(env)(fun.value.values[runValue(env)(ast.index).value])
        }
        if (ast.child) {
            fun = fun.fields.fields.find(e => e.variable.value === ast.child.value).value;
        }
        */

        return fun;

        /*
        for (let i = 0; i < fun.parameters.length; i++) {
            const parameter = fun.parameters[i];
            //TODO
            runValue(env)(ast.parameters)
            env.context.set(parameter.variable, runValue(env)(ast.parameters.parameters[i]));
        }
        */

    } else if (ast.type === Ast.BIN_OP) {
        if (ast.op === '+') {
            return new NumberExprAst(runValue(env)(ast.lhs).value + runValue(env)(ast.rhs).value);
        } else if (ast.op === '-') {
            return new NumberExprAst(runValue(env)(ast.lhs).value - runValue(env)(ast.rhs).value);
        } else if (ast.op === '*') {
            return new NumberExprAst(runValue(env)(ast.lhs).value * runValue(env)(ast.rhs).value);
        } else if (ast.op === '/') {
            return new NumberExprAst(runValue(env)(ast.lhs).value / runValue(env)(ast.rhs).value);
        } else if (ast.op === '==') {
            return new BooleanExprAst(runValue(env)(ast.lhs).value === runValue(env)(ast.rhs).value);
        } else if (ast.op === '<=') {
            return new BooleanExprAst(runValue(env)(ast.lhs).value <= runValue(env)(ast.rhs).value);
        } else if (ast.op === '>=') {
            return new BooleanExprAst(runValue(env)(ast.lhs).value >= runValue(env)(ast.rhs).value);
        } else if (ast.op === '&&') {
            return new BooleanExprAst(runValue(env)(ast.lhs).value && runValue(env)(ast.rhs).value);
        } else if (ast.op === '||') {
            return new BooleanExprAst(runValue(env)(ast.lhs).value || runValue(env)(ast.rhs).value);
        }
    } else if (ast.type === Ast.OBJECT) {
        env = {
            parent: env,
            context: new Map()
        };
        //env.context.set('this', ast);
        return ast;
    } else {
        return ast;
    }
}


const findInEnv = (variable, env) => {
    if (variable.type === Ast.NUMBER) {
        return variable.value;
    } else if (variable.type === Ast.FUNCTION) {
        return variable;
    } else if (variable.type === Ast.OBJECT) {
        return variable;
    } else if (variable.type === Ast.FUNCTION_CALL) {
        env = {
            parent: env,
            context: new Map()
        };
        const fun = findInEnv(variable.fun, env);

        //console.log(fun);
        if (!fun.system) {
            const value = runStatements(env)(fun.body);
            return value;
        }
    }

    while (env) {
        if (variable.type === Ast.IDENTITY) {
            //TODO 
            if (env.context.has(variable.value)) {
                let result = env.context.get(variable.value);
                return result;
            }
        }

        env = env.parent;
    }

    return notMatch;
};


export default runValue;