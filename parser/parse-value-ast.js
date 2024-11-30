import { parseConst } from './parse-const.js';
import { notMatch, isMatch } from './match.js';
import { parseSeq, matchParse } from './helper.js';
import {
    parseSpace,
    parseOptionalSpace,
    parseSpaceOnly,
    parseNewLine,
    parseOptionalSpaceOnly,
} from './parse-space.js';
import { parseIdentity } from './parse-identity.js';
import {
    parseStatementsAst
} from './parse-statement-ast.js';

import {
    Ast,
    NumberValueAst,
    StringValueAst,
    BooleanValueAst,
    IdentityValueAst,
    BinOpValueAst,
    FunctionValueAst,
    FunctionCallAst,
    ObjectValueAst,
    ArrayValueAst,
} from '../ast/index.js';
import {
    PrimeType
} from '../type/constant.js'
import { parseComment } from './parse-comment.js';
import { parseImport } from './parse-module.js';

const binOpPrecedence = (() => {
    const map = new Map();

    map.set('||', 10);
    map.set('&&', 20);
    map.set('|', 30);
    map.set('^', 40);
    map.set('&', 50);
    map.set('==', 60);
    map.set('<=', 60);
    map.set('<', 60);
    map.set('>=', 60);
    map.set('>', 60);
    map.set('!=', 60);
    map.set('+', 70);
    map.set('-', 70);
    map.set('*', 80);
    map.set('/', 80);
    map.set('%', 80);

    return map;
})();
const isBinOpToken = str => (index) => {
    return isMatch(parseBinOpToken(str)(index));
}
const getBinOpPrecedence = (op) => {
    return binOpPrecedence.get(op);
}
const parseBinOpToken = (str) => (index) => {
    for (const [key, value] of binOpPrecedence) {
        const binOpToken = parseConst(key)(str)(index)
        if (isMatch(binOpToken) && !isMatch(parseConst('//')(str)(index)) && !isMatch(parseConst('/*')(str)(index)) && !isMatch(parseConst('->')(str)(index)) && !isMatch(parseConst('<-')(str)(index))) {
            return binOpToken;
        }
    }

    return notMatch(index);
}
const parseBinOpUnitAst = option => leadspace => env => str => (lhs, index) => {
    const lOptionalSpace = parseOptionalSpace(str)(index);
    const op = parseBinOpToken(str)(lOptionalSpace.end);
    if (isMatch(op)) {
        const rOptionalSpace = parseOptionalSpace(str)(op.end);
        let rhs = parseSingleValueAst(option)(leadspace)(env)(str)(rOptionalSpace.end);
        let nOptionalSpace = parseOptionalSpace(str)(rhs.end);
        let nextBinOpToken = parseBinOpToken(str)(nOptionalSpace.end);

        let tmp = rhs;
        while (isMatch(nextBinOpToken) && getBinOpPrecedence(op.type) < getBinOpPrecedence(nextBinOpToken.type)) {
            tmp = rhs;
            rhs = parseBinOpUnitAst(option)(leadspace)(env)(str)(rhs, rhs.end)
            nOptionalSpace = parseOptionalSpace(str)(rhs.end);
            nextBinOpToken = parseBinOpToken(str)(nOptionalSpace.end);
        }

        const ast = {
            type: Ast.BIN_OP,
            op: op.type,
            lhs: lhs,
            rhs: rhs,
            start: index,
            end: rhs.end
        }
        return ast;
    } else {
        return notMatch(index);
    }
}


const parseValueAst = leadSpace => env => str => (index) => {
    return parseValue({
        functionCall: true
    })(leadSpace)(env)(str)(index);
}

const parseValue = option => leadSpace => env => str => (index) => {
    let value = parseSingleValueAst(option)(leadSpace)(env)(str)(index)
    if (isMatch(value)) {
        let optionalSpace = parseOptionalSpace(str)(value.end);
        while (isBinOpToken(str)(optionalSpace.end)) {
            value = parseBinOpUnitAst(option)(leadSpace)(env)(str)(value, optionalSpace.end)
            optionalSpace = parseOptionalSpace(str)(value.end);
        }
    } else {
        return notMatch(index)
    }

    return value;
}

