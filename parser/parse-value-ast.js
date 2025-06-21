import { parseConst } from './parse-const.js';
import { notMatch, isMatch } from './match.js';
import { parseSeq, matchParse } from './helper.js';
import {
    parseSpaceAndNewline,
    parseOptionalSpaceAndNewline,
    parseNewLine,
    parseOptionalSpace,
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
    const lOptionalSpace = parseOptionalSpaceAndNewline(str)(index);
    const op = parseBinOpToken(str)(lOptionalSpace.end);
    if (isMatch(op)) {
        const rOptionalSpace = parseOptionalSpaceAndNewline(str)(op.end);
        let rhs = parseSingleValueAst(option)(leadspace)(env)(str)(rOptionalSpace.end);
        let nOptionalSpace = parseOptionalSpaceAndNewline(str)(rhs.end);
        let nextBinOpToken = parseBinOpToken(str)(nOptionalSpace.end);

        let tmp = rhs;
        while (isMatch(nextBinOpToken) && getBinOpPrecedence(op.type) < getBinOpPrecedence(nextBinOpToken.type)) {
            tmp = rhs;
            rhs = parseBinOpUnitAst(option)(leadspace)(env)(str)(rhs, rhs.end)
            nOptionalSpace = parseOptionalSpaceAndNewline(str)(rhs.end);
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
        let optionalSpace = parseOptionalSpaceAndNewline(str)(value.end);
        while (isBinOpToken(str)(optionalSpace.end)) {
            value = parseBinOpUnitAst(option)(leadSpace)(env)(str)(value, optionalSpace.end)
            optionalSpace = parseOptionalSpaceAndNewline(str)(value.end);
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
    let p = parseOptionalSpaceAndNewline(str)(index);

    const parseParameters = (leadspace) => (str) => (index) => {
        const parseParameter = (leadspace) => (str) => (index) => {
            let variable = parseIdentity(str)(index);
            if (isMatch(variable)) {
                return {
                    start: index,
                    end: variable.end,
                    variable: variable.value
                }
            } else {
                return notMatch(index);
            }
        }
        let parameters = []
        let p = parseOptionalSpaceAndNewline(str)(index);
        p = parseParameter(leadspace)(str)(p.end);
        if (isMatch(p)) {
            while (isMatch(p)) {
                parameters.push(p)
                p = parseSeq(str)(p.end, [parseOptionalSpaceAndNewline, parseConst(','), parseOptionalSpaceAndNewline]);
                p = parseParameter(leadspace)(str)(p.end);
            }

            return {
                parameters,
                start: index,
                end: p.end
            }
        } else {
            const optionalSpace = parseOptionalSpaceAndNewline(str)(index);
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
            parseOptionalSpaceAndNewline,
            parseParameters(leadspace),
            parseOptionalSpaceAndNewline,
            parseConst(')'),
            parseOptionalSpaceAndNewline,
            parseConst('->'),
            parseOptionalSpaceAndNewline,
            parseConst('{'),
            parseOptionalSpaceAndNewline,
            parseStatementsAst(env),
            parseOptionalSpaceAndNewline,
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

        let end = ast.end
        let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(ast.end)
        if (isMatch(functionCall)) {
            let funParameters = [];
            funParameters.push(functionCall.parameters);
            end = functionCall.end;
            let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
            while (isMatch(nextFunctionCall)) {
                nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                if (isMatch(nextFunctionCall)) {
                    end = nextFunctionCall.end;
                    funParameters.push(nextFunctionCall.parameters);
                } else {
                    break;
                }
            }

            ast.arguments = funParameters;
            ast.end = end;
        }

        return ast;
    } else {
        p0 = parseSeq(str)(p.end, [
            parseParameters(leadspace),
            parseOptionalSpaceAndNewline,
            parseConst('->'),
            parseOptionalSpaceAndNewline,
            parseConst('{'),
            parseOptionalSpaceAndNewline,
            parseStatementsAst(env),
            parseOptionalSpaceAndNewline,
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
            // key
            if (isMatch(p0)) {
                let p1 = parseSeq(str)(p0.end, [
                    parseOptionalSpaceAndNewline,
                    parseConst('='),
                    parseOptionalSpaceAndNewline,
                    parseValueAst(leadspace)(env)])
                if (isMatch(p1)) {
                    return {
                        start: index,
                        end: p1.end,
                        key: p0,
                        value: p1.result[3]
                    }
                } else {
                    return {
                        start: index,
                        end: p0.end,
                        key: p0,
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
                    parseOptionalSpaceAndNewline,
                    parseConst(','),
                    parseOptionalSpaceAndNewline
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
        parseOptionalSpaceAndNewline,
        parseFields(leadspace)(env),
        parseOptionalSpaceAndNewline,
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

        const objectField = parseSeq(str)(fields.end,
            [
                parseOptionalSpaceAndNewline,
                parseConst('.'),
                parseOptionalSpaceAndNewline,
                parseIdentityAst
            ]);

        if (isMatch(objectField)) {
            ast.children = [];
            const child = objectField.result[3];
            child.childType = 'FIELD';
            //end = objectField.end;

            ast.children.push(child)

            ast.end = objectField.end;
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
                parseOptionalSpaceAndNewline,
                parseConst(','),
                parseOptionalSpaceAndNewline
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
        parseOptionalSpaceAndNewline,
        parseArrayItems(leadspace)(env),
        parseOptionalSpaceAndNewline,
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

        let objectIndex = parseSeq(str)(values.end,
            [
                parseOptionalSpaceAndNewline,
                parseConst('['),
                parseOptionalSpaceAndNewline,
                parseValueAst(leadspace)(env),
                parseOptionalSpaceAndNewline,
                parseConst(']')
            ]);
        if (isMatch(objectIndex)) {
            ast.children = [];
            let child = { value: objectIndex.result[3] };
            child.childType = 'INDEX';
            //end = objectIndex.end;

            ast.end = objectIndex.end
            ast.children.push(child);
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
        let optionalSpace = parseOptionalSpaceAndNewline(str)(ast.end);

        let objectIndex = parseSeq(str)(optionalSpace.end,
            [
                parseConst('['),
                parseOptionalSpaceAndNewline,
                parseValueAst(leadspace)(env),
                parseOptionalSpaceAndNewline,
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
    const literalAst = parseLiteralValueAst(option)(leadspace)(env)(str)(index);
    if (isMatch(literalAst)) {
        return literalAst;
    }

    const complexValueAst = parseComplexValueAst(option)(leadspace)(env)(str)(index);
    if (isMatch(complexValueAst)) {
        return complexValueAst;
    }

    return notMatch(index);
}

const parseLiteralValueAst = option => leadspace => env => str => (index) => {
    return matchParse(str)(index, [
        parseNumberAst,
        parseStringAst,
        parseBooleanAst,
        //parseFunctionSignAst(leadspace)(env)
    ]);
}

const parseComplexValueAst = option => leadspace => env => str => (index) => {
    let f = notMatch(index);

    f = matchParse(str)(index, [
        parseFunctionAst(leadspace)(env),
        parseObjectAst(leadspace)(env),
        parseArrayAst(leadspace)(env),
        parseIdentityAst,
        parseParenthesis(leadspace)(env),
        parseImport,
        //parseFunctionSignAst(leadspace)(env),
    ])

    if (isMatch(f)) {
        const root = f;
        let end = f.end;

        let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
        if (isMatch(functionCall)) {
            let funParameters = [];
            funParameters.push(functionCall.parameters);
            end = functionCall.end;
            let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
            while (isMatch(nextFunctionCall)) {
                nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                if (isMatch(nextFunctionCall)) {
                    end = nextFunctionCall.end;
                    funParameters.push(nextFunctionCall.parameters);
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
        f.children = f.children || []
        while (match) {
            let optionalSpace = parseOptionalSpaceAndNewline(str)(end);

            let objectIndex = parseSeq(str)(optionalSpace.end,
                [
                    parseConst('['),
                    parseOptionalSpaceAndNewline,
                    parseValueAst(leadspace)(env),
                    parseOptionalSpaceAndNewline,
                    parseConst(']')
                ]);
            if (isMatch(objectIndex)) {
                let child = { value: objectIndex.result[2] };
                child.childType = 'INDEX';
                end = objectIndex.end;

                let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                if (isMatch(functionCall)) {
                    let funParameters = [];
                    funParameters.push(functionCall.parameters);
                    end = functionCall.end;
                    let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                    while (isMatch(nextFunctionCall)) {
                        nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                        if (isMatch(nextFunctionCall)) {
                            end = nextFunctionCall.end;
                            funParameters.push(nextFunctionCall.parameters);
                        } else {
                            break;
                        }
                    }

                    child.arguments = funParameters;
                }

                f.children.push(child);
            } else {
                const objectField = parseSeq(str)(optionalSpace.end,
                    [
                        parseConst('.'),
                        parseOptionalSpaceAndNewline,
                        parseIdentityAst
                    ]);

                if (isMatch(objectField)) {
                    const child = objectField.result[2];
                    child.childType = 'FIELD';
                    end = objectField.end;

                    let functionCall = parseCommonFunctionCall(leadspace)(env)(str)(objectField.end)
                    if (isMatch(functionCall)) {
                        let funParameters = [];
                        funParameters.push(functionCall.parameters);
                        end = functionCall.end;
                        let nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                        while (isMatch(nextFunctionCall)) {
                            nextFunctionCall = parseCommonFunctionCall(leadspace)(env)(str)(end)
                            if (isMatch(nextFunctionCall)) {
                                end = nextFunctionCall.end;
                                funParameters.push(nextFunctionCall.parameters);
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
    } else {
        return notMatch(index);
    }
}

const parseCommonFunctionCall = leadspace => (env) => (str) => (index) => {
    const parseParameters = (str) => (index) => {
        let parameters = []
        let p = parseValueAst(leadspace)(env)(str)(index, true);
        if (isMatch(p)) {
            //env = env.push();
            parameters.push(p)

            p = parseSeq(str)(p.end, [
                parseOptionalSpaceAndNewline,
                parseConst(','),
                parseOptionalSpaceAndNewline,
                parseValueAst(leadspace)(env)
            ]);

            if (isMatch(p)) {
                while (isMatch(p)) {
                    parameters.push(p.result[3])
                    p = parseSeq(str)(p.end, [
                        parseOptionalSpaceAndNewline,
                        parseConst(','),
                        parseOptionalSpaceAndNewline,
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
        parseOptionalSpaceAndNewline,
        parseConst('('),
        parseOptionalSpaceAndNewline
    ]);
    let parseParameterSuffix = null;
    if (isMatch(parameterPrefix)) {
        parseParameterSuffix = str => _index => parseSeq(str)(_index, [parseOptionalSpaceAndNewline, parseConst(')')]);
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
    let space = parseSpaceAndNewline(str)(index);
    let newLine = parseNewLine(str)(space.end);
    if (isMatch(newLine)) {
        while (isMatch(newLine)) {
            newLine = parseSeq(str)(newLine.end, [parseOptionalSpace, parseNewLine]);
        }
        let optionalSpace = parseOptionalSpaceAndNewline(str)(newLine.end);
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

const parseSpaceFunctionCall = leadspace => (env) => (str) => (index) => {
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
    let template = [];
    let currentSubString = '';
    if (char.match(/["`']/)) {
        const strSymbol = char;
        _index++;

        char = str.substring(_index, _index + 1);

        while (char !== strSymbol) {
            if (char === '\\') {
                _index++;

                char = str.substring(_index, _index + 1);
                if (char === 'n') {
                    currentSubString += '\n'
                    _index++;
                } else if (char === 't') {
                    currentSubString += '\t'
                    _index++;
                } else if (char === '\\') {
                    currentSubString += '\\'
                    _index++;
                } else if (char === '$') {
                    currentSubString += '$'
                    _index++;
                } else if (char === '{') {
                    currentSubString += '{'
                    _index++;
                } else if (char === '}') {
                    currentSubString += '}'
                    _index++;
                }
            } else if (char === '$') {
                template.push({ type: "RAW_STRING", value: currentSubString });
                currentSubString = '';
                _index++;
                char = str.substring(_index, _index + 1);
                if (char === '{') {
                    _index++;

                    let v = parseValueAst(0)(null)(str)(_index);
                    _index = v.end;
                    char = str.substring(_index, _index + 1);
                    if (char === '}') {
                        template.push(v);
                        _index++;
                    }
                }
            } else {
                currentSubString += char;
                _index++;

            }

            char = str.substring(_index, _index + 1);
        }
        template.push({ type: "RAW_STRING", value: currentSubString });

        const ast = {
            type: Ast.VALUE,
            value: {
                type: PrimeType.String,
                template: template,
            },
            start: index,
            end: _index + 1
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
            parseOptionalSpaceAndNewline,
            parseValueAst(leadspace)(env),
            parseOptionalSpaceAndNewline,
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
    parseStringAst,
    parseLiteralValueAst,
    parseComplexValueAst
}
