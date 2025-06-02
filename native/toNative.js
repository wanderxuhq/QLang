import { runValue } from "../runtime/run-value.js";
import { equal, PrimeType } from "../type/constant.js";

const toNative = (ast) => {
    const env = ast.env
    const value = ast.value;
    if (ast.native) {
        return ast.value
    }
    //Type._check(PrimeType.Array, ast)

    if (equal(value.type, PrimeType.Array)) {
        return value.values.map(e => toNative(runValue(env)(e).value));
    } else if (equal(value.type, PrimeType.Boolean)) {
        return value.value
    } else if (equal(value.type, PrimeType.Number)) {
        return value.value
    } else if (equal(value.type, PrimeType.String)) {
        return value.value
    } else if (equal(value.type, PrimeType.Type)) {
        let obj = {};
        //runValue
        value.fields.forEach(e => obj[e.key.value] = e.value.value)
        return obj;
    } else if (equal(value.type, PrimeType.Object)) {
        let obj = {};
        //runValue
        value.fields.forEach(e => obj[e.key.value] = toNative(runValue(env)(e.value).value))
        return obj;
    } else if (equal(value.type, PrimeType.Function)) {
        if (!value.system) {
            return {
                parameters: value.parameters.map(e => e.variable),
                statements: value.body.statements
            };
        } else {
            return value.call;
        }
    }
}

export default toNative;