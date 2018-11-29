from QOperation import *
from QNode import *
class QExpression:
    parent = None
    operation = None
    node = None
    children = None
    has_val = False
    def __init__(self, v):
        #if type(v) is QExpression:
        #    self.children.append(v)
        self.children = []
        self.operation=Plus()
        if isinstance(v, QNode):
            self.node = v
            self.has_val = True
        elif type(v) is list:
            for i in range(len(v)):
                c = QExpression(v[i])
                c.parent = self
                self.children.append(c)

    def run(self):
        for i in range(len(self.children)):
            if not self.children[i].has_val:
                self.children[i].run()
        self.node = self.operation.execute(self.children)
        self.has_val = True
        #for i in range(self.childred):
        #    self.children[i].run()

    def add_children(self, c):
        c.parent = self
        self.children.append(c)
        return self

    def set_parent(self, p):
        pass