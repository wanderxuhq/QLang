import { Ast } from "../ast/index.js"

const PrimeType = {
    Boolean: 'Boolean',
    Number: 'Number',
    String: 'String',
    Type: 'Type',
    Object: 'Object',
    Array: 'Array',
    Function: 'Function',
    Void: 'Void',
}

const equal = (t1, t2) => {
    return t1 === t2;
}

export {
    PrimeType, equal
}