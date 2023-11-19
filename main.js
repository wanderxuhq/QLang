//let str = `let  a2 :String= 1`;
let str = 'let y = 5 + 2 * 3 + 4 * 6;let x = 1+ 2 + 3;let z = 1 - 2 + 3 * 4;let a = 1 * 2 + 3'
/*
let str = `let  a1= 1;let  a2 = [1,2,
    3]
 let a3=a1;let  a4 :String= 456;let a5 = (a,b,c){let x = 5;};a5(p)
 x
 y
 z
 q;
 if x {let b = 5; let c = 6;} else {let d = 7};
 if k {let f = 1;} else if i {let g = 2;let j = 3;} else {let h = 3};
 let y = 5 + 2 * 3 + 4;
 `;
 */
//let y = 5 + 2 * 3 + 4;
//let str = `let a5 = (a,b,c){let x = 5;}`;

let token;// = new Token(null, '');
let tokens = [];

class Node {
    type
    value
    children
}

class Token {
    static ASSIGN = 'ASSIGN'
    static IF = 'IF'
    static ELSE = 'ELSE'
    static IDENTIFY = 'IDENTIFY'
    static NUMBER = 'NUMBER'
    static EQUAL = '='
    static COLON = ':'
    static COMMA = ','
    static SEMICOLON = ';'
    static BLANK = ' '
    static NEW_LINE = 'NEW_LINE'
    static BIN_OP = 'BIN_OP'

    static LEFT_PARENTHESIS = '('
    static RIGHT_PARENTHESIS = ')'
    static LEFT_SQUARE_BRACKETS = '['
    static RIGHT_SQUARE_BRACKETS = ']'
    static LEFT_BRACE = '{'
    static RIGHT_BRACE = '}'
    static EOF = 'EOF';

    type
    value
    constructor(type, value) {
        this.type = type
        this.value = value
        tokens.push(this)
    }
}

class Statement {

}

class AssignStatement {
    variable
    type
    value
}


//Token
const getToken = (skipNewline = true, skipSpace = true) => {
    let char = peek();
    if (char !== '') {
        if (char.match(/[A-Za-z]/)) {
            let id = char;
            while (char.match(/[A-Za-z0-9]/)) {
                eat()
                char = peek();
                if (char.match(/[A-Za-z0-9]/)) {
                    id += char
                }
            }
            if (id === 'let') {
                token = new Token(Token.ASSIGN)
                return token
            } else if (id === 'if') {
                token = new Token(Token.IF)
                return token
            } else if (id === 'else') {
                token = new Token(Token.ELSE)
                return token
            } else {
                token = new Token(Token.IDENTIFY, id)
                return token
            }
        } else if (char.match(/[-+*]/)) {
            eat()
            token = new Token(Token.BIN_OP, char);
            return token
        } else if (char.match(/=/)) {
            eat()
            token = new Token(Token.EQUAL);
            return token
        } else if (char.match(/:/)) {
            eat()
            token = new Token(Token.COLON);
            return token
        } else if (char.match(/,/)) {
            eat()
            token = new Token(Token.COMMA)
            return token
        } else if (char.match(/;/)) {
            eat()
            token = new Token(Token.SEMICOLON)
            return token
        } else if (char.match(/[(]/)) {
            eat()
            token = new Token(Token.LEFT_PARENTHESIS)
            return token
        } else if (char.match(/[)]/)) {
            eat()
            token = new Token(Token.RIGHT_PARENTHESIS)
            return token
        } else if (char.match(/[[]/)) {
            eat()
            token = new Token(Token.LEFT_SQUARE_BRACKETS)
            return token
        } else if (char.match(/[\]]/)) {
            eat()
            token = new Token(Token.RIGHT_SQUARE_BRACKETS)
            return token
        } else if (char.match(/[{]/)) {
            eat()
            token = new Token(Token.LEFT_BRACE)
            return token
        } else if (char.match(/[}]/)) {
            eat()
            token = new Token(Token.RIGHT_BRACE)
            return token
        } else if (char.match(/\n/)) {
            if (skipNewline) {
                eat();
                token = getToken(skipNewline, skipSpace)
                return token
            } else {
                eat();
                token = new Token(Token.NEW_LINE)
                return token
            }
        } else if (char.match(/\s/)) {
            let space = char;
            while (char.match(/\s/)) {
                eat()
                char = peek();
                if (char.match(/\s/)) {
                    space += char
                }
            }

            if (skipSpace) {
                token = getToken(skipNewline, skipSpace)
                //tokens.push(token)
                return token;
            } else {
                token = new Token(Token.BLANK, space)
                return token
            }
        } else if (char.match(/[0-9.]/)) {
            let number = char;
            while (char.match(/[0-9.]/)) {
                eat()
                char = peek();
                if (char.match(/[0-9.]/)) {
                    number += char
                }
            }
            token = new Token(Token.NUMBER, number);
            return token
        } else {
            eat()
            token = new Token(null, char)
            return token
        }
    } else {
        token = new Token(Token.EOF)
        return Token.EOF
    }
}

