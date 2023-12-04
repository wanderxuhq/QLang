//const source = `let bool = true || false;let a=  -1; let x = ((2)); let c = (1 + 2) * 3;let a5 = (a,b,c){let x = 5;}
//let d = (g){let k = 1 * 3 + 2 * 4; let l = n}`;
/*
const source = `let i=1
while i <= 9{
    let j = 1
    while j<=i{
        let j=j+1
    }
    let j=1
    let i=i+1
}`
*/
//const source = `let y = 1+2+3*4*5`;
/*
let source = `let  a1= 1;let  a2 = [1,2,
    3]
 let a3=a1;let  a4 :String= 456;let a5 = (a,b,c){let x = 5;};a5(p)
 x
 y
 z
 q;
 if x {let b = 5; let c = 6;} else {let d = 7};
 if k {let f = 1;} else if i {let g = 2;let j = 3;} else {let h = 3};
 let y = 5 + 2 * 3 + 4 * 6;let x = 1+ 2 + 3;let z = (1 - 2 + 3 * 4);let a = 1 * 2 + -3;
 let s = "Hello\\nworld";
 let o = {a: F, b = 3
     c :String = "strvalue",
     f = (p) {
        print(this.a)
      }}
 `;
 */

let source = `
let n = 1
let b = true
let s = "hello world"
let s1 = "value of n is "
let arr = [1, 2, "str", s]
let c = b
print(arr[0])
let t: String ="typed variable"
let st = {
  a: Number = 2,
  b = "str",
  c = n,
  d: String,
  f = (p) {
    print(this.a)
  },
  g = f(1)
}
print(st.a)
print(st.d) //null/novalue
st.d = "struct variable"
print(st.d) //struct variable

let o2 = {
  x = "string1"
  y = 6
}

let f = (p1, p2) {
  return p1 * 3 + p2
}
f(3, 4)
let fib = (n) {
  if n == 0 || n == 1 {
     return n     
  } else {
    return fib(n - 2) + fib(n - 1)
  }
}
if n > 10 {
  print(10)
} else if n > 1{
  print(1)
} else {
  print(0)
}
while i <= 9{
    let j = 1
    while j<=i{
        let j=j+1
    }
    let j=1
    let i=i+1
}
let s
s = 0
`
/*
source = `
let i=1
while (i<=9){
	let j=1
	while j<=i{
		print(j+"*"+i+"="+i*j+"\\t") 
		j=j+1
	}
	print("\\n")
	j=1
	i=i+1
}`
*/
let str = source;

let token;
let tokens = [];

let index = 0;
class Node {
    type
    value
    children
}

class Token {
    static DECLARE = 'DECLARE'
    static IF = 'IF'
    static ELSE = 'ELSE'
    static WHILE = 'WHILE'
    static RETURN = 'RETURN'
    static IDENTITY = 'IDENTITY'
    static NUMBER = 'NUMBER'
    static BOOLEAN = 'BOOLEAN'
    static STRING = 'STRING'
    static EQUAL = '='
    static COLON = ':'
    static COMMA = ','
    static SEMICOLON = ';'
    static BLANK = ' '
    static NEW_LINE = 'NEW_LINE'

    static LEFT_PARENTHESIS = '('
    static RIGHT_PARENTHESIS = ')'
    static LEFT_SQUARE_BRACKETS = '['
    static RIGHT_SQUARE_BRACKETS = ']'
    static LEFT_BRACE = '{'
    static RIGHT_BRACE = '}'
    static EOF = 'EOF';
    static SYMBOL = 'SYMBOL';

    static COMMENT = 'COMMENT'
    type
    value
    position
    constructor(type, value) {
        this.type = type
        this.value = value
        this.position = index
        tokens.push(this)
    }
}

class Statement {

}

class DeclareStatement {
    variable
    type
    value
}


