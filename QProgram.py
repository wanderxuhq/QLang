import copy
from QStatement import *
from QBlock import *
from QFunction import *
class QProgram:
    
    def __init__(self, inputs):
        self.inputs = inputs

    functions = {}
    inputs = []
    def compile(self):
        i = 0
        stack = []
        while i < len(self.inputs):
            input = copy.deepcopy(self.inputs[i])
            
            stmt = QStatement(self.inputs[i])
            if "{" in input:
                stmt = QStatement(input[0: len(input) - 1])
                try:
                    parms = input[input.index("(") + 1: input.rindex(")") ]
                except ValueError:
                    parms = ""
                stack.append((i + 1, stmt.nodes[0], parms))
                

            elif "}" in input:
                infos = stack.pop()
                if len(stack) == 0:
                    self.functions[infos[1].value] = QFunction(infos[1].value, infos[2], QBlock(None, self.inputs[infos[0]: i]))
                    self.functions[infos[1].value].body.compile()
            i = i + 1

    def run(self):
        qf = self.functions["main"]
        qf.body.run({}, self.functions)