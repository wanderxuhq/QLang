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
                    sub_block.compile()
                    self.sub_blocks.append(sub_block)
            elif len(stack) == 0:
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
            if isinstance(sub_block, QBlock):
                if sub_block.meta[0].value == "if":
                    stmt = copy.deepcopy(sub_block.meta[1])
                    stmt.variables = self.variables
                    if stmt.bool_true():
                        sub_block.run(variables)
                elif sub_block.meta[0].value == "while":
                    stmt = copy.deepcopy(sub_block.meta[1])
                    stmt.variables = variables
                    while stmt.bool_true():
                        sub_block.run(variables)
                        stmt = copy.deepcopy(sub_block.meta[1])
                        stmt.variables = variables
            else:
                sub_block.execute(0, len(sub_block.nodes), variables)
            i = i + 1
