import { parseConst } from './parse-const.js';
import { notMatch, isMatch } from './match.js';
import { matchParse, parseSeq } from './helper.js';
import {
    parseSpace,
    parseOptionalSpace,
    parseSpaceOnly,
    parseOptionalSpaceOnly,
    parseNewLine,
    parseOptionalNewLine
} from './parse-space.js';
import { parseIdentity } from './parse-identity.js';
import { parseValueAst } from './parse-value-ast.js';
import {
    Ast,
    StmtsAst,
    DeclareStmtAst,
    AssignStmtAst,
    IfStmtAst,
    WhileStmtAst,
    ReturnStmtAst
} from '../ast/index.js';

const parseStatementAst = env => str => (index) => {
    const p = parseOptionalSpace(str)(index);
    let p0 = parseSeq(str)(p.end, [parseConst('let'), parseSpace, parseIdentity]);

    // let variable
    if (isMatch(p0)) {
        // let variable: Type
        let p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst(':'), parseOptionalSpace, parseValueAst(env)]);
        if (isMatch(p1)) {
            const p2 = parseSeq(str)(p1.end, [parseOptionalSpace, parseConst('='), parseOptionalSpace, parseValueAst(env)]);
            if (isMatch(p2)) {
                const statementEnd = parseStatementEnd(str)(p2.end);
                if (isMatch(statementEnd)) {
                    // let variable: Type = value
                    const ast = new DeclareStmtAst(p1.result[3], p0.result[2], p2.result[3]);
                    //context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                    ast.start = index;
                    ast.end = statementEnd.end;

                    return ast;
                } else {
                    return notMatch(index);
                }
            } else {
                const statementEnd = parseStatementEnd(str)(p1.end);
                if (isMatch(statementEnd)) {
                    // let variable: Type
                    const ast = new DeclareStmtAst(p1.result[3], p0.result[2], null);
                    //context.set(p0.result[2], { type: 'any', value: null })

                    ast.start = index;
                    ast.end = statementEnd.end;

                    return ast;
                } else {
                    return notMatch(index);
                }
            }
        } else {
            p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst('='), parseOptionalSpace, parseValueAst(env)])
            if (isMatch(p1)) {
                const statementEnd = parseStatementEnd(str)(p1.end);
                if (isMatch(statementEnd)) {
                    // let variable = value
                    const ast = new DeclareStmtAst(null, p0.result[2], p1.result[3]);
                    //context.set(p0.result[2], { type: 'any', value: p1.result[3] })
                    ast.start = index;
                    ast.end = statementEnd.end;

                    return ast;
                } else {
                    //console.log(p1)
                    return notMatch(index)
                }
            } else {
                return notMatch(index)
            }
        }
    } else {
        p0 = parseValueAst(env)(str)(p.end);
        if (isMatch(p0)) {
            let p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst('=')]);
            if (isMatch(p1)) {
                let p2 = parseSeq(str)(p1.end, [parseOptionalSpace, parseValueAst(env)]);
                if (isMatch(p2)) {
                    const statementEnd = parseStatementEnd(str)(p2.end);
                    if (isMatch(statementEnd)) {
                        // identity = value

                        let ast = new AssignStmtAst(p0, p2.result[1]);
                        ast.start = index;
                        ast.end = p2.end;

                        return ast;
                    } else {
                        //console.log(`Parse failed: ${str.substring(p2.start, p2.start + 20)}`)
                        return notMatch(index)
                    }
                }
            } else {
                //variable
                const statementEnd = parseStatementEnd(str)(p0.end);
                if (isMatch(statementEnd)) {
                    p0.end = statementEnd.end;
                    return p0
                }

                //console.log(`Parse failed: ${str.substring(p1.start, p1.start + 20)}`)
                return notMatch(index)
            }
        } else {
            let parseBodySeq = [parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')];
            const parseIfSeq = [parseConst('if'), parseOptionalSpace, parseValueAst(env), parseOptionalSpace, ...parseBodySeq];
            p0 = parseSeq(str)(p.end, parseIfSeq)
            if (isMatch(p0)) {
                let ast = new IfStmtAst([{ condition: p0.result[2], body: p0.result[6] }]);
                p0 = parseOptionalSpace(str)(p0.end);
                let p1 = parseSeq(str)(p0.end, [parseConst('else'), parseOptionalSpace, ...parseIfSeq])
                while (isMatch(p1)) {
                    ast.matchBodies.push({ condition: p1.result[4], body: p1.result[8] })
                    p1 = parseSeq(str)(p1.end, [parseConst('else'), parseOptionalSpace, ...parseIfSeq])
                }
                p1 = parseOptionalSpace(str)(p1.end)
                p1 = parseSeq(str)(p1.end, [parseConst('else'), parseOptionalSpace, ...parseBodySeq])
                if (isMatch(p1)) {
                    ast.elseBody = p1.result[4]
                }

                ast.start = p0.start;
                ast.end = p1.end;

                return ast;
            } else {
                p0 = parseSeq(str)(p.end, [parseConst('return'), parseSpace, parseValueAst(env)])
                if (isMatch(p0)) {
                    const statementEnd = parseStatementEnd(str)(p0.end);
                    if (isMatch(statementEnd)) {
                        const ast = new ReturnStmtAst(p0.result[2]);
                        //context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                        ast.start = p0.start;
                        ast.end = statementEnd.end;

                        return ast;
                    } else {
                        return notMatch(index);
                    }
                } else {
                    let parseBodySeq = [parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')];
                    const parseWhileSeq = [parseConst('while'), parseOptionalSpace, parseValueAst(env), parseOptionalSpace, ...parseBodySeq];
                    p0 = parseSeq(str)(p.end, parseWhileSeq)
                    if (isMatch(p0)) {
                        let ast = new WhileStmtAst(p0.result[2], p0.result[6]);

                        ast.start = p0.start;
                        ast.end = p0.end;

                        return ast;
                    } else {
                        //console.log(`Parse failed: ${str.substring(index, index + 20)}`)
                        return notMatch(index);
                    }
                }
            }
        }
        return notMatch(index);
    }
}

const parseStatementsAst = parentEnv => str => (index) => {
    const ast = new StmtsAst([]);
    let env = {
        parent: parentEnv,
        context: new Map()
    };
    //let context = new Map();
    let statement = parseStatementAst(env)(str)(index);
    let end = index;
    while (isMatch(statement)) {
        //TODO 2 step parse declare
        if (statement.type === Ast.DECLARE) {
            env.context.set(statement.variable.value,
                statement.value
            );
        }
        end = statement.end;
        ast.statements.push(statement);
        statement = parseStatementAst(env)(str)(statement.end);
    }

    //console.log(env);

    ast.start = index;
    ast.end = end;

    return ast;
}


const parseStatementEnd = str => (index) => {
    const optionalSpace = parseOptionalSpaceOnly(str)(index);
    const semicolon = parseConst(';')(str)(optionalSpace.end);

    if (isMatch(semicolon)) {
        const optionalNewLine = parseOptionalNewLine(str)(semicolon.end);
        return {
            type: 'STATEMENT_END',
            start: index,
            end: optionalNewLine.end,
        }
    } else {
        const newLine = parseNewLine(str)(optionalSpace.end);
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
                return notMatch(index);
            }
        }
    }

}

export {
    parseStatementAst,
    parseStatementsAst,
    parseStatementEnd
}