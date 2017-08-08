var log = console.log.bind(console);
var debug = console.debug.bind(console);
var err = console.error.bind(console);

(function(){
	
}());

var TYPE = {
	NUMBER: 1,
	STRING: 2,
}
var variables = new Map();

function core(){
	var text = document.getElementById("input").value;
	var statements = text.split("\n");
	//log(statements);
	for(statement of statements){
		//log(statement);
		execute(statement);
	}
}

function calExp(tokens){
	var matches = [
		['(','[','{'],
		[')',']','}']
	];
	
	var operation = new Map([
		['+', function(a, b){
			return a + b;
		}]
	]);
	
	var matchStack = [];
	var operationMark = undefined;
	var laseValue = undefined;
	for(var i in tokens){
		var t = tokens[i];
	var uindex = matches[0].indexOf(t);
	var oindex = matches[1].indexOf(t);
		if(uindex != -1){
			var u = matches[0][uindex];
			matchStack.push({t, i});
		} else if(oindex != -1){
			var o = matches[1][oindex];
			if(t === o){
				tokens = tokens.splice(matchStack[matches[0][oindex]].i,i,calExp(tokens.slice(matchStack[matches[0][oindex]].i,i)));
				matchStack.pop();
			}
		} else if(operation.has(t)) {
			operationMark = t;
			
		} else {
			if(operationMark != undefined){
				r = operation.get(operationMark)(getValue(laseValue),  getValue(t));
				log(r);
			}
			else{
				laseValue = t;
			}
			//tokens[i] = getValue(t);
		}
	}
//	console.log(matchStack);
}


/*
var matches = [
	['(','[','{'],
	[')',']','}']
];
	
function calExp(tokens){
	var tokenStack = [];
	for(var i in tokens){
		var t = tokens[i];
	var uindex = matches[0].indexOf(t);
	var oindex = matches[1].indexOf(t);
		if(uindex != -1){
			var u = matches[0][uindex];
			matchStack.push({t, i});
		} else if(oindex != -1){
			var o = matches[1][oindex];
			if(t === o){
				tokens = tokens.splice(matchStack[matches[0][oindex]].i,i,calExp(tokens.slice(matchStack[matches[0][oindex]].i,i)));
				matchStack.pop();
			}
		} else if(operation.has(t)) {
			
		} else {
			tokens[i] = getValue(t);
		}
	}
}
*/

function execute(originStatement){
	var statement = originStatement.replace(/\s/g,'');
	var tokens = statement.split(/\b/);
	//log(tokens.length);
	if(tokens.length === 1)
		variables.set(tokens[0], undefined)
	else if(tokens[1] === "="){
		var variable = tokens.shift();
		variables.set(variable, undefined);
		var value = tokens;
		value.shift();
		assignment(variable, value);
	}else if(tokens[0] === "if"){
		var bool = calExp(tokens.slice(1,tokens.length));
	}else{
		var cmd = tokens.shift();
		var parameters = tokens;
		command(cmd, parameters);
	}
}

function assignment(variable, value){
	if(constVal(value) > 0){
		variables.set(variable, value);
	} else{
		var val = variables.get(value[0]);
		if (val != undefined){
			variables.set(variable, value[0]);//chain
			//variables.set(variable, val);//value
		}
	}
	debug(variable + ": " + variables.get(variable));
}

function constVal(variable){
	if(variable === undefined){
		return 0
	}
	var reg = /^(\d+)|('(\\'|\\[A-Za-z]|\\\\|[^'])+')$/
	var type = reg.exec(variable);
	if (type === null){
		return 0;
	}
	if(type[1] != undefined) {
		return TYPE.NUMBER;
	} else if(type[2] != undefined) {
		return TYPE.STRING;
	} else {
		return 0;
	}
}

function getValue(v){
	if(constVal(v) === TYPE.NUMBER){
		return parseInt(v);
	} else if(constVal(v) === TYPE.STRING){
		return v;
	}
	else {
		var value = variables.get(v);
		if (value != undefined){
			valueType = constVal(value);
			if(valueType  === TYPE.NUMBER){
				return parseInt(value);
			} else if(valueType === TYPE.STRING){
				return value;
			} else {
				return getValue(value);
			}
		}
	} 
}

function command(cmd, parameters){
	if(cmd === 'print'){
		debug(" result: " + calExp(parameters));
	} else if (cmd === 'add'){
		var sum = 0;
		for(var num of parameters){
			sum += parseInt(num);
		}
		debug("result: " + sum);
	}
}