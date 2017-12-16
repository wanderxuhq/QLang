#import string
import re
import logging
import copy
from QNode import *
import traceback
logger=logging.getLogger("QLang")
logger.setLevel(10)
#print(logger.getEffectiveLevel())
#input="42/21+3+-8/(5-(2*1+2))"
#inputs=["a = 1","b=a","b=b+1","while(a<b){","c=42/21+3+-8/(5-(2+b*2))","d=5" ,"}"]
inputs=["a=0","b=5","c=0","k=0","d=0","while(a<=b){","i=0","while(i<20){","d=d+i","while(k<3){","k=k+1","}","i=i+1","}","c=c+a","a=a+1","}"]
#inputs=["a = 1","a=a+1"]
#inputs=["a=1","b=a+1","c=b>a&&false"]
#f=open('D:\\\\out.txt','w')
pattern = re.compile(
    r"\s*((?P<cmt>\/\/.*)|(?P<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?P<num>((?<=[+-])[+-][0-9]+(\.[0-9]+)?)|([0-9]+)(\.[0-9]+)?)|(?P<alp>[A-Za-z][A-Za-z0-9]*)|(?P<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?P<dob>==|!=|<=|>=|&&|\|\|)|(?P<pnt>[.,/#!$%^&\*;:{}+-=_`~()><]))?"
)
print(inputs)
#pattern="\s*((?P<num>[0-9]+)|([A-Za-z][A-Za-z0-9]*)|(\"(\\\\|\\\"|\\n|[^\"])*\")|(==|<=|>=|&&|\|\|)|([.,/#!$%^&\*;:{}+-=_`~()])|(\/\/.*))?"
#num, character, string, double punct, punct, comment
#0, a, "a0", ==, +, //
#m = pattern.match(input)
lexer = {'var':0, 'num':1, 'alp':2, 'str':3, 'dob':4, 'pnt':5, 'cmt':6}
keywords = ["true", "false"]
cutlength = 0
variables = {}

def cut(tokens, i):
    global cutlength
    del(tokens[i])
    cutlength = cutlength + 1

def boolvalue(token):
    return token.value == "true"

def getvalue(token):
    if token.type == lexer['var'] and token.value not in keywords:
        return getvalue(variables[token.value])
    else:
        return token

def reset(tokens):
    tokens.clear()
    global cutlength
    cutlength = 0

def execute(tokens, start, end):
    stack=[]
    global cutlength
    i = start
    while i < end - cutlength:
        token = tokens[i]
        if token.value == "(":
            i = i + 1
            stack.append(i)
        elif token.value == ")":
            startpos = stack.pop()
            #print(startpos, i)
            if len(stack) == 0:
                #print("call!")
                k = execute(tokens, startpos, i)
                cut(tokens, k)
                cut(tokens, k - 2)
                #end = end - 2
                i = i - 1
            else:
                i = i + 1
        else:
            i = i + 1
    i = start
    #for token in tokens:
    #    print(token.value)
    while i < end - cutlength:
        #print(i, end)
        #for token in tokens:
        #    print(token.value)
        token = tokens[i]
        #print(str(token.value)+" "+str(token.type))
        if token.value == "*":
            val = float(getvalue(tokens[i-1]).value) * float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        elif token.value == "/":
            val = float(getvalue(tokens[i-1]).value) / float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        else:
            i = i + 1

    i=start

    while i < end - cutlength:
        token = tokens[i]
        #print(str(token.value)+" "+str(token.type))
        if token.value == "+":
            val = float(getvalue(tokens[i-1]).value) + float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        elif token.value == "-":
            val = float(getvalue(tokens[i-1]).value) - float(getvalue(tokens[i+1]).value)
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val == int(val):
                val = int(val)
            tokens[i].value=str(val)
        else:
            i = i + 1
    
    i = start
    while i < end - cutlength:
        token = tokens[i]
        if token.value == "==":
            val = getvalue(tokens[i-1]).value == getvalue(tokens[i+1]).value
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        elif token.value == "!=":
            val = getvalue(tokens[i-1]).value != getvalue(tokens[i+1]).value
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        elif token.value == ">":
            val = getvalue(tokens[i-1]).value > getvalue(tokens[i+1]).value
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        elif token.value == "<":
            val = getvalue(tokens[i-1]).value < getvalue(tokens[i+1]).value
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        elif token.value == ">=":
            val = getvalue(tokens[i-1]).value >= getvalue(tokens[i+1]).value
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        elif token.value == "<=":
            val = getvalue(tokens[i-1]).value <= getvalue(tokens[i+1]).value
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        else:
            i = i + 1

    i=start
    while i < end - cutlength:
        token = tokens[i]
        if token.value == "&&":
            val = boolvalue(getvalue(tokens[i-1])) and boolvalue(getvalue(tokens[i+1]))
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        else:
            i = i + 1
    i=start
    while i < end - cutlength:
        token = tokens[i]
        if token.value == "||":
            val = boolvalue(getvalue(tokens[i-1])) or boolvalue(getvalue(tokens[i+1]))
            cut(tokens, i+1)
            cut(tokens, i-1)
            #end = end - 2
            i = i - 1
            if val:
                tokens[i].value = "true"
            else:
                tokens[i].value = "false"
        else:
            i = i + 1

    i=start
    while i < end - cutlength:
        token = tokens[i]
        if token.value == "=":
            variables[tokens[i-1].value] = getvalue(tokens[i+1])
            print(variables)
            #for line in traceback.format_stack():
            #    print(line.strip())
        i = i + 1

    return i
    