const peek = () => {
    if (str === '') {
        return '';
    }
    return str[0];
}

const eat = () => {
    str = str.substring(1);
}

class Ast {
    type

    constructor(type) {
        this.type = type
    }

    static STATEMENTS = 'STATEMENTS';
    static STATEMENT = 'STATEMENT';
    static ASSIGN = 'ASSIGN';
    static IF = 'IF';
    static IF_UNIT = 'IF_UNIT';
    static VALUE = 'VALUE';
    static NUMBER = 'NUMBER';
    static IDENTITY = 'IDENTITY';
    static ARRAY = 'ARRAY';
    static FUNCTION = 'FUNCTION';
    static FUNCTION_CALL = 'FUNCTION_CALL';
    static BIN_OP = 'BIN_OP';
}

class StatementAst extends Ast {
    statement
    constructor(statement) {
        super(Ast.STATEMENT)
        this.statement = statement
    }
}
class StmtAst extends Ast {
    statements
    constructor(statements) {
        super(Ast.STATEMENTS)
        this.statements = statements
    }
}

class AssignStmtAst extends Ast {
    assignType
    variable
    value
    constructor(type, variable, value) {
        super(Ast.ASSIGN)
        this.assignType = type
        this.variable = variable
        this.value = value
    }
}

class IfStmtAst extends StmtAst {
    matchBodies
    elseBody
    constructor(matchBodies, elseBody) {
        super(Ast.IF)
        this.matchBodies = matchBodies
        this.elseBody = elseBody
    }
}

class IfUnitStmtAst extends StmtAst {
    contition
    body
    constructor(condition, body) {
        super(Ast.IF_UNIT)
        this.contition = condition
        this.body = body
    }
}

class ExprAst extends Ast {
}

class NumberExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.NUMBER)
        this.value = value
    }
}

class IdentityExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.IDENTITY)
        this.value = value
    }
}

class ArrayExprAst extends ExprAst {
    constructor(value) {
        super(Ast.ARRAY)
        this.value = value
    }
}

class FunctionExprAst extends ExprAst {
    parameters
    body
    constructor(parameters, body) {
        super(Ast.FUNCTION)
        this.parameters = parameters
        this.body = body
    }
}

class FunctionCallAst extends ExprAst {
    name
    parameters
    constructor(name, parameters) {
        super(Ast.FUNCTION_CALL)
        this.name = name
        this.parameters = parameters
    }
}

class BinOpExprAst extends ExprAst {
    op
    lhs
    rhs
    constructor(op, lhs, rhs) {
        super(Ast.BIN_OP)
        this.op = op;
        this.lhs = lhs;
        this.rhs = rhs;
    }
}

const parseBinOpUnit = (lastPrecedence, lhs) => {
    const precedence = getBinOpPrecedence(token.value)
    const op = token.value;
    if (token.type !== Token.BIN_OP || precedence <= lastPrecedence) {
        return lhs;
    } else {
        getToken()
        return new BinOpExprAst(op, lhs, parseBinOpUnit(precedence, parseValue()))
    }
}

const parseBinOp = (lhs) => {
    while (token.type === Token.BIN_OP) {
        lhs = parseBinOpUnit(0, lhs)
    }
    return lhs
}

