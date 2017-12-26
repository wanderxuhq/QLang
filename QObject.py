import copy
from QStatement import *
from QBlock import *
class QObject:
    
    def __init__(self, inputs):
        self.inputs = inputs

    variables = {}
    functions = {}

    def compile(self):
        i = 0
        stack = []
        while i < len(self.inputs):
            input = copy.deepcopy(self.inputs[i])
            
            stmt = QStatement(self.inputs[i])
            if "{" in input:
                stmt = QStatement(input[0: len(input) - 1])
                try:
                    parms = input[input.index("("): input.rindex(")") + 1 ]
                except ValueError:
                    parms = ""
                stack.append((i + 1, stmt.nodes[0], parms))
                

            elif "}" in input:
                infos = stack.pop()
                if len(stack) == 0:
                    sub_block = QBlock([infos[1], QStatement(infos[2])], self.inputs[ infos[0]: i ])
                    sub_block.compile()
                    self.sub_blocks.append(sub_block)
            elif len(stack) == 0:
                stmt = QStatement(self.inputs[i])
                self.sub_blocks.append(stmt)
            i = i + 1