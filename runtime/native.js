import { Ast } from "../ast/index.js";
import { PrimeType } from "../type/constant.js";
import { makeRunValueInput } from "./run-value.js";

const toNative = (ast) => {
    if (ast.type === PrimeType.Array) {
        return ast.value.values.map(e => toNative(e.value));
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
    } else if (ast.type === PrimeType.Function) {
        return {
            parameters: ast.parameters.map(e => e.variable),
            statements: ast.body.statements
        };
    }
}

const trueTypeOf = (obj) => Object.prototype.toString.call(obj).slice(8, -1).toLowerCase()

const fromNative = (value) => {
    const type = trueTypeOf(value);
    if (type === 'boolean') {
        return {
            type: PrimeType.Boolean,
            value: value
        }
    } else if (type === 'number') {
        return {
            type: PrimeType.Number,
            value: value
        }
    } else if (type === 'string') {
        return {
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
                    value: makeRunValueInput(fromNative(value[field]))
                }
            )
        }
        return {
            type: PrimeType.Object,
            fields: fields
        }
    } else if (type === 'function') {
        return {
            type: 'Function',
            system: true,
            call: value,
        }
    }
}

export {
    toNative, fromNative
}