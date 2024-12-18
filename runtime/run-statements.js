import { Ast } from '../ast/index.js';
import { Void } from '../value/constant.js';
import { toNative } from './native.js';
import { runValue, makeRunValueInput } from './run-value.js';

const runStatements = env => ast => {
    for (const statement of ast.statements) {
        if (statement.type === Ast.DECLARE) {
            const value = runValue(env)(statement.value);
            env.set(statement.variable.value,
                //TODO scope
                value.value
            );
        } else if (statement.type === Ast.ASSIGN) {
            const value = runValue(env)(statement.value);
            let envObj = env.find(statement.variable.value)
            if (!envObj.find) {
                console.log(`${statement.variable.value} not find in env`)
            }

            if (statement.variable.children.length === 0) {
                //TODO scope
                envObj.callback(statement.variable.value, value.value);
            } else {
                let obj = envObj.value;

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
                        field.value.value = value.value
                    } else {
                        lastObj.fields.push(
                            {
                                variable: lastChild,
                                value: {
                                    type: Ast.VALUE,
                                    value: value.value
                                }
                            }
                        )
                    }
                } else if (lastChild.childType === 'INDEX') {
                    const index = toNative(lastChild.value)
                    if (index < lastObj.values.length) {
                        lastObj.values[toNative(lastChild.value)] = value
                    } else {
                        //TODO obj[x] not available
                    }
                }
            }
        } else if (statement.type === Ast.RETURN) {
            const value = runValue(env)(statement.value);
            return {
                status: value.status,
                hasReturn: true,
                value: value.value,
                //TODO scope
                scope: value.scope
            };
        } else if (statement.type === Ast.VALUE || statement.type === Ast.IDENTITY || statement.type === Ast.BIN_OP) {
            /*
            if(statement.value === 'debug') {
                debugger;
            }
            */
            const result = runValue(env)(statement);
            if (result.status.code !== 0) {
                return {
                    status: result.status
                }
            }
        } else if (statement.type === Ast.IF) {
            let hasMatch = false;
            for (const matchBody of statement.matchBodies) {
                if (toNative(runValue(env)(matchBody.condition).value)) {
                    //TODO return in if
                    const value = runStatements(env)(matchBody.body);
                    //TODO has return and return void
                    if (value.hasReturn && value.status.code === 0) {
                        return {
                            status: value.status,
                            hasReturn: true,
                            value: value.value,
                            scope: value.scope
                        };
                    }
                    hasMatch = true;
                    break;
                }
            }

            if (!hasMatch && statement.elseBody) {
                const value = runStatements(env)(statement.elseBody);

                //TODO has return and return void
                if (value.hasReturn && value.status.code === 0) {
                    //TODO return in if
                    return {
                        status: value.status,
                        hasReturn: true,
                        value: value.value,
                        scope: value.scope
                    };
                }
            }
        } else if (statement.type === Ast.WHILE) {
            while (toNative(runValue(env)(statement.condition).value)) {
                const value = runStatements(env)(statement.body);
                if (value.hasReturn && value.status.code === 0) {
                    //TODO return in if
                    return {
                        status: value.status,
                        hasReturn: true,
                        value: value.value,
                        scope: value.scope
                    };
                }
            }
        }
    }

    return {
        status: {
            code: 0,
            message: '',
        },
        hasReturn: false,
        value: {type: Ast.VALUE, value: Void}
    };
}

export default runStatements;
