import {notMatch} from './match.js';
import { Ast } from '../ast/index.js';
import runStatements from './run-statements.js';

const findInEnv = (variable, env) => {
    if (variable.type === Ast.NUMBER) {
        return variable.value;
    } else if (variable.type === Ast.FUNCTION) {
        return variable;
    } else if (variable.type === Ast.FUNCTION_CALL) {
        const fun = findInEnv(variable.fun, env);
        //console.log(fun);
        if (!fun.system) {
            const value = runStatements(fun.body, env);
            return value;
        }
    }

    while (env) {
        if (variable.type === Ast.IDENTITY) {
            //TODO 
            if (env.context.has(variable.value)) {
                return env.context.get(variable.value);
            }
        }

        env = env.parent;
    }

    return notMatch;
};


export default findInEnv;