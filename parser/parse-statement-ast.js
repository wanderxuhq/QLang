import { parseConst } from './parse-const.js';
import { notMatch, isMatch, parseFail } from './match.js';
import { matchParse, parseSeq } from './helper.js';
import {
    parseSpaceAndNewline,
    parseOptionalSpaceAndNewline,
    parseOptionalSpace,
    parseNewLine,
    parseOptionalNewLine,
    parseOptionalNewLines,
    parseEmptyLines
} from './parse-space.js';
import { parseIdentity } from './parse-identity.js';
import { parseComplexValueAst, parseValueAst } from './parse-value-ast.js';
import {
    Ast,
    StmtsAst,
    DeclareStmtAst,
    AssignStmtAst,
    IfStmtAst,
    WhileStmtAst,
    ReturnStmtAst
} from '../ast/index.js';
import { equal, PrimeType } from '../type/constant.js';

const parseStatementAst = env => str => (index) => {
    const p = parseOptionalSpaceAndNewline(str)(index);
    const leadSpace = p.length;
    let p0 = parseSeq(str)(p.end, [parseConst('let'), parseSpaceAndNewline, parseIdentity]);

    // let variable
    if (isMatch(p0)) {
        // let variable
        let p1 = parseSeq(str)(p0.end, [parseOptionalSpaceAndNewline, parseConst('='), parseOptionalSpaceAndNewline, parseValueAst(leadSpace)(env)])
        if (isMatch(p1)) {
            // let variable = value

            const ast = {
                type: Ast.DECLARE,
                variable: p0.result[2],
                value: p1.result[3]
            };

            ast.start = index;
            ast.end = p1.end;

            return ast;
        } else {
            return notMatch(index)
        }
    } else {
        p0 = parseValueAst(leadSpace)(env)(str)(p.end);
        if (isMatch(p0)) {
            let p1 = parseSeq(str)(p0.end, [parseOptionalSpaceAndNewline, parseConst('=')]);
            if (isMatch(p1)) {
                let p2 = parseSeq(str)(p1.end, [parseOptionalSpaceAndNewline, parseValueAst(leadSpace)(env)]);
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
            let parseBodySeq = [parseConst('{'), parseOptionalSpaceAndNewline, parseStatementsAst(env), parseOptionalSpaceAndNewline, parseConst('}')];
            const parseIfSeq = [parseConst('if'), parseOptionalSpaceAndNewline, parseValueAst(leadSpace)(env), parseOptionalSpaceAndNewline, ...parseBodySeq];
            p0 = parseSeq(str)(p.end, parseIfSeq)
            if (isMatch(p0)) {
                let ast = new IfStmtAst([{ condition: p0.result[2], body: p0.result[6] }]);
                let p1 = parseSeq(str)(p0.end, [parseOptionalSpaceAndNewline, parseConst('else'), parseOptionalSpaceAndNewline, ...parseIfSeq])
                while (isMatch(p1)) {
                    ast.matchBodies.push({ condition: p1.result[4], body: p1.result[8] })
                    p1 = parseSeq(str)(p1.end, [parseConst('else'), parseOptionalSpaceAndNewline, ...parseIfSeq])
                }
                p1 = parseSeq(str)(p1.end, [parseOptionalSpaceAndNewline, parseConst('else'), parseOptionalSpaceAndNewline, ...parseBodySeq])
                if (isMatch(p1)) {
                    ast.elseBody = p1.result[5]
                }

                ast.start = p0.start;
                ast.end = p1.end;

                return ast;
            } else {
                p0 = parseSeq(str)(p.end, [parseConst('return'), parseSpaceAndNewline, parseValueAst(leadSpace)(env)])
                if (isMatch(p0)) {
                    const ast = new ReturnStmtAst(p0.result[2]);
                    //context.set(p0.result[2], { type: p1.result[3], value: p2.result[3] });
                    ast.start = p0.start;
                    ast.end = p0.end;

                    return ast;
                } else {
                    let parseBodySeq = [parseConst('{'), parseOptionalSpaceAndNewline, parseStatementsAst(env), parseOptionalSpaceAndNewline, parseConst('}')];
                    const parseWhileSeq = [parseConst('while'), parseOptionalSpaceAndNewline, parseValueAst(leadSpace)(env), parseOptionalSpaceAndNewline, ...parseBodySeq];
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
    let env = parentEnv
    //let context = new Map();
    //let p = parseOptionalSpaceAndNewline(str)(index)
    let p = parseEmptyLines(str)(index);
    let statement = parseStatementAst(env)(str)(p.end);
    let end = index;
    if (isMatch(statement)) {
        while (isMatch(statement)) {
            /*
            if (statement.type === Ast.DECLARE) {
                env.set(statement.variable.value,
                    statement.value
                );
            }
            */
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
    const optionalSpace = parseOptionalSpace(str)(index);
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