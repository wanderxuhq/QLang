import { PrimeType } from "../type/constant.js";

const toNative = (ast) => {
    if (ast.type === PrimeType.Array) {
        return ast.values.map(e => toNative(e.result.value));
    } else if (ast.type === PrimeType.Boolean) {
        return ast.value
    } else if (ast.type === PrimeType.Number) {
        return ast.value
    } else if (ast.type === PrimeType.String) {
        return ast.value
    } else if (ast.type === PrimeType.Object) {
        let obj = {};
        //TODO wrap or unwrap
        ast.fields.forEach(e => obj[e.variable.value] = toNative(e.value.value))
        return obj;
    }
}

export {
    toNative
}