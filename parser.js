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
    BinOpExprAst
} from './ast.js';

const NOT_MATCH = (index) => {
    return {
        type: 'NOT_MATCH',
        index: index,
        length: 0
    }
}

const isMatch = (snip) => {
    return snip.type !== 'NOT_MATCH';
}

const parse = (index, parser) => {
    let result = {
        index: index,
        length: 0,
        result: []
    }
    for (const p of parser) {
        const parseResult = p(result.index);
        
        if (isMatch(parseResult)) {
            result.result.push(parseResult);
            result.index += parseResult.length;
            result.length += parseResult.length
        } else {
            return NOT_MATCH(index);
        }
    }

    return result;
}

const parseConst = (index, token) => {
    if (str.substring(index, index + token.length) === token) {
        return {
            type: token,
            length: token.length,
            index: index + token.length
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseLet = (index) => {
    return parseConst(index, 'let');
}

const parseSpace = (index) => {
    let length = 0;
    let char = str.substring(index, index + 1);
    if (char.match(/\s/)) {
        let space = char;
        index++;
        length++;
        while (char.match(/\s/)) {
            char = str.substring(index, index + 1);
            if (char.match(/\s/)) {
                space += char
                index++;
                length++;
            }
        }
        return {
            type: 'SPACE_ANE_NEWLINE',
            index: index + length,
            length: length,
            value: space
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseOptionalSpace = (index) => {
    let length = 0;
    let char = str.substring(index, index + 1);
    if (char.match(/\s/)) {
        let space = char;
        index++;
        length++;
        while (char.match(/\s/)) {
            char = str.substring(index, index + 1);
            if (char.match(/\s/)) {
                space += char
                index++;
                length++;
            }
        }
        return {
            type: 'SPACE_ANE_NEWLINE',
            length: length,
            index: index + length,
            value: space
        }
    } else {
        return {
            type: 'SPACE_ANE_NEWLINE',
            index: index + length,
            length: length,
            value: ''
        };
    }
}

const parseOptionalSpaceOnly = (index) => {
    let length = 0;
    let char = str.substring(index, index + 1);
    if (char.match(/ /)) {
        let space = char;
        index++;
        length++;
        while (char.match(/ /)) {
            char = str.substring(index, index + 1);
            if (char.match(/ /)) {
                space += char
                index++;
                length++;
            }
        }
        return {
            type: 'SPACE',
            index: index + length,
            length: length,
            value: space
        }
    } else {
        return {
            type: 'SPACE',
            index: index + length,
            length: length,
            value: ''
        };
    }
}


const parseNewLine = (index) => {
    let length = 0;
    let char = str.substring(index, index + 1);
    // For windows \r\n, ignore \r
    if (char.match(/\r/)) {
        index++;
        length++;
        char = str.substring(index, index + 1);
    }
    if (char.match(/\n/)) {
        let newLine = char;
        index++;
        length++;
        while (char.match(/\n/)) {
            char = str.substring(index, index + 1);
            if (char.match(/\n/)) {
                newLine += char
                index++;
                length++;
            }
        }
        return {
            type: 'NEW_LINE',
            index: index + length,
            length: length,
            value: newLine
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseOptionalNewLine = (index) => {
    let length = 0;
    let char = str.substring(index, index + 1);
    if (char.match(/\n/)) {
        let newLine = char;
        index++;
        length++;
        while (char.match(/\n/)) {
            char = str.substring(index, index + 1);
            if (char.match(/\n/)) {
                newLine += char
                index++;
                length++;
            }
        }
        return {
            type: 'NEW_LINE',
            length: length,
            value: newLine
        }
    } else {
        return {
            type: 'NEW_LINE',
            index: index + length,
            length: length,
            value: ''
        };
    }
}


const parseIdentity = (index) => {
    let char = str.substring(index, index + 1);
    let length = 0;
    if (char.match(/[A-Za-z]/)) {
        let id = char;
        index++
        length++
        while (char.match(/[A-Za-z0-9]/)) {
            char = str.substring(index, index + 1);
            if (char.match(/[A-Za-z0-9]/)) {
                id += char
                index++
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
                index: index,
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
    return parseConst(index, ':');
}

const parseEqual = (index) => {
    return parseConst(index, '=');
}

const parseStatementEnd = (index) => {
    const optionalSpace = parseOptionalSpaceOnly(index);
    const semicolon = parseConst(index + optionalSpace.length, ';');

    if (isMatch(semicolon)) {
        const optionalNewLine = parseOptionalNewLine(index + semicolon.length);
        return {
            type: 'STATEMENT_END',
            index: index + semicolon.length + optionalNewLine.length,
            length: semicolon.length + optionalNewLine.length
        }
    } else {
        const newLine = parseNewLine(index + optionalSpace.length);
        if (isMatch(newLine)) {
            return {
                type: 'STATEMENT_END',
                index: index + newLine.length,
                length: newLine.length
            }
        } else {
            if (index + optionalSpace.length === str.length - 1) {
                return {
                    type: 'STATEMENT_END',
                    index: index,
                    length: 0
                }
            } else {
                return NOT_MATCH(index);
            }
        }
    }

}

const flow = (index, parses) => {
    for (const parse of parses) {
        const p = parse(index)
        if (isMatch(p)) {
            return p;
        }
    }

    return NOT_MATCH(index);
}

const parseValueAst = (index) => {
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
            const binOpToken = parseConst(index, key)
            if (isMatch(binOpToken)) {
                return binOpToken;
            }
        }

        return NOT_MATCH(index);
    }
    const parseBinOpUnitAst = (lhs, index) => {
        const lOptionalSpace = parseOptionalSpace(index);
        const op = parseBinOpToken(lOptionalSpace.index);
        if (isMatch(op)) {
            const rOptionalSpace = parseOptionalSpace(op.index);
            let rhs = parseSingleValueAst(rOptionalSpace.index);
            let nOptionalSpace = parseOptionalSpace(rhs.index);
            let nextBinOpToken = parseBinOpToken(nOptionalSpace.index);

            let tmp = rhs;
            let length = rhs.length;
            while (isMatch(nextBinOpToken) && getBinOpPrecedence(op.type) < getBinOpPrecedence(nextBinOpToken.type)) {
                //next = token
                tmp = rhs;
                rhs = parseBinOpUnitAst(rhs, rhs.index)
                nOptionalSpace = parseOptionalSpace(rhs.index);
                nextBinOpToken = parseBinOpToken(nOptionalSpace.index);
                length += rhs.length;
            }

            return {
                ast: new BinOpExprAst(op, lhs, rhs),
                index: rhs.index,
                length: lhs.length + lOptionalSpace.length + op.length + rOptionalSpace.length + rhs.length
            }

        } else {
            return NOT_MATCH(index);
        }
    }

    let value = parseSingleValueAst(index);
    if (isMatch(value)) {
        //let next = token
        while (isBinOpToken(value.index)) {
            value = parseBinOpUnitAst(value, value.index)

            //next = token
        }
    }

    return value
}

const parseSingleValueAst = (index) => {
    const f = flow(index, [
        parseNumberAst,
        parseStringAst,
        parseBooleanAst,
        (index) => {
            let length = 0;
            const identity = parseIdentity(index);
            if (isMatch(identity)) {
                length += identity.length;
                let optionalSpace = parseOptionalSpace(identity.index);
                length += optionalSpace.length;
                let dot = parseConst(optionalSpace.index, '.');

                if (isMatch(dot)) {
                    let path = [];
                    let pathSnip;
                    path.push(identity.value);
                    while (isMatch(dot)) {
                        length += dot.length;

                        optionalSpace = parseOptionalSpace(dot.index);
                        length += optionalSpace.length;

                        pathSnip = parseIdentity(optionalSpace.index);
                        path.push(pathSnip.value);
                        length += pathSnip.length;

                        dot = parseConst(pathSnip.index, '.');
                    }

                    return {
                        ast: new IdentityPathExprAst(path),
                        index: pathSnip.index,
                        length: length
                    }
                }
                return {
                    ast: new IdentityExprAst(identity.value),
                    index: identity.index,
                    length: identity.length
                }
            } else {
                return NOT_MATCH(index);
            }
        }
    ]);

    //parseBinOp(f.index);

    return f;
}
const parseNumberAst = (index) => {
    let char = str.substring(index, index + 1);
    let length = 0;
    if (char.match(/[0-9]/)) {
        let number = char;
        index++
        length++
        while (char.match(/[0-9.]/)) {
            char = str.substring(index, index + 1);
            if (char.match(/[0-9.]/)) {
                number += char
                index++
                length++
            }
        }

        return {
            ast: new NumberExprAst(number),
            index: index,
            length: length,
        };
    } else {
        return NOT_MATCH(index);
    }
}

const parseStringAst = (index) => {
    let char = str.substring(index, index + 1);
    let length = 0;
    let string = '';
    if (char.match(/["`']/)) {
        const strSymbol = char;
        index++
        length++
        char = str.substring(index, index + 1);

        while (char !== strSymbol) {
            char = str.substring(index, index + 1);

            if (char === '\\') {
                index++
                length++
                char = str.substring(index, index + 1);
                if (char === 'n') {
                    string += '\n'
                    index++
                    length++
                } else if (char === 't') {
                    string += '\t'
                    index++
                    length++
                } else if (char === '\\') {
                    string += '\\'
                    index++
                    length++
                }
            } else {
                string += char;
                index++
                length++
            }
        }
        console.log(string);

        return {
            ast: new StringExprAst(string),
            index: index,
            length: length,
        }
    } else {
        return NOT_MATCH(index);
    }
}

const parseBooleanAst = (index) => {
    const trueResult = parseConst(index, 'true');
    if (isMatch(trueResult)) {
        return {
            ast: new BooleanExprAst('true'),
            index: trueResult.index,
            length: trueResult.length,
        }
    } else {
        const falseResult = parseConst(index, 'false');
        if (isMatch(falseResult)) {
            return {
                ast: new BooleanExprAst('false'),
                index: trueResult.index,
                length: trueResult.length,
            }
        } else {
            return NOT_MATCH(index);
        }
    }
}

const parseStatementAst = (index, context) => {
    const p = parse(index, [parseOptionalSpace])
    let p0 = parse(p.index, [parseLet, parseSpace, parseIdentity]);
    // let variable
    if (isMatch(p0)) {
        // let variable: Type
        let p1 = parse(p0.index, [parseOptionalSpace, parseColon, parseOptionalSpace, parseValueAst])
        if (isMatch(p1)) {
            // let variable: Type = value
            const p2 = parse(p1.index, [parseOptionalSpace, parseEqual, parseOptionalSpace, parseValueAst]);
            if (isMatch(p2)) {
                const statementEnd = parse(p2.index, [parseStatementEnd]);
                if (isMatch(statementEnd)) {
                    const ast = new DeclareStmtAst(p1.result[3], p0.result[2], p2.result[3]);
                    context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                    return {
                        ast: ast,
                        index: statementEnd.index,
                        length: p0.length + p1.length + p2.length + statementEnd.length
                    }
                } else {
                    return NOT_MATCH(index);
                }
            } else {
                const statementEnd = parse(p1.index, [parseStatementEnd]);
                if (isMatch(statementEnd)) {
                    const ast = new DeclareStmtAst(p1.result[3], p0.result[2], null);
                    context.set(p0.result[2], { type: 'any', value: null })
                    return {
                        ast: ast,
                        index: statementEnd.index,
                        length: p0.length + p1.length + statementEnd.length
                    };
                } else {
                    return NOT_MATCH(index);
                }
            }
        } else {
            p1 = parse(p0.index, [parseOptionalSpace, parseEqual, parseOptionalSpace, parseValueAst])
            if (isMatch(p1)) {
                // let variable = value
                const statementEnd = parse(p1.index, [parseStatementEnd]);
                if (isMatch(statementEnd)) {
                    const ast = new DeclareStmtAst(null, p0.result[2], p1.result[3]);
                    context.set(p0.result[2], { type: 'any', value: p1.result[3] })
                    return {
                        ast: ast,
                        index: statementEnd.index,
                        length: p0.length + statementEnd.length
                    }
                }
            } else {
                return NOT_MATCH(index)
            }
        }
    } else {
        p0 = parse(p.index, [parseIdentity]);
        if (isMatch(p0)) {
            let p1 = parse(p0.index, [parseOptionalSpace, parseEqual]);
            if (isMatch(p1)) {
                let p2 = parse(p1.index, [parseOptionalSpace, parseValueAst]);
                if (isMatch(p2)) {
                    const statementEnd = parse(p2.index, [parseStatementEnd]);
                    if (isMatch(statementEnd)) {
                        // identity = value
                        return {
                            ast: new AssignStmtAst(p0.result[0], p2.result[1]),
                            index: p2.index,
                            length: p0.length + p1.length + p2.length
                        };
                    } else {
                        return NOT_MATCH(index)
                    }
                }
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


const parseStatements = (index) => {
    const ast = new StmtsAst([]);
    let context = new Map();
    let statement = parseStatementAst(index, context);
    let length = 0;
    let _index = statement.index;
    while (isMatch(statement)) {
        length += statement.length;
        index = statement.index;
        ast.statements.push(statement);
        statement = parseStatementAst(statement.index, context);
    }

    return {
        ast: ast,
        index: _index,
        length: length
    }
}

console.log(JSON.stringify(parseStatements(0), null, 2));
