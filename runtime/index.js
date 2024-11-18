import fs from 'fs';

import rootEnv from '../env.js';
import parse from '../parser/index.js';
import runStatements from './run-statements.js';
import { calculatePos } from '../util/pos.js';

const code = fs.readFileSync('./demo/exp.ql', 'utf-8');
const result = runStatements(rootEnv)(parse(code));
if (result.status.code !== 0) {
    console.log(result.status.message);
    console.log(code.substring(result.status.start), code.substring(result.status.start + 50))
    console.log(calculatePos(code, result.status.start))
}