const parseValue = () => {
    if (token.type === Token.NUMBER) { // value
        let t = token;
        getToken()
        return new NumberExprAst(t.value)
    } else if (token.type === Token.IDENTIFY) { // value
        let t = token;
        getToken()

        if (token.type === Token.LEFT_PARENTHESIS) {
            const paramValues = [];
            let t4 = getToken();
            if (t4.type !== Token.RIGHT_PARENTHESIS) {
                while (true) {
                    if (t4.type === Token.IDENTIFY) {
                        paramValues.push(new IdentityExprAst(t4.value));
                    } else if (t4.type === Token.NUMBER) {
                        paramValues.push(new NumberExprAst(t4.value));
                    }
                    let t5 = getToken()
                    if (t5.type === Token.COMMA) {
                        t4 = getToken()
                        continue;
                    } else if (t5.type === Token.RIGHT_PARENTHESIS) {
                        break;
                    }
                    t4 = getToken()
                };
            }
            getToken(false)

            if (token.type === Token.NEW_LINE) {
                getToken();
            }

            return new FunctionCallAst(t, paramValues)
        }
        return new IdentityExprAst(t.value)
    } else if (token.type === Token.LEFT_SQUARE_BRACKETS) {
        const arrValues = [];
        let t4;
        do {
            t4 = getToken()
            if (t4.type === Token.IDENTIFY || t4.type === Token.NUMBER) {
                arrValues.push(parseValue());
            }
            if (token.type === Token.COMMA) {
                continue;
            } else if (token.type === Token.RIGHT_SQUARE_BRACKETS) {
                break;
            }
        } while (true);
        getToken()
        return new ArrayExprAst(arrValues)
    } else if (token.type === Token.LEFT_PARENTHESIS) {
        const paramValues = [];
        let t4 = getToken();
        if (t4.type !== Token.RIGHT_PARENTHESIS) {
            while (true) {
                if (t4.type === Token.IDENTIFY) {
                    paramValues.push(t4.value);
                }
                let t5 = getToken()
                if (t5.type === Token.COMMA) {
                    t4 = getToken()
                    continue;
                } else if (t5.type === Token.RIGHT_PARENTHESIS) {
                    break;
                }
                t4 = getToken()
            };
        }
        getToken()

        if (token.type === Token.LEFT_BRACE) {
            //getToken()
            return new FunctionExprAst(paramValues, parseBlock());
        } else {

        }
    }
}

const parseBlock = () => {
    const ast = new StmtAst([]);

    if (token.type === Token.LEFT_BRACE) {
        getToken()
        while (token.type && str) {
            ast.statements.push(parseStatement());
            //let t7 = getToken(false)
            if (token.type === Token.SEMICOLON) {
                getToken()
            }
            if (token.type === Token.RIGHT_BRACE || token.type === Token.EOF) {
                break;
            }
        }
    }
    getToken()

    return ast;
}

const parseStatements = () => {
    const ast = new StmtAst([]);
    while (token.type && token.type !== Token.EOF) {
        const statement = parseStatement();
        if (statement) {
            ast.statements.push(statement);
        }
        if (token.type === Token.SEMICOLON) {
            getToken()
        }
    }

    return ast
}

const parseStatement = () => {
    console.dir(token);
    if (token.type === Token.ASSIGN) { // let
        let t1 = getToken();
        if (t1.type === Token.IDENTIFY) { //id
            let t2 = getToken();
            if (t2.type === Token.EQUAL) { // =
                let t3 = getToken()
                if (t3.type === Token.NUMBER || t3.type === Token.IDENTIFY || t3.type === Token.LEFT_SQUARE_BRACKETS || t3.type === Token.LEFT_PARENTHESIS) {
                    let valueAst = parseValue()
                    if (token.type === Token.BIN_OP) {
                        valueAst = parseBinOp(valueAst)
                    }
                    const ast = new AssignStmtAst(null, t1.value, valueAst);
                    //TODO exp

                    //getToken(false)
                    return ast;
                }
            } else if (t2.type === Token.COLON) { // :
                let t4 = getToken()
                if (t4.type === Token.IDENTIFY) { // type
                    let t5 = getToken()
                    if (t5.type === Token.EQUAL) { // =
                        let t6 = getToken();
                        if (t6.type === Token.NUMBER || t6.type === Token.IDENTIFY || t6.type === Token.LEFT_SQUARE_BRACKETS) {
                            const ast = new AssignStmtAst(t4.value, t1.value, parseValue());
                            //TODO exp
                            //getToken(false);
                            return ast;
                        }
                    }

                }
            }
        }
        //console.dir(t);
    } else if (token.type === Token.IDENTIFY) {
        const valueAst = parseValue();
        //getToken()
        return valueAst;
    } else if (token.type === Token.IF) {
        getToken();

        const matchBodies = [];
        matchBodies.push(new IfUnitStmtAst(parseValue(), parseBlock()));
        let elseBody;
        if (token.type === Token.ELSE) {
            while (token.type === Token.ELSE) {
                getToken();
                if (token.type === Token.IF) {
                    getToken();
                    matchBodies.push(new IfUnitStmtAst(parseValue(), parseBlock()));
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
    } else {
        console.log("token", token)
        throw new Error()
    }
}

const getBinOpPrecedence = (op) => {
    const map = new Map();
    map.set('-', 5);
    map.set('+', 10);
    map.set('*', 20);
    return map.get(op);
}

//let lastPrecedence = 0;
//str = `${str}`;
getToken()
console.log(JSON.stringify(parseStatements(), null, 2))
console.log(tokens);