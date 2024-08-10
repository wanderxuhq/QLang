const fs = require('fs')
const source = fs.readFileSync('./demo/clojure.ql')
let str = source;

let token;
let tokens = [];

let index = 0;
let row = 0;
let col = 0;

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
            row++;
            col = 0;
            eat();
            if (skipNewline) {
                token = getToken(skipNewline, skipSpace)
                match = true;
                return token
            } else {
                token = new Token(Token.NEW_LINE)
                match = true;
                return token
            }
        } else if (char.match(/\s/)) {
            let space = char;
            while (char.match(/\s/)) {
                if (char === '\n') {
                    row++;
                    col = 0;
                }
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
    col++
}

class Ast {
    type
    index
    row
    col
    parent
    context

    constructor(type) {
        this.type = type
        this.row = row
        this.col = col
        this.index = index
        this.context = {
            scope: new Map(),
            object: new Map(),
            parameter: new Map()
        }
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
    static PARENTHESIS_LIST = 'PARENTHESIS_LIST';
    static COMMA_LIST = 'COMMA_LIST';
    static BIN_OP = 'BIN_OP';

    accept(visitor) {
        return visitor.visit(this)
    }

    inContext(variable) {
        if (this.context.scope.has(variable)) {
            const result = {
                level: 0,
                value: this.context.scope.get(variable)
            }
            //console.log(variable, result)
            return result
        } else if (this.context.parameter.has(variable)) {
            const result = {
                level: "parameter",
                value: this.context.parameter.get(variable)
            }
            //console.log(variable, result)
            return result
        } else if (this.context.object.has(variable)) {
            const result = {
                level: "object",
                value: this.context.object.get(variable)
            }
            //console.log(variable, result)
            return result
        } else {
            let parent = this.parent
            let depth = 0;
            while (parent !== undefined) {
                if (parent.context.scope.has(variable)) {
                    depth++;
                    const result = {
                        level: depth,
                        value: parent.context.scope.get(variable)
                    }
                    //console.log(variable, result)
                    return result
                }
                parent = parent.parent
            }

            return { level: -1 };
        }
    }
}

class StmtsAst extends Ast {
    statements
    constructor(statements) {
        super(Ast.STATEMENTS)
        this.statements = statements
    }

    toObject() {
        return {
            type: "STATEMENTS",
            statements: this.statements.map(e => e.toObject())
        }
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

    toObject() {
        return {
            type: "DECLARE",
            declareType: this.declareType,
            variable: this.variable,
            value: this.value.toObject()
        }
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

    toObject() {
        return {
            type: "ASSIGN",
            variable: this.variable,
            value: this.value
        }
    }
}

class ReturnStmtAst extends Ast {
    value
    constructor(value) {
        super(Ast.RETURN)
        this.value = value
    }

    toObject() {
        return {
            type: "RETURN",
            value: this.value.toObject()
        }
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

    toObject() {
        return {
            type: "IF",
            matchBodies: this.matchBodies,
            elseBody: this.elseBody
        }
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

    toObject() {
        return {
            type: "IF_UNIT",
            condition: this.condition,
            body: this.body
        }
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

    toObject() {
        return {
            type: "WHILE",
            condition: this.condition,
            body: this.body
        }
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

    toObject() {
        return {
            type: "NUMBER",
            value: this.value
        }
    }
}

class BooleanExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.BOOLEAN)
        this.value = value
    }

    toObject() {
        return {
            type: "BOOLEAN",
            value: this.value
        }
    }
}

class StringExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.STRING)
        this.value = value
    }

    toObject() {
        return {
            type: "STRING",
            value: this.value
        }
    }
}

class ObjectExprAst extends ExprAst {
    fields
    constructor(fields) {
        super(Ast.OBJECT)
        this.fields = fields
    }

    toObject() {
        return {
            type: "OBJECT",
            fields: this.fields
        }
    }
}

class IdentityExprAst extends ExprAst {
    value
    constructor(value) {
        super(Ast.IDENTITY)
        this.value = value
    }

    toObject() {
        return {
            type: "IDENTITY",
            value: this.value
        }
    }
}

class ArrayExprAst extends ExprAst {
    constructor(value) {
        super(Ast.ARRAY)
        this.value = value
    }

    toObject() {
        return {
            type: "ARRAY",
            value: this.value
        }
    }
}

class ArrayIndexExprAst extends ExprAst {
    constructor(name, value) {
        super(Ast.ARRAY_INDEX)
        this.name = name
        this.value = value
    }

    toObject() {
        return {
            type: "ARRAY_INDEX",
            value: this.value
        }
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

    toObject() {
        return {
            type: "FUNCTION",
            parameters: this.parameters,
            body: this.body.toObject()
        }
    }
}

class CommaListAstSnip extends ExprAst {
    value
    constructor(value) {
        super(Ast.COMMA_LIST)
        this.value = value
    }

    toObject() {
        return {
            type: "COMMA_LIST",
            value: this.value
        }
    }
}

class ParenthesisListAstSnip extends ExprAst {
    value
    constructor(value) {
        super(Ast.PARENTHESIS_LIST)
        this.value = value
    }

    toObject() {
        return {
            type: "PARENTHESIS_LIST",
            value: this.value
        }
    }
}

class FunctionCallAst extends ExprAst {
    fun
    parameters
    constructor(fun, parameters) {
        super(Ast.FUNCTION_CALL)
        this.fun = fun
        this.parameters = parameters
    }

    toObject() {
        return {
            type: "FUNCTION_CALL",
            fun: this.fun.toObject(),
            parameters: this.parameters
        }
    }
}

class BinOpExprAst extends ExprAst {
    op
    lhs
    rhs
    constructor(op, lhs, rhs) {
        super(Ast.BIN_OP)
        this.op = op.value;
        this.lhs = lhs;
        this.rhs = rhs;
    }

    toObject() {
        return {
            type: "BIN_OP",
            op: this.op,
            lhs: this.lhs,
            rhs: this.rhs
        }
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

    return new BinOpExprAst(op, lhs, rhs)
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
            const parenthesisList = parseParenthesisList().value

            let functionCallAst = new FunctionCallAst(t, parenthesisList[0])
            for (let i = 1; i < parenthesisList.length; i++) {
                const parenthesisResult = parenthesisList[i]
                functionCallAst = new FunctionCallAst(functionCallAst, parenthesisResult)
            }
            return functionCallAst
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
        } else if (token.type === Token.COMMA) {
            const list = new CommaListAstSnip([])

            while (token.type === Token.COMMA) {
                list.value.push(parseValue())
            }

            return list
        }
        return new IdentityExprAst(t.value)
    } else if (isBinOpToken(token) && (token.value === '+' || token.value === '-')) {
        const op = token;
        getToken()
        return new BinOpExprAst(op, new NumberExprAst(0), parseValue());
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

        if (t4.type === Token.BOOLEAN || t4.type === Token.NUMBER || t4.type === Token.STRING) {
            let v = parseBinOp(parseValue())
            if (token.type === Token.RIGHT_PARENTHESIS) {
                getToken()
            } else {
                // Parenthesis mis match
            }
            return v
        } else if (t4.type === Token.RIGHT_PARENTHESIS) {
            getToken()

            if (token.type === Token.LEFT_BRACE) {
                return new FunctionExprAst([], parseBlock());
            } else {
                const v = parseValue();
                if (token.type === Token.RIGHT_PARENTHESIS) {
                    getToken()
                    return v;
                }
            }
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

const parseParenthesisList = () => {
    let result = new ParenthesisListAstSnip([[]])
    let index = 0;
    while (token.type === Token.LEFT_PARENTHESIS) {
        getToken()
        const value = parseBinOp(parseValue());
        if (value) {
            result.value[index].push(value)
        } else {
            //novalue
        }
        while (token.type === Token.COMMA) {
            getToken();
            const value = parseValue()
            if (value) {
                result.value[index].push(value)
            } else {
                //novalue
            }
        }
        if (token.type === Token.RIGHT_PARENTHESIS) {
            getToken();
            index++
            result.value[index] = []
        } else {
            //Parenthesis mis match
        }
    }
    result.value = result.value.slice(0, result.value.length - 1);

    return result
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

/*
console.log(source);
console.log(JSON.stringify(ast, null, 2))
console.log(source);
*/
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

const semanticParser = (() => {
    const statementsVisitor = {}, declareVisitor = {}, assignVisitor = {}, returnVisitor = {}, valueVisitor = {}, ifVisitor = {}, whileVisitor = {};
    statementsVisitor.visit = (statementsAst) => {
        let maxLevel = 0;
        for (const statement of statementsAst.statements) {
            //statement.parent = statementsAst
            if (statement.type === Ast.DECLARE) {
                statementsAst.context.scope.set(statement.variable, statement.value)
                if (statement.value) {
                    //TODO replace?
                    statement.value.context.scope = statementsAst.context.scope
                    statement.value.accept(valueVisitor)
                }
            } else if (statement.type === Ast.ASSIGN) {
                statementsAst.context.scope.set(statement.variable, statement.value)
                statement.value.context.scope = statementsAst.context.scope
                statement.parent = statementsAst
                statement.value.accept(valueVisitor)
                statement.level = statement.inContext(statement.variable.value).level
            } else if (statement.type === Ast.RETURN) {
                //stmt += statement.accept(returnVisitor)
                statement.value.context.scope = statementsAst.context.scope
                statement.value.accept(valueVisitor)
            } else if (isValueAst(statement)) {
                //TODO
                statement.context.scope = statementsAst.context.scope
                statement.accept(valueVisitor)
                //stmt += statement.accept(valueVisitor)
            } else if (statement.type === Ast.IF) {
                //TODO
                statement.matchBodies.map(e => {
                    e.condition.context.scope = statementsAst.context.scope;
                    e.body.context.scope = statementsAst.context.scope;
                })
                if (statement.elseBody) {
                    statement.elseBody.context.scope = statementsAst.context.scope;
                }
                statement.parent = statementsAst
                statement.accept(ifVisitor)
            } else if (statement.type === Ast.WHILE) {
                statement.condition.context.scope = statementsAst.context.scope;
                statement.body.context.scope = statementsAst.context.scope;
                statement.accept(whileVisitor)
            }

            if (statement.level > maxLevel) {
                maxLevel = statement.level
            }
        }

        statementsAst.level = maxLevel
    }
    declareVisitor.visit = (declareStmtAst) => {

    }
    assignVisitor.visit = (assignStmtAst) => {

    }
    returnVisitor.visit = (returnStmtAst) => {

    }
    valueVisitor.visit = (ast) => {
        let numberVisitor = {}, identityVisitor = {}, booleanVisitor = {}, stringVisitor = {}, binOpVisitor = {}, arrayVisitor = {}, objectVisitor = {}, functionVisitor = {}, functionCallVisitor = {}

        numberVisitor.visit = (numberExprAst) => {
            //return numberExprAst.value
        }
        identityVisitor.visit = (identityExprAst) => {
            const inContext = ast.inContext(identityExprAst.value)
            if (inContext.level === -1) {
                console.error(`${identityExprAst.value} is not in context`)
            } else {
                identityExprAst.level = inContext.level
            }
            //return identityExprAst.value
        }
        booleanVisitor.visit = (booleanExprAst) => {
            //return booleanExprAst.value
        }
        stringVisitor.visit = (stringExprAst) => {
            //return `"${stringExprAst.value.replace('\n', '\\n').replace('\t', '\\t')}"`;
        }
        binOpVisitor.visit = (binOpExprAst) => {
            binOpExprAst.lhs.context.scope = ast.context.scope
            binOpExprAst.lhs.accept(valueVisitor)
            binOpExprAst.rhs.context.scope = ast.context.scope
            binOpExprAst.rhs.accept(valueVisitor)
            //return `(${binOpExprAst.lhs.accept(valueVisitor)}${binOpExprAst.op}${binOpExprAst.rhs.accept(valueVisitor)})`;
        }
        arrayVisitor.visit = (arrayExprAst) => {
            arrayExprAst.value.map(e => {
                e.parent = arrayExprAst.parent
                //TODO replace?
                e.context.scope = arrayExprAst.context.scope
                e.accept(valueVisitor)
            })
            //return `[ ${arrayExprAst.value.map(e => e.accept(valueVisitor)).join(', ')} ]`;
        }
        objectVisitor.visit = (objectExprAst) => {
            //TODO
            //return "{\n" + objectExprAst.fields.map(e => `${e.identity.value}: ${e.value?.accept(valueVisitor)}`).join(',\n') + "\n}"
        }
        functionVisitor.visit = (functionExprAst) => {
            functionExprAst.body.parent = functionExprAst
            functionExprAst.body.context.scope = functionExprAst.context.scope
            for (const parameter of functionExprAst.parameters) {
                //TODO scope?
                functionExprAst.body.context.scope.set(parameter, undefined)
            }
            //functionExprAst.body.parent = ast.context
            functionExprAst.body.accept(statementsVisitor)
            functionExprAst.level = functionExprAst.body.level
            functionExprAst.pure = functionExprAst.level === 0
            //return `(${functionExprAst.parameters.join(', ')}) => {\n${functionExprAst.body.accept(statementsVisitor)}}`
        }
        functionCallVisitor.visit = (functionCallExprAst) => {
            //TODO
            if (functionCallExprAst.fun.type === Ast.IDENTITY) {
                const inContext = functionCallExprAst.inContext(functionCallExprAst.fun.value);
                if (inContext.level === -1) {
                    console.error(`${functionCallExprAst.fun.value} is not in context`)
                } else if (inContext.value.type !== Ast.FUNCTION) {
                    console.error(`${functionCallExprAst.fun.value} is not in function`)
                } else {
                    functionCallExprAst.name = functionCallExprAst.fun
                    functionCallExprAst.fun = inContext.value
                    for (let i = 0; i < inContext.value.parameters.length; i++) {
                        inContext.value.context.scope.set(inContext.value.parameters[i], functionCallExprAst.parameters[i])
                    }
                    if (inContext.level > 0) {
                        functionCallExprAst.level = inContext.level - 1;
                        functionCallExprAst.pure = false;
                    } else {
                        functionCallExprAst.level = 0;
                        functionCallExprAst.pure = inContext.value.pure || functionCallExprAst.parent !== undefined
                    }
                }
            } else {
                functionCallExprAst.fun.context.scope = functionCallExprAst.context.scope
                functionCallVisitor.visit(functionCallExprAst.fun)
            }
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
        ifStmtAst.matchBodies.map(e => {
            e.condition.accept(valueVisitor)
            e.body.accept(statementsVisitor)
        })

        if (ifStmtAst.elseBody) {
            ifStmtAst.elseBody.accept(statementsVisitor)
        }
    }
    whileVisitor.visit = (whileStmtAst) => {
        whileStmtAst.condition.accept(valueVisitor)
        whileStmtAst.body.accept(statementsVisitor)
    }

    ast.accept(statementsVisitor)
    //console.log(ast)
})()

//console.log(ast)
console.log(JSON.stringify(ast.toObject(), null, 2));

const runtime = (() => {

    const runStatements = (ast, envStack) => {
        const env = envStack[envStack.length - 1]

        for (const statement of ast.statements) {
            if (isValueAst(statement)) {
                runValue(statement, envStack)
            } else if (statement.type === Ast.DECLARE) {
                //env.push(a)
                env.set(statement.variable, runValue(statement.value, envStack))
            } else if (statement.type === Ast.ASSIGN) {
                env.set(statement.variable.value, runValue(statement.value, envStack))
            } else if (statement.type === Ast.FUNCTION_CALL) {
                //env.set(statement.name, statement)
                runFunction(statement, envStack)
            } else if (statement.type === Ast.RETURN) {
                return runValue(statement.value, envStack)
            } else if (statement.type === Ast.IF) {
                let match = false
                for (const matchBody of statement.matchBodies) {
                    if (runValue(matchBody.condition, envStack)) {
                        match = true
                        return runStatements(matchBody.body, envStack)
                    }
                }

                if (!match) {
                    return runStatements(statement.elseBody, envStack)
                }
            } else if (statement.type === Ast.WHILE) {
                while (runValue(statement.condition, envStack)) {
                    runStatements(statement.body, envStack)
                }
            }
        }
    }

    const findInEnvStack = (key, envStack) => {
        for (let i = envStack.length - 1; i >= 0; i--) {
            const env = envStack[i];
            if (env.has(key)) {
                return {
                    env: env,
                    value: env.get(key)
                }
            }
        }
    }

    const runValue = (ast, envStack) => {
        /*
        let numberVisitor = {},
            identityVisitor = {},
            booleanVisitor = {},
            stringVisitor = {},
            binOpVisitor = {},
            arrayVisitor = {},
            objectVisitor = {},
            functionVisitor = {},
            functionCallVisitor = {}
            */
        if (ast.type === Ast.NUMBER) {
            return Number(ast.value)
        } else if (ast.type === Ast.IDENTITY) {
            const v = findInEnvStack(ast.value, envStack);
            if (v) {
                return v.value
            } else {
                //TODO novalue
            }
        } else if (ast.type === Ast.STRING) {
            return ast.value
        } else if (ast.type == Ast.BOOLEAN) {
            return ast.value
        } else if (ast.type == Ast.OBJECT) {
            const obj = {}
            for (const field of ast.fields) {
                obj[field.identity.value] = runValue(field.value, envStack)
            }
            return obj;
        } else if (ast.type === Ast.BIN_OP) {
            if (ast.op === '+') {
                return runValue(ast.lhs, envStack) + runValue(ast.rhs, envStack)
            } else if (ast.op === '-') {
                return runValue(ast.lhs, envStack) - runValue(ast.rhs, envStack)
            } else if (ast.op === '*') {
                return runValue(ast.lhs, envStack) * runValue(ast.rhs, envStack)
            } else if (ast.op === '/') {
                return runValue(ast.lhs, envStack) / runValue(ast.rhs, envStack)
            } else if (ast.op === '&&') {
                return runValue(ast.lhs, envStack) && runValue(ast.rhs, envStack)
            } else if (ast.op === '||') {
                return runValue(ast.lhs, envStack) || runValue(ast.rhs, envStack)
            } else if (ast.op === '==') {
                return runValue(ast.lhs, envStack) === runValue(ast.rhs, envStack)
            } else if (ast.op === '<=') {
                return runValue(ast.lhs, envStack) <= runValue(ast.rhs, envStack)
            } else if (ast.op === '>=') {
                return runValue(ast.lhs, envStack) >= runValue(ast.rhs, envStack)
            } else if (ast.op === '.') {
                const v = findInEnvStack(ast.lhs.value, envStack)
                if (v) {
                    const obj = v.value
                    //const value = runValue(obj.fields.find(e => e.identity.value === ast.rhs.value).value)
                    return obj[ast.rhs.value]
                    //console.log("value", value)
                    //return value
                } else {
                    //novalue
                }
            }
        } else if (ast.type === Ast.FUNCTION_CALL) {
            //console.log(ast)
            return runFunction(ast, envStack)
        } else if (ast.type === Ast.FUNCTION) {
            //console.log(ast)
            //TODO deal with function
            return ast
        }
    }

    // Run function call
    const runFunction = (ast, envStack) => {
        if (ast.type === Ast.FUNCTION) {
            const fun = ast
            /*
            for (let i = 0; i < fun.parameters.length; i++) {
                env.set(fun.parameters[i], runValue(ast.parameters[i]))
            }
                */
            const result = runStatements(fun.body, envStack)

            if (result.type === Ast.FUNCTION) {
                result.callbackEnv = new Map();

                for (let i = 0; i < fun.parameters.length; i++) {
                    //result.callbackEnv.set()
                    result.callbackEnv.set(fun.parameters[i], runValue(ast.parameters[i]))
                }

            }

            return result
        } else if (ast.name?.value === 'print') {
            const result = runValue(ast.parameters[0], envStack);
            process.stdout.write(result + '')
            return
        } else if (ast.fun.type === Ast.IDENTITY) {
            const v = findInEnvStack(ast.fun.value, envStack)
            if (v) {
                const fun = v.value
                const env = new Map()
                envStack.push(env)
                for (let i = 0; i < fun.parameters.length; i++) {
                    env.set(fun.parameters[i], runValue(ast.parameters[i]))
                }
                const result = runStatements(fun.body, envStack)

                if (result.type === Ast.FUNCTION) {
                    result.callbackEnv = new Map();

                    for (let i = 0; i < fun.parameters.length; i++) {
                        //result.callbackEnv.set()
                        result.callbackEnv.set(fun.parameters[i], runValue(ast.parameters[i]))
                    }

                }
                envStack.pop()

                return result
            }
        } else if (ast.fun.type === Ast.FUNCTION) {
            const env = new Map()
            envStack.push(env)
            for (let i = 0; i < ast.fun.parameters.length; i++) {
                env.set(ast.fun.parameters[i], runValue(ast.parameters[i], envStack))
            }
            const result = runStatements(ast.fun.body, envStack)

            if (result.type === Ast.FUNCTION) {
                result.callbackEnv = new Map();

                for (let i = 0; i < ast.fun.parameters.length; i++) {
                    //result.callbackEnv.set()
                    result.callbackEnv.set(ast.fun.parameters[i], runValue(ast.parameters[i]))
                }

            }

            envStack.pop()
            return result;
        } else if (ast.fun.type === Ast.FUNCTION_CALL) {
            console.log("function call")

            const result = runFunction(ast.fun, envStack)
            //TODO if funResult is function
            const env = new Map()
            envStack.push(env)
            for (let i = 0; i < result.parameters.length; i++) {
                env.set(result.parameters[i], runValue(ast.parameters[i], envStack))
            }
            //TODO need more investigate
            if (result.type === Ast.FUNCTION) {
                result.callbackEnv.forEach((value, key, map) => {
                    env.set(key, value);
                })
            }

            
            if (result.type === Ast.FUNCTION) {
                return runFunction(result, envStack)
            }
            
            envStack.pop()

            return result;
            /*
            const result = runStatements(funResult.body, envStack)

            if (result.type === Ast.FUNCTION) {
                result.callbackEnv = new Map();
                
                for (let i = 0; i < ast.fun.parameters.length; i++) {
                    //result.callbackEnv.set()
                    result.callbackEnv.set(ast.fun.parameters[i], runValue(ast.parameters[i]))
                }
                
            }

            envStack.pop()
            return result;
*/
            //return runFunction(ast.fun, envStack)
        }
    }

    const envStack = []
    envStack.push(new Map())
    runStatements(ast, envStack)
})()
const compiler = (() => {
    return
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
            if (functionCallExprAst.fun.type === Ast.IDENTITY) {
                let fun = functionCallExprAst.fun.value

                if (functionCallExprAst.fun.value === 'print') {
                    fun = 'process.stdout.write'
                }
                return `${fun}(${functionCallExprAst.parameters.map(e => e.accept(valueVisitor)).join(', ')})`
            } else if (functionCallExprAst.fun.type === Ast.FUNCTION) {
                return `${functionCallExprAst.name.value}(${functionCallExprAst.parameters.map(e => e.accept(valueVisitor)).join(', ')})`;
            } else if (functionCallExprAst.fun.type === Ast.FUNCTION_CALL) {
                return `${functionCallVisitor.visit(functionCallExprAst.fun)}(${functionCallExprAst.parameters.map(e => e.accept(valueVisitor)).join(', ')})`
                //return `${functionCallExprAst.name.value}(${functionCallExprAst.parameters.map(e => e.accept(valueVisitor)).join(', ')})`;
            }

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
        if (ifStmtAst.elseBody) {
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