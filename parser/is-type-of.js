import findInEnv from './find-in-env.js';
import { Ast } from '../ast/index.js';
import runStatements from './run-statements.js';

export default (ast, type, env) => {
    if (ast.type === Ast.IDENTITY) {
        const value = findInEnv(ast, env);
        return value.type == type;
    } else if (ast.type === Ast.FUNCTION_CALL) {
        //console.log(ast);
        const fun = findInEnv(ast.fun, env)
        //console.log(fun);
        if (fun.system) {
            //TODO
            return false;
        } else {
            const value = runStatements(fun.body, env);
            return value?.type == type;
        }
    }
}