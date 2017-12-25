#import string
import logging
from QBlock import *
logging.basicConfig(format='[%(asctime)s, line %(lineno)d]: %(message)s',level=logging.DEBUG)
inputs = []
with open('demo/iftest.ql') as f:
    for line in f:
        inputs.append(line)
f.closed

logging.debug(inputs)

a = QBlock(None, inputs)
a.compile()
a.run({})


#def execute end
#while len(tokens) > 1:
#execute(tokens, 0, len(tokens))
#print(len(tokens))
#print("END!")
#print(a.variables)
#print(a)
#print(a.sub_blocks)
        
    #m = pattern.match(input)
    
#for m in re.match(pattern, input):
#    print(m.group('num'))
    #f.write(token[0]+"\n")
#f.close()
#if __name__ == "main":
