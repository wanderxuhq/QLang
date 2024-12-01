import fs from 'fs';

import rootEnv from '../env.js';
import parse from '../parser/index.js';
import runStatements from './run-statements.js';
import { calculatePos } from '../util/pos.js';
import { Ast } from '../ast/index.js';

const code = fs.readFileSync('./demo/type.ql', 'utf-8');

const ast = parse(code)
const result = runStatements(rootEnv)(ast);
if (result.status.code !== 0) {
    console.log(result.status.message);
    console.log(code.substring(result.status.start), code.substring(result.status.start + 50))
    console.log(calculatePos(code, result.status.start))
}
