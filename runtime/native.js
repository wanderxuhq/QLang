import { Ast } from "../ast/index.js";
import { PrimeType } from "../type/constant.js";
import { makeRunValueInput, runValue } from "./run-value.js";

const toNative = (ast) => {
    const env = ast.env
    const value = ast.value
    if (value.type === PrimeType.Array) {
        return value.values.map(e => toNative(runValue(env)(e).value));
    } else if (value.type === PrimeType.Boolean) {
        return value.value
    } else if (value.type === PrimeType.Number) {
        return value.value
    } else if (value.type === PrimeType.String) {
        return value.value
    } else if (value.type === PrimeType.Object) {
        let obj = {};
        //runValue
        value.fields.forEach(e => obj[e.variable.value] = toNative(runValue(env)(e.value).value))
        return obj;
    } else if (value.type === PrimeType.Function) {
        return {
            parameters: value.parameters.map(e => e.variable),
            statements: value.body.statements
        };
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
        result = {
            type: 'Function',
            system: true,
            call: value,
        }
    }

    return {
        type: Ast.VALUE,
        value: result
    }
}

export {
    toNative, fromNative
}