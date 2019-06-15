import logging
#from QProgram import *
from QStatement import *
logging.basicConfig(format='[%(asctime)s, line %(lineno)d]: %(message)s',level=logging.DEBUG)
inputs = []
with open('demo/fibonacci.ql') as f:
    for line in f:
        inputs.append(line)
f.closed

#for input in inputs:
#    logging.debug(input)

#a = QBlock(None, inputs)
#a.compile()
##a.run({})
#print(a)

#p = QProgram(inputs)
#p.compile()
#logging.debug(p.functions)
#p.run()

#x=QExpression()
#a=QExpression()
#a.value=2
#b=QExpression()
#b.value=3
#x.children=[a,b]
#x=QExpression([[QNode(2,16),[QNode(2,25),QNode(2,94)]],[QNode(2,6),QNode(2,7)]])
#x.operation=Plus()
#x.run()
#print(x.node.value)
x=QStatement('((1+2+3.5*4)**5+(6+7*8))+(9)')
#x=QStatement('1+2')
x.run()