const parseIdentityAst = str => (index) => {
    let identity = parseIdentity(str)(index);

    if (isMatch(identity)) {
        const ast = {
            type: Ast.IDENTITY,
            value: identity.value,
            start: index,
            end: identity.end
        }

        return ast;
    } else {
        return notMatch(index);
    }
}

const parseFunctionAst = leadspace => env => str => (index) => {
    let p = parseOptionalSpace(str)(index);

    const parseParameters = (leadspace) => (str) => (index) => {
        const parseParameter = (leadspace) => (str) => (index) => {
            let variable = parseIdentity(str)(index);
            if (isMatch(variable)) {
                let parameter = {
                    start: index,
                    end: variable.end,
                    variable: variable.value
                }
                let p0 = parseSeq(str)(variable.end, [parseOptionalSpace, parseConst(':'), parseOptionalSpace]);

                if (isMatch(p0)) {
                    let type = parseValueAst(leadspace)(str)(p0.end);
                    parameter.end = p0.end
                    /* = {
                        start: index,
                        end: p0.end,
                        variable: variable.value
                    }
                    */
                    //TODO
                    if (isMatch(type)) {
                        parameter.type = type

                        parameter.end = type.end
                    }
                }
                return parameter;
            } else {
                return notMatch(index);
            }
        }
        let parameters = []
        let p = parseOptionalSpace(str)(index);
        p = parseParameter(leadspace)(str)(p.end);
        if (isMatch(p)) {
            while (isMatch(p)) {
                parameters.push(p)
                p = parseSeq(str)(p.end, [parseOptionalSpace, parseConst(','), parseOptionalSpace]);
                p = parseParameter(leadspace)(str)(p.end);
            }

            return {
                parameters,
                start: index,
                end: p.end
            }
        } else {
            const optionalSpace = parseOptionalSpace(str)(index);
            return {
                parameters,
                start: index,
                end: optionalSpace.end
            }
        }

    }

    let p0 = parseSeq(str)(p.end,
        [
            parseConst('('),
            parseOptionalSpace,
            parseParameters(leadspace),
            parseOptionalSpace,
            parseConst(')'),
            parseOptionalSpace,
            parseConst('->'),
            parseOptionalSpace,
            parseConst('{'),
            parseOptionalSpace,
            parseStatementsAst(env),
            parseOptionalSpace,
            parseConst('}')
        ]);
    if (isMatch(p0)) {
        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.Function,
                parameters: p0.result[2].parameters,
                body: p0.result[10]

            },
            start: index,
            end: p0.end
        }

        return ast;
    } else {
        p0 = parseSeq(str)(p.end, [
            parseParameters(leadspace),
            parseOptionalSpace,
            parseConst('->'),
            parseOptionalSpace,
            parseConst('{'),
            parseOptionalSpace,
            parseStatementsAst(env),
            parseOptionalSpace,
            parseConst('}')
        ]);
        if (isMatch(p0)) {
            const ast = {
                type: Ast.VALUE,
                value: {
                    type: PrimeType.Function,
                    parameters: p0.result[0].parameters,
                    body: p0.result[6]
                },
                start: index,
                end: p0.end
            }
            return ast;
        } else {
            return notMatch(index);
        }
    }
}

