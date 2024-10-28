import { Ast } from '../ast/index.js';
import runValue from './run-value.js';

const runStatements = env => ast => {
    for (const statement of ast.statements) {
        if (statement.type === Ast.DECLARE) {
            const value = runValue(env)(statement.value);
            env.context.set(statement.variable.value,
                value
            );
            if (statement.value.arguments) {
                env.scope.set(statement.variable.value, env.scope.get('_temp'))
            }
        } else if (statement.type === Ast.ASSIGN) {
            const value = runValue(env)(statement.value);
            env.context.set(statement.variable.value,
                value
            );
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

export default runStatements;
