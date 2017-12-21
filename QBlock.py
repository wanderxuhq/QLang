import re
import copy
from QNode import *
from QStatement import *
class QBlock:
    inputs = None
    meta = None
    sub_blocks = []
    #(type, stmt, start, end)

    variables = {}
    
    def __init__(self, meta, inputs, variables):
        self.inputs = inputs
        self.sub_blocks = []
        self.variables = variables
        self.meta = meta
    
        
    def compile(self):
        i = 0
        stack = []
        while i < len(self.inputs):
            input = copy.deepcopy(self.inputs[i])
            
            stmt = QStatement(self.inputs[i], self.variables)
            if "{" in input:
                stmt = QStatement(input[0: len(input) - 1], self.variables)
                #self.sub_blocks.append((1,stmt))
                stack.append((i + 1, stmt.nodes[0], input[input.index("("): input.rindex(")") + 1 ]))
                #self.run()
            elif "}" in input:
                infos = stack.pop()
                if len(stack) == 0:
                    sub_block = QBlock([infos[1], QStatement(infos[2], self.variables)], self.inputs[ infos[0]: i ], self.variables)
                    self.sub_blocks.append(sub_block)
                    #sub_block.run()
                
            #if stmt.nodes[0].value == "if":
            #    stack.append(i)
            #    stmt.execute(1, len(stmt.nodes))
            #    if stmt.nodes[1].value == "true":
            #        #while len(stack) > 0:
            #            #i = i + 1
            #        if stmt.nodes[0].value == "}":
            #            sub_block = QBlock(self.inputs[stack.pop(), i + 1 ])
            #            self.sub_blocks.append((1, sub_block))
            #            #sub_block.run(self.inputs, stack.pop(), i)
            #    else:#TODO else clause
            #        while len(stack) > 0:
            #            
            #            if stmt.nodes[0].value == "}":
            #                self.sub_blocks.append((1,self.inputs[stack.pop(), i + 1 ]))
            #                stack.pop()
            #            i = i + 1
            #            
            #elif stmt.nodes[0].value == "while":
            #    stack.append(('wh',i))
            #        #while len(stack) > 0:
            #    stmt.nodes = parse(copy.deepcopy(context[i]))
            #elif stmt.nodes[0].value == "}":
            #    mark = stack[len(stack) - 1]
            #    if mark[0] == "wh":
            #        subend = i
            #        i = mark[1]
            #        stmt.nodes = parse(copy.deepcopy(context[mark[1]]))
            #        execute(stmt.nodes, 1, len(stmt.nodes))
            #        ctokens = copy.deepcopy(stmt.nodes)
            #        reset(stmt.nodes)
            #        substart = stack[len(stack) - 1][1] + 1
            #        if ctokens[1].value == "true":
            #            run(context, substart, subend)
            #        else:
            #            stack.pop()
            #            i = subend
            #    #elif mark[0] == "if":
            #        #TODO
            #    else:
            #        stack.pop()
            #        i = subend

            else:
                stmt = QStatement(self.inputs[i], self.variables)
                self.sub_blocks.append(stmt)
                #execute?
                #stmt.execute(0, len(stmt.nodes))
            i = i + 1
            #calc = copy.deepcopy(tokens)
    def run(self, variables):
        self.variables = variables
        i = 0
        while i < len(self.sub_blocks):
            sub_block = copy.deepcopy(self.sub_blocks[i])
            #if sub_block[0] == 0:
            #    sub_block[1].execute(0, len(sub_block[1].nodes))
            if isinstance(sub_block, QBlock):
                if sub_block.meta[0].value == "if":
                    stmt = copy.deepcopy(sub_block.meta[1])
                    stmt.variables = self.variables
                    if stmt.bool_true():
                        sub_block.run(variables)
                elif sub_block.meta[0].value == "while":
                    stmt = copy.deepcopy(sub_block.meta[1])
                    print("stmt")
                    stmt.variables = variables
                    while stmt.bool_true():
                        print(sub_block.sub_blocks)
                        sub_block.run(variables)
                        stmt = copy.deepcopy(sub_block.meta[1])
                        print(stmt.nodes)
                        stmt.variables = variables
                        print(stmt.variables)
                        print("while check")
                        
            else:
                print("execute check")
                sub_block.execute(0, len(sub_block.nodes), variables)
                #stmt = sub_block[1]
                #if stmt.nodes[0].value == "if":
                #    stmt.execute(1, len(stmt.nodes))
                #    if stmt.nodes[1].value == "true":
                #        self.sub_blocks[i+1][1].run()
                #    i = i + 1
                #elif stmt.nodes[0].value == "while":
                #    stmt.execute(1, len(stmt.nodes))
                #    while stmt.nodes[1].value == "true":
                #        if self.sub_blocks[i][0] != 2:
                #            i = i + 1
                #        else:
                #            self.sub_blocks[i][1].run()
                #        sub_block = copy.deepcopy(self.sub_blocks[i])
                #        stmt = sub_block[1]
                #        stmt.execute(1, len(stmt.nodes))
                #    i = i + 1
            print(i)
            i = i + 1
