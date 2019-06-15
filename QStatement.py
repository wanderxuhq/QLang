import re
from QNode import *
#from QOperation import *
#from QExpression import *
class QStatement:
    pattern = re.compile(
        r"\s*((?P<cmt>\/\/.*)|(?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?P<num>[0-9]+(\.[0-9]+)?)|(?P<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?P<pnt>\*\*|==|!=|<=|>=|&&|\|\||[.,/#!$%^&\*;:{}+-=_`~()><]))?"
    )

    inputs = None
    variables = {}
    def __init__(self, inputs):
        self.inputs = inputs
        #self.parse()
        #self.opstack = [0]
    
    def __str__(self):
        return str(self.inputs)
    def __repr__(self):
        return str(self.inputs)

    def boolvalue(self, node):
        return node.value == "true"

    def run(self):
            nodes = []
            for m in self.pattern.finditer(self.inputs):
                    if m.group('var') != None:
                        #if m.group('var') in QUtil.keywords:
                        #    nodes.append(m.group('var'))
                        #else:
                        nodes.append(QNode(QNode.VAR, m.group('var')))
                    elif m.group('num') != None:
                        nodes.append(QNode(QNode.NUM, m.group('num')))
                    elif m.group('str') != None:
                        nodes.append(QNode(QNode.STR, m.group('str')))
                    elif m.group('pnt') != None:
                        nodes.append(QNode(QNode.PNT, m.group('pnt')))
                    #elif m.group('cmt') != None:
                    #    nodes.append(QNode(TokenType.CMT, m.group('cmt')))
                    #else:
                        #print("error")
            #print(tokens)
            #parent_stack = [{'predicate': None}]
            print(self.execute(nodes))

    def execute(self, nodes):
        exp = [{'predicate': None}]
        length = len(nodes)
        n = 0
        while n < length:
            node = nodes[n]
            print(node)
            if node.value == '(':
                exp[len(exp) - 1]['noun'], skip = self.execute(nodes[n + 1: len(nodes)])
                n = n + skip
            elif node.value == ')':
                length = n + 1
                break
            elif node.type == QNode.VAR or node.type == QNode.NUM or node.type == QNode.STR:
                exp[len(exp) - 1]['noun'] = node
            elif node.type == QNode.PNT:
                if exp[len(exp) - 1]['predicate'] != None and self.Operation[exp[len(exp) - 1]['predicate']]['priority'] >= self.Operation[node.value]['priority']:
                    for i in range(len(exp) - 1, 0, -1):
                        exp[i - 1]['noun'] = QNode(QNode.NUM, self.Operation[exp[i]['predicate']]['apply'](float(exp[i - 1]['noun'].value), float(exp[i]['noun'].value)))
                    exp = [{'predicate': None, 'noun': exp[0]['noun']}]
                exp.append({'predicate': node.value})
            n = n + 1
        if len(exp) > 1:
            for i in range(len(exp) - 1, 0, -1):
                exp[i - 1]['noun'] = QNode(QNode.NUM, self.Operation[exp[i]['predicate']]['apply'](float(exp[i - 1]['noun'].value), float(exp[i]['noun'].value)))
        return exp[0]['noun'], length

    def assign(self, var, value):
        self.variables[var] = value

    Operation = {
        '+': {'priority': 1, 'apply': lambda x, y: x + y},
        '-': {'priority': 1, 'apply': lambda x, y: x - y},
        '*': {'priority': 2, 'apply': lambda x, y: x * y},
        '/': {'priority': 2, 'apply': lambda x, y: x / y},
        '**': {'priority': 3, 'apply': lambda x, y: x ** y},
        '=': {'priority': 0, 'apply': lambda x, y: self.assign(x, y)}
    }
