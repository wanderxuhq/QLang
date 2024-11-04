import { Ast } from "../ast/index.js";

const toNative = (ast) => {
    if (ast.subType === Ast.ARRAY) {
        return ast.values.map(e => toNative(e));
    } else if (ast.subType === Ast.BOOLEAN) {
        return ast.value
    } else if (ast.subType === Ast.NUMBER) {
        return ast.value
    } else if (ast.subType === Ast.STRING) {
        return ast.value
    }
}

export {
    toNative
}