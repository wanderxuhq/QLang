import { Ast } from "../ast/index.js";
import { PrimeType, equal } from "../type/constant.js";
import { makeRunValueInput, runValue } from "./run-value.js";

const toNative = (ast) => {
    const env = ast.env
    const value = ast.value;

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
        value.fields.forEach(e => obj[e.variable.value] = e.value.value)
        return obj;
    } else if (equal(value.type, PrimeType.Object)) {
        let obj = {};
        //runValue
        value.fields.forEach(e => obj[e.variable.value] = toNative(runValue(env)(e.value).value))
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

const trueTypeOf = (obj) => Object.prototype.toString.call(obj).slice(8, -1).toLowerCase()

const fromNative = (value) => {
    const type = trueTypeOf(value);
    let result = undefined;
    if (type === 'boolean') {
        result = {
            type: PrimeType.Boolean,
            value: value
        }
    } else if (type === 'number') {
        result = {
            type: PrimeType.Number,
            value: value
        }
    } else if (type === 'string') {
        result = {
            type: PrimeType.String,
            value: value
        }
    } else if (type === 'object') {
        let fields = [];
        for (const field in value) {
            fields.push(
                {
                    variable: {
                        type: Ast.IDENTITY,
                        value: field
                    },
                    value: fromNative(value[field])
                }
            )
        }
        result = {
            type: PrimeType.Object,
            fields: fields
        }
    } else if (type === 'function') {
        return {
            type: Ast.VALUE,
            native: true,
            value: value
        }
    }

    return {
        type: Ast.VALUE,
        value: result
    }
}

const wrap = (value) => {
    return {
        type: Ast.VALUE,
        native: true,
        value: value
    }
}

const unwrap = (value) => {
    return value.value;
}

export {
    toNative, fromNative, wrap, unwrap
}