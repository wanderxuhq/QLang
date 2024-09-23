import { parseConst } from './parse-const.js';
import isTypeOf from './is-type-of.js';
import { notMatch, isMatch } from './match.js';
import { parseSeq, matchParse } from './helper.js';
import {
    parseSpace,
    parseOptionalSpace,
} from './parse-space.js';
import { parseIdentity } from './parse-identity.js';
import {
    parseStatementsAst
} from './parse-statement-ast.js';
import findInEnv from './find-in-env.js';

import {
    Ast,
    NumberExprAst,
    StringExprAst,
    BooleanExprAst,
    IdentityExprAst,
    BinOpExprAst,
    FunctionExprAst,
    FunctionCallAst,
    ObjectExprAst,
    ArrayExprAst,
} from '../ast/index.js';

const parseValueAst = env => str => (index) => {
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
    const isBinOpToken = (index) => {
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
    const parseBinOpUnitAst = str => (lhs, index) => {
        const lOptionalSpace = parseOptionalSpace(str)(index);
        const op = parseBinOpToken(str)(lOptionalSpace.end);
        if (isMatch(op)) {
            const rOptionalSpace = parseOptionalSpace(str)(op.end);
            let rhs = parseSingleValueAst(env)(str)(rOptionalSpace.end);
            let nOptionalSpace = parseOptionalSpace(str)(rhs.end);
            let nextBinOpToken = parseBinOpToken(str)(nOptionalSpace.end);

            let tmp = rhs;
            while (isMatch(nextBinOpToken) && getBinOpPrecedence(op.type) < getBinOpPrecedence(nextBinOpToken.type)) {
                tmp = rhs;
                rhs = parseBinOpUnitAst(str)(rhs, rhs.end)
                nOptionalSpace = parseOptionalSpace(str)(rhs.end);
                nextBinOpToken = parseBinOpToken(str)(nOptionalSpace.end);
            }

            let ast = new BinOpExprAst(op, lhs, rhs);
            ast.start = index;
            ast.end = rhs.end;
            return ast;
        } else {
            return notMatch(index);
        }
    }

    let value = parseSingleValueAst(env)(str)(index)
    if (isMatch(value)) {
        let optionalSpace = parseOptionalSpace(str)(value.end);
        while (isBinOpToken(optionalSpace.end)) {
            value = parseBinOpUnitAst(str)(value, optionalSpace.end)
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
        let ast = new IdentityExprAst(identity.value);
        ast.start = index;
        ast.end = identity.end;

        return ast;
    } else {
        return notMatch(index);
    }
}

const parseFunctionAst = env => str => (index) => {
    let p = parseOptionalSpace(str)(index);

    const parseParameters = (str) => (index) => {
        const parseParameter = (str) => (index) => {
            let variable = parseIdentity(str)(index);
            if (isMatch(variable)) {
                let p0 = parseSeq(str)(variable.end, [parseOptionalSpace, parseConst(':'), parseOptionalSpace]);
                let parameter = {
                    start: index,
                    end: p0.end,
                    variable: variable.value
                }
                let type = parseIdentityAst(str)(p0.end);

                if (isMatch(type)) {
                    let pType = findInEnv(type, env)

                    if (isMatch(pType)) {
                        parameter.type = pType;
                        parameter.end = type.end;
                    } else {
                        let pType = parseValueAst(env)(str)(p0.end)
                        if (isMatch(pType)) {
                            parameter.type = pType

                            parameter.end = pType.end
                        }
                    }
                } else {
                    let pType = parseValueAst(env)(str)(p0.end)
                    if (isMatch(pType)) {
                        parameter.type = pType

                        parameter.end = pType.end
                    }
                }

                return parameter;
            } else {
                return notMatch(index);
            }
        }
        let parameters = []
        let p = parseOptionalSpace(str)(index);
        p = parseParameter(str)(p.end);
        if (isMatch(p)) {
            while (isMatch(p)) {
                parameters.push(p)
                p = parseSeq(str)(p.end, [parseOptionalSpace, parseConst(','), parseOptionalSpace]);
                p = parseParameter(str)(p.end);
            }

            return {
                parameters,
                start: index,
                end: p.end
            }
        } else {
            return notMatch(index);
        }

    }

    let p0 = parseSeq(str)(p.end,
        [
            parseConst('('),
            parseOptionalSpace,
            parseParameters,
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
        let ast = new FunctionExprAst(p0.result[2].parameters, p0.result[10]);
        ast.start = index;
        ast.end = p0.end;
        return ast;
    } else {
        p0 = parseSeq(str)(p.end, [
            parseParameters,
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
            let ast = new FunctionExprAst(p0.result[0].parameters, p0.result[6]);
            ast.start = index;
            ast.end = p0.end;

            return ast;
        } else {
            return notMatch(index);
        }
    }
}

const parseObjectAst = env => str => (index) => {
    const parseFields = env => (str) => (index) => {
        const parseField = env => (str) => index => {
            let p0 = parseIdentity(str)(index)
            // variable
            if (isMatch(p0)) {
                // variable: Type
                let p1 = parseSeq(str)(p0.end, [
                    parseOptionalSpace,
                    parseConst(':'),
                    parseOptionalSpace,
                    parseValueAst(env)
                ])
                if (isMatch(p1)) {
                    // variable: Type = value
                    const p2 = parseSeq(str)(p1.end, [
                        parseOptionalSpace,
                        parseEqual,
                        parseOptionalSpace,
                        parseValueAst(env)
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
                        parseEqual,
                        parseOptionalSpace,
                        parseValueAst(env)])
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
        let field = parseField(env)(str)(index);
        if (isMatch(field)) {
            let fields = []
            while (isMatch(field)) {
                fields.push(field);
                let p = parseSeq(str)(field.end, [
                    parseOptionalSpace,
                    parseConst(','),
                    parseOptionalSpace
                ])
                field = parseField(env)(str)(p.end);
            }

            return {
                start: index,
                end: field.end,
                fields: fields
            };
        } else {
            return notMatch(index);
        }
    }

    const fields = parseSeq(str)(index, [
        parseConst('{'),
        parseOptionalSpace,
        parseFields(env),
        parseOptionalSpace,
        parseConst('}')
    ])
    if (isMatch(fields)) {
        let ast = new ObjectExprAst(fields.result[2]);
        ast.start = index;
        ast.end = fields.end;
        return ast
    } else {
        return notMatch(index)
    }
}

const parseArrayAst = env => str => (index) => {
    const parseArrayItems = env => (str) => (index) => {
        let values = []
        let value = parseValueAst(env)(str)(index);
        while (isMatch(value)) {
            values.push(value);
            let p = parseSeq(str)(value.end, [
                parseOptionalSpace,
                parseConst(','),
                parseOptionalSpace
            ])
            value = parseValueAst(env)(str)(p.end)
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
        parseArrayItems(env),
        parseOptionalSpace,
        parseConst(']')
    ]);

    if (isMatch(values)) {
        let ast = new ArrayExprAst(values.result[2]);
        ast.start = index;
        ast.end = values.end;
        return ast
    } else {
        return notMatch(index);
    }
}

const parseSingleValueAst = env => str => (index) => {
    let f = matchParse(str)(index, [
        parseNumberAst,
        parseStringAst,
        parseBooleanAst,
        parseFunctionAst(env),
        parseIdentityAst,
        parseObjectAst(env),
        parseArrayAst(env),
        parseParenthesis(env)
    ]);

    if (isMatch(f)) {
        let optionalSpace = parseOptionalSpace(str)(f.end);

        let objectIndex = parseSeq(str)(optionalSpace.end,
            [
                parseConst('['),
                parseOptionalSpace,
                parseValueAst(env),
                parseOptionalSpace,
                parseConst(']')
            ]);
        if (isMatch(objectIndex)) {
            f.index = objectIndex.result[2];
            f.end = objectIndex.end;
        }

        const dot = parseConst('.')(str)(f.end);

        if (isMatch(dot)) {
            const child = parseValueAst(env)(str)(dot.end);
            f.child = child;
            f.end = child.end;
        }

        const parseFunctionCall = (env) => (str) => (ast, index) => {
            const parseParameters = (str) => (index) => {
                let parameters = []
                let p = parseValueAst(env)(str)(index, true);
                if (isMatch(p)) {
                    env = {
                        context: new Map(),
                        parent: env
                    }
                    const fun = findInEnv(ast, env)

                    if (isTypeOf(ast, Ast.FUNCTION, env)) {
                        for (let i = 0; i < fun.parameters.length; i++) {
                            if (!isMatch(p)) {
                                console.log("Parameter mismatch")
                                return notMatch(index)
                            }
                            const parameter = fun.parameters[i];
                            env.context.set(parameter.variable, p)

                            parameters.push(p)
                            p = parseSeq(str)(p.end, [
                                parseOptionalSpace,
                                parseConst(','),
                                parseOptionalSpace
                            ]);
                            p = parseValueAst(env)(str)(p.end, true);
                        }

                        if (isMatch(p)) {
                            console.log("Parameter mismatch:", p)
                        }
                    } else {
                        while (isMatch(p)) {
                            parameters.push(p)
                            p = parseSeq(str)(p.end, [
                                parseOptionalSpace,
                                parseConst(','),
                                parseOptionalSpace
                            ]);
                            p = parseValueAst(env)(str)(p.end, true);
                        }
                    }


                    return {
                        type: 'PARAMETERS',
                        parameters,
                        start: index,
                        end: p.end
                    }
                } else {
                    return notMatch(index);
                }
            }

            let parameterPrefix = parseSeq(str)(index, [
                parseOptionalSpace,
                parseConst('('),
                parseOptionalSpace
            ]);
            let parseParameterSuffix = null;
            if (isMatch(parameterPrefix)) {
                parseParameterSuffix = str => _index => parseConst(')')(str)(_index)
            } else {
                let value = findInEnv(f, env);
                if (value?.type === Ast.FUNCTION) {
                    parameterPrefix = parseSpace(str)(ast.end)
                    parseParameterSuffix = str => _index => parseConst('')(str)(_index)
                }
            }

            if (parseParameterSuffix !== null) {
                const parameters = parseParameters(str)(parameterPrefix.end);
                if (isMatch(parameters)) {
                    const parameterSuffix = parseParameterSuffix(str)(parameters.end);
                    if (isMatch(parameterSuffix)) {
                        let functionCallAst = new FunctionCallAst(ast, parameters);
                        functionCallAst.start = index;
                        //TODO
                        functionCallAst.end = parameterSuffix.end;
                        return functionCallAst
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

        if (isTypeOf(f, Ast.FUNCTION, env)) {
            const start = f.start;
            let functionCall = parseFunctionCall(env)(str)(f, f.end)
            //TODO Type Inference

            if (isTypeOf(functionCall, Ast.FUNCTION, env)) {
                let nextFunctionCall = parseFunctionCall(env)(str)(functionCall, functionCall.end)
                while (isMatch(nextFunctionCall)) {
                    nextFunctionCall = parseFunctionCall(env)(str)(functionCall, functionCall.end)
                    if (isMatch(nextFunctionCall)) {
                        functionCall = nextFunctionCall
                    } else {
                        break;
                    }
                }
            }


            f = functionCall;
            f.start = start;
        }

    }

    return f;
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

        let ast = new NumberExprAst(number);
        ast.start = index;
        ast.end = index + length;

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

        let ast = new StringExprAst(string);
        ast.start = index;
        ast.end = index + length;

        return ast;
    } else {
        return notMatch(index);
    }
}

const parseBooleanAst = str => (index) => {
    const trueResult = parseConst('true')(str)(index);
    if (isMatch(trueResult)) {
        let ast = new BooleanExprAst('true');
        ast.start = index;
        ast.end = trueResult.end;
        return ast
    } else {
        const falseResult = parseConst('false')(str)(index);
        if (isMatch(falseResult)) {
            let ast = new BooleanExprAst('false');
            ast.start = index;
            ast.end = falseResult.end;

            return ast;
        } else {
            return notMatch(index);
        }
    }
}

const parseParenthesis = env => str => (index) => {
    const result = parseSeq(str)(index,
        [
            parseConst('('),
            parseOptionalSpace,
            parseValueAst(env),
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
    parseValueAst
}