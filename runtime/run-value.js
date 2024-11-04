import {
    Ast,
    NumberValueAst,
    BooleanValueAst,
    ArrayValueAst
} from '../ast/index.js';
import { findInEnv, createEnv } from '../env.js';
import { notMatch } from '../parser/match.js';
import { toNative } from './native.js';
import runStatements from './run-statements.js';

const runValue = env => ast => {
    //console.log(ast.value)
    if (ast.subType === Ast.IDENTITY) {
        let result = findInEnv(env)(ast)(null);

        //console.trace()
        if (ast.arguments) {
            env.runScope = new Map();
            if (env.scope.has(ast.value)) {
                for(const [key, value] of env.scope.get(ast.value)) {
                    env.runScope.set(key, value)
                }
            }

            const tmpResult = runFunction(env)(result)(ast);
            result = {
                env: env,
                value: tmpResult.value,
                context: tmpResult.context
            }
        }

        if (ast.children.length > 0) {
            const root = ast;
            
            for (let childIndex = 0; childIndex < ast.children.length; childIndex++) {
                const child = ast.children[childIndex];
                if (child.childType === 'INDEX') {
                    result = runValue(env)(result.value.values[runValue(env)(child).value.value])
                    //ast = child
                } else if (child.childType === 'FIELD') {
                    //env = createEnv(env);
                    env.context.set('this', result)

                    result = runValue(env)(result.value.fields.fields.find(e => e.variable.value === child.value).value);
                }

                if (child.arguments) {
                    env.runScope = new Map();
                    if (env.scope.has(root.value)) {
                        //for(const [key, value] of env.scope.get(root.value)) {
                            env.runScope = env.scope.get(root.value)
                            //env.runScope.set(key, value)
                        //}
                    }
                    const tmpResult = runFunction(env)(result)(child);
                    result = {
                        env: env,
                        value: tmpResult.value,
                        context: tmpResult.context
                    }
                }
            }
        }

        return result;
    } else if (ast.subType === Ast.BIN_OP) {
        if (ast.op === '+') {
            return {value: new NumberValueAst(toNative(runValue(env)(ast.lhs).value) + toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '-') {
            return {value: new NumberValueAst(toNative(runValue(env)(ast.lhs).value) - toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '*') {
            return {value: new NumberValueAst(toNative(runValue(env)(ast.lhs).value) * toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '/') {
            return {value: new NumberValueAst(toNative(runValue(env)(ast.lhs).value) / toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '==') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) === toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '<') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) < toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '>') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) > toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '<=') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) <= toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '>=') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) >= toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '&&') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) && toNative(runValue(env)(ast.rhs).value)), env: env};
        } else if (ast.op === '||') {
            return {value: new BooleanValueAst(toNative(runValue(env)(ast.lhs).value) || toNative(runValue(env)(ast.rhs).value)), env: env};
        }
    } else if (ast.subType === Ast.OBJECT) {
        return {value: ast, env: env};
    } else if (ast.subType === Ast.FUNCTION) {
        return {value: ast, env: env};
    } else if (ast.subType === Ast.ARRAY) {
        return {value: new ArrayValueAst(ast.values.map(e => runValue(env)(e).value)), env: env};
    } else {
        return {value: ast, env: env};
    }
}

const runFunction = env => fun => ast => {
    for (let i = 0; i < ast.arguments.length; i++) {
        fun = fun.value
        //TODO
        if (!fun.system) {
        //if (true) {
            //TODO move up
            env = createEnv(env);
            for (let j = 0; j < fun.parameters.length; j++) {
                env.context.set(
                    fun.parameters[j].variable,
                    runValue(env)(ast.arguments[i].parameters[j]).value
                );
            }
            
            //env.runScope = env.parent.runScope
            fun = runStatements(env)(fun.body);
            //env = env.parent;
            //fun.env = env;
        } else {
            let parameters = [];
            for (let j = 0; j < fun.parameters.length; j++) {
                parameters.push(
                    runValue(env)(ast.arguments[i].parameters[j]).value
                );
            }
            fun = fun.call.apply(this, parameters.map(e => toNative(e)));
        }
    }

    /*
    for (const [key, value] of env.context) {
        env.scope.set(key, value);
    }
    */
   //env.scope = env.context

    return {
        value: fun?.value,
        context: env.context
    };
}

export default runValue;