import { Ast } from '../ast/index.js';
import findInEnv from './find-in-env.js';

export default (ast, env) => {
    env = {
        context: new Map(),
        parent: env
    }
    for (const statement of ast.statements) {
        if (statement.type === Ast.DECLARE) {
            env.context.set(statement.variable.value, statement.value);
        } else if (statement.type === Ast.ASSIGN) {
            env.context.set(statement.variable.value, statement.value);
        } else if (statement.type === Ast.RETURN) {
            return findInEnv(statement.value, env);
        }
        //runStatement(ast, env);
    }
}