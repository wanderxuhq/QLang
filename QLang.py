#import string
import logging
from QProgram import *
logging.basicConfig(format='[%(asctime)s, line %(lineno)d]: %(message)s',level=logging.DEBUG)
inputs = []
with open('demo/function.ql') as f:
    for line in f:
        inputs.append(line)
f.closed

for input in inputs:
    logging.debug(input)

#a = QBlock(None, inputs)
#a.compile()
##a.run({})
#print(a)

p = QProgram(inputs)
p.compile()
#logging.debug(p.functions)
p.run()