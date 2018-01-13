from QStatement import *
class QFunction:
    name = None
    parameters = None
    body = None

    def __init__(self, name, parameters, body):
        self.name = name
        self.parameters = self.parse_parameter(parameters)
        self.body = body

    def parse_parameter(self, input):
        parameters = []
        pattern = re.compile(
            r"(?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)"
        )
        for m in pattern.finditer(input):
            parameters.append(QNode(QUtil.TokenType.VAR, m.group('var')))
        return parameters

    def call(self, caller, params, functions):
        #i = 2
        k = 0
        #params = []
        variables = {}
        #while i < len(caller.nodes) - 1:
        #    params.append(caller.nodes[i].getvalue(caller.nodes[i].value))
        #    i = i + 2
        #    k = k + 1
        i = 0
        while i < len(self.parameters):
            variables[self.parameters[i].value] = params[i]
            i = i + 1
        return self.body.run(variables, functions)
    def __str__(self):
        return str(self.name) + ", " + str(self.parameters) + ", "  + str(self.body)
    def __repr__(self):
        return str(self.name) + ", " + str(self.parameters) + ", "  + str(self.body)