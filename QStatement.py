import re
from QNode import *
class QStatement:
    inputs = None
    nodes = None
    cutlength = 0
    variables = None
    pattern = re.compile(
        r"\s*((?P<cmt>\/\/.*)|(?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?P<num>((?<=[+-])[+-][0-9]+(\.[0-9]+)?)|([0-9]+)(\.[0-9]+)?)|(?P<alp>[A-Za-z][A-Za-z0-9]*)|(?P<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?P<dob>==|!=|<=|>=|&&|\|\|)|(?P<pnt>[.,/#!$%^&\*;:{}+-=_`~()><]))?"
    )
    def __init__(self, inputs, variables):
        self.inputs = inputs
        self.parse()
        self.variables = variables
    
    def cut(self, i):
        del(self.nodes[i])
        self.cutlength = self.cutlength + 1

    def boolvalue(self, node):
        return node.value == "true"

    def getvalue(self, node):
        if node.type == QNode.lexer['var'] and node.value not in QNode.keywords:
            return self.getvalue(self.variables[node.value])
        else:
            return node

    def reset(self, tokens):
        tokens.clear()
        self.cutlength = 0

    def parse(self):
            nodes = []
            for m in self.pattern.finditer(self.inputs):
                    if m.group('var') != None:
                        nodes.append(QNode(QNode.lexer['var'], m.group('var')))
                    elif m.group('num') != None:
                        nodes.append(QNode(QNode.lexer['num'], m.group('num')))
                    elif m.group('alp') != None:
                        nodes.append(QNode(QNode.lexer['alp'], m.group('alp')))
                    elif m.group('str') != None:
                        nodes.append(QNode(QNode.lexer['str'], m.group('str')))
                    elif m.group('dob') != None:
                        nodes.append(QNode(QNode.lexer['dob'], m.group('dob')))
                    elif m.group('pnt') != None:
                        nodes.append(QNode(QNode.lexer['pnt'], m.group('pnt')))
                    elif m.group('cmt') != None:
                        nodes.append(QNode(QNode.lexer['cmt'], m.group('cmt')))
                    #else:
                        #print("error")
            #print(tokens)
            self.nodes = nodes
            return nodes

    def execute(self, start, end):
        stack=[]
        i = start
        while i < end - self.cutlength:
            node = self.nodes[i]
            if node.value == "(":
                i = i + 1
                stack.append(i)
            elif node.value == ")":
                startpos = stack.pop()
                #print(startpos, i)
                if len(stack) == 0:
                    #print("call!")
                    k = self.execute(startpos, i)
                    self.cut(k)
                    self.cut(k - 2)
                    #end = end - 2
                    i = i - 1
                else:
                    i = i + 1
            else:
                i = i + 1
        i = start
        #for token in tokens:
        #    print(token.value)
        while i < end - self.cutlength:
            #print(i, end)
            #for token in tokens:
            #    print(token.value)
            node = self.nodes[i]
            #print(str(token.value)+" "+str(token.type))
            if node.value == "*":
                val = float(self.getvalue(self.nodes[i-1]).value) * float(self.getvalue(self.nodes[i+1]).value)
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val == int(val):
                    val = int(val)
                self.nodes[i].value=str(val)
            elif node.value == "/":
                val = float(self.getvalue(self.nodes[i-1]).value) / float(self.getvalue(self.nodes[i+1]).value)
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val == int(val):
                    val = int(val)
                self.nodes[i].value=str(val)
            else:
                i = i + 1

        i=start

        while i < end - self.cutlength:
            node = self.nodes[i]
            #print(str(token.value)+" "+str(token.type))
            if node.value == "+":
                val = float(self.getvalue(self.nodes[i-1]).value) + float(self.getvalue(self.nodes[i+1]).value)
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val == int(val):
                    val = int(val)
                self.nodes[i].value=str(val)
            elif node.value == "-":
                val = float(self.getvalue(self.nodes[i-1]).value) - float(self.getvalue(self.nodes[i+1]).value)
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val == int(val):
                    val = int(val)
                self.nodes[i].value=str(val)
            else:
                i = i + 1
        
        i = start
        while i < end - self.cutlength:
            node = self.nodes[i]
            if node.value == "==":
                val = self.getvalue(self.nodes[i-1]).value == self.getvalue(self.nodes[i+1]).value
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            elif node.value == "!=":
                val = self.getvalue(self.nodes[i-1]).value != self.getvalue(self.nodes[i+1]).value
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            elif node.value == ">":
                val = self.getvalue(self.nodes[i-1]).value > self.getvalue(self.nodes[i+1]).value
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            elif node.value == "<":
                val = float(self.getvalue(self.nodes[i-1]).value) < float(self.getvalue(self.nodes[i+1]).value)
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            elif node.value == ">=":
                val = self.getvalue(self.nodes[i-1]).value >= self.getvalue(self.nodes[i+1]).value
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            elif node.value == "<=":
                val = self.getvalue(self.nodes[i-1]).value <= self.getvalue(self.nodes[i+1]).value
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            else:
                i = i + 1

        i=start
        while i < end - self.cutlength:
            node = self.nodes[i]
            if node.value == "&&":
                val = self.boolvalue(self.getvalue(self.nodes[i-1])) and self.boolvalue(self.getvalue(self.nodes[i+1]))
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            else:
                i = i + 1
        i=start
        while i < end - self.cutlength:
            node = self.nodes[i]
            if node.value == "||":
                val = self.boolvalue(self.getvalue(self.nodes[i-1])) or self.boolvalue(self.getvalue(self.nodes[i+1]))
                self.cut(i+1)
                self.cut(i-1)
                #end = end - 2
                i = i - 1
                if val:
                    self.nodes[i].value = "true"
                else:
                    self.nodes[i].value = "false"
            else:
                i = i + 1

        i=start
        while i < end - self.cutlength:
            node = self.nodes[i]
            if node.value == "=":
                self.variables[self.nodes[i-1].value] = self.getvalue(self.nodes[i+1])
                print(self.inputs)
                print(self.variables)
                #for line in traceback.format_stack():
                #    print(line.strip())
            i = i + 1

        return i

    def bool_true(self):
        self.execute(0, len(self.nodes))
        return len(self.nodes) == 1 and self.nodes[0].bool_true()