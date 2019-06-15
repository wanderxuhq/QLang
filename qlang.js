//(function(){
//var pattern = /\s*((\/\/.*)|([_$A-Za-z][_\$A-Za-z0-9]*)|([0-9]+(\.[0-9]+)?)|(\"(\\\\|\\\"|\\n|[^\"])*\")|(\*\*|==|!=|<=|>=|&&|\|\||[.,/#!$%^&\*;:{}+-=_`~()><]))?/g;

class QNode{
	constructor(type, value){
		this.type = type;
		this.value = value;
	}
	static NUM = 1;
	static CHAR = 2;
	static STR = 3;
	static VAR = 4;
	static PNT = 5;
}

function QStatement(inputs, variables){
	this.inputs = inputs;
	this.variables = variables || {};
	this.pattern = /\s*((?<cmt>\/\/.*)|(?<var>[_$A-Za-z][_\$A-Za-z0-9]*)|(?<num>[0-9]+(\.[0-9]+)?)|(?<str>\"(\\\\|\\\"|\\n|[^\"])*\")|(?<pnt>\*\*|==|!=|<=|>=|&&|\|\||[.,/#!$%^&\*;:{}+-=_`~()><]))?/g;
	
	this.run = function(){
		var nodes = [];
		do{
			var m = this.pattern.exec(this.inputs);
			if (m.groups['var'] !== undefined){
				//if m.group('var') in QUtil.keywords:
				//    nodes.append(m.group('var'))
				//else:
				nodes.push(new QNode(QNode.VAR, m.groups['var']));
			} else if (m.groups['num'] != null){
				nodes.push(new QNode(QNode.NUM, m.groups['num']));
			} else if (m.groups['str'] != null){
				nodes.push(new QNode(QNode.STR, m.groups['str']));
			} else if (m.groups['pnt'] != null){
				nodes.push(new QNode(QNode.PNT, m.groups['pnt']));
			}
		} while(m.index < inputs.length);
		return this.execute(nodes)[0];
	}
	
	this.execute = function(nodes){
		console.log(this.inputs, nodes);
		var exp = [{predicate: null}];
		var length = nodes.length;
		var n = 0;
		while (n < length){
			var node = nodes[n];
			console.log(node);
			if (node.value == '('){
				[exp[exp.length - 1]['noun'], skip] = this.execute(nodes.slice(n + 1, nodes.length));
				console.log(exp[exp.length - 1], skip);
				n = n + skip;
			} else if (node.value == ')'){
				length = n + 1;
				break;
			} else if (node.type == QNode.VAR || node.type == QNode.NUM || node.type == QNode.STR){
				exp[exp.length - 1]['noun'] = node;
			} else if (node.type == QNode.PNT){
				if (exp[exp.length - 1]['predicate'] !== null && this.Operation[exp[exp.length - 1]['predicate']]['priority'] >= this.Operation[node.value]['priority']){
					for(var i = exp.length - 1; i > 0; i--){
						console.log('hit!');
						exp[i - 1]['noun'] = new QNode(QNode.NUM, this.Operation[exp[i]['predicate']]['apply'](parseFloat(exp[i - 1]['noun'].value), parseFloat(exp[i]['noun'].value)));
					}
					exp = [{'predicate': null, 'noun': exp[0]['noun']}];
				}
				exp.push({'predicate': node.value})
			}
			n = n + 1;
		}
		if (exp.length > 1){
			for(var i = exp.length - 1; i > 0; i--){
				console.log('hit!');
				exp[i - 1]['noun'] = new QNode(QNode.NUM, this.Operation[exp[i]['predicate']]['apply'](parseFloat(exp[i - 1]['noun'].value), parseFloat(exp[i]['noun'].value)))
			}
		}
		console.log(exp[0], length);
		return [exp[0]['noun'], length];	
	}
	
	this.Operation = {
		'+': {'priority': 1, 'apply': (x, y) => x + y},
		'-': {'priority': 1, 'apply': (x, y) => x - y},
		'*': {'priority': 2, 'apply': (x, y) => x * y},
		'/': {'priority': 2, 'apply': (x, y) => x / y},
		'**': {'priority': 3, 'apply': (x, y) => x ** y},
		'=': {'priority': 0, 'apply': (x, y) => {this.variables[variable] = value;}}
	}
}

//})();
