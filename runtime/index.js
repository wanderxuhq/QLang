import rootEnv from '../env.js';
import parse from '../parser/index.js';
import runStatements from './run-statements.js';

runStatements(rootEnv)(parse('./demo/exp.ql'));
