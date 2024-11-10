import { Ast } from '../ast/index.js';
import { createEnv, findInEnv } from '../env.js';
import { PrimeType } from '../type/constant.js';
import { Void } from '../value/constant.js';
import { toNative } from './native.js';
import runValue from './run-value.js';

const runStatements = env => ast => {
    for (const statement of ast.statements) {
        if (statement.type === Ast.DECLARE) {
            const value = runValue(env)(statement.value);
            env.context.set(statement.variable.value,
                value.result.value
            );
            if (statement.value.arguments) {
                //env.scope = value.context
                env.scope.set(statement.variable.value, value.context)
            }
        } else if (statement.type === Ast.ASSIGN) {
            const value = runValue(env)(statement.value);
            let envObj = findInEnv(env)(statement.variable)(null);
            let subContext;
            if (envObj.type === 'context') {
                subContext = envObj.env.context;
            } else if (envObj.type === 'runScope') {
                subContext = envObj.env.runScope;
            }
            if (statement.variable.children.length === 0) {
                subContext.set(statement.variable.value, value.result.value)
            } else {
                let obj = subContext.get(statement.variable.value);

                let lastObj = obj;
                for (let index = 0; index < statement.variable.children.length - 1; index++) {
                    const child = statement.variable.children[index];
                    if (child.childType === 'INDEX') {
                        const indexObj = lastObj.values[toNative(child.value)]
                        if (indexObj) {
                            //TODO
                            lastObj = indexObj.value
                        } else {
                            //TODO obj[x] cannot be null
                            lastObj = null
                        }
                    } else if (child.childType === 'FIELD') {
                        const field = lastObj.fields.find(e => e.variable.value === child.value);
                        if (field) {
                            lastObj = field.value.value
                        } else {
                            //TODO obj.x cannot be null
                            lastObj = null
                        }
                    }
                }

                const lastChild = statement.variable.children[statement.variable.children.length - 1];
                if (lastChild.childType === 'FIELD') {
                    const field = lastObj.fields.find(e => e.variable.value === lastChild.value)
                    if (field) {
                        field.value.value = value.result.value
                    } else {
                        lastObj.fields.push(
                            {
                                variable: lastChild,
                                value: {
                                    type: Ast.VALUE,
                                    value: value.result.value
                                }
                            }
                        )
                    }
                } else if (lastChild.childType === 'INDEX') {
                    const index = toNative(lastChild.value)
                    if (index < lastObj.values.length) {
                        lastObj.values[toNative(lastChild.value)] = value.result
                    } else {
                        //TODO obj[x] not available
                    }
                }
            }
        } else if (statement.type === Ast.RETURN) {
            const value = runValue(env)(statement.value);
            return value;
        } else if (statement.type === Ast.FUNCTION_CALL) {
            runValue(env)(statement);
        } else if (statement.type === Ast.VALUE || statement.type === Ast.IDENTITY) {
            if(statement.value === 'debug') {
                debugger;
            }
            runValue(env)(statement);
        } else if (statement.type === Ast.IF) {
            runValue(env)(statement.matchBodies[0].condition)
            let hasMatch = false;
            for (const matchBody of statement.matchBodies) {
                if (toNative(runValue(env)(matchBody.condition).result.value)) {
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
            while (toNative(runValue(env)(statement.condition).result.value)) {
                const value = runStatements(env)(statement.body);
                if (value) {
                    //TODO return in if
                    return value;
                }
            }
        }
    }

    return {result: Void, env: env};
}

export default runStatements;
