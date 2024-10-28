class Ast {
    type
    index
    row
    col
    parent
    context

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
    static IDENTITY_PATH = 'IDENTITY_PATH';
    static ARRAY = 'ARRAY';
    static IDENTITY_INDEX = 'IDENTITY_INDEX';
    static FUNCTION = 'FUNCTION';
    static FUNCTION_CALL = 'FUNCTION_CALL';
    static PARENTHESIS_LIST = 'PARENTHESIS_LIST';
    static COMMA_LIST = 'COMMA_LIST';
    static BIN_OP = 'BIN_OP';
    static VALUE = 'VALUE';

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
            type: Ast.STATEMENTS,
            statements: this.statements.map(e => e.toObject())
        }
    }

    toValue() {
        return {
            type: Ast.STATEMENTS,
            statements: this.statements.map(statement => statement.toValue())
        };
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
            type: Ast.DECLARE,
            declareType: this.declareType,
            variable: this.variable,
            value: this.value.toObject()
        }
    }

    toValue() {
        return {
            type: Ast.DECLARE,
            variable: this.variable,
            value: this.value.toValue()
        };
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
            type: Ast.ASSIGN,
            variable: this.variable,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.ASSIGN,
            variable: this.variable,
            value: this.value.toValue()
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
            type: Ast.RETURN,
            value: this.value.toObject()
        }
    }

    toValue() {
        return {
            type: Ast.RETURN,
            value: this.value.toValue()
        };
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
            type: Ast.IF,
            matchBodies: this.matchBodies,
            elseBody: this.elseBody
        }
    }

    toValue() {
        return {
            type: Ast.IF,
            //TODO
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
            type: Ast.WHILE,
            condition: this.condition,
            body: this.body
        }
    }

    toValue() {
        return {
            type: Ast.WHILE,
            condition: this.condition.toValue(),
            body: this.body.toValue()
        }
    }
}


class ExprAst extends Ast {
}

class ValueAst extends Ast {
    constructor(subType) {
        super(Ast.VALUE)
        this.subType = subType
    }
}

class NumberValueAst extends ValueAst {
    value
    constructor(value) {
        super(Ast.NUMBER)
        this.value = value
    }

    toObject() {
        return {
            type: Ast.NUMBER,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.NUMBER,
            value: this.value
        }
    }
}

class BooleanValueAst extends ValueAst {
    value
    constructor(value) {
        super(Ast.BOOLEAN)
        this.value = value
    }

    toObject() {
        return {
            type: Ast.BOOLEAN,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.BOOLEAN,
            value: this.value
        }
    }
}

class StringValueAst extends ValueAst {
    value
    constructor(value) {
        super(Ast.STRING)
        this.value = value
    }

    toObject() {
        return {
            type: Ast.STRING,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.STRING,
            value: this.value
        }
    }
}

class ObjectValueAst extends ValueAst {
    fields
    constructor(fields) {
        super(Ast.OBJECT)
        this.fields = fields
    }

    toObject() {
        return {
            type: Ast.OBJECT,
            fields: this.fields
        }
    }

    toValue() {
        return {
            type: Ast.OBJECT,
            fields: this.fields.map(field => {
                return {
                    identity: field.identity.toValue(),
                    type: field.type?.toValue(),
                    value: field.value.toValue()
                }
            })
        }
    }
}

class IdentityValueAst extends ValueAst {
    value
    constructor(value) {
        super(Ast.IDENTITY)
        this.value = value
    }

    toObject() {
        return {
            type: Ast.IDENTITY,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.IDENTITY,
            value: this.value
        }
    }
}

class IdentityPathExprAst extends ExprAst {
    path
    constructor(value) {
        super(Ast.IDENTITY_PATH)
        this.path = value
    }

    toObject() {
        return {
            type: Ast.IDENTITY_PATH,
            value: this.path
        }
    }

    toValue() {
        return {
            type: Ast.IDENTITY_PATH,
            value: this.path
        }
    }
}

class ArrayValueAst extends ValueAst {
    constructor(value) {
        super(Ast.ARRAY)
        this.value = value
    }

    toObject() {
        return {
            type: Ast.ARRAY,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.ARRAY,
            value: this.value.map(item => item.toValue())
        }
    }
}

class IdentityIndexExprAst extends ExprAst {
    constructor(name, value) {
        super(Ast.IDENTITY_INDEX)
        this.name = name
        this.value = value
    }

    toObject() {
        return {
            type: Ast.IDENTITY_INDEX,
            value: this.value
        }
    }

    toValue() {
        return {
            type: Ast.IDENTITY_INDEX,
            value: this.value
        }
    }
}

class FunctionValueAst extends ValueAst {
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

    toValue() {
        return {
            type: Ast.FUNCTION,
            parameters: clone(this.parameters),
            body: this.body.toValue()
        }
    }
}

class FunctionCallAst extends ValueAst {
    fun
    parameters
    constructor(fun, parameters) {
        super(Ast.FUNCTION_CALL)
        this.fun = fun
        this.parameters = parameters
    }

    toObject() {
        return {
            type: Ast.FUNCTION_CALL,
            fun: this.fun.toObject(),
            parameters: this.parameters
        }
    }

    toValue() {
        return {
            type: Ast.FUNCTION_CALL,
            fun: this.fun.toValue(),
            parameters: this.parameters.map(parameter => parameter.toValue())
        }
    }
}

class BinOpValueAst extends ValueAst {
    op
    lhs
    rhs
    constructor(op, lhs, rhs) {
        super(Ast.BIN_OP)
        this.op = op.type;
        this.lhs = lhs;
        this.rhs = rhs;
    }

    toObject() {
        return {
            type: Ast.BIN_OP,
            op: this.op,
            lhs: this.lhs,
            rhs: this.rhs
        }
    }

    toValue() {
        return {
            type: Ast.BIN_OP,
            op: this.op,
            lhs: this.lhs.toValue(),
            rhs: this.rhs.toValue()
        }
    }
}

export {
    Ast,
    StmtsAst,
    DeclareStmtAst,
    AssignStmtAst,
    ValueAst,
    NumberValueAst,
    StringValueAst,
    BooleanValueAst,
    IdentityValueAst,
    IdentityPathExprAst,
    IdentityIndexExprAst,
    BinOpValueAst,
    IfStmtAst,
    WhileStmtAst,
    FunctionValueAst,
    FunctionCallAst,
    ObjectValueAst,
    ArrayValueAst,
    ReturnStmtAst
}
