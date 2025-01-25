import { Ast } from "../ast/index.js"

const PrimeType = {
    Boolean: {type: Ast.IDENTITY, value: 'Boolean'},
    Number: {type: Ast.IDENTITY, value: 'Number'},
    String: {type: Ast.IDENTITY, value: 'String'},
    Type: {type: Ast.IDENTITY, value: 'Type'},
    Object: {type: Ast.IDENTITY, value: 'Object'},
    Array: {type: Ast.IDENTITY, value: 'Array'},
    Function: {type: Ast.IDENTITY, value: 'Function'},
    Void: {type: Ast.IDENTITY, value: 'Void'},
}

const equal = (t1, t2) => {
    if (t1 === t2) {
        return true;
    }

    let t1Type;
    if (t1.type === Ast.IDENTITY) {
        t1Type = t1.value;
    }
    let t2Type;
    if (t2.type === Ast.IDENTITY) {
        t2Type = t2.value;
    }

    if (t1Type && t2Type) {
        if (t1Type === t2Type) {
            return true;
        }
    }

    if (t1.type === Ast.VALUE) {
        if (t1.value.secondaryType === 'FunctionSign') {
            return equal(t2, PrimeType.Function)
        }
    }
    if (t2.type === Ast.VALUE) {
        if (t2.value.secondaryType === 'FunctionSign') {
            return equal(t1, PrimeType.Function)
        }
    }
    return false;
}

export {
    PrimeType, equal
}