const parseObjectAst = leadspace => env => str => (index) => {
    const parseFields = leadspace => env => (str) => (index) => {
        const parseField = leadspace => env => (str) => index => {
            let p0 = parseIdentity(str)(index)
            // variable
            if (isMatch(p0)) {
                // variable: Type
                let p1 = parseSeq(str)(p0.end, [
                    parseOptionalSpace,
                    parseConst(':'),
                    parseOptionalSpace,
                    parseValueAst(leadspace)(env)
                ])
                if (isMatch(p1)) {
                    // variable: Type = value
                    const p2 = parseSeq(str)(p1.end, [
                        parseOptionalSpace,
                        parseConst('='),
                        parseOptionalSpace,
                        parseValueAst(leadspace)(env)
                    ]);
                    if (isMatch(p2)) {
                        return {
                            start: index,
                            end: p2.end,
                            type: p1.result[3],
                            variable: p0,
                            value: p2.result[3]
                        }
                    } else {
                        return {
                            start: index,
                            end: p1.end,
                            type: p1.result[3],
                            variable: p0,
                        }
                    }
                } else {
                    p1 = parseSeq(str)(p0.end, [
                        parseOptionalSpace,
                        parseConst('='),
                        parseOptionalSpace,
                        parseValueAst(leadspace)(env)])
                    if (isMatch(p1)) {
                        return {
                            start: index,
                            end: p1.end,
                            variable: p0,
                            value: p1.result[3]
                        }
                    } else {
                        return {
                            start: index,
                            end: p0.end,
                            variable: p0,
                        }
                    }
                }
            } else {
                return notMatch(index)
            }

        }
        let field = parseField(leadspace)(env)(str)(index);
        if (isMatch(field)) {
            let fields = []
            while (isMatch(field)) {
                fields.push(field);
                let p = parseSeq(str)(field.end, [
                    parseOptionalSpace,
                    parseConst(','),
                    parseOptionalSpace
                ])
                field = parseField(leadspace)(env)(str)(p.end);
            }

            return {
                start: index,
                end: field.end,
                fields: fields
            };
        } else {
            return {
                start: index,
                end: index,
                fields: []
            };
        }
    }

    const fields = parseSeq(str)(index, [
        parseConst('{'),
        parseOptionalSpace,
        parseFields(leadspace)(env),
        parseOptionalSpace,
        parseConst('}')
    ])
    if (isMatch(fields)) {
        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.Object,
                fields: fields.result[2].fields
            },
            start: index,
            end: fields.end
        }
        return ast
    } else {
        return notMatch(index)
    }
}

const parseArrayAst = leadspace => env => str => (index) => {
    const parseArrayItems = leadspace => env => (str) => (index) => {
        let values = []
        let value = parseValueAst(leadspace)(env)(str)(index);
        while (isMatch(value)) {
            values.push(value);
            let p = parseSeq(str)(value.end, [
                parseOptionalSpace,
                parseConst(','),
                parseOptionalSpace
            ])
            value = parseValueAst(leadspace)(env)(str)(p.end)
        }

        return {
            start: index,
            end: value.end,
            values: values
        }
    }
    const values = parseSeq(str)(index, [
        parseConst('['),
        parseOptionalSpace,
        parseArrayItems(leadspace)(env),
        parseOptionalSpace,
        parseConst(']')
    ]);

    if (isMatch(values)) {
        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.Array,
                values: values.result[2].values
            },
            start: index,
            end: values.end
        }
        return ast
    } else {
        return notMatch(index);
    }
}

const addIndexAndChild = ast => leadspace => env => (str) => (index) => {
    let match = true;
    ast.children = [];
    while (match) {
        let optionalSpace = parseOptionalSpace(str)(ast.end);

        let objectIndex = parseSeq(str)(optionalSpace.end,
            [
                parseConst('['),
                parseOptionalSpace,
                parseValueAst(leadspace)(env),
                parseOptionalSpace,
                parseConst(']')
            ]);
        if (isMatch(objectIndex)) {
            ast.children.push({
                type: 'INDEX',
                value: objectIndex.result[2]
            })
            ast.end = objectIndex.end;
        } else {
            const dot = parseConst('.')(str)(optionalSpace.end);

            if (isMatch(dot)) {
                const child = parseIdentityAst(str)(dot.end);//parseValueAst(env)(str)(dot.end);
                ast.children.push({
                    type: 'FIELD',
                    value: child
                })
                ast.end = child.end;
            } else {
                match = false;
            }
        }
    }
}

