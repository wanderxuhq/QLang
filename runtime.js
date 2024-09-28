import parse from './parser/index.js';

import {
    Ast,
    NumberExprAst,
    BooleanExprAst
} from './ast/index.js';
import findInEnv from './parser/find-in-env.js';

Ast.STATEMENTS
//const statemets = parse();


let context = new Map();

context.set('String', { name: 'String', type: 'Type' });
context.set('Int', { name: 'Int', type: 'Type' });
context.set('Void', { name: 'Void', type: 'Type' });
context.set('print', { type: 'FUNCTION', system: true, call: e => {
    process.stdout.write(e + '')
}, parameters: [{variable: 'o'}] });

const runStatements = env => ast => {
    for (const statement of ast.statements) {
        if (statement.type === Ast.DECLARE) {
            const value = runValue(env)(statement.value);
            env.context.set(statement.variable.value,
                value
            );
        } else if (statement.type === Ast.ASSIGN) {
            const value = runValue(env)(statement.value);
            env.context.set(statement.variable.value,
                value
            );
        } else if (statement.type === Ast.RETURN) {
            const value = runValue(env)(statement.value);
            return value;
        } else if (statement.type === Ast.FUNCTION_CALL) {
            runValue(env)(statement);
        } else if (statement.type === Ast.IF) {
            runValue(env)(statement.matchBodies[0].condition)
            let hasMatch = false;
            for (const matchBody of statement.matchBodies) {
                if (runValue(env)(matchBody.condition).value) {
                    //TODO return in if
                    const value = runStatements(env)(matchBody.body);
                    if (value) {
                        return value;
                    }
                    hasMatch = true;
                    break;
                }
            }

            if (!hasMatch && statement.elseBody) {
                const value = runStatements(env)(statement.elseBody);

                if (value) {
                    //TODO return in if
                    return value;
                }
            }
        } else if (statement.type === Ast.WHILE) {
            while (runValue(env)(statement.condition).value) {
                runStatements(env)(statement.body);
            }
        }
    }

}

const runValue = env => ast => {
    if (ast.type === Ast.IDENTITY) {
        //TODO
        let result = findInEnv(ast, env);
        if (ast.index) {
            result = result.value.values[runValue(env)(ast.index).value]
        }
        if (ast.child) {
            result = result.fields.fields.find(e => e.variable.value === ast.child.value).value;

            env = {
                parent: env,
                context: new Map()
            };
            env.context.set(ast.child.value, result)
            result = runValue(env)(ast.child)
        }

        return result;
    } else if (ast.type === Ast.FUNCTION_CALL) {
        //TODO
        env = {
            parent: env,
            context: new Map()
        };

        const fun = findInEnv(ast.fun, env)
        if (fun.system) {
            return fun.call.apply(this, ast.parameters.parameters.map(e => runValue(env)(e).value))
        } else {
            for (let i = 0; i < fun.parameters.length; i++) {
                const parameter = fun.parameters[i];
                env.context.set(parameter.variable, runValue(env)(ast.parameters.parameters[i]));
            }
    
            return runStatements(env)(fun.body);
        }
        
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

/*
const runValue = env => ast =>{
    if (ast.type === Ast.NUMBER) {
        return new Number(ast.value);
    } else if (ast.type === Ast.STRING) {
        return ast.value;
    } else if (ast.type === Ast.BOOLEAN) {
        return ast.value;
    } else if (ast.type === Ast.FUNCTION) {
        //TODO
        return ast;
    } else if (ast.type === Ast.FUNCTION_CALL) {
        //TODO
    } else if (ast.type === Ast.IDENTITY) {
        //TODO
        return findInEnv(ast.value);
    } else if (ast.type === Ast.OBJECT) {
        //TODO
        let result = {};
        for (const v of ast.fields.fields) {
            result[v.variable.value] = runValue(env)(v.value);
        }

        return result;
    } else if (ast.type === Ast.ARRAY) {
        let result = [];
        for (const v of ast.value.values) {
            result.push(runValue(env)(v));
        }

        return result;
    }
}
*/

runStatements({ context: context })(parse('./demo/99.ql'));