def parse(input):
    tokens = []
    for m in pattern.finditer(input):
            if m.group('var') != None:
                tokens.append(QNode(lexer['var'], m.group('var')))
            elif m.group('num') != None:
                tokens.append(QNode(lexer['num'], m.group('num')))
            elif m.group('alp') != None:
                tokens.append(QNode(lexer['alp'], m.group('alp')))
            elif m.group('str') != None:
                tokens.append(QNode(lexer['str'], m.group('str')))
            elif m.group('dob') != None:
                tokens.append(QNode(lexer['dob'], m.group('dob')))
            elif m.group('pnt') != None:
                tokens.append(QNode(lexer['pnt'], m.group('pnt')))
            elif m.group('cmt') != None:
                tokens.append(QNode(lexer['cmt'], m.group('cmt')))
            #else:
                #print("error")
    #print(tokens)
    return tokens

def run(context, start, end):
    i = start
    stack = []
    while i < end:
        input = copy.deepcopy(context[i])
        curcontext = context[i]
        tokens = parse(input)
        if tokens[0].value == "if":
            stack.append(i)
            execute(tokens, 1, len(tokens))
            if tokens[1].value == "true":
                #while len(stack) > 0:
                    #i = i + 1
                if tokens[0].value == "}":
                    reset(tokens)
                    run(context, stack.pop(), i)
            else:#TODO else clause
                while len(stack) > 0:
                    i = i + 1
                    if parse(context[i])[0].value == "}":
                        stack.pop()
                    
        elif tokens[0].value == "while":
            stack.append(('wh',i))
                #while len(stack) > 0:
            tokens = parse(copy.deepcopy(context[i]))
        elif tokens[0].value == "}":
            mark = stack[len(stack) - 1]
            if mark[0] == "wh":
                subend = i
                i = mark[1]
                tokens = parse(copy.deepcopy(context[mark[1]]))
                execute(tokens, 1, len(tokens))
                ctokens = copy.deepcopy(tokens)
                reset(tokens)
                substart = stack[len(stack) - 1][1] + 1
                if ctokens[1].value == "true":
                    run(context, substart, subend)
                else:
                    stack.pop()
                    i = subend
            #elif mark[0] == "if":
                #TODO
            
        #else:
        #    stack.pop()
        #    i = subend

        elif tokens[0].type != 6:
            execute(tokens, 0, len(tokens))
        i = i + 1
        reset(tokens)
        #calc = copy.deepcopy(tokens)

run(inputs, 0, len(inputs))

#def execute end
#while len(tokens) > 1:
#execute(tokens, 0, len(tokens))
#print(len(tokens))
print("END!")
print(variables)
        
    #m = pattern.match(input)
    
#for m in re.match(pattern, input):
#    print(m.group('num'))
    #f.write(token[0]+"\n")
#f.close()
#if __name__ == "main":
