import { Ast } from '../ast/index.js';
import { createEnv, findInEnv } from '../env.js';
import { toNative } from './native.js';
import runValue from './run-value.js';

const runStatements = env => ast => {
    
    for (const statement of ast.statements) {
        if (statement.type === Ast.DECLARE) {
            const value = runValue(env)(statement.value);
            env.context.set(statement.variable.value,
                value.value
            );
            if (statement.value.arguments) {
                //env.scope = value.context
                env.scope.set(statement.variable.value, value.context)
            }
        } else if (statement.type === Ast.ASSIGN) {
            const value = runValue(env)(statement.value).value;
            let subEnv = findInEnv(env)(statement.variable)(null);
            if (subEnv.type === 'context') {
                subEnv.env.context.set(statement.variable.value, value)
            } else if (subEnv.type === 'runScope') {
                subEnv.env.runScope.set(statement.variable.value, value)
            }
            
            if (statement.value.arguments) {
                env.scope.set(statement.variable.value, env.scope.get('_temp'))
            }
        } else if (statement.type === Ast.RETURN) {
            const value = runValue(env)(statement.value);
            return value;
        } else if (statement.type === Ast.FUNCTION_CALL) {
            runValue(env)(statement);
        } else if (statement.type === Ast.VALUE) {
            runValue(env)(statement);
        } else if (statement.type === Ast.IF) {
            runValue(env)(statement.matchBodies[0].condition)
            let hasMatch = false;
            for (const matchBody of statement.matchBodies) {
                if (toNative(runValue(env)(matchBody.condition).value)) {
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
            while (toNative(runValue(env)(statement.condition).value)) {
                const value = runStatements(env)(statement.body);
                if (value) {
                    //TODO return in if
                    return value;
                }
            }
        }
    }
}

export default runStatements;
