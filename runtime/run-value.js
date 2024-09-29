import {
    Ast,
    NumberExprAst,
    BooleanExprAst
} from '../ast/index.js';
import {notMatch} from '../parser/match.js';
import runStatements from './run-statements.js';

const runValue = env => ast => {
    if (ast.type === Ast.IDENTITY) {
        //TODO
        let result = findInEnv(ast, env);

        if (ast.index) {
            result = result.value.values[runValue(env)(ast.index).value]
        }
        if (ast.child) {
            result = result.fields.fields.find(e => e.variable.value === ast.child.value).value;
        }

        return result;
    } else if (ast.type === Ast.FUNCTION_CALL) {
        env = {
            parent: env,
            context: new Map()
        };

        let fun = runValue(env)(ast.fun)
        for (let i = 0; i < ast.parameters.length; i++) {
            let parameters = runValue(env)(ast.parameters[i].parameters);

            for (let j = 0; j < fun.parameters.length; j++) {
                const parameter = fun.parameters[j];
                env.context.set(parameter.variable, runValue(env)(parameters[j]));
            }
            if (!fun.system) {
                fun = runStatements(env)(fun.body);
            } else {
                return fun.call.apply(this, parameters.map(e => runValue(env)(e).value));
            }
        }

        if (ast.index) {
            fun = runValue(env)(fun.value.values[runValue(env)(ast.index).value])
        }
        if (ast.child) {
            fun = fun.fields.fields.find(e => e.variable.value === ast.child.value).value;
        }

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