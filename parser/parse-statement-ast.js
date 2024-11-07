import { parseConst } from './parse-const.js';
import { notMatch, isMatch, parseFail } from './match.js';
import { matchParse, parseSeq } from './helper.js';
import {
    parseSpace,
    parseOptionalSpace,
    parseSpaceOnly,
    parseOptionalSpaceOnly,
    parseNewLine,
    parseOptionalNewLine,
    parseOptionalNewLines,
    parseEmptyLines
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
    const leadSpace = p.length;
    let p0 = parseSeq(str)(p.end, [parseConst('let'), parseSpace, parseIdentity]);

    // let variable
    if (isMatch(p0)) {
        // let variable: Type
        let p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst(':'), parseOptionalSpace, parseValueAst(leadSpace)(env)]);
        if (isMatch(p1)) {
            const p2 = parseSeq(str)(p1.end, [parseOptionalSpace, parseConst('='), parseOptionalSpace, parseValueAst(leadSpace)(env)]);
            if (isMatch(p2)) {
                // let variable: Type = value
                const ast = new DeclareStmtAst(p1.result[3], p0.result[2], p2.result[3]);
                //context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                ast.start = index;
                ast.end = p2.end;

                return ast;
            } else {
                // let variable: Type
                const ast = new DeclareStmtAst(p1.result[3], p0.result[2], null);

                ast.start = index;
                ast.end = p1.end;

                return ast;
            }
        } else {
            p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst('='), parseOptionalSpace, parseValueAst(leadSpace)(env)])
            if (isMatch(p1)) {
                // let variable = value
                const ast = new DeclareStmtAst(null, p0.result[2], p1.result[3]);
                ast.start = index;
                ast.end = p1.end;

                return ast;
            } else {
                return notMatch(index)
            }
        }
    } else {
        p0 = parseValueAst(leadSpace)(env)(str)(p.end);
        if (isMatch(p0)) {
            let p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst('=')]);
            if (isMatch(p1)) {
                let p2 = parseSeq(str)(p1.end, [parseOptionalSpace, parseValueAst(leadSpace)(env)]);
                if (isMatch(p2)) {
                    // identity = value

                    if (p0.type === Ast.IDENTITY) {
                        //TODO segmentation
                        let ast = new AssignStmtAst(p0, p2.result[1]);
                        ast.start = index;
                        ast.end = p2.end;
                        return ast;
                    } else {
                        return parseFail(`Assign left side "${p0.value}" cannot be "${p0.type}"`)(str)(index, p2.end);
                    }
                } else {
                    return notMatch(index);
                }
            } else {
                //variable
                return p0
            }
        } else {
            let parseBodySeq = [parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')];
            const parseIfSeq = [parseConst('if'), parseOptionalSpace, parseValueAst(leadSpace)(env), parseOptionalSpace, ...parseBodySeq];
            p0 = parseSeq(str)(p.end, parseIfSeq)
            if (isMatch(p0)) {
                let ast = new IfStmtAst([{ condition: p0.result[2], body: p0.result[6] }]);
                let p1 = parseSeq(str)(p0.end, [parseOptionalSpace, parseConst('else'), parseOptionalSpace, ...parseIfSeq])
                while (isMatch(p1)) {
                    ast.matchBodies.push({ condition: p1.result[4], body: p1.result[8] })
                    p1 = parseSeq(str)(p1.end, [parseConst('else'), parseOptionalSpace, ...parseIfSeq])
                }
                p1 = parseSeq(str)(p1.end, [parseOptionalSpace, parseConst('else'), parseOptionalSpace, ...parseBodySeq])
                if (isMatch(p1)) {
                    ast.elseBody = p1.result[5]
                }

                ast.start = p0.start;
                ast.end = p1.end;

                return ast;
            } else {
                p0 = parseSeq(str)(p.end, [parseConst('return'), parseSpace, parseValueAst(leadSpace)(env)])
                if (isMatch(p0)) {
                    const ast = new ReturnStmtAst(p0.result[2]);
                    //context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                    ast.start = p0.start;
                    ast.end = p0.end;

                    return ast;
                } else {
                    let parseBodySeq = [parseConst('{'), parseOptionalSpace, parseStatementsAst(env), parseOptionalSpace, parseConst('}')];
                    const parseWhileSeq = [parseConst('while'), parseOptionalSpace, parseValueAst(leadSpace)(env), parseOptionalSpace, ...parseBodySeq];
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
        context: new Map(),
        scope: new Map(),
    };
    //let context = new Map();
    //let p = parseOptionalSpace(str)(index)
    let p = parseEmptyLines(str)(index);
    let statement = parseStatementAst(env)(str)(p.end);
    let end = index;
    if (isMatch(statement)) {
        while (isMatch(statement)) {
            if (statement.type === Ast.DECLARE) {
                env.context.set(statement.variable.value,
                    statement.value
                );
            }
            end = statement.end;
            ast.statements.push(statement);

            const statementEnd = parseStatementEnd(str)(statement.end);
            if (isMatch(statementEnd)) {
                end = statementEnd.end;
            } else {
                break;
            }

            statement = parseStatementAst(env)(str)(end);
        }
    }

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