const parseSingleValueAst = option => leadspace => env => str => (index) => {
    let f = matchParse(str)(index, [
        parseNumberAst,
        parseStringAst,
        parseBooleanAst,
        parseFunctionAst(leadspace)(env),
        parseIdentityAst,
        parseObjectAst(leadspace)(env),
        parseArrayAst(leadspace)(env),
        parseParenthesis(leadspace)(env),
        parseImport
    ]);

    if (isMatch(f)) {
        const root = f;
        let end = f.end;

        let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
        if (isMatch(functionCall)) {
            let funParameters = [];
            funParameters.push(functionCall);
            end = functionCall.end;
            let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
            while (isMatch(nextFunctionCall)) {
                nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                if (isMatch(nextFunctionCall)) {
                    end = nextFunctionCall.end;
                    funParameters.push(nextFunctionCall);
                } else {
                    break;
                }
            }

            f.arguments = funParameters;
            f.end = end;
        } else {
            if (option.functionCall) {

            }
        }

        let match = true;
        f.children = []
        while (match) {
            let optionalSpace = parseOptionalSpace(str)(end);

            let objectIndex = parseSeq(str)(optionalSpace.end,
                [
                    parseConst('['),
                    parseOptionalSpace,
                    parseValueAst(leadspace)(env),
                    parseOptionalSpace,
                    parseConst(']')
                ]);
            if (isMatch(objectIndex)) {
                let child = objectIndex.result[2];
                child.childType = 'INDEX';
                f.children.push(child)

                end = objectIndex.end;
            } else {
                const objectField = parseSeq(str)(optionalSpace.end,
                    [
                        parseConst('.'),
                        parseOptionalSpace,
                        parseIdentityAst
                    ]);

                if (isMatch(objectField)) {
                    const child = objectField.result[2];
                    child.childType = 'FIELD';
                    end = objectField.end;

                    let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(objectField.end)
                    if (isMatch(functionCall)) {
                        let funParameters = [];
                        funParameters.push(functionCall);
                        end = functionCall.end;
                        let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                        while (isMatch(nextFunctionCall)) {
                            nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                            if (isMatch(nextFunctionCall)) {
                                end = nextFunctionCall.end;
                                funParameters.push(nextFunctionCall);
                            } else {
                                break;
                            }
                        }

                        child.arguments = funParameters;
                    }

                    f.children.push(child)

                } else {
                    match = false;
                }
            }
        }
        root.end = end;

        return root;

        //addIndexAndChild(f)(leadspace)(env)(str)(f.end)

        /*
        const start = f.start;
        let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(f.end)
        //TODO Type Inference

        if (isMatch(functionCall)) {
            let funParameters = [];
            funParameters.push(functionCall);
            let end = functionCall.end;
            let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
            while (isMatch(nextFunctionCall)) {
                nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                if (isMatch(nextFunctionCall)) {
                    end = nextFunctionCall.end;
                    funParameters.push(nextFunctionCall);
                } else {
                    break;
                }
            }

            f = new FunctionCallAst(f, funParameters);
            f.start = start;
            f.end = end;
            addIndexAndChild(f)(leadspace)(env)(str)(end);
        } else {
            if (option.functionCall) {
                
            }
        }

        */
    } else {
        return notMatch(index);
    }
}

const parseCommonFunctionCall = leadspace => (env) => (str) => (index) => {
    const parseParameters = (str) => (index) => {
        let parameters = []
        let p = parseValueAst(leadspace)(env)(str)(index, true);
        if (isMatch(p)) {
            env = env.push();
            parameters.push(p)

            p = parseSeq(str)(p.end, [
                parseOptionalSpace,
                parseConst(','),
                parseOptionalSpace,
                parseValueAst(leadspace)(env)
            ]);

            if (isMatch(p)) {
                while (isMatch(p)) {
                    parameters.push(p.result[3])
                    p = parseSeq(str)(p.end, [
                        parseOptionalSpace,
                        parseConst(','),
                        parseOptionalSpace,
                        parseValueAst(leadspace)(env)
                    ]);
                }
            }

            return {
                type: 'PARAMETERS',
                parameters,
                start: index,
                end: p.end
            }
        } else {
            return {
                type: 'PARAMETERS',
                parameters,
                start: index,
                end: index
            }
        }
    }

    let parameterPrefix = parseSeq(str)(index, [
        parseOptionalSpace,
        parseConst('('),
        parseOptionalSpace
    ]);
    let parseParameterSuffix = null;
    if (isMatch(parameterPrefix)) {
        parseParameterSuffix = str => _index => parseSeq(str)(_index, [parseOptionalSpace, parseConst(')')]);
        const parameters = parseParameters(str)(parameterPrefix.end);
        if (isMatch(parameters)) {
            const parameterSuffix = parseParameterSuffix(str)(parameters.end);
            if (isMatch(parameterSuffix)) {
                parameters.start = index;
                parameters.end = parameterSuffix.end;
                return parameters
            } else {
                return notMatch(index);
            }
        } else {
            return notMatch(index);
        }
    } else {
        return notMatch(index);
    }
}