//Token
const getToken = (skipNewline = true, skipSpace = true, skipComment = true) => {
    let char = peek();
    //let symbol = char;
    if (char !== '') {


        //if (isBinOpSymbol(char)) {
        let symbol = '';
        const binOpSymbols = Array.from(binOpPrecedence.keys()).join('');
        while (binOpSymbols.indexOf(char) > -1) {
            symbol = `${symbol}${char}`
            eat()
            char = peek();
        }
        /*
        while (binOpSymbols.find(e => e.startsWith(`${symbol}${char}`))) {
            symbol = `${symbol}${char}`
            eat()
            char = peek();
        }*/
        if (isBinOpSymbol(symbol)) {
            token = new Token(Token.SYMBOL, symbol)
            return token;
        } else {
            str = `${symbol}${str}`
            char = peek()
        }
        //}

        let match = false;
        if (char.match(/[A-Za-z]/)) {
            let id = char;
            while (char.match(/[A-Za-z0-9]/)) {
                eat()
                char = peek();
                if (char.match(/[A-Za-z0-9]/)) {
                    id += char
                }
            }

            match = true;
            if (id === 'let') {
                token = new Token(Token.DECLARE)
                return token
            } else if (id === 'if') {
                token = new Token(Token.IF)
                return token
            } else if (id === 'else') {
                token = new Token(Token.ELSE)
                return token
            } else if (id === 'while') {
                token = new Token(Token.WHILE)
                return token
            } else if (id === 'return') {
                token = new Token(Token.RETURN)
                return token
            } else if (id === 'true' || id === 'false') {
                token = new Token(Token.BOOLEAN, id)
                return token
            } else {
                token = new Token(Token.IDENTITY, id)
                return token
            }
        } else if (char.match(/=/)) {
            eat()
            if (peek() !== '=') {
                match = true;
                token = new Token(Token.EQUAL);
                return token
            } else {
                eat()
                //symbol += '='
            }
        } else if (char.match(/:/)) {
            match = true;
            eat()
            token = new Token(Token.COLON);
            return token
        } else if (char.match(/,/)) {
            match = true;
            eat()
            token = new Token(Token.COMMA)
            return token
        } else if (char.match(/;/)) {
            match = true;
            eat()
            token = new Token(Token.SEMICOLON)
            return token
        } else if (char.match(/[(]/)) {
            match = true;
            eat()
            token = new Token(Token.LEFT_PARENTHESIS)
            return token
        } else if (char.match(/[)]/)) {
            match = true;
            eat()
            token = new Token(Token.RIGHT_PARENTHESIS)
            return token
        } else if (char.match(/[[]/)) {
            match = true;
            eat()
            token = new Token(Token.LEFT_SQUARE_BRACKETS)
            return token
        } else if (char.match(/[\]]/)) {
            match = true;
            eat()
            token = new Token(Token.RIGHT_SQUARE_BRACKETS)
            return token
        } else if (char.match(/[{]/)) {
            match = true;
            eat()
            token = new Token(Token.LEFT_BRACE)
            return token
        } else if (char.match(/[}]/)) {
            match = true;
            eat()
            token = new Token(Token.RIGHT_BRACE)
            return token
        } else if (char.match(/\n/)) {
            if (skipNewline) {
                eat();
                token = getToken(skipNewline, skipSpace)
                match = true;
                return token
            } else {
                eat();
                token = new Token(Token.NEW_LINE)
                match = true;
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
                match = true;
                return token;
            } else {
                token = new Token(Token.BLANK, space)
                match = true;
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
            match = true;
            token = new Token(Token.NUMBER, number);
            return token
        } else if (char.match(/["`']/)) {
            const strSymbol = char;
            let string = '';
            eat()
            char = peek()
            while (char !== strSymbol) {
                if (char === '\\') {
                    eat()
                    char = peek()
                    if (char === 'n') {
                        string += '\n'
                    } else if (char === 't') {
                        string += '\t'
                    } else if (char === '\\') {
                        string += '\\\\'
                    }
                } else {
                    string += char;
                }
                eat()
                char = peek()
            }
            eat()

            match = true;
            token = new Token(Token.STRING, string);
            return token;
        } else if (char.match(/\//)) {
            eat()
            char = peek()
            let comment = ''
            if (char.match(/\//)) {
                while (char !== '\n') {
                    eat()
                    char = peek()
                    comment += char
                }
                comment = comment.substring(0, comment.length - 1)
                if (!skipComment) {
                    match = true
                    token = new Token(Token.COMMENT, comment)
                    return token
                } else {
                    match = true
                    token = getToken(skipNewline, skipSpace, skipComment)
                    return token
                }
            } else if (char.match(/[*]/)) {
                while (true) {
                    eat()
                    char = peek()
                    comment += char

                    if (char === '*') {
                        eat()
                        char = peek()
                        if (char === '/') {
                            eat()
                            break;
                        }
                    }
                }
                comment = comment.substring(0, comment.length - 1)
                if (!skipComment) {
                    match = true
                    token = new Token(Token.COMMENT, comment)
                    return token
                } else {
                    match = true
                    token = getToken(skipNewline, skipSpace, skipComment);
                    return token
                }
            }
        }

        if (!match && isBinOpSymbol(char)) {
            let symbol = '';
            const binOpSymbols = Array.from(binOpPrecedence.keys());
            while (binOpSymbols.find(e => e.startsWith(`${symbol}${char}`))) {
                symbol = `${symbol}${char}`
                eat()
                char = peek();
            }
            token = new Token(Token.SYMBOL, symbol)
            return token;
        } else {
            return token;
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
    index++
}

class Ast {
    type

    constructor(type) {
        this.type = type
    }

    static STATEMENTS = 'STATEMENTS';
    static STATEMENT = 'STATEMENT';
    static DECLARE = 'DECLARE';
    static ASSIGN = 'ASSIGN';
    static IF = 'IF';
    static IF_UNIT = 'IF_UNIT';
    static WHILE = 'WHILE';
    static RETURN = 'RETURN';
    static VALUE = 'VALUE';
    static NUMBER = 'NUMBER';
    static BOOLEAN = 'BOOLEAN';
    static STRING = 'STRING';
    static OBJECT = 'OBJECT';
    static IDENTITY = 'IDENTITY';
    static ARRAY = 'ARRAY';
    static ARRAY_INDEX = 'ARRAY_INDEX';
    static FUNCTION = 'FUNCTION';
    static FUNCTION_CALL = 'FUNCTION_CALL';
    static BIN_OP = 'BIN_OP';

    accept(visitor) {
        return visitor.visit(this)
    }
}

class StatementAst extends Ast {
    statement
    constructor(statement) {
        super(Ast.STATEMENT)
        this.statement = statement
    }
}
class StmtsAst extends Ast {
    statements
    constructor(statements) {
        super(Ast.STATEMENTS)
        this.statements = statements
    }
}

class DeclareStmtAst extends Ast {
    declareType
    variable
    value
    constructor(type, variable, value) {
        super(Ast.DECLARE)
        this.declareType = type
        this.variable = variable
        this.value = value
    }
}


class AssignStmtAst extends Ast {
    variable
    value
    constructor(variable, value) {
        super(Ast.ASSIGN)
        this.variable = variable
        this.value = value
    }
}

class ReturnStmtAst extends Ast {
    value
    constructor(value) {
        super(Ast.RETURN)
        this.value = value
    }
}

class IfStmtAst extends Ast {
    matchBodies
    elseBody
    constructor(matchBodies, elseBody) {
        super(Ast.IF)
        this.matchBodies = matchBodies
        this.elseBody = elseBody
    }
}

class IfUnitStmtAst extends Ast {
    condition
    body
    constructor(condition, body) {
        super(Ast.IF_UNIT)
        this.condition = condition
        this.body = body
    }
}

class WhileStmtAst extends Ast {
    condition
    body
    constructor(condition, body) {
        super(Ast.WHILE)
        this.condition = condition
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

class BooleanExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.BOOLEAN)
        this.value = value
    }
}

class StringExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.STRING)
        this.value = value
    }
}

class ObjectExprAst extends ExprAst {
    fields
    constructor(fields) {
        super(Ast.OBJECT)
        this.fields = fields
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

class ArrayIndexExprAst extends ExprAst {
    constructor(name, value) {
        super(Ast.ARRAY_INDEX)
        this.name = name
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

const isValueAst = (ast) => {
    return ast.type === Ast.NUMBER
        || ast.type === Ast.IDENTITY
        || ast.type === Ast.BOOLEAN
        || ast.type === Ast.STRING
        || ast.type === Ast.ARRAY
        || ast.type === Ast.OBJECT
        || ast.type === Ast.FUNCTION
        || ast.type === Ast.FUNCTION_CALL
        || ast.type === Ast.BIN_OP
}

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
    map.set('.', 90);

    return map;
})();

const getBinOpPrecedence = (op) => {
    return binOpPrecedence.get(op);
}

const isBinOpSymbol = (char) => {
    return binOpPrecedence.has(char)
}

const isBinOpToken = (token) => {
    return token.type === Token.SYMBOL && isBinOpSymbol(token.value)
}

const isValueToken = (token) => {
    return token.type === Token.NUMBER
        || token.type === Token.IDENTITY
        || token.type === Token.BOOLEAN
        || token.type === Token.STRING
        || token.type === Token.LEFT_SQUARE_BRACKETS
        || token.type === Token.LEFT_PARENTHESIS
        || token.type === Token.LEFT_BRACE
        || isBinOpToken(token)
}

const parseBinOpUnit = (lhs) => {
    const op = token;
    getToken()
    let rhs = parseValue()

    let next = token
    while (isBinOpToken(next) && getBinOpPrecedence(op.value) < getBinOpPrecedence(next.value)) {
        rhs = parseBinOpUnit(rhs)
        next = token
    }

    return new BinOpExprAst(op.value, lhs, rhs)
}


const parseBinOp = (value) => {
    let next = token
    while (isBinOpToken(next)) {
        value = parseBinOpUnit(value)

        next = token
    }
    return value
}

const parseValue = () => {
    if (token.type === Token.NUMBER) {
        let t = token;
        getToken()
        return new NumberExprAst(t.value)
    } else if (token.type === Token.BOOLEAN) {
        let t = token;
        getToken()

        return new BooleanExprAst(t.value)
    } else if (token.type === Token.STRING) {
        let t = token
        getToken()

        return new StringExprAst(t.value)
    } else if (token.type === Token.IDENTITY) {
        let t = token;
        getToken()

        if (token.type === Token.LEFT_PARENTHESIS) {
            const paramValues = [];
            let t4 = getToken();
            if (t4.type !== Token.RIGHT_PARENTHESIS) {
                while (true) {
                    if (isValueToken(t4)) {
                        paramValues.push(parseBinOp(parseValue()));
                    }
                    let t5 = token
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
        } else if (token.type === Token.LEFT_SQUARE_BRACKETS) {
            getToken();
            const value = parseBinOp(parseValue());
            if (token.type === Token.RIGHT_SQUARE_BRACKETS) {
                const arrayIndexToken = new ArrayIndexExprAst(t, value);
                getToken();

                return arrayIndexToken;
            } else {
                //TODO error
            }
        }
        return new IdentityExprAst(t.value)
    } else if (isBinOpToken(token) && (token.value === '+' || token.value === '-')) {
        const op = token;
        getToken()
        return new BinOpExprAst(op.value, new NumberExprAst(0), parseValue());
    } else if (token.type === Token.LEFT_SQUARE_BRACKETS) {
        const arrValues = [];
        let t4;
        do {
            t4 = getToken()
            if (isValueToken(t4)) {
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
        let t4 = getToken();
        //, + ( )

        if (t4.type !== Token.IDENTITY) {
            let v = parseBinOp(parseValue())
            if (token.type === Token.RIGHT_PARENTHESIS) {
                getToken()
            } else {
                // Parenthesis mis match
            }
            return v
        }

        let t8 = getToken();
        const paramValues = [];
        if (t8.type === Token.COMMA) {
            if (t4.type === Token.IDENTITY) {
                paramValues.push(t4.value);
            }
            while (true) {
                t4 = getToken()
                if (t4.type === Token.IDENTITY) {
                    paramValues.push(t4.value);
                }
                let t5 = getToken()
                if (t5.type === Token.COMMA) {
                    continue;
                } else if (t5.type === Token.RIGHT_PARENTHESIS) { //(x,y,z)
                    break;
                } else {
                    //break;
                }
                //t4 = getToken()
            };
            getToken()
            if (token.type === Token.LEFT_BRACE) {
                //getToken()
                return new FunctionExprAst(paramValues, parseBlock());
            } else {

            }
        } else if (t8.type === Token.RIGHT_PARENTHESIS) {
            getToken()

            if (token.type === Token.LEFT_BRACE) {
                paramValues.push(t4.value)
                return new FunctionExprAst(paramValues, parseBlock());
            } else {
                const v = parseValue();
                if (token.type === Token.RIGHT_PARENTHESIS) {
                    getToken()
                    return v;
                }
            }
        } else {
            const v = parseBinOp(new IdentityExprAst(t4.value));
            if (token.type === Token.RIGHT_PARENTHESIS) {
                getToken()
            } else {
                //TODO error
            }

            return v
        }
    } else if (token.type === Token.LEFT_BRACE) {
        getToken()

        const fields = [];
        while (token.type === Token.IDENTITY) {
            const identity = new IdentityExprAst(token.value)
            let type
            let value
            getToken()
            if (token.type === Token.EQUAL) {
                getToken()
                value = parseBinOp(parseValue())
                //fields.push();
            } else if (token.type === Token.COLON) {
                getToken()
                if (token.type === Token.IDENTITY) {
                    type = new IdentityExprAst(token.value)
                } else {
                    // error
                }
                getToken();
                if (token.type === Token.EQUAL) {
                    getToken()
                    if (isValueToken(token)) {
                        value = parseBinOp(parseValue())
                    }
                }
            }

            if (token.type === Token.NEW_LINE || token.type == Token.COMMA) {
                getToken()
            }
            fields.push({ identity: identity, type: type, value: value });
        }

        if (token.type === Token.RIGHT_BRACE) {
            getToken()
        }

        return new ObjectExprAst(fields);
    }
}

const parseBlock = () => {
    let ast;

    if (token.type === Token.LEFT_BRACE) {
        getToken()
        ast = parseStatements()

    }
    if (token.type === Token.RIGHT_BRACE || token.type === Token.EOF) {
        //break;
        getToken()
    }

    return ast;
}

const parseStatements = () => {
    const ast = new StmtsAst([]);
    while (token.type && token.type !== Token.EOF && token.type !== Token.RIGHT_BRACE) {
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
}

//let lastPrecedence = 0;
//str = `${str}`;
getToken()

const ast = parseStatements();

console.log(source);
console.log(JSON.stringify(ast, null, 2))
console.log(source);



class Visitor {
    visit(t) {
        return null
    }
}

class MapVisitor {
    visitors
    constructor(visitors) {
        this.visitors = visitors
    }
}

console.log();
const compiler = (() => {
    const statementsVisitor = {}, declareVisitor = {}, assignVisitor = {}, returnVisitor = {}, valueVisitor = {}, ifVisitor = {}, whileVisitor = {};
    statementsVisitor.visit = (statementsAst) => {
        let stmt = ''
        for (const statement of statementsAst.statements) {
            if (statement.type === Ast.DECLARE) {
                stmt += statement.accept(declareVisitor)
            } else if (statement.type === Ast.ASSIGN) {
                stmt += statement.accept(assignVisitor)
            } else if (statement.type === Ast.RETURN) {
                stmt += statement.accept(returnVisitor)
            } else if (isValueAst(statement)) {
                stmt += statement.accept(valueVisitor)
            } else if (statement.type === Ast.IF) {
                stmt += statement.accept(ifVisitor)
            } else if (statement.type === Ast.WHILE) {
                stmt += statement.accept(whileVisitor)
            }
            stmt += ';\n'
        }

        console.log(stmt)

        return stmt;
    }
    declareVisitor.visit = (declareStmtAst) => {
        let stmt = `let ${declareStmtAst.variable}`

        stmt += ` = ${declareStmtAst.value?.accept(valueVisitor)}`;

        return stmt;
    }
    assignVisitor.visit = (assignStmtAst) => {
        let stmt = `let ${assignStmtAst.variable}`

        stmt += ` = ${assignStmtAst.value?.accept(valueVisitor)}`;

        return `${assignStmtAst.variable.accept(valueVisitor)} = ${assignStmtAst.value.accept(valueVisitor)}`;
    }
    returnVisitor.visit = (returnStmtAst) => {
        return `return ${returnStmtAst.value?.accept(valueVisitor)}`;
    }
    valueVisitor.visit = (ast) => {
        let numberVisitor = {}, identityVisitor = {}, booleanVisitor = {}, stringVisitor = {}, binOpVisitor = {}, arrayVisitor = {}, objectVisitor = {}, functionVisitor = {}, functionCallVisitor = {}

        numberVisitor.visit = (numberExprAst) => {
            return numberExprAst.value
        }
        identityVisitor.visit = (identityExprAst) => {
            return identityExprAst.value
        }
        booleanVisitor.visit = (booleanExprAst) => {
            return booleanExprAst.value
        }
        stringVisitor.visit = (stringExprAst) => {
            return `"${stringExprAst.value.replace('\n', '\\n').replace('\t', '\\t')}"`;
        }
        binOpVisitor.visit = (binOpExprAst) => {
            return `(${binOpExprAst.lhs.accept(valueVisitor)}${binOpExprAst.op}${binOpExprAst.rhs.accept(valueVisitor)})`;
        }
        arrayVisitor.visit = (arrayExprAst) => {
            return `[ ${arrayExprAst.value.map(e => e.accept(valueVisitor)).join(', ')} ]`;
        }
        objectVisitor.visit = (objectExprAst) => {
            return "{\n" + objectExprAst.fields.map(e => `${e.identity.value}: ${e.value?.accept(valueVisitor)}`).join(',\n') + "\n}"
        }
        functionVisitor.visit = (functionExprAst) => {
            return `(${functionExprAst.parameters.join(', ')}) => {\n${functionExprAst.body.accept(statementsVisitor)}}`
        }
        functionCallVisitor.visit = (functionCallExprAst) => {
            return `${functionCallExprAst.name.value}(${functionCallExprAst.parameters.map(e => e.accept(valueVisitor)).join(', ')})`
        }

        if (ast.type === Ast.NUMBER) {
            return ast.accept(numberVisitor)
        } else if (ast.type === Ast.IDENTITY) {
            return ast.accept(identityVisitor)
        } else if (ast.type === Ast.BOOLEAN) {
            return ast.accept(booleanVisitor)
        } else if (ast.type === Ast.STRING) {
            return ast.accept(stringVisitor)
        } else if (ast.type === Ast.BIN_OP) {
            return ast.accept(binOpVisitor)
        } else if (ast.type === Ast.ARRAY) {
            return ast.accept(arrayVisitor)
        } else if (ast.type === Ast.OBJECT) {
            return ast.accept(objectVisitor)
        } else if (ast.type === Ast.FUNCTION) {
            return ast.accept(functionVisitor)
        } else if (ast.type === Ast.FUNCTION_CALL) {
            return ast.accept(functionCallVisitor)
        }

        return '';
    }
    ifVisitor.visit = (ifStmtAst) => {
        let stmt = '';
        const firstMatch = ifStmtAst.matchBodies.pop()
        stmt += `if (${firstMatch.condition.accept(valueVisitor)}) {\n${firstMatch.body.accept(statementsVisitor)}}`
        stmt += ifStmtAst.matchBodies.map(e => ` else if (${e.condition.accept(valueVisitor)}) {\n${e.body.accept(statementsVisitor)}}`).join('')
        if (ifStmtAst.elseBody){
            stmt += ` else {\n${ifStmtAst.elseBody.accept(statementsVisitor)}}`
        }

        return stmt
    }
    whileVisitor.visit = (whileStmtAst) => {
        return `while (${whileStmtAst.condition.accept(valueVisitor)}) {\n${whileStmtAst.body.accept(statementsVisitor)}}`
    }

    ast.accept(statementsVisitor)
})()
//console.log(tokens);