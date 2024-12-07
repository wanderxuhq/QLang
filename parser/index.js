import fs from 'fs';
//const source = fs.readFileSync('./demo/declare.ql', 'utf-8');

import {
    parseStatementsAst
} from './parse-statement-ast.js'
import rootEnv from '../env.js';


//const result = parseStatementsAst({ context: context })(source)(0);
//fs.writeFileSync("output.json", JSON.stringify(result, null, 2));

export default (source) => {
    const result = parseStatementsAst(rootEnv)(
        source
    )(0);
    fs.writeFileSync("output.json", JSON.stringify(result, null, 2));  
    return result;
};