const parseLeadSpace = leadspace => (str) => (index) => {
    let space = parseSpaceOnly(str)(index);
    let newLine = parseNewLine(str)(space.end);
    if (isMatch(newLine)) {
        while (isMatch(newLine)) {
            newLine = parseSeq(str)(newLine.end, [parseOptionalSpaceOnly, parseNewLine]);
        }
        let optionalSpace = parseOptionalSpace(str)(newLine.end);
        if (optionalSpace.length > leadspace) {
            return optionalSpace;
        } else {
            return notMatch(index);
        }
    } else {
        if (isMatch(space) && space.length && space.length > 0) {
            return space
        } else {
            return notMatch(index);
        }
    }
}

const parseSpaceFunctinoCall = leadspace => (env) => (str) => (index) => {
    let parameter = parseSeq(str)(index, [parseLeadSpace(leadspace), parseValue({ functionCall: false })(leadspace)(env)])
    if (isMatch(parameter)) {
        let funParameters = [];
        funParameters.push({
            type: 'PARAMETERS',
            parameters: [parameter.result[1]],
            start: index,
            end: parameter.end
        });
        let end = parameter.end;
        while (isMatch(parameter)) {
            parameter = parseSeq(str)(parameter.end, [parseLeadSpace(leadspace), parseValue({ functionCall: false })(leadspace)(env)]);
            if (isMatch(parameter)) {
                end = parameter.end;
                funParameters.push({
                    type: 'PARAMETERS',
                    parameters: [parameter.result[1]],
                    start: index,
                    end: parameter.end
                });
                end = parameter.end;
            } else {
                break;
            }
        }

        f = new FunctionCallAst(f, funParameters);
        f.start = start;
        f.end = end;
        addIndexAndChild(f)(leadspace)(env)(str)(end);
        //}
    }
}

const parseNumberAst = str => (index) => {
    let _index = index;
    let char = str.substring(_index, _index + 1);
    let length = 0;
    if (char.match(/[0-9]/)) {
        let number = char;
        _index++;
        length++
        while (char.match(/[0-9.]/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/[0-9.]/)) {
                number += char
                _index++;
                length++
            }
        }

        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.Number,
                value: new Number(number).valueOf()
            },
            start: index,
            end: index + length
        }

        return ast;
    } else {
        return notMatch(index);
    }
}

const parseStringAst = str => (index) => {
    let _index = index;
    let char = str.substring(_index, _index + 1);
    let length = 0;
    let string = '';
    if (char.match(/["`']/)) {
        const strSymbol = char;
        _index++;
        length++
        char = str.substring(_index, _index + 1);

        while (char !== strSymbol) {
            if (char === '\\') {
                _index++;
                length++
                char = str.substring(_index, _index + 1);
                if (char === 'n') {
                    string += '\n'
                    _index++;
                    length++
                } else if (char === 't') {
                    string += '\t'
                    _index++;
                    length++
                } else if (char === '\\') {
                    string += '\\'
                    _index++;
                    length++
                }
            } else {
                string += char;
                _index++;
                length++
            }

            char = str.substring(_index, _index + 1);
        }
        length++;

        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.String,
                value: string
            },
            start: index,
            end: index + length
        }

        return ast;
    } else {
        return notMatch(index);
    }
}

const parseBooleanAst = str => (index) => {
    const trueResult = parseConst('true')(str)(index);
    if (isMatch(trueResult)) {
        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.Boolean,
                value: true
            },
            start: index,
            end: trueResult.end
        };
        return ast
    } else {
        const falseResult = parseConst('false')(str)(index);
        if (isMatch(falseResult)) {
            const ast = {
                type: Ast.VALUE,
                value: {
                    type: PrimeType.Boolean,
                    value: false
                },
                start: index,
                end: falseResult.end
            }

            return ast;
        } else {
            return notMatch(index);
        }
    }
}

const parseParenthesis = leadspace => env => str => (index) => {
    const result = parseSeq(str)(index,
        [
            parseConst('('),
            parseOptionalSpace,
            parseValueAst(leadspace)(env),
            parseOptionalSpace,
            parseConst(')')
        ]);
    if (isMatch(result)) {
        let ast = result.result[2];
        ast.start = result.start;
        ast.end = result.end;

        return ast;
    } else {
        return notMatch(index)
    }
}

export {
    parseValueAst,
    parseStringAst
}
