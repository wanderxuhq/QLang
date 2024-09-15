import fs from 'fs';
const source = fs.readFileSync('./demo/declare.ql', 'utf-8');
let str = source;

import {
    Ast,
    StmtsAst,
    DeclareStmtAst,
    AssignStmtAst,
    NumberExprAst,
    StringExprAst,
    BooleanExprAst,
    IdentityExprAst,
    IdentityPathExprAst,
    BinOpExprAst,
    IdentityIndexExprAst,
    IfStmtAst,
    FunctionExprAst
} from './ast.js';
import { match } from 'assert';

const NOT_MATCH = (index) => {
    return {
        type: 'NOT_MATCH',
        start: index,
        end: index,
        length: 0
    }
}

const isMatch = (snip) => {
    return snip.type !== 'NOT_MATCH';
}

const parse = (index, parser) => {
    let result = {
        start: index,
        end: index,
        result: []
    }
    for (const p of parser) {
        const parseResult = p(result.end);

        if (isMatch(parseResult)) {
            result.result.push(parseResult);
            result.end = parseResult.end;
        } else {
            return NOT_MATCH(index);
        }
    }

    return result;
}

const parseConst = token => index => {
    if (str.substring(index, index + token.length) === token) {
        return {
            type: token,
            start: index,
            end: index + token.length
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseLet = (index) => {
    return parseConst('let')(index);
}

const parseSpace = (index) => {
    let _index = index;
    let length = 0;
    let char = str.substring(_index, _index + 1);
    let comment = parseComment(_index);

    if (char.match(/\s/)) {
        let space = char;
        _index++;
        length++;
        while (char.match(/\s/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/\s/)) {
                space += char
                _index++;
                length++;
            } else {
                comment = parseComment(_index);
                if (isMatch(comment)) {
                    _index = comment.end;
                    //char = str.substring(_index, _index + 1);
                    console.log('comment1: ', str.substring(comment.start, comment.end));
                    char = str.substring(_index, _index + 1);
                }
            }
        }
        return {
            type: 'SPACE_ANE_NEWLINE',
            start: index,
            end: _index,
            value: space
        }
    } else if(isMatch(comment)) {
        const optionalSpace = parseOptionalSpace(comment.end);
        console.log('comment2: ', str.substring(index, optionalSpace.end));
        return {
            type: 'SPACE',
            start: index,
            end: optionalSpace.end,
            //TODO /*value*/
            value: str.substring(index, optionalSpace.end)
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseOptionalSpace = (index) => {
    const space = parseSpace(index);
    if (isMatch(space)) {
        return space;
    } else {
        return {
            type: 'SPACE_ANE_NEWLINE',
            start: index,
            end: index,
            value: ''
        };
    }
}

const parseSpaceOnly = (index) => {
    let _index = index;
    let length = 0;
    let char = str.substring(_index, _index + 1);
    let comment = parseComment(_index);

    if (char.match(/\s/ && char !== '\n' && char !== '\r')) {
        let space = char;
        _index++;
        length++;
        while (char.match(/\s/ && char !== '\n' && char !== '\r')) {
            char = str.substring(_index, _index + 1);
            if (char.match(/\s/ && char !== '\n' && char !== '\r')) {
                space += char
                _index++;
                length++;
            } else {
                comment = parseComment(_index);
                if (isMatch(comment)) {
                    _index = comment.end;
                    console.log('comment3: ', str.substring(index, _index));
                    char = str.substring(_index, _index + 1);
                    //char = str.substring(_index, _index + 1);
                }
            }
        }
        return {
            type: 'SPACE',
            start: index,
            end: _index,
            value: space
        }
    } else if(isMatch(comment)) {
        console.log('comment4: ', str.substring(index, comment.end));
        return {
            type: 'SPACE',
            start: index,
            end: comment.end,
            //TODO /*value*/
            value: str.substring(index, comment.end)
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseOptionalSpaceOnly = (index) => {
    const spaceOnly = parseSpaceOnly(index);
    if (isMatch(spaceOnly)) {
        return spaceOnly;
    } else {
        return {
            type: 'SPACE',
            start: index,
            end: index,
            value: ''
        };
    }
}

const parseNewLine = (index) => {
    let _index = index;
    let length = 0;
    let char = str.substring(_index, _index + 1);
    // For windows \r\n, ignore \r
    if (char.match(/\r/)) {
        _index++;
        length++;
        char = str.substring(_index, _index + 1);
    }
    if (char.match(/\n/)) {
        let newLine = char;
        _index++;
        length++;
        while (char.match(/\n/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/\n/)) {
                newLine += char
                _index++;
                length++;
            }
        }
        return {
            type: 'NEW_LINE',
            start: index,
            end: index + length,
            value: newLine
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseOptionalNewLine = (index) => {
    const newLine = parseNewLine(index);
    if (isMatch(newLine)) {
        return newLine;
    } else {
        return {
            type: 'NEW_LINE',
            start: index,
            end: index,
            value: ''
        };
    }
}

const parseComment = (index) => {
    let _index = index;
    let startComment = parseConst('/*')(index);
    if (isMatch(startComment)) {
        _index = startComment.end;
        let char = str.substring(_index, _index + 1);
        
        let endComment = parseConst('*/')(_index);
        if (!isMatch(endComment)) {
            let comment = char;
            _index++;
            endComment = parseConst('*/')(_index);
            while (!isMatch(endComment)) {
                char = str.substring(_index, _index + 1);
                if (!isMatch(endComment)) {
                    comment += char;
                    _index++;
                    endComment = parseConst('*/')(_index);
                }
            }

            return {
                type: 'COMMENT',
                start: index,
                end: endComment.end,
                comment: comment
            }
        } else {
            return {
                type: 'COMMENT',
                start: index,
                end: endComment.end,
                comment: comment
            }
        }
    } else {
        startComment = parseConst('//')(index);
        if (isMatch(startComment)) {
            _index = startComment.end;
            let char = str.substring(_index, _index + 1);

            let endComment = parseNewLine(_index);
            if (!isMatch(endComment)) {
                let comment = char;
                _index++;
                endComment = parseNewLine(_index);
                while (!isMatch(endComment) && _index < str.length) {
                    char = str.substring(_index, _index + 1);
                    if (!isMatch(endComment)) {
                        comment += char;
                        _index++;
                        endComment = parseNewLine(_index);
                    }
                }

                return {
                    type: 'COMMENT',
                    start: index,
                    end: _index,
                    comment: comment,
                }
            } else {
                return {
                    type: 'COMMENT',
                    start: index,
                    end: endComment.end,
                    comment: '',
                }
            }
        } else {
            return NOT_MATCH(index);
        }
    }
}

const parseIdentity = (index) => {
    let _index = index;
    let char = str.substring(index, index + 1);
    let length = 0;
    if (char.match(/[A-Za-z]/)) {
        let id = char;
        _index++;
        length++
        while (char.match(/[A-Za-z0-9]/)) {
            char = str.substring(_index, _index + 1);
            if (char.match(/[A-Za-z0-9]/)) {
                id += char
                _index++;
                length++
            }
        }

        if (id !== 'let' &&
            id !== 'if' &&
            id !== 'else' &&
            id !== 'while' &&
            id !== 'return' &&
            id !== 'true' &&
            id !== 'false'
        ) {
            return {
                type: 'IDENTITY',
                start: index,
                end: index + length,
                length: length,
                value: id
            }
        } else {
            return NOT_MATCH(index);
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseColon = (index) => {
    return parseConst(':')(index);
}

const parseEqual = (index) => {
    return parseConst('=')(index);
}

const parseStatementEnd = (index) => {
    const optionalSpace = parseOptionalSpaceOnly(index);
    const semicolon = parseConst(';')(optionalSpace.end);

    if (isMatch(semicolon)) {
        const optionalNewLine = parseOptionalNewLine(semicolon.end);
        return {
            type: 'STATEMENT_END',
            start: index,
            end: optionalNewLine.end,
        }
    } else {
        const newLine = parseNewLine(optionalSpace.end);
        if (isMatch(newLine)) {
            return {
                type: 'STATEMENT_END',
                start: index,
                end: newLine.end,
            }
        } else {
            if (optionalSpace.end === str.length) {
                return {
                    type: 'STATEMENT_END',
                    start: optionalSpace.end,
                    end: index,
                    length: 0
                }
            } else {
                return NOT_MATCH(index);
            }
        }
    }

}

const matchParse = (index, parses) => {
    for (const parse of parses) {
        const p = parse(index)
        if (isMatch(p)) {
            return p;
        }
    }

    return NOT_MATCH(index);
}

const parseValueAst = env => (index) => {
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
        return isMatch(parseBinOpToken(index));
    }
    const getBinOpPrecedence = (op) => {
        return binOpPrecedence.get(op);
    }
    const parseBinOpToken = (index) => {
        for (const [key, value] of binOpPrecedence) {
            const binOpToken = parseConst(key)(index)
            if (isMatch(binOpToken) && !isMatch(parseConst('//')(index)) && !isMatch(parseConst('/*')(index))) {
                return binOpToken;
            }
        }

        return NOT_MATCH(index);
    }
    const parseBinOpUnitAst = (lhs, index) => {
        const lOptionalSpace = parseOptionalSpace(index);
        const op = parseBinOpToken(lOptionalSpace.end);
        if (isMatch(op)) {
            const rOptionalSpace = parseOptionalSpace(op.end);
            let rhs = parseSingleValueAst(env)(rOptionalSpace.end);
            let nOptionalSpace = parseOptionalSpace(rhs.end);
            let nextBinOpToken = parseBinOpToken(nOptionalSpace.end);

            let tmp = rhs;
            //let length = rhs.length;
            while (isMatch(nextBinOpToken) && getBinOpPrecedence(op.type) < getBinOpPrecedence(nextBinOpToken.type)) {
                //next = token
                tmp = rhs;
                rhs = parseBinOpUnitAst(rhs, rhs.end)
                nOptionalSpace = parseOptionalSpace(rhs.end);
                nextBinOpToken = parseBinOpToken(nOptionalSpace.end);
                //length += rhs.length;
            }

            return {
                type: 'AST',
                ast: new BinOpExprAst(op, lhs, rhs),
                start: index,
                end: rhs.end,
            }

        } else {
            return NOT_MATCH(index);
        }
    }

    let value = parseSingleValueAst(env)(index)
    if (isMatch(value)) {
        //console.log(`findInEnv: ${value.ast.value}`, findInEnv(value.ast, env));
        let optionalSpace = parseOptionalSpace(value.end);
        while (isBinOpToken(optionalSpace.end)) {
            value = parseBinOpUnitAst(value, optionalSpace.end)
            optionalSpace = parseOptionalSpace(value.end);
        }
    }

    return value;
}

const parseIdentityAst = (index) => {
    let identity = parseIdentity(index);
    
    if (isMatch(identity)) {
        let identityAst = {
            type: 'AST',
            ast: new IdentityExprAst(identity.value),
            start: index,
            end: identity.end,
        }

        return identityAst;
    } else {
        return NOT_MATCH(index);
    }
}

const parseValuePathAst = env => identityAst => (index) => {
    let optionalSpace = parseOptionalSpace(identityAst.end);

    let objectIndex = parse(optionalSpace.end, [parseConst('['), parseOptionalSpace, parseValueAst(env), parseOptionalSpace, parseConst(']')]);
    if (isMatch(objectIndex)) {
        identityAst.index = objectIndex.result[2];
        console.log(objectIndex)
        identityAst.end = objectIndex.end;
    }

    const dot = parseConst('.')(identityAst.end);

    if (isMatch(dot)) {
        const child = parseValueAst(env)(dot.end);
        identityAst.ast.child = child;
        identityAst.end = child.end;
    }

    return identityAst;
}

const parseFunctionAst = env => (index) => {
    let p = parseOptionalSpace(index);

    const parseParameters = (index) => {
        const parseParameter = (index) => {
            let p = parseIdentity(index);
            if (isMatch(p)) {
                let parameter= {
                    variable: p.value
                }
                let p0 = parse(p.end, [parseOptionalSpace, parseConst(':'), parseOptionalSpace, ]);
                let identity = parseIdentityAst(p0.end);
                let identityEnd = parse(identity.end, [parseOptionalSpace, parseConst('=')]);
                let end = p0.end;

                if (isMatch(identity) && isMatch(identityEnd)) {
                    let pType = findInEnv(identity.ast, env)

                    if (isMatch(pType)) {
                        parameter.type = pType;
                        end = identity.end;
                    } else {
                        let pType = parseValueAst(env)(p0.end)
                        if (isMatch(pType)) {
                            parameter.type = pType

                            end = pType.end
                        }
                    }
                } else {
                    let pType = parseValueAst(env)(p0.end)
                    if (isMatch(pType)) {
                        parameter.type = pType

                        end = pType.end
                    }
                }

                /*
                let pType = parseValueAst(env)(p0.end)
                if (isMatch(pType)) {
                    parameter.type = pType

                    end = pType.end
                }
                */
                
                return {
                    parameter,
                    start: index,
                    end: end
                };
            } else {
                return NOT_MATCH(index);
            }
        }
        let parameters = []
        let p = parseOptionalSpace(index);
        p = parseParameter(p.end);
        if (isMatch(p)) {
            while (isMatch(p)) {
                parameters.push(p)
                p = parse(p.end, [parseOptionalSpace, parseConst(','), parseOptionalSpace]);
                p = parseParameter(p.end);
            }

            return {
                parameters,
                start: index,
                end: p.end
            }
        } else {
            return NOT_MATCH(index);
        }
        
    } 

    let p0 = parse(p.end, [parseConst('('), parseOptionalSpace, parseParameters, parseOptionalSpace, parseConst(')'), parseOptionalSpace, parseConst('=>'), parseOptionalSpace, parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')]);
    if (isMatch(p0)) {
        console.log(p0);
        return {
            type: 'AST',
            ast: new FunctionExprAst(p0.result[2].parameters, p0.result[10]),
            start: index,
            end: p0.end
        }
    } else {
        p0 = parse(p.end, [parseParameters, parseOptionalSpace, parseConst('=>'), parseOptionalSpace, parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')]);
        if (isMatch(p0)) {
            console.log(p0);
            return {
                type: 'AST',
                ast: new FunctionExprAst(p0.result[0].parameters, p0.result[6]),
                start: index,
                end: p0.end
            }
        } else {
            return NOT_MATCH(index);
        }
    }
}


const parseSingleValueAst = env => (index) => {
    const f = matchParse(index, [
        parseNumberAst,
        parseStringAst,
        parseBooleanAst,
        parseFunctionAst(env),
        parseIdentityAst,
        parseParenthesis(env)
    ]);

    if (isMatch(f)) {
        parseValuePathAst(env)(f)(f.index);
    }

    return f;
}
const parseNumberAst = (index) => {
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

        return {
            type: 'AST',
            ast: new NumberExprAst(number),
            start: index,
            end: index + length,
        };
    } else {
        return NOT_MATCH(index);
    }
}

const parseStringAst = (index) => {
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

            //_index++;
        }
        length++;
        console.log(string);

        return {
            type: 'AST',
            ast: new StringExprAst(string),
            start: index,
            end: index + length,
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseBooleanAst = (index) => {
    const trueResult = parseConst('true')(index);
    if (isMatch(trueResult)) {
        return {
            type: 'AST',
            ast: new BooleanExprAst('true'),
            start: index,
            end: trueResult.end,
        }
    } else {
        const falseResult = parseConst('false')(index);
        if (isMatch(falseResult)) {
            return {
                type: 'AST',
                ast: new BooleanExprAst('false'),
                start: index,
                end: falseResult.end,
            }
        } else {
            return NOT_MATCH(index);
        }
    }
}

const parseParenthesis = env => (index) => {
    const result = parse(index, [parseConst('('), parseOptionalSpace, parseValueAst(env), parseOptionalSpace, parseConst(')')]);
    if (isMatch(result)) {
        return {
            type: 'AST',
            ast: result.result[2].ast,
            start: result.start,
            end: result.end,
        }
    } else {
        return NOT_MATCH(index)
    }
}

const parseStatementAst = env => (index) => {
    const p = parse(index, [parseOptionalSpace])
    let p0 = parse(p.end, [parseLet, parseSpace, parseIdentity]);
    // let variable
    if (isMatch(p0)) {
        // let variable: Type
        let p1 = parse(p0.end, [parseOptionalSpace, parseColon, parseOptionalSpace, parseValueAst(env)])
        if (isMatch(p1)) {
            // let variable: Type = value
            const p2 = parse(p1.end, [parseOptionalSpace, parseEqual, parseOptionalSpace, parseValueAst(env)]);
            if (isMatch(p2)) {
                const statementEnd = parse(p2.end, [parseStatementEnd]);
                if (isMatch(statementEnd)) {
                    const ast = new DeclareStmtAst(p1.result[3], p0.result[2], p2.result[3]);
                    //context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                    return {
                        type: 'AST',
                        ast: ast,
                        start: index,
                        end: statementEnd.end,
                    }
                } else {
                    return NOT_MATCH(index);
                }
            } else {
                const statementEnd = parse(p1.end, [parseStatementEnd]);
                if (isMatch(statementEnd)) {
                    const ast = new DeclareStmtAst(p1.result[3], p0.result[2], null);
                    //context.set(p0.result[2], { type: 'any', value: null })
                    return {
                        type: 'AST',
                        ast: ast,
                        start: index,
                        end: statementEnd.end
                    };
                } else {
                    return NOT_MATCH(index);
                }
            }
        } else {
            p1 = parse(p0.end, [parseOptionalSpace, parseEqual, parseOptionalSpace, parseValueAst(env)])
            if (isMatch(p1)) {
                // let variable = value
                const statementEnd = parse(p1.end, [parseStatementEnd]);
                if (isMatch(statementEnd)) {
                    const ast = new DeclareStmtAst(null, p0.result[2], p1.result[3]);
                    //context.set(p0.result[2], { type: 'any', value: p1.result[3] })
                    return {
                        type: 'AST',
                        ast: ast,
                        start: index,
                        end: statementEnd.end,
                    }
                } else {
                    console.log(p1)
                    return NOT_MATCH(index)
                }
            } else {
                return NOT_MATCH(index)
            }
        }
    } else {
        p0 = parseValueAst(env)(p.end);
        if (isMatch(p0)) {
            let p1 = parse(p0.end, [parseOptionalSpace, parseEqual]);
            if (isMatch(p1)) {
                let p2 = parse(p1.end, [parseOptionalSpace, parseValueAst(env)]);
                if (isMatch(p2)) {
                    const statementEnd = parse(p2.end, [parseStatementEnd]);
                    if (isMatch(statementEnd)) {
                        // identity = value
                        return {
                            type: 'AST',
                            ast: new AssignStmtAst(p0, p2.result[1]),
                            start: index,
                            end: p2.end,
                        };
                    } else {
                        console.log(`Parse failed: ${str.substring(p2.start, p2.start + 20)}`)
                        return NOT_MATCH(index)
                    }
                }
            } else {
                console.log(`Parse failed: ${str.substring(p1.start, p1.start + 20)}`)
                return NOT_MATCH(index)
            }
        } else {
            const parseBodySeq = [parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')];
            const parseIfSeq = [parseConst('if'), parseOptionalSpace, parseValueAst(env), parseOptionalSpace, ...parseBodySeq];
            p0 = parse(p.end, parseIfSeq)
            if (isMatch(p0)) {
                console.log(p0);
                let ast = new IfStmtAst([{condition: p0.result[2], body: p0.result[6]}]);
                p0 = parseOptionalSpace(p0.end);
                let p1 = parse(p0.end, [parseConst('else'), parseOptionalSpace, ...parseIfSeq])
                while (isMatch(p1)) {
                    ast.matchBodies.push({condition: p1.result[4], body: p1.result[8]})
                    p1 = parse(p1.end, [parseConst('else'), parseOptionalSpace, ...parseIfSeq])
                }
                p1 = parseOptionalSpace(p1.end)
                p1 = parse(p1.end, [parseConst('else'), parseOptionalSpace, ...parseBodySeq])
                if (isMatch(p1)) {
                    ast.elseBody = p1.result[4]
                }
                return {
                    type: 'AST',
                    ast: ast,
                    start: p0.start,
                    end: p1.end,
                };
            } else {
                console.log(`Parse failed: ${str.substring(p0.start, p0.start + 20)}`)
                return NOT_MATCH(index)
            }
        }
        return NOT_MATCH(index);
    }


    /*
     //console.dir(token);
     if (token.type === Token.DECLARE) { // let
         let t1 = getToken();
         if (t1.type === Token.IDENTITY) { //id
             let t2 = getToken();
             if (t2.type === Token.EQUAL) { // =
                 let t3 = getToken()
                 if (isValueToken(t3)) {
                     let valueAst = parseValue()
                     if (isBinOpToken(token)) {
                         valueAst = parseBinOp(valueAst)
                     }
                     const ast = new DeclareStmtAst(null, t1.value, valueAst);
                     //TODO exp
 
                     //getToken(false)
                     return ast;
                 }
             } else if (t2.type === Token.COLON) { // :
                 let t4 = getToken()
                 if (t4.type === Token.IDENTITY) { // type
                     let t5 = getToken()
                     if (t5.type === Token.EQUAL) { // =
                         let t6 = getToken();
                         if (isValueToken(t6)) {
                             const ast = new DeclareStmtAst(t4.value, t1.value, parseValue());
                             //TODO exp
                             //getToken(false);
                             return ast;
                         }
                     }
 
                 }
             } else {
                 return new DeclareStmtAst(null, t1.value, null);
             }
         }
         //console.dir(t);
     } else if (token.type === Token.IDENTITY) {
         const valueAst = parseBinOp(parseValue());
 
         //const variable = parseBinOp(parseValue())
         if (token.type === Token.EQUAL) {
             getToken()
             const value = parseBinOp(parseValue())
 
             return new AssignStmtAst(valueAst, value)
         }
         return valueAst;
     } else if (token.type === Token.IF) {
         getToken();
 
         const matchBodies = [];
         const value = parseValue();
         matchBodies.push(new IfUnitStmtAst(parseBinOp(value), parseBlock()));
         let elseBody;
         if (token.type === Token.ELSE) {
             while (token.type === Token.ELSE) {
                 getToken();
                 if (token.type === Token.IF) {
                     getToken();
                     matchBodies.push(new IfUnitStmtAst(parseBinOp(parseValue()), parseBlock()));
                     //getToken()
                 } else {
                     elseBody = parseBlock();
                     //getToken();
                     break;
                 }
                 //getToken();
             }
         } else {
             getToken()
         }
 
         return new IfStmtAst(matchBodies, elseBody);
     } else if (token.type === Token.WHILE) {
         getToken();
 
         const condition = parseBinOp(parseValue());
         return new WhileStmtAst(condition, parseBlock())
     } else if (token.type === Token.RETURN) {
         getToken()
         return new ReturnStmtAst(parseBinOp(parseValue()))
     } else {
         console.log("token", token)
         throw new Error()
     }
         */
}

const parseStatementsAst = parentEnv => (index) => {
    const ast = new StmtsAst([]);
    let env = {
        parent: parentEnv,
        context: new Map()
    };
    //let context = new Map();
    let statement = parseStatementAst(env)(index);
    let end = index;
    while (isMatch(statement)) {
        if (statement.ast.type === Ast.DECLARE) {
            env.context.set(statement.ast.variable.value, statement.ast.value);
        }
        end = statement.end;
        ast.statements.push(statement);
        statement = parseStatementAst(env)(statement.end);
    }

    console.log(env);

    return {
        type: 'AST',
        ast: ast,
        start: index,
        end: end
    }
}

const findInEnv = (variable, env) => {
    if (variable.type === Ast.NUMBER) {
        return variable.value;
    }
    while (env) {
        if (variable.type === Ast.IDENTITY) {
            //TODO 
            if (env.context.has(variable.value)) {
                return env.context.get(variable.value)
            }
        }

        env = env.parent;
    }

    return NOT_MATCH;
}

let context = new Map();
context.set('String', {name: 'String', type: 'Type'});
context.set('Int', {name: 'Int', type: 'Type'});

console.log(JSON.stringify(parseStatementsAst({context: context})(0), null, 2));
